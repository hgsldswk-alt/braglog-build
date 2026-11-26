import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct LocalDay: Codable, Hashable, Comparable, Sendable {
    let raw: String

    init(_ date: Date = Date(), calendar: Calendar = .journal) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        raw = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    init?(raw: String) {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), (1...9999).contains(year), let month = Int(parts[1]),
              let day = Int(parts[2]), let date = Calendar.utcJournal.date(from: DateComponents(
                year: year, month: month, day: day, hour: 12)),
              Self(date, calendar: .utcJournal).raw == raw else { return nil }
        self.raw = raw
    }

    func date(calendar: Calendar = .journal) -> Date {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date(timeIntervalSince1970: 0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
            ?? Date(timeIntervalSince1970: 0)
    }

    var display: String { date().formatted(date: .abbreviated, time: .omitted) }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        let value = try box.decode(String.self)
        guard let day = Self(raw: value) else {
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "Invalid local date")
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        try box.encode(raw)
    }
}

extension Calendar {
    static var journal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        return calendar
    }

    static var utcJournal: Calendar {
        var calendar = journal
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

struct Win: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var day = LocalDay()
    var createdAt = Date()
    var savedOrder = 0
    var action = ""
    var result = ""
    var metric = ""
    var project = ""
    var tags: [String] = []
    var roleID: UUID?
    var situation = ""
    var task = ""
    var photoID: UUID?

    var valid: Bool { !action.trimmed.isEmpty }

    mutating func prepare() {
        action = action.trimmed
        project = project.trimmed
        var seen = Set<String>()
        tags = tags.map(\.trimmed).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func matches(_ query: String) -> Bool {
        query.trimmed.isEmpty || ([action, result, metric, project] + tags).contains {
            $0.localizedStandardContains(query.trimmed)
        }
    }

    static func recent(_ lhs: Win, _ rhs: Win) -> Bool {
        if lhs.day != rhs.day { return lhs.day > rhs.day }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct Role: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = ""
    var organization = ""
    var start: LocalDay?
    var end: LocalDay?
    var archived = false

    var label: String { organization.trimmed.isEmpty ? title : "\(title) · \(organization)" }
    var valid: Bool {
        guard !title.trimmed.isEmpty else { return false }
        if let start, let end { return start <= end }
        return true
    }
}

enum Period: String, Codable, CaseIterable, Identifiable, Sendable {
    case week, month, quarter, custom
    var id: Self { self }
    var title: String { L.t("period." + rawValue) }

    func span(now: Date = Date(), calendar: Calendar = .journal) -> ClosedRange<LocalDay> {
        let today = LocalDay(now, calendar: calendar)
        let interval: DateInterval?
        switch self {
        case .week: interval = calendar.dateInterval(of: .weekOfYear, for: now)
        case .month: interval = calendar.dateInterval(of: .month, for: now)
        case .quarter:
            let parts = calendar.dateComponents([.year, .month], from: now)
            if let month = parts.month, let start = calendar.date(from: DateComponents(
                year: parts.year, month: ((month - 1) / 3) * 3 + 1, day: 1)),
               let end = calendar.date(byAdding: .month, value: 3, to: start) {
                interval = DateInterval(start: start, end: end)
            } else { interval = nil }
        case .custom: interval = nil
        }
        guard let interval else { return today...today }
        return LocalDay(interval.start, calendar: calendar)...LocalDay(
            interval.end.addingTimeInterval(-1), calendar: calendar)
    }
}

struct WinFilter: Codable, Equatable, Sendable {
    var period: Period = .quarter
    var start = LocalDay()
    var end = LocalDay()
    var roleID: UUID?
    var project: String?
    var tag: String?
    var query = ""
    var unrestricted = false

    func span(now: Date = Date(), calendar: Calendar = .journal) -> ClosedRange<LocalDay>? {
        if unrestricted { return nil }
        if period == .custom { return min(start, end)...max(start, end) }
        return period.span(now: now, calendar: calendar)
    }

    func apply(_ wins: [Win], now: Date = Date(), calendar: Calendar = .journal) -> [Win] {
        let range = span(now: now, calendar: calendar)
        return wins.filter {
            (range?.contains($0.day) ?? true)
                && (roleID == nil || $0.roleID == roleID)
                && (project == nil || $0.project == project)
                && (tag.map($0.tags.contains) ?? true)
                && $0.matches(query)
        }.sorted(by: Win.recent)
    }
}

struct Reminder: Codable, Equatable, Sendable {
    var enabled = false
    var weekday = 6
    var hour = 17
    var minute = 0

    var components: DateComponents {
        DateComponents(hour: hour, minute: minute, weekday: weekday)
    }
}

struct Progress: Codable, Equatable, Sendable {
    static let levels = [10, 50, 100]
    var saves = 0
    var days: Set<LocalDay> = []
    var milestones: [Int] = []
    var cards: [Int: Counts] = [:]
    var lifetime = Counts()
    var reviewed: Set<String> = []

    var reviewEligible: Bool { saves >= 5 && days.count >= 3 }

    mutating func record(day: LocalDay, win: Win) -> Int? {
        saves += 1
        lifetime.add(win)
        days.insert(day)
        guard Self.levels.contains(saves), !milestones.contains(saves) else { return nil }
        milestones.append(saves)
        cards[saves] = lifetime
        return saves
    }
}

struct Journal: Codable, Sendable {
    var revision: Int?
    var wins: [Win] = []
    var roles: [Role] = []
    var currentRole: UUID?
    var nextOrder = 0
    var templates: [ExportTemplate] = []
    var template = ExportTemplate()
    var filter = WinFilter()
    var reminder = Reminder()
    var progress = Progress()
    var pendingDeletion: [DeletedWin] = []

    func visible(pro: Bool) -> [Win] {
        if pro { return wins.sorted(by: Win.recent) }
        return Array(wins.sorted { $0.savedOrder > $1.savedOrder }.prefix(20)).sorted(by: Win.recent)
    }

    mutating func save(_ win: Win, now: Date = Date()) throws -> Int? {
        guard win.valid else { throw JournalFailure.invalid }
        var entry = win
        entry.prepare()
        if let index = wins.firstIndex(where: { $0.id == entry.id }) {
            entry.createdAt = wins[index].createdAt
            entry.savedOrder = wins[index].savedOrder
            wins[index] = entry
            return nil
        }
        nextOrder += 1
        entry.createdAt = now
        entry.savedOrder = nextOrder
        wins.append(entry)
        return progress.record(day: LocalDay(now), win: entry)
    }

    mutating func makeCurrent(_ id: UUID) {
        guard let index = roles.firstIndex(where: { $0.id == id }) else { return }
        roles[index].archived = false
        currentRole = id
    }

    mutating func archive(_ id: UUID) {
        guard let index = roles.firstIndex(where: { $0.id == id }) else { return }
        roles[index].archived = true
        if currentRole == id { currentRole = nil }
    }
}

struct DeletedWin: Codable, Sendable {
    var win: Win
    var expires: Date
}

enum JournalFailure: Error { case invalid, unavailable, attachment, file, busy }

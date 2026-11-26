import Foundation

enum CSVColumn: String, CaseIterable, Identifiable, Sendable {
    case id, date, action, result, metric, project, tags, situation, task
    case createdAt, roleID, role, organization, roleStart, roleEnd, roleArchived, roleCurrent, schema
    var id: Self { self }
    var title: String { L.t("csv." + rawValue) }

    private var aliases: [String] {
        switch self {
        case .id: return ["recordid", "记录id", "紀錄id"]
        case .date: return ["day", "日期", "成果日期"]
        case .action: return ["title", "win", "accomplishment", "whatdidyoudo", "成果", "标题", "標題", "成果标题", "成果標題", "做了什么", "做了什麼"]
        case .result: return ["结果", "結果", "成效"]
        case .metric: return ["指标", "指標", "数字", "數字", "数字指标", "數字指標"]
        case .project: return ["项目", "專案", "項目"]
        case .tags: return ["标签", "標籤"]
        case .situation: return ["情境"]
        case .task: return ["任务", "任務"]
        case .createdAt: return ["创建时间", "建立時間"]
        case .roleID: return ["任职id", "任職id"]
        case .role: return ["position", "job", "任职", "任職", "职位", "職位", "角色"]
        case .organization: return ["company", "organisation", "组织", "組織", "公司"]
        case .roleStart: return ["startdate", "任职开始", "任職開始"]
        case .roleEnd: return ["enddate", "任职结束", "任職結束"]
        case .roleArchived: return ["已归档", "已封存"]
        case .roleCurrent: return ["????", "????"]
        case .schema: return []
        }
    }

    static func match(_ header: String) -> Self? {
        let key = header.trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
        return allCases.first { $0.rawValue.lowercased() == key || $0.aliases.contains(key) }
    }
}

struct CSVMapping: Identifiable, Sendable {
    let column: CSVColumn
    let header: String
    var id: CSVColumn { column }
}

struct CSVItem: Sendable {
    let win: Win
    let role: Role?
    let explicitID: Bool
    let duplicate: Bool
}

struct CSVPreview: Sendable {
    let mapping: [CSVMapping]
    let items: [CSVItem]
    let badLines: [Int]
    let backupRoles: [Role]
    let currentRole: UUID?

    var duplicates: Int { items.filter(\.duplicate).count }
    var validCount: Int { items.count - duplicates }

    @discardableResult
    func apply(to journal: inout Journal, keepDuplicates: Bool) -> Int {
        var knownIDs = Set(journal.wins.map(\.id) + journal.pendingDeletion.map { $0.win.id })
        var count = 0
        for role in backupRoles where !journal.roles.contains(where: { $0.id == role.id }) {
            journal.roles.append(role)
        }
        if journal.currentRole == nil, let currentRole,
           journal.roles.contains(where: { $0.id == currentRole && !$0.archived }) {
            journal.currentRole = currentRole
        }
        for item in items {
            var win = item.win
            if knownIDs.contains(win.id) || (item.duplicate && (item.explicitID || !keepDuplicates)) { continue }
            if let role = item.role {
                let existing = journal.roles.first { $0.id == role.id }
                    ?? (!item.explicitID ? JournalCSV.matchRole(role, in: journal.roles) : nil)
                if let existing {
                    win.roleID = existing.id
                } else {
                    journal.roles.append(role)
                    win.roleID = role.id
                }
            }
            journal.nextOrder += 1
            win.savedOrder = journal.nextOrder
            journal.wins.append(win)
            knownIDs.insert(win.id)
            count += 1
        }
        return count
    }
}

enum JournalCSV {
    static let maximumBytes = 16 * 1024 * 1024

    static func encode(_ journal: Journal) throws -> String {
        let headers = CSVColumn.allCases.map(\.rawValue)
        let roles = Dictionary(uniqueKeysWithValues: journal.roles.map { ($0.id, $0) })
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rows = [headers.joined(separator: ",")]
        for role in journal.roles {
            let values = Array(repeating: "", count: 10) + [role.id.uuidString, role.title,
                role.organization, role.start?.raw ?? "", role.end?.raw ?? "", role.archived ? "1" : "0",
                journal.currentRole == role.id ? "1" : "0", "BLROLE1"]
            rows.append(values.map { quote(escapeFormula($0)) }.joined(separator: ","))
        }
        for win in journal.wins.sorted(by: { $0.savedOrder < $1.savedOrder }) {
            let role = win.roleID.flatMap { roles[$0] }
            let tags = String(decoding: try JSONEncoder().encode(win.tags), as: UTF8.self)
            let values = [
                win.id.uuidString, win.day.raw, win.action, win.result, win.metric, win.project, tags,
                win.situation, win.task, iso.string(from: win.createdAt), role?.id.uuidString ?? "",
                role?.title ?? "", role?.organization ?? "", role?.start?.raw ?? "", role?.end?.raw ?? "",
                role.map { $0.archived ? "1" : "0" } ?? "", "", "BLCSV1"
            ]
            rows.append(values.map { quote(escapeFormula($0)) }.joined(separator: ","))
        }
        let text = "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
        guard text.utf8.count <= maximumBytes else { throw JournalFailure.file }
        return text
    }

    static func preview(_ text: String, existing journal: Journal) throws -> CSVPreview {
        guard text.utf8.count <= maximumBytes else { throw JournalFailure.file }
        let rows = parse(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let header = rows.first, !header.broken else { throw JournalFailure.file }
        var indexes: [CSVColumn: Int] = [:]
        var mapping: [CSVMapping] = []
        for (index, value) in header.cells.enumerated() {
            if let column = CSVColumn.match(value), indexes[column] == nil {
                indexes[column] = index
                mapping.append(CSVMapping(column: column, header: value))
            }
        }
        guard indexes[.date] != nil, indexes[.action] != nil else { throw JournalFailure.file }
        var roles = journal.roles
        let existing = journal.wins + journal.pendingDeletion.map(\.win)
        var fingerprints = Set(existing.map(Fingerprint.init))
        var ids = Set(existing.map(\.id))
        var badLines: [Int] = []
        var backupRoles: [Role] = []
        var currentRole: UUID?
        var items: [CSVItem] = []
        for row in rows.dropFirst() {
            if !row.broken && row.cells.allSatisfy({ $0.trimmed.isEmpty }) { continue }
            func raw(_ column: CSVColumn) -> String {
                guard let index = indexes[column], row.cells.indices.contains(index) else { return "" }
                return row.cells[index]
            }
            let backup = raw(.schema) == "BLCSV1"
            let roleRow = raw(.schema) == "BLROLE1"
            func value(_ column: CSVColumn) -> String {
                (backup || roleRow) ? unescapeFormula(raw(column)) : raw(column)
            }
            let id = UUID(uuidString: value(.id).trimmed)
            let roleID = UUID(uuidString: value(.roleID).trimmed)
            guard !row.broken, row.cells.count <= header.cells.count,
                  value(.id).trimmed.isEmpty || id != nil,
                  value(.roleID).trimmed.isEmpty || roleID != nil else {
                badLines.append(row.line)
                continue
            }
            var role = Role()
            role.title = value(.role).trimmed
            role.organization = value(.organization)
            role.start = parseDay(value(.roleStart))
            role.end = parseDay(value(.roleEnd))
            role.archived = value(.roleArchived) == "1"
            if let roleID { role.id = roleID }
            if (!value(.roleStart).trimmed.isEmpty && role.start == nil)
                || (!value(.roleEnd).trimmed.isEmpty && role.end == nil)
                || (!role.title.isEmpty && !role.valid) {
                badLines.append(row.line)
                continue
            }
            if roleRow {
                guard roleID != nil, role.valid, !backupRoles.contains(where: { $0.id == role.id }) else {
                    badLines.append(row.line)
                    continue
                }
                backupRoles.append(role)
                if !roles.contains(where: { $0.id == role.id }) { roles.append(role) }
                if !role.archived && value(.roleCurrent) == "1" && currentRole == nil { currentRole = role.id }
                continue
            }
            let timestamp = parseInstant(value(.createdAt))
            guard let day = parseDay(value(.date)), !value(.action).trimmed.isEmpty,
                  value(.createdAt).trimmed.isEmpty || timestamp != nil else {
                badLines.append(row.line)
                continue
            }
            let resolved = roles.first { $0.id == role.id }
                ?? (roleID == nil ? matchRole(role, in: roles) : nil)
                ?? (role.valid ? role : nil)
            if let resolved, !roles.contains(where: { $0.id == resolved.id }) { roles.append(resolved) }
            var win = Win()
            if let id { win.id = id }
            win.day = day
            win.createdAt = timestamp ?? day.date(calendar: .utcJournal)
            win.action = value(.action)
            win.result = value(.result)
            win.metric = value(.metric)
            win.project = value(.project)
            win.situation = value(.situation)
            win.task = value(.task)
            win.roleID = resolved?.id
            let tags = value(.tags)
            if backup {
                guard let decoded = try? JSONDecoder().decode([String].self, from: Data(tags.utf8)) else {
                    badLines.append(row.line)
                    continue
                }
                win.tags = decoded
            } else {
                win.tags = tags.components(separatedBy: CharacterSet(charactersIn: ",;，；、"))
            }
            win.prepare()
            let fingerprint = Fingerprint(win)
            let duplicate = id == nil ? fingerprints.contains(fingerprint) : ids.contains(win.id)
            ids.insert(win.id)
            fingerprints.insert(fingerprint)
            items.append(CSVItem(win: win, role: resolved, explicitID: id != nil, duplicate: duplicate))
        }
        return CSVPreview(mapping: mapping, items: items, badLines: badLines,
                          backupRoles: backupRoles, currentRole: currentRole)
    }

    static func matchRole(_ role: Role, in roles: [Role]) -> Role? {
        roles.first { $0.title == role.title && $0.organization == role.organization
            && $0.start == role.start && $0.end == role.end }
    }

    private struct Fingerprint: Hashable {
        let day: LocalDay
        let role: UUID?
        let fields: [String]
        let tags: [String]

        init(_ win: Win) {
            day = win.day
            role = win.roleID
            fields = [win.action, win.result, win.metric, win.project, win.situation, win.task]
            tags = win.tags.sorted()
        }
    }

    private static func parseDay(_ input: String) -> LocalDay? {
        let value = input.trimmed.replacingOccurrences(of: "/", with: "-")
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, let year = Int(parts[0]),
              (1...9999).contains(year), let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        return LocalDay(raw: String(format: "%04d-%02d-%02d", year, month, day))
    }

    private static func parseInstant(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }

    private static func escapeFormula(_ cell: String) -> String {
        if cell.hasPrefix("'") || cell.hasPrefix("\t") || cell.hasPrefix("\r") || cell.hasPrefix("\n")
            || cell.trimmed.first.map({ "=+-@".contains($0) }) == true {
            return "'" + cell
        }
        return cell
    }

    private static func unescapeFormula(_ cell: String) -> String {
        cell.hasPrefix("'") ? String(cell.dropFirst()) : cell
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private struct Row {
        let line: Int
        let cells: [String]
        let broken: Bool
    }

    private enum State { case start, plain, quoted, closed }

    private static func parse(_ text: String) -> [Row] {
        var rows: [Row] = []
        var cells: [String] = []
        var cell = ""
        var state = State.start
        var line = 1
        var rowLine = 1
        var broken = false
        for character in text {
            let newline = character == "\n" || character == "\r" || character == "\r\n"
            if state == .quoted {
                if character == "\"" { state = .closed }
                else { cell.append(character) }
            } else if character == "," || newline {
                cells.append(cell)
                cell = ""
                state = .start
                if newline {
                    rows.append(Row(line: rowLine, cells: cells, broken: broken))
                    cells = []
                    broken = false
                    rowLine = line + 1
                }
            } else if character == "\"" && (state == .start || state == .closed) {
                if state == .closed { cell.append(character) }
                state = .quoted
            } else {
                if state == .closed || character == "\"" { broken = true }
                cell.append(character)
                state = .plain
            }
            if newline { line += 1 }
        }
        if !cells.isEmpty || state != .start || !cell.isEmpty {
            rows.append(Row(line: rowLine, cells: cells + [cell], broken: broken || state == .quoted))
        }
        return rows
    }
}

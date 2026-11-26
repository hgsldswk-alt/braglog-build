import Combine
import Foundation

struct Notice: Identifiable, Equatable {
    let id = UUID()
    let key: String
    var undo: UUID?
    var milestone: Int?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var journal = Journal()
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var capture = Win()
    @Published var notice: Notice?
    @Published var storageError: String?
    @Published var reviewCandidate = false
    private var requestMarkedInSession = false
    @Published var reminderDenied = false
    @Published private(set) var reminderSetting = Reminder()
    @Published var filter = WinFilter()
    @Published var exportSelection: Set<UUID>?
    @Published var exportTemplate = ExportTemplate()

    private var database: JournalDatabase?
    private var launchInProgress = false
    private var draftJobs: [String: Task<Void, Never>] = [:]
    private var pendingDrafts: [String: Win] = [:]
    private var preferencesJob: Task<Void, Never>?
    private var savingKey: String?
    private var savedFilter = WinFilter()
    private var savedTemplate = ExportTemplate()
    private var noticeJob: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private let reminder = WeeklyReminder()

    func start() async {
        guard !loaded, !launchInProgress else { return }
        launchInProgress = true
        defer { launchInProgress = false }
        do {
            if database == nil {
                let root = try await Task.detached(priority: .userInitiated) {
                    let manager = FileManager.default
                    if Launch.testing {
                        let seed = ProcessInfo.processInfo.environment["BRAG_TEST_ID"] ?? "default"
                        let name = String(seed.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
                        let folder = manager.temporaryDirectory.appendingPathComponent("BragLogUITest-" + name)
                        if Launch.testFlag("-reset"), manager.fileExists(atPath: folder.path) {
                            try manager.removeItem(at: folder)
                        }
                        return folder
                    }
                    var folder = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
                        .appendingPathComponent("BragLog", isDirectory: true)
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try folder.setResourceValues(values)
                    return folder
                }.value
                database = JournalDatabase(root: root)
            }
            guard let database else { return }
            let state = try await database.load()
            receive(state.journal)
            if (Launch.testFlag("-seed") || Launch.testFlag("-seed-many") || Launch.testFlag("-review-ready")
                || Launch.testFlag("-milestone-ready")), journal.wins.isEmpty {
                receive(try await database.mutate { $0 = DemoJournal.make() }.0)
            }
            if let draft = state.drafts["capture"] {
                capture = draft
            } else {
                capture = newCapture()
                if Launch.testFlag("-draft") {
                    capture.action = ProcessInfo.processInfo.environment["BRAG_DRAFT"] ?? L.t("demo.action1")
                }
            }
            pendingDrafts = state.drafts
            filter = journal.filter
            savedFilter = journal.filter
            exportTemplate = journal.template
            savedTemplate = journal.template
            reminderSetting = journal.reminder
            storageError = nil
            loaded = true
            reconcileReminder()
        } catch {
            storageError = "error.load"
        }
    }

    func newCapture() -> Win {
        var win = Win()
        win.roleID = journal.currentRole
        return win
    }

    func editing(_ win: Win) -> Win {
        pendingDrafts[win.id.uuidString] ?? win
    }

    func queueDraft(_ win: Win, key: String) {
        guard loaded, let database else { return }
        let isEmptyCapture = key == "capture" && !win.valid && win.result.isEmpty && win.metric.isEmpty
            && win.project.isEmpty && win.tags.isEmpty && win.situation.isEmpty && win.task.isEmpty
            && win.photoID == nil && win.day == LocalDay() && win.roleID == journal.currentRole
        let draft = isEmptyCapture ? nil : win
        pendingDrafts[key] = draft
        draftJobs[key]?.cancel()
        draftJobs[key] = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                try await database.writeDraft(draft, key: key)
            } catch is CancellationError {
                return
            } catch {
                storageError = "error.draft"
            }
        }
    }

    func flushDrafts() async {
        guard loaded, let database else { return }
        let pending = pendingDrafts
        for (key, win) in pending where key != savingKey && pendingDrafts[key] == win {
            draftJobs[key]?.cancel()
            do { try await database.writeDraft(win, key: key) }
            catch { storageError = "error.draft" }
        }
        await persistPreferences()
    }

    @discardableResult
    func save(_ win: Win, editing: Bool, pro: Bool) async -> Bool {
        guard !busy, win.valid, let database else { return false }
        let key = editing ? win.id.uuidString : "capture"
        busy = true
        savingKey = key
        defer { busy = false; savingKey = nil }
        draftJobs[key]?.cancel()
        let priorPhoto = journal.wins.first { $0.id == win.id }?.photoID
        let photoSkipped = !pro && win.photoID != nil && win.photoID != priorPhoto
        do {
            let (state, level) = try await database.save(win, editing: editing, pro: pro, now: Date())
            receive(state)
            pendingDrafts.removeValue(forKey: key)
            storageError = nil
            if editing {
                show(photoSkipped ? "status.savedWithoutPhoto" : "status.updated")
            } else {
                capture = newCapture()
                show(photoSkipped ? "status.savedWithoutPhoto" : "status.saved", undo: win.id, milestone: level)
                let version = Self.version
                reviewCandidate = journal.progress.reviewEligible && !requestMarkedInSession
                    && !journal.progress.reviewed.contains(version)
            }
            return true
        } catch {
            queueDraft(win, key: key)
            storageError = "error.save"
            return false
        }
    }

    func attach(_ jpeg: Data, to win: Win, key: String) async -> Win? {
        guard let database, !busy else { return nil }
        busy = true
        defer { busy = false }
        draftJobs[key]?.cancel()
        do {
            let next = try await database.stagePhoto(jpeg, draft: win, key: key)
            pendingDrafts[key] = next
            return next
        } catch {
            queueDraft(win, key: key)
            storageError = "error.photo"
            return nil
        }
    }

    func photo(_ id: UUID) async -> Data? { await database?.photo(id) }

    func delete(_ id: UUID, pro: Bool, fromSave: Bool = false) async -> Bool {
        guard !busy, let database else { return false }
        busy = true
        defer { busy = false }
        draftJobs[id.uuidString]?.cancel()
        do {
            receive(try await database.delete(id, now: Date(), pro: pro))
            pendingDrafts.removeValue(forKey: id.uuidString)
            if fromSave { show("status.removed") }
            else { show("status.removed", undo: id) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Launch.testing ? 31 : 10))
                do {
                    let state = try await database.sweep()
                    self?.receive(state)
                }
                catch { self?.storageError = "error.save" }
            }
            if fromSave { reviewCandidate = false }
            return true
        } catch {
            storageError = "error.save"
            return false
        }
    }

    func undo(_ id: UUID, pro: Bool) async {
        if journal.wins.contains(where: { $0.id == id }) {
            _ = await delete(id, pro: pro, fromSave: true)
            return
        }
        guard !busy, let database else { return }
        busy = true
        defer { busy = false }
        do {
            receive(try await database.undo(id, now: Date()))
            show("status.restored")
        } catch { storageError = "error.undo" }
    }

    @discardableResult
    func change(_ update: @escaping @Sendable (inout Journal) throws -> Void) async -> Bool {
        guard !busy, let database else { return false }
        busy = true
        defer { busy = false }
        do {
            receive(try await database.mutate(update).0)
            return true
        } catch {
            storageError = "error.save"
            return false
        }
    }

    func rememberPreferences() {
        preferencesJob?.cancel()
        preferencesJob = Task {
            do { try await Task.sleep(for: .milliseconds(280)) }
            catch { return }
            await persistPreferences()
        }
    }

    private func persistPreferences() async {
        guard loaded, filter != savedFilter || exportTemplate != savedTemplate, let database else { return }
        let range = filter
        let template = exportTemplate
        do {
            _ = try await database.mutate {
                $0.filter = range
                $0.template = template
            }
            savedFilter = range
            savedTemplate = template
        } catch { storageError = "error.save" }
    }

    func setReminder(_ settings: Reminder) {
        reminderSetting = settings
        let previous = reminderTask
        previous?.cancel()
        reminderTask = Task {
            await previous?.value
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            await applyReminder(settings, ask: settings.enabled && !journal.reminder.enabled)
        }
    }

    func reconcileReminder() {
        guard loaded, journal.reminder.enabled, reminderTask == nil else { return }
        let settings = journal.reminder
        reminderTask = Task { await applyReminder(settings, ask: false) }
    }

    private func applyReminder(_ settings: Reminder, ask: Bool) async {
        defer { if !Task.isCancelled { reminderTask = nil } }
        do {
            let allowed = try await reminder.apply(settings, ask: ask)
            guard !Task.isCancelled else { return }
            var next = settings
            next.enabled = allowed
            reminderDenied = settings.enabled && !allowed
            let persisted = next
            if let database { receive(try await database.mutate { $0.reminder = persisted }.0) }
            if !Task.isCancelled { reminderSetting = persisted }
        } catch {
            if !Task.isCancelled {
                reminderSetting = journal.reminder
                storageError = "error.reminder"
            }
        }
    }

    func show(_ key: String, undo: UUID? = nil, milestone: Int? = nil) {
        noticeJob?.cancel()
        let item = Notice(key: key, undo: undo, milestone: milestone)
        notice = item
        noticeJob = Task {
            do { try await Task.sleep(for: .seconds(undo == nil ? 4 : (Launch.testing ? 30 : 9))) }
            catch { return }
            if notice == item { notice = nil }
        }
    }

    func recordReviewRequest() {
        requestMarkedInSession = true
        reviewCandidate = false
        guard let database else { return }
        let version = Self.version
        Task {
            do { _ = try await database.mutate { $0.progress.reviewed.insert(version) } }
            catch { storageError = "error.save" }
        }
    }

    private func receive(_ state: Journal) {
        if (state.revision ?? 0) >= (journal.revision ?? 0) { journal = state }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

private enum DemoJournal {
    static func make() -> Journal {
        var journal = Journal()
        var lead = Role()
        lead.title = L.t("demo.role1")
        lead.organization = L.t("demo.org")
        var previous = Role()
        previous.title = L.t("demo.role2")
        journal.roles = [lead, previous]
        journal.currentRole = lead.id
        let today = LocalDay()
        let size = Launch.testFlag("-seed-many") ? 22 : 3
        for index in (1...size).reversed() {
            var win = Win()
            win.day = today
            win.createdAt = Date().addingTimeInterval(Double(-index * 100))
            let example = (index - 1) % 3 + 1
            win.savedOrder = size + 1 - index
            win.action = L.t("demo.action" + String(example))
            if size > 3 { win.action += " #" + String(win.savedOrder) }
            win.project = L.t("demo.project" + String(example))
            win.roleID = index == 3 ? previous.id : lead.id
            win.result = L.t("demo.result" + String(example))
            win.metric = index == 1 ? L.t("demo.metric") : ""
            win.tags = [PublicCategory.allCases[example - 1].title]
            journal.wins.append(win)
        }
        journal.nextOrder = journal.wins.count
        if Launch.testFlag("-review-ready") || Launch.testFlag("-milestone-ready") {
            let calendar = Calendar.journal
            let now = Date()
            let target = Launch.testFlag("-milestone-ready") ? 9 : 4
            for index in 0..<target {
                let date = calendar.date(byAdding: .day, value: -1 - index % 2, to: now) ?? now
                _ = journal.progress.record(day: LocalDay(date), win: journal.wins[index % journal.wins.count])
            }
        }
        return journal
    }
}

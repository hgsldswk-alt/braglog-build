import Foundation
import SQLite3

actor JournalDatabase {
    private let root: URL
    private var connection: OpaquePointer?
    private var journal = Journal()
    private var drafts: [String: Win] = [:]
    private let photos: URL
    private var loaded = false

    init(root: URL) {
        self.root = root
        photos = root.appendingPathComponent("Evidence", isDirectory: true)
    }

    deinit { sqlite3_close(connection) }

    struct Snapshot: Sendable {
        let journal: Journal
        let drafts: [String: Win]
    }

    func load() throws -> Snapshot {
        if loaded { return Snapshot(journal: journal, drafts: drafts) }
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        if connection == nil {
            let path = root.appendingPathComponent("journal.sqlite").path
            let status = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            guard status == SQLITE_OK else {
                sqlite3_close(connection)
                connection = nil
                throw JournalFailure.file
            }
        }
        try execute("CREATE TABLE IF NOT EXISTS local_state (name TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        let stored = try read(Journal.self, key: "journal") ?? Journal()
        let savedDrafts = try read([String: Win].self, key: "drafts") ?? [:]
        journal = stored
        drafts = savedDrafts
        loaded = true
        do {
            try sweep()
        } catch {
            loaded = false
            throw error
        }
        return Snapshot(journal: journal, drafts: drafts)
    }

    func mutate<T: Sendable>(_ change: @Sendable (inout Journal) throws -> T) throws -> (Journal, T) {
        guard loaded else { throw JournalFailure.unavailable }
        var next = journal
        let result = try change(&next)
        next.revision = (journal.revision ?? 0) + 1
        try write(next, key: "journal")
        journal = next
        return (next, result)
    }

    func save(_ win: Win, editing: Bool, pro: Bool, now: Date) throws -> (Journal, Int?) {
        guard loaded else { throw JournalFailure.unavailable }
        let key = editing ? win.id.uuidString : "capture"
        if editing, !journal.visible(pro: pro).contains(where: { $0.id == win.id }) {
            throw JournalFailure.unavailable
        }
        if !editing && (journal.wins.contains(where: { $0.id == win.id })
                        || journal.pendingDeletion.contains(where: { $0.win.id == win.id })) {
            return (journal, nil)
        }
        let previous = journal.wins.first { $0.id == win.id }
        var entry = win
        if let photo = win.photoID, photo != previous?.photoID {
            if !pro { entry.photoID = previous?.photoID }
            else if !FileManager.default.fileExists(atPath: photoURL(photo).path) { throw JournalFailure.attachment }
        }
        var next = journal
        let level = try next.save(entry, now: now)
        next.revision = (journal.revision ?? 0) + 1
        var newDrafts = drafts
        newDrafts.removeValue(forKey: key)
        try transaction {
            try write(next, key: "journal")
            try write(newDrafts, key: "drafts")
        }
        journal = next
        drafts = newDrafts
        let candidates = [previous?.photoID, win.photoID].compactMap { $0 }
        for photo in Set(candidates) where photo != entry.photoID { removeUnreferenced(photo) }
        return (next, level)
    }

    func writeDraft(_ win: Win?, key: String) throws {
        guard loaded else { throw JournalFailure.unavailable }
        if let win {
            let exists = journal.wins.contains { $0.id == win.id }
            let deleted = journal.pendingDeletion.contains { $0.win.id == win.id }
            if (key == "capture" && (exists || deleted)) || (key != "capture" && !exists) { return }
        }
        let previous = drafts[key]?.photoID
        var next = drafts
        next[key] = win
        try write(next, key: "drafts")
        drafts = next
        if let previous, previous != win?.photoID {
            removeUnreferenced(previous)
        }
    }

    func stagePhoto(_ jpeg: Data, draft: Win, key: String) throws -> Win {
        guard loaded, !jpeg.isEmpty else { throw JournalFailure.attachment }
        var win = draft
        let id = UUID()
        let url = photoURL(id)
        try jpeg.write(to: url, options: .atomic)
        win.photoID = id
        do { try writeDraft(win, key: key) }
        catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return win
    }

    func photo(_ id: UUID) -> Data? { try? Data(contentsOf: photoURL(id)) }

    func delete(_ id: UUID, now: Date, pro: Bool) throws -> Journal {
        guard loaded, journal.visible(pro: pro).contains(where: { $0.id == id }),
              let win = journal.wins.first(where: { $0.id == id }) else {
            throw JournalFailure.unavailable
        }
        var next = journal
        var newDrafts = drafts
        next.wins.removeAll { $0.id == id }
        next.pendingDeletion.append(DeletedWin(win: win, expires: now.addingTimeInterval(Launch.testing ? 30 : 10)))
        next.revision = (journal.revision ?? 0) + 1
        let draftPhoto = newDrafts.removeValue(forKey: id.uuidString)?.photoID
        try transaction {
            try write(next, key: "journal")
            try write(newDrafts, key: "drafts")
        }
        journal = next
        drafts = newDrafts
        if let draftPhoto { removeUnreferenced(draftPhoto) }
        return next
    }

    func undo(_ id: UUID, now: Date) throws -> Journal {
        try mutate { journal in
            guard let item = journal.pendingDeletion.first(where: { $0.win.id == id && now < $0.expires }) else {
                throw JournalFailure.unavailable
            }
            journal.pendingDeletion.removeAll { $0.win.id == id }
            journal.wins.append(item.win)
        }.0
    }

    @discardableResult
    func sweep(now: Date = Date()) throws -> Journal {
        let expired = journal.pendingDeletion.filter { $0.expires <= now }
        if !expired.isEmpty {
            _ = try mutate { $0.pendingDeletion.removeAll { $0.expires <= now } }
            for id in expired.compactMap({ $0.win.photoID }) { removeUnreferenced(id) }
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: photos,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > 86_400 else { continue }
            removeUnreferenced(id)
        }
        return journal
    }

    private func photoURL(_ id: UUID) -> URL {
        photos.appendingPathComponent(id.uuidString + ".jpg")
    }

    private func removeUnreferenced(_ id: UUID) {
        let used = journal.wins.contains { $0.photoID == id }
            || journal.pendingDeletion.contains { $0.win.photoID == id }
            || drafts.values.contains { $0.photoID == id }
        if !used { try? FileManager.default.removeItem(at: photoURL(id)) }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw JournalFailure.file }
    }

    private func transaction(_ operations: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operations()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &query, nil) == SQLITE_OK, let query else {
            sqlite3_finalize(query)
            throw JournalFailure.file
        }
        return query
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        let query = try statement("SELECT payload FROM local_state WHERE name = ?")
        defer { sqlite3_finalize(query) }
        guard sqlite3_bind_text(query, 1, key, -1, Self.transient) == SQLITE_OK else { throw JournalFailure.file }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw JournalFailure.file }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0))))
    }

    private func write<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = try statement("INSERT OR REPLACE INTO local_state (name, payload) VALUES (?, ?)")
        defer { sqlite3_finalize(query) }
        guard sqlite3_bind_text(query, 1, key, -1, Self.transient) == SQLITE_OK else { throw JournalFailure.file }
        let status = data.withUnsafeBytes {
            sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), Self.transient)
        }
        guard status == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else { throw JournalFailure.file }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

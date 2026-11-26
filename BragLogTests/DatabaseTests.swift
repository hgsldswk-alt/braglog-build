import SQLite3
import XCTest

final class DatabaseTests: XCTestCase {
    func testConcurrentRetriesSameStableIDWriteOnlyOneWin() async throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = JournalDatabase(root: root)
        _ = try await db.load()
        let item = Win(action: "One win")
        let now = Date()
        async let first = db.save(item, editing: false, pro: true, now: now)
        async let second = db.save(item, editing: false, pro: true, now: now)
        _ = try await (first, second)
        let reopened = try await JournalDatabase(root: root).load()
        XCTAssertEqual(reopened.journal.wins.map(\.id), [item.id])
        XCTAssertEqual(reopened.journal.progress.saves, 1)
    }

    func testFailedSaveRollsBackWinAndKeepsDraftForRetry() async throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = JournalDatabase(root: root)
        _ = try await db.load()
        let item = Win(action: "Keep this draft\nincluding this line")
        try await db.writeDraft(item, key: "capture")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("journal.sqlite").path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let trigger = "CREATE TRIGGER test_failure BEFORE INSERT ON local_state WHEN NEW.name = 'drafts' "
            + "BEGIN SELECT RAISE(ABORT, 'test'); END;"
        XCTAssertEqual(sqlite3_exec(handle, trigger, nil, nil, nil), SQLITE_OK)
        do {
            _ = try await db.save(item, editing: false, pro: true, now: Date())
            XCTFail("The database write should fail")
        } catch { XCTAssertTrue(error is JournalFailure) }
        let saved = try await JournalDatabase(root: root).load()
        XCTAssertTrue(saved.journal.wins.isEmpty)
        XCTAssertEqual(saved.drafts["capture"], item)
        XCTAssertEqual(sqlite3_exec(handle, "DROP TRIGGER test_failure", nil, nil, nil), SQLITE_OK)
        let (recovered, _) = try await db.save(item, editing: false, pro: true, now: Date())
        XCTAssertEqual(recovered.wins.map(\.id), [item.id])
        let last = try await JournalDatabase(root: root).load()
        XCTAssertNil(last.drafts["capture"])
    }

    func testAttachmentSurvivesUndoAndExpiresWithDeletion() async throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = JournalDatabase(root: root)
        _ = try await db.load()
        let now = Date()
        let bytes = Data([1, 2, 3])
        let entry = try await db.stagePhoto(bytes, draft: Win(action: "Win"), key: "capture")
        _ = try await db.save(entry, editing: false, pro: true, now: now)
        let id = try XCTUnwrap(entry.photoID)
        _ = try await db.delete(entry.id, now: now, pro: true)
        let restored = try await db.undo(entry.id, now: now.addingTimeInterval(3))
        XCTAssertEqual(restored.wins.first?.photoID, id)
        XCTAssertEqual(restored.progress.saves, 1)
        let attached = await db.photo(id)
        XCTAssertEqual(attached, bytes)
        _ = try await db.delete(entry.id, now: now, pro: true)
        try await db.sweep(now: now.addingTimeInterval(11))
        let cleaned = await db.photo(id)
        XCTAssertNil(cleaned)
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

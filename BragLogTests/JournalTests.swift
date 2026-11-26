import XCTest

final class JournalTests: XCTestCase {
    func testRequiredFieldTrimmingAndMultilineAreLossless() throws {
        var journal = Journal()
        var entry = Win()
        entry.action = " \t\n "
        XCTAssertThrowsError(try journal.save(entry))
        XCTAssertTrue(journal.wins.isEmpty)
        entry.action = " \nFirst line\n\nSecond line \n"
        entry.metric = " 18 min → 7 min "
        _ = try journal.save(entry)
        XCTAssertEqual(journal.wins.first?.action, "First line\n\nSecond line")
        XCTAssertEqual(journal.wins.first?.metric, " 18 min → 7 min ")
        let before = try XCTUnwrap(journal.wins.first)
        entry.action = "Edited"
        _ = try journal.save(entry, now: Date().addingTimeInterval(60))
        XCTAssertEqual(journal.progress.saves, 1)
        XCTAssertEqual(journal.wins.first?.savedOrder, before.savedOrder)
        XCTAssertEqual(journal.wins.first?.createdAt, before.createdAt)
    }

    func testLocalDaySurvivesTimeZoneAndRejectsImpossibleDate() throws {
        var tokyo = Calendar.utcJournal
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        var losAngeles = Calendar.utcJournal
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T16:05:00Z"))
        let recorded = LocalDay(instant, calendar: tokyo)
        XCTAssertEqual(recorded.raw, "2026-01-02")
        XCTAssertEqual(LocalDay(instant, calendar: losAngeles).raw, "2026-01-01")
        let restored = try JSONDecoder().decode(LocalDay.self, from: JSONEncoder().encode(recorded))
        XCTAssertEqual(LocalDay(restored.date(calendar: losAngeles), calendar: losAngeles), recorded)
        XCTAssertNil(LocalDay(raw: "2026-02-29"))
    }

    func testPeriodBoundariesAndCombinedFilters() throws {
        let march = try day("2026-03-31")
        let april = try day("2026-04-01")
        let june = try day("2026-06-30")
        let july = try day("2026-07-01")
        let now = april.date(calendar: .utcJournal)
        XCTAssertEqual(Period.quarter.span(now: now, calendar: .utcJournal), april...june)
        XCTAssertEqual(Period.month.span(now: now, calendar: .utcJournal).upperBound, try day("2026-04-30"))
        var monday = Calendar.utcJournal
        monday.firstWeekday = 2
        XCTAssertEqual(Period.week.span(now: now, calendar: monday).lowerBound, try day("2026-03-30"))
        let role = UUID()
        var win = Win(day: april, action: "Delivered", metric: "18 min → 7 min", project: "Support",
                      tags: ["Impact"], roleID: role)
        var other = win
        other.id = UUID()
        win.day = june
        other.day = july
        let range = WinFilter(roleID: role, project: "Support", tag: "Impact", query: "18 min")
        XCTAssertEqual(range.apply([win, other], now: now, calendar: .utcJournal).map(\.id), [win.id])
        var custom = WinFilter(period: .custom, start: april, end: march)
        XCTAssertEqual(custom.span(), march...april)
        custom.query = "missing"
        XCTAssertTrue(custom.apply([win, other]).isEmpty)
    }

    func testFreeHistoryAllowanceUsesSaveOrderBeforeDateRange() throws {
        var journal = Journal()
        let oldDay = try day("2022-01-01")
        let future = try day("2029-01-01")
        for index in 0..<21 {
            _ = try journal.save(Win(day: index == 0 ? future : oldDay, action: "Win \(index)"))
        }
        let free = journal.visible(pro: false)
        XCTAssertEqual(free.count, 20)
        XCTAssertFalse(free.contains { $0.day == future })
        XCTAssertEqual(journal.visible(pro: true).count, 21)
        let filter = WinFilter(period: .custom, start: future, end: future)
        XCTAssertTrue(filter.apply(free).isEmpty)
        XCTAssertEqual(filter.apply(journal.visible(pro: true)).count, 1)
    }

    func testArchivingKeepsRelationshipAndWeekdayReminderIsFloating() throws {
        var journal = Journal()
        let role = Role(title: "Designer", organization: "Studio")
        journal.roles.append(role)
        journal.makeCurrent(role.id)
        _ = try journal.save(Win(action: "Delivered", roleID: role.id))
        journal.archive(role.id)
        XCTAssertNil(journal.currentRole)
        XCTAssertEqual(journal.wins.first?.roleID, role.id)
        XCTAssertEqual(journal.roles.first?.archived, true)
        let reminder = Reminder()
        XCTAssertEqual(reminder.components.weekday, 6)
        XCTAssertEqual(reminder.components.hour, 17)
        XCTAssertNil(reminder.components.timeZone)
        let reference = try day("2026-11-25")
        for identifier in ["Asia/Tokyo", "America/Los_Angeles"] {
            var calendar = Calendar.journal
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
            let next = try XCTUnwrap(calendar.nextDate(after: reference.date(calendar: calendar),
                matching: reminder.components, matchingPolicy: .nextTime))
            XCTAssertEqual(calendar.component(.hour, from: next), 17)
            XCTAssertEqual(calendar.component(.weekday, from: next), 6)
        }
    }

    func testReviewThresholdAndEveryMilestoneOnce() throws {
        var progress = Progress()
        let first = try day("2026-11-24")
        let second = try day("2026-11-25")
        let third = try day("2026-11-26")
        let win = Win(action: "Confidential", tags: [PublicCategory.problem.title, "Private"])
        for _ in 0..<4 { XCTAssertNil(progress.record(day: first, win: win)) }
        _ = progress.record(day: second, win: win)
        XCTAssertFalse(progress.reviewEligible)
        _ = progress.record(day: third, win: win)
        XCTAssertTrue(progress.reviewEligible)
        var awarded: [Int] = []
        for _ in 7...110 {
            if let level = progress.record(day: third, win: win) { awarded.append(level) }
        }
        XCTAssertEqual(awarded, [10, 50, 100])
        XCTAssertEqual(progress.cards[10]?.buckets[.problem], 10)
        XCTAssertEqual(progress.cards[100]?.total, 100)
    }

    func testTrialBoundaryFreeLaunchAndReceiptReconciliation() {
        let first = Date(timeIntervalSince1970: 100_000)
        let paid = first.addingTimeInterval(86_400)
        var access = Entitlement(firstOpen: first, proStartedAt: paid)
        XCTAssertEqual(access.trialStart, paid)
        XCTAssertTrue(access.hasPro(at: access.trialEnd.addingTimeInterval(-1), free: false))
        XCTAssertFalse(access.hasPro(at: access.trialEnd, free: false))
        XCTAssertTrue(access.hasPro(at: access.trialEnd, free: true))
        access.reconcile(pro: false, trialReceipt: paid.addingTimeInterval(200))
        XCTAssertEqual(access.trialStart, paid)
        access.reconcile(pro: true, trialReceipt: first)
        XCTAssertEqual(access.trialStart, first)
        XCTAssertTrue(access.hasPro(at: access.trialEnd, free: false))
        access.reconcile(pro: false, trialReceipt: nil)
        XCTAssertFalse(access.hasPro(at: access.trialEnd, free: false))
        let widget = WidgetAccess(unlocked: true, expires: access.trialEnd)
        XCTAssertFalse(widget.isOpen(at: access.trialEnd))
        XCTAssertTrue(widget.isOpen(at: access.trialEnd.addingTimeInterval(-1)))
        var reinstalled = Entitlement(firstOpen: paid)
        reinstalled.reconcile(pro: false, trialReceipt: first)
        XCTAssertEqual(reinstalled.trialEnd, first.addingTimeInterval(Entitlement.trialLength))
    }

    func testVerifiedTrialReceiptCanRestoreOriginalStartWhenClaimedLater() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let token = try XCTUnwrap(TrialReceipt.token(start: start))
        let purchase = start.addingTimeInterval(17 * 86_400)
        XCTAssertEqual(TrialReceipt.start(token: token, purchaseDate: purchase), start)
        XCTAssertEqual(TrialReceipt.start(token: nil, purchaseDate: purchase), purchase)
        let tooLate = start.addingTimeInterval(31 * 86_400)
        XCTAssertEqual(TrialReceipt.start(token: token, purchaseDate: tooLate), tooLate)
    }

    private func day(_ raw: String) throws -> LocalDay {
        try XCTUnwrap(LocalDay(raw: raw))
    }
}

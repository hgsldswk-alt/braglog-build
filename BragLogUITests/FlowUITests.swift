import XCTest

final class FlowUITests: XCTestCase {
    private let uiTimeout: TimeInterval = 15

    override func setUpWithError() throws { continueAfterFailure = false }

    func testFirstLaunchFocusSavesAndRestoresDraftAfterRelaunch() {
        let id = UUID().uuidString
        let app = launch(id: id)
        let input = field(app, "capture.action")
        XCTAssertTrue(input.waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: uiTimeout))
        input.typeText("Built a better handoff")
        tap(app, "capture.save")
        XCTAssertTrue(app.staticTexts["status.message"].waitForExistence(timeout: uiTimeout))
        tap(app, "tab.history")
        let row = indexedButtons(app, prefix: "win.row.").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(row.label.contains("Built a better handoff"))

        tap(app, "tab.capture")
        let draft = field(app, "capture.action")
        tap(draft, in: app)
        draft.typeText("An unfinished draft")
        XCUIDevice.shared.press(.home)
        app.terminate()
        let reopened = launch(id: id, reset: false)
        XCTAssertTrue(field(reopened, "capture.action").waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(field(reopened, "capture.action").value as? String, "An unfinished draft")
    }

    func testDetailsEditingDeletionAndUndo() {
        let app = launch(["-no-focus"], environment: ["BRAG_DRAFT": "Outcome from the handoff\nFollow-up"],
                         draft: true)
        tap(app, "capture.details")
        let result = field(app, "edit.result")
        XCTAssertTrue(result.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(field(app, "edit.action").value as? String, "Outcome from the handoff\nFollow-up")
        tap(result, in: app, scroll: true)
        result.typeText("Staff can run the handoff")
        dismissEditKeyboardIfVisible(in: app)
        let metric = field(app, "edit.metric")
        tap(metric, in: app, scroll: true)
        metric.typeText("18 min to 7 min")
        dismissEditKeyboardIfVisible(in: app)
        tap(app, "edit.save")
        tap(app, "tab.history")
        let row = indexedButtons(app, prefix: "win.row.").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: uiTimeout))
        let editedRow = app.buttons[row.identifier]
        tap(editedRow, in: app, scroll: true)
        let action = field(app, "edit.action")
        replace(action, with: "Handoff playbook", in: app)
        dismissEditKeyboardIfVisible(in: app)
        tap(app, "edit.save")
        let save = app.buttons["edit.save"].firstMatch
        let editorClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [editorClosed], timeout: uiTimeout), .completed,
                       "The editor did not close after saving")
        XCTAssertTrue(editedRow.waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(editedRow.label.contains("Handoff playbook"))
        tap(editedRow, in: app, scroll: true)
        XCTAssertTrue(action.waitForExistence(timeout: uiTimeout), "The editor did not reopen")
        XCTAssertEqual(action.value as? String, "Handoff playbook")

        let delete = app.buttons["edit.delete"].firstMatch
        guard let deleteButton = readyElement(in: app, scroll: true, name: "edit.delete above the save footer",
                                              file: #filePath, line: #line, find: {
            guard self.isTappable(delete), save.exists, delete.frame.maxY <= save.frame.minY else { return nil }
            return delete
        }) else { return }
        deleteButton.tap()

        let count = app.staticTexts["history.count"]
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !save.exists && count.exists && count.label == "Wins: 0" && !editedRow.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: uiTimeout), .completed,
                       "Delete did not remove \(editedRow):\n\(app.debugDescription)")
        let undo = app.buttons["status.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: uiTimeout),
                      "Undo did not appear after deletion:\n\(app.debugDescription)")
        tap(app, "status.undo")
        XCTAssertTrue(editedRow.waitForExistence(timeout: uiTimeout), "Undo did not restore the deleted win")
    }

    func testHistoryFiltersAndHistoryExportUseSameSelection() {
        let app = launch(["-seed", "-no-focus"])
        tap(app, "tab.history")
        tap(app, "history.period.week")
        tap(app, "history.period.month")
        tap(app, "history.period.quarter")
        tap(app, "history.period.custom")
        tap(app, "range.apply")
        tap(app, "history.role")
        tap(app, "Product Ops · Studio North")
        tap(app, "history.export")
        XCTAssertEqual(app.staticTexts["export.selected"].label, "2 selected")
        tap(app, "export.format.star")
        tap(app, "export.preview", scroll: true)
        let preview = app.staticTexts["export.fullText"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(preview.label.contains("18 min → 7 min"))
        tap(app, "export.copy")
        XCTAssertTrue(app.staticTexts["status.message"].waitForExistence(timeout: uiTimeout))
        tap(app, "export.share")
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: uiTimeout))

        tap(app, "tab.history")
        let search = field(app, "history.search")
        tap(search, in: app)
        search.typeText("not a matching win")
        tap(app, "history.clear", scroll: true)
        XCTAssertTrue(app.staticTexts["history.count"].label.contains("3"))
    }

    func testExpiredRecordingAndPurchaseRestoreUnlockHistory() {
        let app = launch(["-seed-many", "-expired", "-restore-owned", "-no-focus"])
        tap(app, "tab.history")
        XCTAssertEqual(app.staticTexts["history.count"].label, "Wins: 20")
        tap(app, "tab.export")
        XCTAssertTrue(app.buttons["export.format.list"].exists)
        XCTAssertFalse(app.buttons["export.format.star"].exists)
        tap(app, "tab.capture")
        let input = field(app, "capture.action")
        tap(input, in: app)
        input.typeText("New win after expiry")
        tap(app, "capture.save")
        tap(app, "tab.settings")
        tap(app, "settings.restore", scroll: true)
        tap(app, "tab.history")
        XCTAssertEqual(app.staticTexts["history.count"].label, "Wins: 23")
        tap(app, "tab.export")
        XCTAssertTrue(app.buttons["export.format.star"].exists)
    }

    func testPaywallPurchaseOpensFeatures() {
        let app = launch(["-paywall", "-expired", "-no-focus"])
        tap(app, "paywall.buy")
        let owned = app.descendants(matching: .any)["paywall.owned"].firstMatch
        XCTAssertTrue(owned.waitForExistence(timeout: uiTimeout))
    }

    func testDeniedPermissionsLeaveCaptureAvailable() {
        let app = launch(["-deny-camera", "-deny-notifications", "-no-focus"],
                         environment: ["BRAG_DRAFT": "Save with permissions off"], draft: true)
        tap(app, "tab.settings")
        let toggle = app.switches["reminder.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: uiTimeout))
        tap(toggle, in: app, scroll: true)
        XCTAssertTrue(app.staticTexts["reminder.denied"].waitForExistence(timeout: uiTimeout))
        tap(app, "tab.capture")
        tap(app, "capture.details")
        tap(app, "edit.photo", scroll: true)
        tapConfirmation(app, "Camera")
        XCTAssertTrue(app.staticTexts["edit.photoMessage"].waitForExistence(timeout: uiTimeout))
        tap(app, "edit.save")
        XCTAssertTrue(app.staticTexts["status.message"].waitForExistence(timeout: uiTimeout))
    }

    func testMilestoneCardAndIdleReview() {
        var app = launch(["-milestone-ready", "-no-focus"], environment: ["BRAG_DRAFT": "Tenth win"], draft: true)
        tap(app, "capture.save")
        tap(app, "status.milestone")
        XCTAssertTrue(app.images["card.art"].waitForExistence(timeout: uiTimeout))
        tap(app, "card.share")
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: uiTimeout))
        XCTAssertFalse(app.staticTexts["review.requested"].exists)
        app.terminate()
        let id = UUID().uuidString
        app = launch(["-review-ready", "-no-focus"], id: id,
                     environment: ["BRAG_DRAFT": "A win on a third day"], draft: true)
        tap(app, "capture.save")
        XCTAssertTrue(app.staticTexts["review.requested"].waitForExistence(timeout: uiTimeout))
        app.terminate()
        app = launch(["-no-focus"], id: id, reset: false,
                     environment: ["BRAG_DRAFT": "Another win"], draft: true)
        tap(app, "capture.save")
        XCTAssertFalse(app.staticTexts["review.requested"].waitForExistence(timeout: uiTimeout))
    }

    func testTemplatePreviewImportAndRoleManagement() {
        let code = Data("""
        {"version":1,"format":"star","fields":["project","date"],"includeProject":false,"includeDate":false}
        """.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let app = launch(["-no-focus"], environment: ["BRAG_TEMPLATE": "BLT1:" + code])
        tap(app, "tab.settings")
        tap(app, "settings.paste.test", scroll: true)
        tap(app, "settings.templateImport", scroll: true)
        XCTAssertTrue(app.staticTexts["settings.templateStatus"].waitForExistence(timeout: uiTimeout))
        tap(app, "tab.export")
        XCTAssertTrue(app.buttons["export.format.star"].isSelected)
        tap(app, "tab.settings")
        tap(app, "settings.roles", scroll: true)
        tap(app, "role.add")
        let name = field(app, "role.name")
        tap(name, in: app, scroll: true)
        name.typeText("Stage 2")
        tap(app, "role.save", scroll: true)
        XCTAssertTrue(indexedButtons(app, prefix: "role.row.").firstMatch.waitForExistence(timeout: uiTimeout))
    }

    func testCSVPreviewAndImportWorkflow() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let fixture = """
        date,action,metric
        \(formatter.string(from: Date())),Restored from a backup,12 days
        2026-02-30,Invalid row,0
        """
        let app = launch(["-no-focus"], environment: ["BRAG_CSV": fixture])
        tap(app, "tab.settings")
        tap(app, "settings.csvIn", scroll: true)
        XCTAssertTrue(app.staticTexts["Preview CSV import"].waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(app.staticTexts["Invalid rows: 3"].exists)
        tap(app, "csv.apply", scroll: true)
        tap(app, "tab.history")
        let win = indexedButtons(app, prefix: "win.row.").firstMatch
        XCTAssertTrue(win.waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(win.label.contains("Restored from a backup"))
    }

    @discardableResult
    private func launch(_ flags: [String] = [], id: String = UUID().uuidString, reset: Bool = true,
                        environment: [String: String] = [:], draft: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (reset ? ["-reset"] : []) + (draft ? ["-draft"] : []) + flags
        app.launchEnvironment = environment.merging(["BRAG_TEST_ID": id]) { _, new in new }
        var retryLaunch = false
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            guard issue.compactDescription.contains("Failed to get launch progress") else { return false }
            retryLaunch = true
            return true
        }
        XCTExpectFailure("The simulator intermittently loses launch progress", options: options) {
            app.launch()
        }
        if retryLaunch { app.launch() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: uiTimeout), "App did not reach the foreground")
        return app
    }

    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (elementType == %d OR elementType == %d)",
            id, XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue))
        return query.firstMatch
    }

    private func indexedButtons(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    private func replace(_ item: XCUIElement, with value: String, in app: XCUIApplication,
                         file: StaticString = #filePath, line: UInt = #line) {
        guard let field = readyElement(in: app, scroll: true, name: item.debugDescription,
                                       file: file, line: line, find: { self.isTappable(item) ? item : nil })
        else { return }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let count = (field.value as? String ?? "").count + 2
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + value)
    }

    private func tap(_ app: XCUIApplication, _ name: String, scroll: Bool = false,
                     file: StaticString = #filePath, line: UInt = #line) {
        let query = app.buttons.matching(identifier: name)
        readyElement(in: app, scroll: scroll, name: name, file: file, line: line) {
            query.allElementsBoundByIndex.first(where: self.isTappable)
        }?.tap()
    }

    private func tap(_ item: XCUIElement, in app: XCUIApplication, scroll: Bool = false,
                     file: StaticString = #filePath, line: UInt = #line) {
        readyElement(in: app, scroll: scroll, name: item.debugDescription, file: file, line: line) {
            self.isTappable(item) ? item : nil
        }?.tap()
    }

    private func tapConfirmation(_ app: XCUIApplication, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let matchingLabel = NSPredicate(format: "label == %@", label)
        let alertButton = app.alerts.buttons.matching(matchingLabel).firstMatch
        let sheetButton = app.sheets.buttons.matching(matchingLabel).firstMatch
        readyElement(in: app, scroll: false, name: label, file: file, line: line) {
            [alertButton, sheetButton].first(where: self.isTappable)
        }?.tap()
    }

    private func dismissEditKeyboardIfVisible(in app: XCUIApplication) {
        let done = app.buttons["edit.keyboard"].firstMatch
        if isTappable(done) { done.tap() }
    }

    private func isTappable(_ item: XCUIElement) -> Bool {
        item.exists && item.isHittable && item.isEnabled
    }

    private func readyElement(in app: XCUIApplication, scroll: Bool, name: @autoclosure () -> String,
                              file: StaticString, line: UInt,
                              find: @escaping () -> XCUIElement?) -> XCUIElement? {
        if let item = find() { return item }
        if scroll {
            for _ in 0..<5 {
                app.swipeUp(velocity: .slow)
                if let item = find() { return item }
            }
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in find() != nil }, object: nil)
        if XCTWaiter.wait(for: [ready], timeout: uiTimeout) == .completed, let item = find() { return item }
        XCTFail("Element not visible and tappable: \(name())", file: file, line: line)
        return nil
    }
}

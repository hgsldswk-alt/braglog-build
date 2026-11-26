import XCTest

final class StoreScreenshots: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testStoreEnglish() { store("en", locale: "en_US") }
    func testStoreSimplifiedChinese() { store("zh-Hans", locale: "zh_CN") }
    func testStoreTraditionalChinese() { store("zh-Hant", locale: "zh_TW") }

    func testPaywallScreenshot() {
        let app = start("zh-Hans", locale: "zh_CN", flags: ["-paywall", "-paid-mode"])
        wait(app.buttons["paywall.buy"])
        wait(app.buttons["paywall.trial"])
        wait(app.buttons["paywall.restore"])
        shot(app, "paid-01-paywall")
    }

    private func store(_ language: String, locale: String) {
        let app = start(language, locale: locale, flags: ["-seed", "-draft"])
        let prefix = "store-\(language)-"
        wait(app.buttons["capture.save"])
        shot(app, prefix + "01-capture")

        tap(app, "tab.history")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "win.row.")).firstMatch
        wait(row)
        row.tap()
        wait(app.buttons["edit.save"])
        shot(app, prefix + "02-details")

        tap(app, "sheet.back")
        wait(app.staticTexts["history.count"])
        shot(app, prefix + "03-history")

        tap(app, "history.export")
        wait(app.staticTexts["export.previewText"])
        shot(app, prefix + "04-export")

        tap(app, "tab.capture")
        tap(app, "capture.count")
        wait(app.images["card.art"])
        shot(app, prefix + "05-card")
    }

    private func start(_ language: String, locale: String, flags: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset", "-no-focus", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", locale] + flags
        app.launchEnvironment = ["BRAG_TEST_ID": UUID().uuidString]
        app.launch()
        return app
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id].firstMatch
        wait(button)
        button.tap()
    }

    private func wait(_ item: XCUIElement) {
        XCTAssertTrue(item.waitForExistence(timeout: 8), "Missing \(item)")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let file = XCTAttachment(screenshot: app.screenshot())
        file.name = name
        file.lifetime = .keepAlways
        add(file)
    }
}

import XCTest

final class DeskPadUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Run on a simulator with no saved connections. This flow never saves one,
    /// so repeated runs leave the connection store unchanged and need no server.
    @MainActor
    func testConnectionListCanOpenValidateAndCancelNewConnection() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let list = app.navigationBars["DeskPad"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Connections"].exists)
        app.buttons["Add Connection"].tap()

        let form = app.navigationBars["New Connection"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let save = form.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "A server address is required before saving")
        let host = app.textFields["IP Address or Hostname"]
        host.tap()
        host.typeText("127.0.0.1")
        XCTAssertTrue(save.isEnabled)

        form.buttons["Cancel"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertFalse(form.exists)
        XCTAssertTrue(app.staticTexts["No Connections"].exists, "Cancel must not save a connection")
        XCTAssertTrue(app.buttons["Add Connection"].isHittable)
    }
}

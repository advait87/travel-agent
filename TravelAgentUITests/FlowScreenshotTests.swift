import XCTest

/// Walks the main flow on a demo trip and saves a screenshot after every step.
/// Screenshots go to $SCREENSHOT_DIR (pass TEST_RUNNER_SCREENSHOT_DIR to xcodebuild) and into the test report.
final class FlowScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-resetData", "-demoTrip"]
        app.launch()
    }

    func testRunningLateFlow() {
        XCTAssertTrue(app.staticTexts["Goa"].waitForExistence(timeout: 10))
        sleep(3)  // first check-in and map pins
        shot("home")

        // Tell the agent we stayed too long.
        let box = app.descendants(matching: .any)["agentBox"].firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()
        box.typeText("Still at Baga beach, staying longer than planned")
        shot("typed")
        app.buttons["Send"].firstMatch.tap()

        let apply = app.buttons["Apply"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 15), "The agent should propose a new plan")
        shot("proposal")

        apply.tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.buttons["Undo"].firstMatch.waitForExistence(timeout: 5))
        shot("applied")

        app.buttons["Undo"].firstMatch.tap()
        sleep(1)
        shot("undone")

        // The rest of Home: day cards, live card, feed.
        app.swipeUp()
        sleep(2)
        shot("day-cards")
        app.swipeUp()
        shot("live-card")
        app.swipeUp()
        shot("feed")

        // Full conversation.
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        let conversation = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'See conversation'")).firstMatch
        if conversation.waitForExistence(timeout: 3) {
            conversation.tap()
            sleep(1)
            shot("conversation")
            app.buttons["Close"].firstMatch.tap()
        }

        // Full map.
        let map = app.staticTexts["Open map"].firstMatch
        if map.waitForExistence(timeout: 3) {
            map.tap()
            sleep(4)
            shot("map")
        }
    }

    /// Taps "Allow" on the system notification prompt if it shows up.
    private func allowNotificationsIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    private func shot(_ name: String) {
        // DEMO_PACE (seconds) slows the walkthrough down for screen recordings.
        if let pace = ProcessInfo.processInfo.environment["DEMO_PACE"].flatMap(Double.init) {
            Thread.sleep(forTimeInterval: pace)
        }
        step += 1
        let label = String(format: "%02d-%@", step, name)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = label
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(label).png"))
        }
    }
}

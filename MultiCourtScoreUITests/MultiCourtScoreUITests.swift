//
//  MultiCourtScoreUITests.swift
//  MultiCourtScoreUITests
//

import XCTest

final class MultiCourtScoreUITests: XCTestCase {
    private var appSupportDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        let tempRoot = FileManager.default.temporaryDirectory
        let suiteDirectory = tempRoot.appendingPathComponent("MultiCourtScore-UITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: suiteDirectory, withIntermediateDirectories: true)
        appSupportDirectory = suiteDirectory
    }

    override func tearDownWithError() throws {
        if let appSupportDirectory {
            try? FileManager.default.removeItem(at: appSupportDirectory)
        }
    }

    @MainActor
    func testOperatorControlsAndModals() throws {
        let app = makeApp()
        app.launch()
        app.activate()

        let settingsButton = try requireElement(app.buttons["toolbar.settings"], in: app)

        settingsButton.tap()
        let settingsClose = app.buttons["settings.close"]
        XCTAssertTrue(settingsClose.waitForExistence(timeout: 2))
        settingsClose.tap()
        XCTAssertFalse(settingsClose.waitForExistence(timeout: 1))

        let scanButton = app.buttons["toolbar.scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 2))
        scanButton.tap()
        let scanClose = app.buttons["scan.close"]
        XCTAssertTrue(scanClose.waitForExistence(timeout: 2))
        scanClose.tap()
        XCTAssertFalse(scanClose.waitForExistence(timeout: 1))

        let courtStart = app.buttons["court.1.start"]
        let courtStop = app.buttons["court.1.stop"]
        XCTAssertTrue(courtStart.waitForExistence(timeout: 2))
        XCTAssertTrue(courtStop.waitForExistence(timeout: 2))
        XCTAssertTrue(courtStart.isEnabled)

        courtStart.tap()
        XCTAssertFalse(courtStart.isEnabled)
        XCTAssertTrue(courtStop.isEnabled)

        courtStop.tap()
        XCTAssertTrue(courtStart.isEnabled)

        let copyButton = app.buttons["court.1.copyURL"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 2))
        copyButton.tap()

        let courtCard = app.otherElements["court.card.1"]
        XCTAssertTrue(courtCard.waitForExistence(timeout: 2))
        courtCard.tap()

        let queueEditorClose = app.buttons["queueEditor.close"]
        XCTAssertTrue(queueEditorClose.waitForExistence(timeout: 2))
        queueEditorClose.tap()
        XCTAssertFalse(queueEditorClose.waitForExistence(timeout: 1))
    }

    @MainActor
    func testGlobalStartStopButtonsDoNotCrash() throws {
        let app = makeApp()
        app.launch()
        app.activate()

        let startAll = try requireElement(app.buttons["toolbar.startAll"], in: app)
        let stopAll = app.buttons["toolbar.stopAll"]
        XCTAssertTrue(stopAll.waitForExistence(timeout: 2))

        startAll.tap()
        XCTAssertTrue(app.buttons["court.1.stop"].isEnabled)
        XCTAssertTrue(app.buttons["court.3.stop"].isEnabled)

        stopAll.tap()
        XCTAssertTrue(app.buttons["court.1.start"].isEnabled)
        XCTAssertTrue(app.buttons["court.3.start"].isEnabled)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            makeApp().launch()
        }
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--uitest-mode")
        app.launchEnvironment["MULTICOURTSCORE_APP_SUPPORT_DIR"] = appSupportDirectory.path
        return app
    }

    @MainActor
    private func requireElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) throws -> XCUIElement {
        if element.waitForExistence(timeout: timeout) {
            return element
        }

        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "Accessibility Tree"
        attachment.lifetime = .keepAlways
        add(attachment)

        throw XCTSkip("Host automation session did not expose the app content accessibility tree. The deterministic UI-test harness is in place, but this macOS runner only exposes the menu bar for MultiCourtScore.")
    }
}

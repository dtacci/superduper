//
//  PindropUITests.swift
//  PindropUITests
//
//  Created on 2026-03-21.
//

import AppKit
import XCTest

final class PindropUITests: XCTestCase {
    private let targetBundleIdentifier = "com.dantacci.superduper-dictation"
    private let testModeKey = "PINDROP_TEST_MODE"
    private let uiTestModeKey = "PINDROP_UI_TEST_MODE"
    private let uiTestSurfaceKey = "PINDROP_UI_TEST_SURFACE"
    private let settingsTabKey = "PINDROP_UI_TEST_SETTINGS_TAB"
    private let defaultsSuiteKey = "PINDROP_TEST_USER_DEFAULTS_SUITE"
    private var launchedApplication: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let launchedApplication, launchedApplication.state != .notRunning {
            launchedApplication.terminate()
        }
        launchedApplication = nil
    }

    @MainActor
    func testSettingsFixtureLaunches() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(settingsTab: "general")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.toggle.launchAtLogin"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Interface Language"].exists)
    }

    @MainActor
    func testDictationTabFixtureLaunches() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(settingsTab: "dictation")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.picker.dictationLanguage"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Microphone"].exists)
    }

    @MainActor
    func testAppearanceTabFixtureLaunches() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(settingsTab: "appearance")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.theme.mode"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Theme Mode"].exists)
        XCTAssertTrue(app.staticTexts["Recording indicator"].exists)
    }

    @MainActor
    func testMeetingsFixtureArmsAndDisarmsOnlyTheSelectedOccurrence() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(surface: "meetings")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["meetings.page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Design review"].exists)

        let armButton = app.buttons["meeting.calendar.arm"]
        XCTAssertTrue(armButton.waitForExistence(timeout: 2))
        armButton.click()

        let disarmButton = app.buttons["meeting.calendar.disarm"]
        XCTAssertTrue(disarmButton.waitForExistence(timeout: 2))
        disarmButton.click()
        XCTAssertTrue(armButton.waitForExistence(timeout: 2))
    }

    @MainActor
    func testGoogleCalendarSetupWizardCompletesPrivacyConnectionAndReadiness() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(surface: "calendarSetup")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["googleCalendar.setupWizard"]
                .waitForExistence(timeout: 5)
        )

        app.buttons["Continue"].click()

        let connectButton = app.buttons["googleCalendar.setup.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 2))
        connectButton.click()

        let enableButton = app.buttons["googleCalendar.setup.enableLaunchAtLogin"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 2))
        enableButton.click()

        let finishButton = app.buttons["googleCalendar.setup.finish"]
        XCTAssertTrue(finishButton.isEnabled)
    }

    private func configuredApplication(
        surface: String = "settings",
        settingsTab: String = "general",
        defaultsSuite: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[testModeKey] = "1"
        app.launchEnvironment[uiTestModeKey] = "1"
        app.launchEnvironment[uiTestSurfaceKey] = surface
        app.launchEnvironment[settingsTabKey] = settingsTab
        if let defaultsSuite {
            app.launchEnvironment[defaultsSuiteKey] = defaultsSuite
        }
        return app
    }

    private func skipIfTargetAppIsAlreadyRunning() throws {
        let runningApplications = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleIdentifier)
        if !runningApplications.isEmpty {
            throw XCTSkip("Quit Pindrop before running UI tests so XCTest does not force-terminate your active app session.")
        }
    }

}

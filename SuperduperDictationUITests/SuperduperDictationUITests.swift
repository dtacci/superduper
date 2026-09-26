//
//  SuperduperDictationUITests.swift
//  SuperduperDictationUITests
//
//  Created on 2026-03-21.
//

import AppKit
import XCTest

final class SuperduperDictationUITests: XCTestCase {
    private let targetBundleIdentifier = "com.dantacci.superduper-dictation"
    private let testModeKey = "SUPERDUPER_TEST_MODE"
    private let uiTestModeKey = "SUPERDUPER_UI_TEST_MODE"
    private let uiTestSurfaceKey = "SUPERDUPER_UI_TEST_SURFACE"
    private let settingsTabKey = "SUPERDUPER_UI_TEST_SETTINGS_TAB"
    private let defaultsSuiteKey = "SUPERDUPER_TEST_USER_DEFAULTS_SUITE"
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
    func testWeeklyMeetingReviewStartsUnselectedAndAllowsExplicitSelection() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(surface: "meetings")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let reviewButton = app.buttons["meetings.reviewWeek"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5))
        reviewButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["meetings.weeklyReview"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Recommended to record"].exists)
        XCTAssertTrue(app.staticTexts["0 meeting recordings selected"].exists)

        let eventToggle = app.descendants(matching: .any)["meetings.weeklyReview.google:primary:fixture-event"]
        XCTAssertTrue(eventToggle.waitForExistence(timeout: 2))
        eventToggle.click()
        XCTAssertTrue(app.staticTexts["1 meeting recordings selected"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testGoogleCalendarSetupSignsInFromOneScreenAndOffersLaunchAtLogin() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(surface: "calendarSetup")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["googleCalendar.setupWizard"]
                .waitForExistence(timeout: 5)
        )
        // A built-in client means no client ID form until the user asks for one.
        XCTAssertFalse(app.textFields["googleCalendar.setup.clientID"].exists)

        let connectButton = app.buttons["googleCalendar.setup.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 2))
        connectButton.click()

        // While the browser is open the sign-in can be canceled and retried.
        let cancelButton = app.buttons["googleCalendar.setup.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
        cancelButton.click()
        XCTAssertTrue(connectButton.waitForExistence(timeout: 2))
        connectButton.click()

        let finishSignIn = app.buttons["fixture.finishGoogleSignIn"]
        XCTAssertTrue(finishSignIn.waitForExistence(timeout: 2))
        finishSignIn.click()

        let enableButton = app.buttons["googleCalendar.setup.enableLaunchAtLogin"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 2))
        let doneButton = app.buttons["googleCalendar.setup.finish"]
        XCTAssertTrue(doneButton.isEnabled)
        enableButton.click()
    }

    @MainActor
    func testGoogleCalendarSetupWizardAcceptsAClientIDWithoutRebuilding() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(surface: "calendarSetupUnconfigured")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        let connectButton = app.buttons["googleCalendar.setup.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        XCTAssertFalse(connectButton.isEnabled)

        let clientIDField = app.textFields["googleCalendar.setup.clientID"]
        XCTAssertTrue(clientIDField.waitForExistence(timeout: 2))
        clientIDField.click()
        clientIDField.typeText("friend.apps.googleusercontent.com")

        let saveButton = app.buttons["googleCalendar.setup.saveClientID"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.click()

        XCTAssertTrue(connectButton.waitForExistence(timeout: 2))
        XCTAssertTrue(connectButton.isEnabled)
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
            throw XCTSkip("Quit Superduper Dictation before running UI tests so XCTest does not force-terminate your active app session.")
        }
    }

}

//
//  AppTestMode.swift
//  SuperduperDictation
//
//  Created on 2026-03-21.
//

import AppKit
import SwiftData
import SwiftUI

enum AppTestMode {
    static let unitTestModeKey = "SUPERDUPER_TEST_MODE"
    static let uiTestModeKey = "SUPERDUPER_UI_TEST_MODE"
    static let uiTestSurfaceKey = "SUPERDUPER_UI_TEST_SURFACE"
    static let uiTestSettingsTabKey = "SUPERDUPER_UI_TEST_SETTINGS_TAB"
    static let testUserDefaultsSuiteKey = "SUPERDUPER_TEST_USER_DEFAULTS_SUITE"

    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var isRunningUITests: Bool {
        environment[uiTestModeKey] == "1"
    }

    static var isRunningUnitTests: Bool {
        !isRunningUITests && (
            environment[unitTestModeKey] == "1"
                || environment["XCTestConfigurationFilePath"] != nil
        )
    }

    static var isRunningAnyTests: Bool {
        isRunningUITests || isRunningUnitTests
    }
}

enum AppUITestSurface: String {
    case settings
    case meetings
    case calendarSetup
    case calendarSetupUnconfigured
}

enum AppUITestFixture {
    static var isEnabled: Bool {
        surface != nil
    }

    static var surface: AppUITestSurface? {
        guard AppTestMode.isRunningUITests else { return nil }
        let rawValue = AppTestMode.environment[AppTestMode.uiTestSurfaceKey] ?? AppUITestSurface.settings.rawValue
        return AppUITestSurface(rawValue: rawValue)
    }

    static var settingsInitialTab: SettingsTab {
        let rawValue = AppTestMode.environment[AppTestMode.uiTestSettingsTabKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return SettingsTab(rawValue: rawValue ?? "") ?? .general
    }

    @ViewBuilder
    @MainActor
    static func rootView() -> some View {
        switch surface {
        case .settings:
            SettingsFixtureRootView(initialTab: settingsInitialTab)
        case .meetings:
            MeetingsFixtureRootView()
        case .calendarSetup:
            GoogleCalendarSetupFixtureRootView(isConfigured: true)
        case .calendarSetupUnconfigured:
            GoogleCalendarSetupFixtureRootView(isConfigured: false)
        case nil:
            EmptyView()
        }
    }

    @MainActor
    static func configureApplication() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
private struct GoogleCalendarSetupFixtureRootView: View {
    @State private var state: MeetingsFeatureState

    init(isConfigured: Bool) {
        let state = MeetingsFeatureState()
        state.isGoogleConfigured = isConfigured
        state.activeGoogleClientID = isConfigured ? "built-in.apps.googleusercontent.com" : nil
        state.googleClientSource = isConfigured ? .builtIn : nil
        state.hasBuiltInGoogleClient = isConfigured
        _state = State(initialValue: state)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stands in for the browser round-trip: the connect finishes when the test
            // chooses "Finish sign-in" (a real sign-in happens outside the app).
            if state.isConnectingGoogle {
                Button("Finish sign-in") {
                    state.isConnectingGoogle = false
                    state.isGoogleConnected = true
                    state.googleAccountEmail = "me@example.com"
                }
                .padding(12)
                .accessibilityIdentifier("fixture.finishGoogleSignIn")
            }
            GoogleCalendarSetupWizard(
                meetingsState: state,
                actions: GoogleCalendarSetupActions(
                    connect: { state.isConnectingGoogle = true },
                    cancelConnect: { state.isConnectingGoogle = false },
                    saveCustomClient: { clientID, _ in
                        state.googleClientIDDraft = clientID
                        state.activeGoogleClientID = clientID
                        state.googleClientSource = .custom
                        state.isGoogleConfigured = true
                    },
                    enableLaunchAtLogin: { state.isLaunchAtLoginEnabled = true }
                )
            )
        }
    }
}

@MainActor
private struct MeetingsFixtureRootView: View {
    @State private var state: MeetingsFeatureState

    private static let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create meetings UI-test fixture model container: \(error)")
        }
    }()

    init() {
        let state = MeetingsFeatureState()
        state.isGoogleConfigured = true
        state.isGoogleConnected = true
        state.isLaunchAtLoginEnabled = true
        state.replaceEvents([
            MeetingOccurrenceSnapshot(
                id: "fixture-event",
                provider: "google",
                calendarID: "primary",
                eventID: "fixture-event",
                recurringEventID: nil,
                title: "Design review",
                start: Date().addingTimeInterval(3_600),
                end: Date().addingTimeInterval(5_400),
                joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
                rawSnapshotJSON: "{}",
                otherParticipantCount: 1,
                externalParticipantCount: 1
            )
        ])
        _state = State(initialValue: state)
    }

    var body: some View {
        MeetingsView(
            meetingsState: state,
            googleCalendarActions: GoogleCalendarSetupActions(
                enableLaunchAtLogin: { state.isLaunchAtLoginEnabled = true }
            ),
            onRefresh: {},
            onReviewWeek: { state.isWeeklyReviewPresented = true },
            onApplyWeeklySelection: { _ in state.isWeeklyReviewPresented = false },
            onRecordMeeting: {},
            onArm: { event in
                state.armedOccurrenceIDsByIdentity[event.persistentIdentity] = UUID()
            },
            onDisarm: { identity in
                state.armedOccurrenceIDsByIdentity[identity] = nil
            },
            onRetryProcessing: { _ in },
            onRegenerateInsights: { _ in }
        )
        .frame(minWidth: 900, minHeight: 620)
        .modelContainer(Self.modelContainer)
    }
}

private struct SettingsFixtureRootView: View {
    @StateObject private var settings = SettingsStore()

    let initialTab: SettingsTab

    /// Deterministic in-memory store so panes using @Query (e.g. Privacy) render
    /// in the fixture without touching the real persistent store.
    private static let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create UI-test fixture model container: \(error)")
        }
    }()

    var body: some View {
        SettingsPaneContent(settings: settings, tab: initialTab)
            .frame(minWidth: 620, minHeight: 420)
            .environment(\.locale, settings.selectedAppLocale.locale)
            .environment(\.layoutDirection, settings.selectedAppLocale.layoutDirection)
            .modelContainer(Self.modelContainer)
    }
}

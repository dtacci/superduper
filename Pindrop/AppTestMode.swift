//
//  AppTestMode.swift
//  Pindrop
//
//  Created on 2026-03-21.
//

import AppKit
import SwiftData
import SwiftUI

enum AppTestMode {
    static let unitTestModeKey = "PINDROP_TEST_MODE"
    static let uiTestModeKey = "PINDROP_UI_TEST_MODE"
    static let uiTestSurfaceKey = "PINDROP_UI_TEST_SURFACE"
    static let uiTestSettingsTabKey = "PINDROP_UI_TEST_SETTINGS_TAB"
    static let testUserDefaultsSuiteKey = "PINDROP_TEST_USER_DEFAULTS_SUITE"

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
            GoogleCalendarSetupFixtureRootView()
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
    @State private var state = MeetingsFeatureState()

    var body: some View {
        GoogleCalendarSetupWizard(
            meetingsState: state,
            onConnect: { state.isGoogleConnected = true },
            onEnableLaunchAtLogin: { state.isLaunchAtLoginEnabled = true }
        )
        .task {
            state.isGoogleConfigured = true
        }
    }
}

@MainActor
private struct MeetingsFixtureRootView: View {
    @State private var state = MeetingsFeatureState()

    private static let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create meetings UI-test fixture model container: \(error)")
        }
    }()

    var body: some View {
        MeetingsView(
            meetingsState: state,
            onConnect: {},
            onEnableLaunchAtLogin: { state.isLaunchAtLoginEnabled = true },
            onDisconnect: {},
            onRefresh: {},
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
        .task {
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
                    rawSnapshotJSON: "{}"
                )
            ])
        }
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

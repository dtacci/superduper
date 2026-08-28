//
//  StatusBarControllerTests.swift
//  PindropTests
//
//  Created on 2026-07-13.
//

import AppKit
import Testing
@testable import Pindrop

@MainActor
@Suite(.serialized)
struct StatusBarControllerTests {
    @Test func recordingIndicatorMenuIsCheckmarkedAndDoesNotChangeRecordingState() throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }
        let recorder = try AudioRecorder(
            permissionManager: MockPermissionProvider(),
            captureBackend: MockAudioCaptureBackend(identifier: "microphone"),
            systemAudioCaptureBackend: MockAudioCaptureBackend(identifier: "system")
        )
        let sut = StatusBarController(audioRecorder: recorder, settingsStore: settingsStore)
        let item = try #require(sut.recordingIndicatorMenuItemForTesting())

        #expect(item.state == .on)
        #expect(item.title == localized("Show Recording Indicator", locale: settingsStore.selectedAppLocale.locale))

        var toggleCount = 0
        sut.onToggleRecordingIndicator = {
            toggleCount += 1
            settingsStore.floatingIndicatorEnabled.toggle()
        }
        item.menu?.performActionForItem(at: item.menu?.index(of: item) ?? -1)
        sut.updateMenuState()

        #expect(toggleCount == 1)
        #expect(item.state == .off)
        #expect(!recorder.isRecording)
    }

    @Test func meetingCaptureMenuReflectsShortcutAndRecordingState() throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let audioRecorder = try AudioRecorder(
            permissionManager: MockPermissionProvider(),
            captureBackend: MockAudioCaptureBackend(identifier: "microphone"),
            systemAudioCaptureBackend: MockAudioCaptureBackend(identifier: "system")
        )
        let sut = StatusBarController(
            audioRecorder: audioRecorder,
            settingsStore: settingsStore
        )

        let meetingItem = try #require(sut.meetingCaptureMenuItemForTesting())
        let weeklyItem = try #require(sut.weeklyMeetingsMenuItemForTesting())
        let recordingItem = try #require(sut.recordingMenuItemForTesting())
        #expect(meetingItem.title == localized("Record Meeting", locale: settingsStore.selectedAppLocale.locale))
        #expect(meetingItem.isEnabled)
        #expect(meetingItem.action != nil)
        #expect(meetingItem.target === sut)
        #expect(meetingItem.keyEquivalent == " ")
        #expect(meetingItem.keyEquivalentModifierMask.contains(.option))
        #expect(meetingItem.keyEquivalentModifierMask.contains(.shift))

        #expect(weeklyItem.title == localized("Check Weekly Meetings", locale: settingsStore.selectedAppLocale.locale))
        #expect(weeklyItem.action != nil)
        #expect(weeklyItem.target === sut)
        var weeklyReviewCount = 0
        sut.onReviewWeeklyMeetings = { weeklyReviewCount += 1 }
        weeklyItem.menu?.performActionForItem(at: weeklyItem.menu?.index(of: weeklyItem) ?? -1)
        #expect(weeklyReviewCount == 1)

        sut.setRecordingState(isMeetingCapture: true)
        #expect(meetingItem.title == localized("Stop Meeting", locale: settingsStore.selectedAppLocale.locale))
        #expect(meetingItem.isEnabled)
        #expect(!recordingItem.isEnabled)

        sut.setProcessingState()
        #expect(!meetingItem.isEnabled)

        sut.setIdleState()
        #expect(meetingItem.title == localized("Record Meeting", locale: settingsStore.selectedAppLocale.locale))
        #expect(meetingItem.isEnabled)
        #expect(recordingItem.isEnabled)
    }

    @Test func promptPresetMenuShowsSelectionAndRoutesChanges() throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let provider = ProviderConfig(kind: .openai, displayName: "OpenAI")
        settingsStore.upsertProvider(provider)
        settingsStore.setAssignment(
            ModelAssignment(
                providerID: provider.id,
                modelID: "gpt-4o-mini",
                promptPresetID: BuiltInPresetID.cleanTranscript
            ),
            for: .transcriptionEnhancement
        )

        let audioRecorder = try AudioRecorder(
            permissionManager: MockPermissionProvider(),
            captureBackend: MockAudioCaptureBackend(identifier: "microphone"),
            systemAudioCaptureBackend: MockAudioCaptureBackend(identifier: "system")
        )
        let sut = StatusBarController(
            audioRecorder: audioRecorder,
            settingsStore: settingsStore
        )
        let clean = StatusBarController.PromptPresetOption(
            id: "clean-row-id",
            assignmentID: BuiltInPresetID.cleanTranscript,
            name: "Clean Transcript"
        )
        let meeting = StatusBarController.PromptPresetOption(
            id: "meeting-row-id",
            assignmentID: BuiltInPresets.meetingNotes.identifier,
            name: "Meeting Notes"
        )

        sut.updatePromptPresets([clean, meeting])

        var menu = try #require(sut.promptPresetMenuForTesting())
        #expect(menu.items.count == 2)
        #expect(menu.items[0].title == clean.name)
        #expect(menu.items[0].state == .on)
        #expect(menu.items[1].title == meeting.name)
        #expect(menu.items[1].state == .off)
        #expect(sut.promptPresetMenuItemForTesting()?.isEnabled == true)

        var didApplySelection = false
        sut.onSelectPromptPreset = { option in
            didApplySelection = AppCoordinator.applyPromptPresetSelection(
                option,
                to: settingsStore
            )
        }
        menu.performActionForItem(at: 1)
        #expect(didApplySelection)
        #expect(
            settingsStore.assignment(for: .transcriptionEnhancement)?.promptPresetID
                == meeting.assignmentID
        )
        #expect(settingsStore.selectedPresetId == meeting.id)

        #expect(menu.items[0].state == .off)
        #expect(menu.items[1].state == .on)

        settingsStore.selectedAppLocale = .german
        sut.reloadLocalizedStrings()
        menu = try #require(sut.promptPresetMenuForTesting())
        #expect(menu.items.count == 2)
        #expect(menu.items[0].state == .off)
        #expect(menu.items[1].state == .on)
        #expect(
            sut.promptPresetMenuItemForTesting()?.title
                == localized("Prompt Preset", locale: AppLocale.german.locale)
        )

        settingsStore.setAssignment(nil, for: .transcriptionEnhancement)
        sut.updateDynamicItems()
        #expect(sut.promptPresetMenuItemForTesting()?.isEnabled == false)
        #expect(!menu.items[0].isEnabled)
        #expect(!menu.items[1].isEnabled)

        sut.updatePromptPresets([])
        #expect(menu.items.isEmpty)
    }

    @Test func promptPresetSelectionMapsCustomIDsAndNoOpsWhenDisabled() {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let customID = UUID().uuidString
        let custom = StatusBarController.PromptPresetOption(
            id: customID,
            assignmentID: customID,
            name: "Custom Preset"
        )

        #expect(!AppCoordinator.applyPromptPresetSelection(custom, to: settingsStore))
        #expect(settingsStore.selectedPresetId == nil)

        settingsStore.setAssignment(
            ModelAssignment(
                providerID: UUID(),
                modelID: "gpt-4o-mini",
                promptPresetID: BuiltInPresetID.cleanTranscript
            ),
            for: .transcriptionEnhancement
        )

        #expect(AppCoordinator.applyPromptPresetSelection(custom, to: settingsStore))
        #expect(
            settingsStore.assignment(for: .transcriptionEnhancement)?.promptPresetID
                == customID
        )
        #expect(settingsStore.selectedPresetId == customID)
    }
}

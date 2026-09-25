//
//  OutputManagerTests.swift
//  SuperduperDictationTests
//
//  Created on 2026-01-25.
//

import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import SuperduperDictation

final class MockClipboard: ClipboardProtocol {
    var copiedText: String?
    var clipboardContent: String?
    var restoreCount = 0
    var lastRestoredSnapshot: ClipboardSnapshot?
    var changeCount = 0

    func copyToClipboard(_ text: String) -> Bool {
        copiedText = text
        clipboardContent = text
        changeCount += 1
        return true
    }

    func captureSnapshot() -> ClipboardSnapshot {
        guard let clipboardContent else {
            return ClipboardSnapshot(items: [], changeCount: changeCount)
        }

        let data = Data(clipboardContent.utf8)
        return ClipboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: data]], changeCount: changeCount)
    }

    func currentChangeCount() -> Int { changeCount }
    func currentStringContent() -> String? { clipboardContent }

    func restoreSnapshot(_ snapshot: ClipboardSnapshot) -> Bool {
        restoreCount += 1
        lastRestoredSnapshot = snapshot
        changeCount += 1

        guard let firstItem = snapshot.items.first,
              let data = firstItem[NSPasteboard.PasteboardType.string.rawValue] else {
            clipboardContent = nil
            copiedText = nil
            return true
        }

        let restoredText = String(data: data, encoding: .utf8)
        clipboardContent = restoredText
        copiedText = restoredText
        return true
    }
}

final class MockKeySimulation: KeySimulationProtocol {
    var pasteSimulated = false
    var simulatePasteCallCount = 0
    var lastAllowSystemEventsFallback: Bool?
    var allowSystemEventsFallbackHistory: [Bool] = []
    /// When set, `simulatePaste` throws — exercises the copy-only fallback paths.
    var pasteError: Error?

    func simulatePaste(allowSystemEventsFallback: Bool) async throws {
        lastAllowSystemEventsFallback = allowSystemEventsFallback
        allowSystemEventsFallbackHistory.append(allowSystemEventsFallback)
        if let pasteError {
            throw pasteError
        }
        pasteSimulated = true
        simulatePasteCallCount += 1
    }
}

/// Records requested delays without waiting, except the clipboard-restore delay,
/// which can be given a real duration to hold a restore pending.
final class RecordingSleeper {
    var durations: [UInt64] = []
    var restoreDelayNanoseconds: UInt64?

    func sleep(_ nanoseconds: UInt64) async throws {
        durations.append(nanoseconds)
        if nanoseconds == OutputManager.clipboardRestoreDelayNanoseconds,
           let restoreDelayNanoseconds {
            try await Task.sleep(nanoseconds: restoreDelayNanoseconds)
        }
    }
}

@MainActor
@Suite
struct OutputManagerTests {
    private func makeSUT(
        outputMode: OutputMode = .clipboard,
        accessibilityPermissionChecker: @escaping () -> Bool = { true },
        frontmostApplicationProvider: @escaping () -> NSRunningApplication? = { nil },
        virtualMachineHostChecker: @escaping (String?) -> Bool = { VirtualMachineHostDetector.isVirtualMachineHost(bundleIdentifier: $0) },
        sleeper: RecordingSleeper = RecordingSleeper(),
        modifierFlagsProvider: @escaping () -> CGEventFlags = { [] },
        screenLockedChecker: @escaping () -> Bool = { false }
    ) -> (outputManager: OutputManager, mockClipboard: MockClipboard, mockKeySimulation: MockKeySimulation) {
        let mockClipboard = MockClipboard()
        let mockKeySimulation = MockKeySimulation()
        let outputManager = OutputManager(
            outputMode: outputMode,
            clipboard: mockClipboard,
            keySimulation: mockKeySimulation,
            accessibilityPermissionChecker: accessibilityPermissionChecker,
            frontmostApplicationProvider: frontmostApplicationProvider,
            virtualMachineHostChecker: virtualMachineHostChecker,
            sleeper: { try await sleeper.sleep($0) },
            modifierFlagsProvider: modifierFlagsProvider,
            screenLockedChecker: screenLockedChecker
        )
        return (outputManager, mockClipboard, mockKeySimulation)
    }

    @Test func initialOutputModeIsClipboard() {
        let fixture = makeSUT()
        #expect(fixture.outputManager.outputMode == .clipboard)
    }

    @Test func setOutputMode() {
        let fixture = makeSUT()
        fixture.outputManager.setOutputMode(.directInsert)
        #expect(fixture.outputManager.outputMode == .directInsert)

        fixture.outputManager.setOutputMode(.clipboard)
        #expect(fixture.outputManager.outputMode == .clipboard)
    }

    @Test func copyToClipboard() throws {
        let fixture = makeSUT()
        let testText = "Hello from SuperduperDictation!"

        try fixture.outputManager.copyToClipboard(testText)

        #expect(fixture.mockClipboard.copiedText == testText)
        #expect(fixture.mockClipboard.clipboardContent == testText)
    }

    @Test func copyToClipboardReplacesExistingContent() throws {
        let fixture = makeSUT()

        try fixture.outputManager.copyToClipboard("First text")
        #expect(fixture.mockClipboard.copiedText == "First text")

        try fixture.outputManager.copyToClipboard("Second text")
        #expect(fixture.mockClipboard.copiedText == "Second text")
    }

    // Clipboard mode is copy-only: the transcript stays on the pasteboard, no paste
    // keystroke is simulated, and the prior contents ride along for Undo.
    @Test func outputWithClipboardMode() async throws {
        let fixture = makeSUT()
        fixture.outputManager.setOutputMode(.clipboard)
        fixture.mockClipboard.clipboardContent = "Previous clipboard content"

        let result = try await fixture.outputManager.output("Clipboard mode test")

        #expect(result.kind == .copiedToClipboard)
        #expect(result.clipboardFallbackReason == .copyOnlyMode)
        #expect(fixture.mockClipboard.clipboardContent == "Clipboard mode test")
        #expect(fixture.mockKeySimulation.pasteSimulated == false)
        #expect(fixture.mockClipboard.restoreCount == 0)

        let snapshot = try #require(result.previousClipboardSnapshot)
        #expect(fixture.outputManager.restoreClipboardSnapshot(snapshot))
        #expect(fixture.mockClipboard.clipboardContent == "Previous clipboard content")
    }

    @Test func outputWithEmptyTextThrowsError() async {
        let fixture = makeSUT()
        fixture.outputManager.setOutputMode(.clipboard)

        do {
            try await fixture.outputManager.output("")
            Issue.record("Expected error for empty text")
        } catch OutputManagerError.emptyText {
            #expect(fixture.mockClipboard.copiedText == nil)
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test func checkAccessibilityPermission() {
        let fixture = makeSUT()
        let hasPermission = fixture.outputManager.checkAccessibilityPermission()
        #expect(hasPermission == true || hasPermission == false)
    }

    // Direct insert is paste-based: one atomic Cmd+V with clipboard snapshot/restore.
    @Test func directInsertPastesAndRestoresClipboard() async throws {
        let fixture = makeSUT(outputMode: .directInsert)
        fixture.mockClipboard.clipboardContent = "Previous clipboard content"

        let result = try await fixture.outputManager.output("Direct insert test")
        await fixture.outputManager.awaitPendingClipboardRestore()

        #expect(result.kind == .pasted)
        #expect(fixture.mockKeySimulation.pasteSimulated)
        #expect(fixture.mockClipboard.restoreCount == 1)
        #expect(fixture.mockClipboard.clipboardContent == "Previous clipboard content")
    }

    // Only the short pre-paste settle and the deferred restore delay remain; the
    // restore no longer blocks `output` from returning.
    @Test func directInsertSleepsOnlyPrePasteAndDeferredRestoreDelays() async throws {
        let sleeper = RecordingSleeper()
        let fixture = makeSUT(outputMode: .directInsert, sleeper: sleeper)
        fixture.mockClipboard.clipboardContent = "previous"

        _ = try await fixture.outputManager.output("Fast words")
        await fixture.outputManager.awaitPendingClipboardRestore()

        #expect(sleeper.durations == [
            OutputManager.prePasteDelayNanoseconds,
            OutputManager.clipboardRestoreDelayNanoseconds,
        ])
    }

    @Test func outputReturnsBeforeDeferredClipboardRestore() async throws {
        let sleeper = RecordingSleeper()
        sleeper.restoreDelayNanoseconds = 10_000_000_000
        let fixture = makeSUT(outputMode: .directInsert, sleeper: sleeper)
        fixture.mockClipboard.clipboardContent = "previous"

        let result = try await fixture.outputManager.output("Pasted words")

        #expect(result.kind == .pasted)
        #expect(fixture.mockClipboard.restoreCount == 0)
        #expect(fixture.mockClipboard.clipboardContent == "Pasted words")

        fixture.outputManager.flushPendingClipboardRestore()
        #expect(fixture.mockClipboard.restoreCount == 1)
        #expect(fixture.mockClipboard.clipboardContent == "previous")
    }

    @Test func pasteWaitsForHeldHotkeyModifiers() async throws {
        let sleeper = RecordingSleeper()
        var heldPolls = 3
        let fixture = makeSUT(
            outputMode: .directInsert,
            sleeper: sleeper,
            modifierFlagsProvider: {
                guard heldPolls > 0 else { return [] }
                heldPolls -= 1
                return .maskAlternate
            }
        )

        _ = try await fixture.outputManager.output("Held modifier")

        #expect(Array(sleeper.durations.prefix(4)) == [
            OutputManager.modifierReleasePollNanoseconds,
            OutputManager.modifierReleasePollNanoseconds,
            OutputManager.modifierReleasePollNanoseconds,
            OutputManager.prePasteDelayNanoseconds,
        ])
        #expect(fixture.mockKeySimulation.pasteSimulated)
    }

    @Test func pasteProceedsAfterModifierWaitCap() async throws {
        let sleeper = RecordingSleeper()
        let fixture = makeSUT(
            outputMode: .directInsert,
            sleeper: sleeper,
            modifierFlagsProvider: { .maskAlternate }
        )

        _ = try await fixture.outputManager.output("Stuck modifier")

        let pollCount = sleeper.durations.filter { $0 == OutputManager.modifierReleasePollNanoseconds }.count
        #expect(UInt64(pollCount) == OutputManager.modifierReleaseMaxWaitNanoseconds / OutputManager.modifierReleasePollNanoseconds)
        #expect(fixture.mockKeySimulation.pasteSimulated)
    }

    // Back-to-back dictations: the second paste must snapshot the user's clipboard,
    // not the first transcript that is still waiting for its deferred restore.
    @Test func nextPasteSnapshotsUserClipboardNotTransientTranscript() async throws {
        let sleeper = RecordingSleeper()
        sleeper.restoreDelayNanoseconds = 50_000_000
        let fixture = makeSUT(outputMode: .directInsert, sleeper: sleeper)
        fixture.mockClipboard.clipboardContent = "previous"

        _ = try await fixture.outputManager.output("First transcript")
        _ = try await fixture.outputManager.output("Second transcript")
        await fixture.outputManager.awaitPendingClipboardRestore()

        #expect(fixture.mockClipboard.restoreCount == 2)
        #expect(fixture.mockClipboard.clipboardContent == "previous")
    }

    @Test func copyReplacingClipboardFlushesPendingRestore() async throws {
        let sleeper = RecordingSleeper()
        sleeper.restoreDelayNanoseconds = 10_000_000_000
        let fixture = makeSUT(outputMode: .directInsert, sleeper: sleeper)
        fixture.mockClipboard.clipboardContent = "previous"

        _ = try await fixture.outputManager.output("Pasted words")
        let snapshot = try fixture.outputManager.copyReplacingClipboard("Copied from history")

        let data = try #require(snapshot.items.first?[NSPasteboard.PasteboardType.string.rawValue])
        #expect(String(data: data, encoding: .utf8) == "previous")
        #expect(fixture.mockClipboard.clipboardContent == "Copied from history")
    }

    // A long recording can end after the Mac locked; pasting would type into the
    // lock screen, so the transcript is copied instead.
    @Test func directInsertCopiesInsteadOfPastingWhileScreenIsLocked() async throws {
        let fixture = makeSUT(outputMode: .directInsert, screenLockedChecker: { true })
        fixture.mockClipboard.clipboardContent = "previous"

        let result = try await fixture.outputManager.output("Meeting notes")

        #expect(result.kind == .copiedToClipboard)
        #expect(result.clipboardFallbackReason == .screenLocked)
        #expect(fixture.mockKeySimulation.pasteSimulated == false)
        #expect(fixture.mockClipboard.clipboardContent == "Meeting notes")
        #expect(result.previousClipboardSnapshot != nil)
    }

    @Test func loginWindowDestinationIsTreatedAsLocked() async throws {
        let loginWindow = NSRunningApplication.runningApplications(
            withBundleIdentifier: ScreenLockState.loginWindowBundleIdentifier
        ).first
        guard let loginWindow else { return }
        let fixture = makeSUT(outputMode: .directInsert, frontmostApplicationProvider: { loginWindow })

        let result = try await fixture.outputManager.output("Hidden words")

        #expect(result.clipboardFallbackReason == .screenLocked)
        #expect(fixture.mockKeySimulation.pasteSimulated == false)
    }

    @Test func directInsertCopiesOnlyWithoutAccessibility() async throws {
        let fixture = makeSUT(outputMode: .directInsert, accessibilityPermissionChecker: { false })

        let result = try await fixture.outputManager.output("Direct insert test")

        #expect(result.kind == .copiedToClipboard)
        #expect(fixture.mockClipboard.copiedText == "Direct insert test")
        #expect(fixture.mockKeySimulation.pasteSimulated == false)
        #expect(fixture.mockClipboard.restoreCount == 0)
    }

    @Test func directInsertFallsBackToCopyWhenPasteFails() async throws {
        struct PasteFailure: Error {}
        let fixture = makeSUT(outputMode: .directInsert)
        fixture.mockKeySimulation.pasteError = PasteFailure()

        let result = try await fixture.outputManager.output("Important words")

        // The user's words must never be lost: paste failed, so the text stays on the
        // clipboard and the caller is told so.
        #expect(result.kind == .copiedToClipboard)
        #expect(fixture.mockClipboard.copiedText == "Important words")
        #expect(fixture.mockClipboard.clipboardContent == "Important words")
    }

    // Copy-only mode doesn't depend on Accessibility at all.
    @Test func clipboardModeIsCopyOnlyRegardlessOfAccessibility() async throws {
        for hasAccessibility in [false, true] {
            let fixture = makeSUT(
                outputMode: .clipboard,
                accessibilityPermissionChecker: { hasAccessibility }
            )

            let result = try await fixture.outputManager.output("Clipboard test")

            #expect(result.kind == .copiedToClipboard)
            #expect(result.clipboardFallbackReason == .copyOnlyMode)
            #expect(fixture.mockClipboard.clipboardContent == "Clipboard test")
            #expect(fixture.mockKeySimulation.pasteSimulated == false)
            #expect(fixture.mockClipboard.restoreCount == 0)
        }
    }

    @Test func clipboardFallbackWithoutAccessibilityReportsIntentionalReasonAndSnapshot() async throws {
        let fixture = makeSUT(outputMode: .directInsert, accessibilityPermissionChecker: { false })
        fixture.mockClipboard.clipboardContent = "previous"

        let result = try await fixture.outputManager.output("New text")

        #expect(result.clipboardFallbackReason == .accessibilityUnavailable)
        // The prior pasteboard contents come back with the result so callers can
        // offer Undo for the intentional copy fallback.
        let snapshot = try #require(result.previousClipboardSnapshot)
        #expect(fixture.outputManager.restoreClipboardSnapshot(snapshot))
        #expect(fixture.mockClipboard.clipboardContent == "previous")
    }

    @Test func pasteFailureFallbackReportsPasteFailedReason() async throws {
        struct PasteFailure: Error {}
        let fixture = makeSUT(outputMode: .directInsert)
        fixture.mockKeySimulation.pasteError = PasteFailure()

        let result = try await fixture.outputManager.output("Important words")

        #expect(result.clipboardFallbackReason == .pasteFailed)
        #expect(result.previousClipboardSnapshot == nil)
    }

    // Once the paste keystroke lands the insertion is committed: cancelling the
    // surrounding operation during the deferred restore window must neither fail
    // the output nor skip the clipboard restore.
    @Test func cancellationDuringRestoreWindowStillReportsPastedAndRestores() async throws {
        let sleeper = RecordingSleeper()
        sleeper.restoreDelayNanoseconds = 100_000_000
        let fixture = makeSUT(outputMode: .directInsert, sleeper: sleeper)
        fixture.mockClipboard.clipboardContent = "previous"

        let task = Task { @MainActor in
            try await fixture.outputManager.output("Committed words")
        }
        let result = try await task.value
        // Cancel while the deferred restore is still pending.
        task.cancel()
        await fixture.outputManager.awaitPendingClipboardRestore()

        #expect(result.kind == .pasted)
        #expect(fixture.mockKeySimulation.pasteSimulated)
        #expect(fixture.mockClipboard.restoreCount == 1)
        #expect(fixture.mockClipboard.clipboardContent == "previous")
    }

    // Cancellation before the paste keystroke aborts cleanly: the prior clipboard
    // comes back and no copy fallback pretends the output happened.
    @Test func cancellationBeforePasteAbortsWithoutClipboardFallback() async throws {
        final class BlockingKeySimulation: KeySimulationProtocol {
            func simulatePaste(allowSystemEventsFallback: Bool) async throws {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }

        let mockClipboard = MockClipboard()
        let outputManager = OutputManager(
            outputMode: .directInsert,
            clipboard: mockClipboard,
            keySimulation: BlockingKeySimulation(),
            accessibilityPermissionChecker: { true },
            frontmostApplicationProvider: { nil },
            virtualMachineHostChecker: { _ in false },
            modifierFlagsProvider: { [] },
            screenLockedChecker: { false }
        )
        mockClipboard.clipboardContent = "previous"

        let task = Task { @MainActor in
            try await outputManager.output("Aborted words")
        }
        // Land the cancel while the paste keystroke is still blocked.
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(mockClipboard.clipboardContent == "previous")
    }

    @Test func outputCapturesFrontmostAppDestinationOnDirectInsert() async throws {
        let current = NSRunningApplication.current
        let fixture = makeSUT(
            outputMode: .directInsert,
            frontmostApplicationProvider: { current }
        )

        let result = try await fixture.outputManager.output("Hello world")

        #expect(result.kind == .pasted)
        #expect(result.destinationAppName == current.localizedName)
        #expect(result.destinationAppBundleID == current.bundleIdentifier)
    }

    @Test func outputCapturesFrontmostAppDestinationInClipboardMode() async throws {
        let current = NSRunningApplication.current
        let fixture = makeSUT(
            outputMode: .clipboard,
            frontmostApplicationProvider: { current }
        )

        let result = try await fixture.outputManager.output("Clipboard only")

        #expect(result.kind == .copiedToClipboard)
        #expect(result.clipboardFallbackReason == .copyOnlyMode)
        #expect(result.destinationAppName == current.localizedName)
        #expect(result.destinationAppBundleID == current.bundleIdentifier)
    }

    @Test func outputCapturesNilDestinationWhenProviderReturnsNil() async throws {
        let fixture = makeSUT(outputMode: .directInsert, frontmostApplicationProvider: { nil })

        let result = try await fixture.outputManager.output("No app")

        #expect(result.kind == .pasted)
        #expect(result.destinationAppName == nil)
        #expect(result.destinationAppBundleID == nil)
    }

    @Test func errorDescriptions() {
        #expect(OutputManagerError.accessibilityPermissionDenied.errorDescription != nil)
        #expect(OutputManagerError.emptyText.errorDescription != nil)
        #expect(OutputManagerError.clipboardWriteFailed.errorDescription != nil)
        #expect(OutputManagerError.textInsertionFailed.errorDescription != nil)
    }

    @Test func mockClipboardTracksOperations() {
        let mockClipboard = MockClipboard()
        #expect(mockClipboard.copiedText == nil)
        #expect(mockClipboard.clipboardContent == nil)
        #expect(mockClipboard.restoreCount == 0)

        let success = mockClipboard.copyToClipboard("test")
        #expect(success)
        #expect(mockClipboard.copiedText == "test")
        #expect(mockClipboard.clipboardContent == "test")

        let snapshot = mockClipboard.captureSnapshot()
        mockClipboard.clipboardContent = nil
        mockClipboard.copiedText = nil

        #expect(mockClipboard.restoreSnapshot(snapshot))
        #expect(mockClipboard.restoreCount == 1)
        #expect(mockClipboard.clipboardContent == "test")
    }

    @Test func mockKeySimulationTracksPaste() async throws {
        let mockKeySimulation = MockKeySimulation()
        #expect(mockKeySimulation.pasteSimulated == false)
        #expect(mockKeySimulation.simulatePasteCallCount == 0)

        try await mockKeySimulation.simulatePaste()

        #expect(mockKeySimulation.pasteSimulated)
        #expect(mockKeySimulation.simulatePasteCallCount == 1)
        #expect(mockKeySimulation.lastAllowSystemEventsFallback == true)
    }

    @Test func systemKeySimulationPostsPhysicalCommandAroundPasteShortcut() async throws {
        var postedEvents: [KeySimulationEvent] = []
        var sleepDurations: [UInt64] = []
        var systemEventsFallbackCalled = false
        let sut = SystemKeySimulation(
            pasteScriptRunner: {
                systemEventsFallbackCalled = true
                return false
            },
            keyEventPoster: { _, event in
                postedEvents.append(event)
                return true
            },
            sleeper: { duration in
                sleepDurations.append(duration)
            }
        )

        try await sut.simulatePaste()

        #expect(postedEvents == [
            KeySimulationEvent(virtualKey: 0x37, keyDown: true, flags: .maskCommand),
            KeySimulationEvent(virtualKey: 0x09, keyDown: true, flags: .maskCommand),
            KeySimulationEvent(virtualKey: 0x09, keyDown: false, flags: .maskCommand),
            KeySimulationEvent(virtualKey: 0x37, keyDown: false, flags: []),
        ])
        #expect(sleepDurations == Array(repeating: SystemKeySimulation.nativeKeyEventGapNanoseconds, count: 3))
        #expect(systemEventsFallbackCalled == false)
    }

    // VM hosts (System Events fallback disabled) keep wide gaps; hypervisors drop
    // modifier events that arrive too close together.
    @Test func systemKeySimulationUsesWideGapsForVirtualMachines() async throws {
        var sleepDurations: [UInt64] = []
        let sut = SystemKeySimulation(
            pasteScriptRunner: { false },
            keyEventPoster: { _, _ in true },
            sleeper: { duration in
                sleepDurations.append(duration)
            }
        )

        try await sut.simulatePaste(allowSystemEventsFallback: false)

        #expect(sleepDurations == Array(repeating: SystemKeySimulation.virtualMachineKeyEventGapNanoseconds, count: 3))
    }

    @Test func systemKeySimulationFallsBackToSystemEventsWhenCGEventPostingFails() async throws {
        var postedEvents: [KeySimulationEvent] = []
        var systemEventsFallbackCalled = false
        let sut = SystemKeySimulation(
            pasteScriptRunner: {
                systemEventsFallbackCalled = true
                return true
            },
            keyEventPoster: { _, event in
                postedEvents.append(event)
                return false
            },
            sleeper: { _ in }
        )

        try await sut.simulatePaste()

        // Command-down fails → no stuck-modifier cleanup needed; System Events fallback runs.
        #expect(postedEvents == [
            KeySimulationEvent(virtualKey: 0x37, keyDown: true, flags: .maskCommand),
        ])
        #expect(systemEventsFallbackCalled)
    }

    @Test func systemKeySimulationReleasesCommandWhenLaterEventCreationFails() async throws {
        var postedEvents: [KeySimulationEvent] = []
        var systemEventsFallbackCalled = false
        let sut = SystemKeySimulation(
            pasteScriptRunner: {
                systemEventsFallbackCalled = true
                return false
            },
            keyEventPoster: { _, event in
                postedEvents.append(event)
                // Succeed Command-down, fail V-down so defer must emit Command-up.
                if event.virtualKey == 0x09 && event.keyDown {
                    return false
                }
                return true
            },
            sleeper: { _ in }
        )

        await #expect(throws: OutputManagerError.textInsertionFailed) {
            try await sut.simulatePaste(allowSystemEventsFallback: false)
        }

        #expect(postedEvents == [
            KeySimulationEvent(virtualKey: 0x37, keyDown: true, flags: .maskCommand),
            KeySimulationEvent(virtualKey: 0x09, keyDown: true, flags: .maskCommand),
            KeySimulationEvent(virtualKey: 0x37, keyDown: false, flags: []),
        ])
        #expect(systemEventsFallbackCalled == false)
    }

    @Test func systemKeySimulationSkipsSystemEventsFallbackWhenDisabled() async throws {
        var systemEventsFallbackCalled = false
        let sut = SystemKeySimulation(
            pasteScriptRunner: {
                systemEventsFallbackCalled = true
                return true
            },
            keyEventPoster: { _, _ in false },
            sleeper: { _ in }
        )

        await #expect(throws: OutputManagerError.textInsertionFailed) {
            try await sut.simulatePaste(allowSystemEventsFallback: false)
        }
        #expect(systemEventsFallbackCalled == false)
    }

    @Test func nativeDirectInsertAllowsSystemEventsFallback() async throws {
        let fixture = makeSUT(
            outputMode: .directInsert,
            virtualMachineHostChecker: { _ in false }
        )

        let result = try await fixture.outputManager.output("Native app text")

        #expect(result.kind == .pasted)
        #expect(fixture.mockKeySimulation.pasteSimulated)
        #expect(fixture.mockKeySimulation.lastAllowSystemEventsFallback == true)
    }

    @Test func knownVMDirectInsertUsesClipboardPasteWithoutSystemEventsFallback() async throws {
        let fixture = makeSUT(
            outputMode: .directInsert,
            virtualMachineHostChecker: { _ in true }
        )
        fixture.mockClipboard.clipboardContent = "previous"

        let result = try await fixture.outputManager.output("Hello from VM")
        await fixture.outputManager.awaitPendingClipboardRestore()

        #expect(result.kind == .pasted)
        #expect(fixture.mockKeySimulation.pasteSimulated)
        #expect(fixture.mockKeySimulation.lastAllowSystemEventsFallback == false)
        #expect(fixture.mockClipboard.restoreCount == 1)
        #expect(fixture.mockClipboard.clipboardContent == "previous")
    }

    @Test func virtualMachineHostDetectorRecognizesKnownHosts() {
        let known = [
            "com.vmware.fusion",
            "com.vmware.vmware-vmx",
            "com.parallels.desktop.console",
            "org.virtualbox.app.VirtualBox",
            "org.virtualbox.app.VirtualBoxVM",
            "codes.rambo.VirtualBuddy",
            // Case / whitespace normalization
            " COM.VMWARE.FUSION ",
            // Vendor helper prefix
            "com.vmware.fusion.helper",
        ]

        for bundleID in known {
            #expect(
                VirtualMachineHostDetector.isVirtualMachineHost(bundleIdentifier: bundleID),
                "Expected VM host for \(bundleID)"
            )
        }
    }

    @Test func virtualMachineHostDetectorRejectsNativeApps() {
        let native = [
            "com.apple.TextEdit",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "",
            "   ",
        ]

        for bundleID in native {
            #expect(
                VirtualMachineHostDetector.isVirtualMachineHost(bundleIdentifier: bundleID) == false,
                "Expected non-VM for \(bundleID)"
            )
        }
        #expect(VirtualMachineHostDetector.isVirtualMachineHost(bundleIdentifier: nil) == false)
    }
}

//
//  OutputManager.swift
//  Pindrop
//
//  Created on 2026-01-25.
//

import Foundation
import AppKit
import ApplicationServices
import os.log

enum OutputMode {
    case clipboard
    case directInsert
}

enum OutputManagerError: Error, LocalizedError {
    case accessibilityPermissionDenied
    case emptyText
    case clipboardWriteFailed
    case textInsertionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required for direct text insertion"
        case .emptyText:
            return "Cannot output empty text"
        case .clipboardWriteFailed:
            return "Failed to write text to clipboard"
        case .textInsertionFailed:
            return "Failed to insert text directly"
        }
    }
}

// MARK: - Protocols

protocol ClipboardProtocol {
    func copyToClipboard(_ text: String) -> Bool
    func captureSnapshot() -> ClipboardSnapshot
    func currentChangeCount() -> Int
    func currentStringContent() -> String?
    func restoreSnapshot(_ snapshot: ClipboardSnapshot) -> Bool
}

struct ClipboardSnapshot: Equatable {
    let items: [[String: Data]]
    let changeCount: Int

    static let empty = ClipboardSnapshot(items: [], changeCount: 0)
}

protocol KeySimulationProtocol {
    /// Simulates ⌘V.
    /// - Parameter allowSystemEventsFallback: When `true`, a failed CGEvent sequence may
    ///   fall back to System Events. Hypervisors often ignore System Events' synthetic
    ///   modifiers and only receive a bare `v`, so callers should pass `false` for known VM hosts.
    func simulatePaste(allowSystemEventsFallback: Bool) async throws
}

extension KeySimulationProtocol {
    func simulatePaste() async throws {
        try await simulatePaste(allowSystemEventsFallback: true)
    }
}

struct KeySimulationEvent: Equatable {
    let virtualKey: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

/// Conservative detection of frontmost hypervisor / VM host apps where Unicode key
/// injection (`virtualKey: 0`) and System Events paste are unreliable.
enum VirtualMachineHostDetector {
    /// Bundle IDs for VMware Fusion, Parallels, VirtualBox, and VirtualBuddy/AVF hosts.
    static let knownBundleIdentifiers: Set<String> = [
        "com.vmware.fusion",
        "com.vmware.vmware-vmx",
        "com.parallels.desktop.console",
        "org.virtualbox.app.virtualbox",
        "org.virtualbox.app.virtualboxvm",
        "codes.rambo.virtualbuddy",
    ]

    static func isVirtualMachineHost(bundleIdentifier: String?) -> Bool {
        guard let normalized = normalizedBundleIdentifier(bundleIdentifier) else {
            return false
        }
        if knownBundleIdentifiers.contains(normalized) {
            return true
        }
        // Prefix matches catch helper / guest-window processes that share a vendor root.
        return knownBundleIdentifiers.contains { known in
            normalized.hasPrefix(known + ".")
        }
    }

    static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        let normalized = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - Real Implementations

final class SystemClipboard: ClipboardProtocol {
    func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func captureSnapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        guard let pasteboardItems = pasteboard.pasteboardItems else {
            return .empty
        }

        let items = pasteboardItems.map { item in
            var capturedItem: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    capturedItem[type.rawValue] = data
                }
            }
            return capturedItem
        }

        return ClipboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    func currentChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    func currentStringContent() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func restoreSnapshot(_ snapshot: ClipboardSnapshot) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return true
        }

        let pasteboardItems = snapshot.items.map { capturedItem in
            let item = NSPasteboardItem()
            for (type, data) in capturedItem {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }

        return pasteboard.writeObjects(pasteboardItems)
    }
}

final class SystemKeySimulation: KeySimulationProtocol {
    private let pasteScriptRunner: () throws -> Bool
    private let keyEventPoster: (CGEventSource?, KeySimulationEvent) -> Bool
    private let sleeper: (UInt64) async throws -> Void

    init(
        pasteScriptRunner: @escaping () throws -> Bool = SystemKeySimulation.runSystemEventsPasteScript,
        keyEventPoster: @escaping (CGEventSource?, KeySimulationEvent) -> Bool = SystemKeySimulation.postKeyEvent,
        sleeper: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.pasteScriptRunner = pasteScriptRunner
        self.keyEventPoster = keyEventPoster
        self.sleeper = sleeper
    }

    /// Gap between the synthetic ⌘/V key events for native apps.
    static let nativeKeyEventGapNanoseconds: UInt64 = 8_000_000
    /// Hypervisors drop modifier events that arrive too close together, so VM hosts
    /// keep the original wide gap.
    static let virtualMachineKeyEventGapNanoseconds: UInt64 = 50_000_000

    func simulatePaste(allowSystemEventsFallback: Bool) async throws {
        // Callers disable the System Events fallback exactly for known VM hosts.
        let keyEventGap = allowSystemEventsFallback
            ? Self.nativeKeyEventGapNanoseconds
            : Self.virtualMachineKeyEventGapNanoseconds
        do {
            try await simulatePasteWithCGEvent(keyEventGapNanoseconds: keyEventGap)
            return
        } catch {
            guard allowSystemEventsFallback else {
                throw error
            }

            Log.output.debug("CGEvent paste failed; falling back to System Events: \(error.localizedDescription)")
            if try pasteScriptRunner() {
                return
            }

            throw error
        }
    }

    private static func runSystemEventsPasteScript() throws -> Bool {
        let scriptSource = "tell application \"System Events\" to keystroke \"v\" using command down"
        guard let script = NSAppleScript(source: scriptSource) else {
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error {
            Log.output.debug("System Events paste failed: \(String(describing: error))")
            return false
        }

        return true
    }

    /// Posts an explicit physical Command down/up around `v`. Hypervisors ignore
    /// `.maskCommand` alone and only honor real modifier key events.
    ///
    /// If any event after Command-down fails to create/post, Command-up is still
    /// emitted so the modifier is not left stuck.
    private func simulatePasteWithCGEvent(keyEventGapNanoseconds: UInt64) async throws {
        let commandKeyCode: CGKeyCode = 0x37
        let vKeyCode: CGKeyCode = 0x09
        let source = CGEventSource(stateID: .hidSystemState)

        var commandIsDown = false
        defer {
            if commandIsDown {
                // Best-effort cleanup; ignore failure so the original error surfaces.
                _ = keyEventPoster(
                    source,
                    KeySimulationEvent(virtualKey: commandKeyCode, keyDown: false, flags: [])
                )
            }
        }

        let commandDown = KeySimulationEvent(virtualKey: commandKeyCode, keyDown: true, flags: .maskCommand)
        guard keyEventPoster(source, commandDown) else {
            Log.output.error("Failed to create CGEvent for paste")
            throw OutputManagerError.textInsertionFailed
        }
        commandIsDown = true
        try await sleeper(keyEventGapNanoseconds)

        let vDown = KeySimulationEvent(virtualKey: vKeyCode, keyDown: true, flags: .maskCommand)
        guard keyEventPoster(source, vDown) else {
            Log.output.error("Failed to create CGEvent for paste")
            throw OutputManagerError.textInsertionFailed
        }
        try await sleeper(keyEventGapNanoseconds)

        let vUp = KeySimulationEvent(virtualKey: vKeyCode, keyDown: false, flags: .maskCommand)
        guard keyEventPoster(source, vUp) else {
            Log.output.error("Failed to create CGEvent for paste")
            throw OutputManagerError.textInsertionFailed
        }
        try await sleeper(keyEventGapNanoseconds)

        let commandUp = KeySimulationEvent(virtualKey: commandKeyCode, keyDown: false, flags: [])
        guard keyEventPoster(source, commandUp) else {
            Log.output.error("Failed to create CGEvent for paste")
            throw OutputManagerError.textInsertionFailed
        }
        // Successful Command-up; prevent the defer from posting a second one.
        commandIsDown = false
    }

    private static func postKeyEvent(source: CGEventSource?, event: KeySimulationEvent) -> Bool {
        guard let cgEvent = CGEvent(
            keyboardEventSource: source,
            virtualKey: event.virtualKey,
            keyDown: event.keyDown
        ) else {
            Log.output.error("Failed to create CGEvents for paste")
            return false
        }

        cgEvent.flags = event.flags
        cgEvent.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
final class OutputManager {

    /// How `output(_:)` actually landed the text in the target app. `.pasted` means the
    /// paste keystroke was issued; `.copiedToClipboard` means the text was left on the
    /// clipboard for the user to paste manually — `clipboardFallbackReason` tells
    /// callers whether that was copy-only mode working as designed, the intentional
    /// no-AX fallback, or a real paste failure, so they can surface the right message.
    ///
    /// Destination fields are always captured from the frontmost app at insert/copy time
    /// (including clipboard-only mode: "frontmost app at copy time").
    struct OutputResult: Equatable {
        enum Kind: Equatable {
            case pasted
            case copiedToClipboard
        }

        enum ClipboardFallbackReason: Equatable {
            /// Clipboard output mode: copying IS the output, by user choice.
            case copyOnlyMode
            /// Accessibility permission is missing; copying was the intended behavior.
            case accessibilityUnavailable
            /// A paste was attempted and failed; the copy is a recovery, not a success.
            case pasteFailed
        }

        let kind: Kind
        let clipboardFallbackReason: ClipboardFallbackReason?
        /// Pasteboard contents captured before the fallback copy replaced them, so
        /// callers can offer Undo. Only set for `.copiedToClipboard`.
        let previousClipboardSnapshot: ClipboardSnapshot?
        let destinationAppName: String?
        let destinationAppBundleID: String?

        var didPaste: Bool { kind == .pasted }
        var didCopyToClipboard: Bool { kind == .copiedToClipboard }

        static func pasted(
            destinationAppName: String? = nil,
            destinationAppBundleID: String? = nil
        ) -> OutputResult {
            OutputResult(
                kind: .pasted,
                clipboardFallbackReason: nil,
                previousClipboardSnapshot: nil,
                destinationAppName: destinationAppName,
                destinationAppBundleID: destinationAppBundleID
            )
        }

        static func copiedToClipboard(
            reason: ClipboardFallbackReason = .pasteFailed,
            previousClipboardSnapshot: ClipboardSnapshot? = nil,
            destinationAppName: String? = nil,
            destinationAppBundleID: String? = nil
        ) -> OutputResult {
            OutputResult(
                kind: .copiedToClipboard,
                clipboardFallbackReason: reason,
                previousClipboardSnapshot: previousClipboardSnapshot,
                destinationAppName: destinationAppName,
                destinationAppBundleID: destinationAppBundleID
            )
        }
    }

    /// Brief settle after writing the pasteboard before posting ⌘V.
    static let prePasteDelayNanoseconds: UInt64 = 20_000_000
    /// Settle after re-activating a target app that had lost frontmost status.
    static let activationSettleDelayNanoseconds: UInt64 = 80_000_000
    /// How long the transcript stays on the pasteboard after ⌘V before the user's
    /// previous clipboard comes back — apps like Electron/Chrome read it lazily.
    static let clipboardRestoreDelayNanoseconds: UInt64 = 500_000_000
    static let modifierReleasePollNanoseconds: UInt64 = 10_000_000
    static let modifierReleaseMaxWaitNanoseconds: UInt64 = 250_000_000

    private struct PendingClipboardRestore {
        let id: UUID
        let snapshot: ClipboardSnapshot
        let expectedChangeCount: Int
        let insertedText: String
        let task: Task<Void, Never>
    }

    private(set) var outputMode: OutputMode
    private let clipboard: ClipboardProtocol
    private let keySimulation: KeySimulationProtocol
    private let accessibilityPermissionChecker: () -> Bool
    private let frontmostApplicationProvider: () -> NSRunningApplication?
    private let virtualMachineHostChecker: (String?) -> Bool
    private let sleeper: (UInt64) async throws -> Void
    private let modifierFlagsProvider: () -> CGEventFlags
    private var pendingClipboardRestore: PendingClipboardRestore?

    init(
        outputMode: OutputMode = .clipboard,
        clipboard: ClipboardProtocol = SystemClipboard(),
        keySimulation: KeySimulationProtocol = SystemKeySimulation(),
        accessibilityPermissionChecker: @escaping () -> Bool = { AXIsProcessTrusted() },
        frontmostApplicationProvider: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        virtualMachineHostChecker: @escaping (String?) -> Bool = { VirtualMachineHostDetector.isVirtualMachineHost(bundleIdentifier: $0) },
        sleeper: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        modifierFlagsProvider: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }
    ) {
        self.outputMode = outputMode
        self.clipboard = clipboard
        self.keySimulation = keySimulation
        self.accessibilityPermissionChecker = accessibilityPermissionChecker
        self.frontmostApplicationProvider = frontmostApplicationProvider
        self.virtualMachineHostChecker = virtualMachineHostChecker
        self.sleeper = sleeper
        self.modifierFlagsProvider = modifierFlagsProvider
    }

    func setOutputMode(_ mode: OutputMode) {
        self.outputMode = mode
    }

    @discardableResult
    func output(_ text: String) async throws -> OutputResult {
        guard !text.isEmpty else {
            throw OutputManagerError.emptyText
        }

        Log.output.debug("Output called, mode: \(String(describing: self.outputMode)), length: \(text.count)")

        // Capture insert/copy-time frontmost app unconditionally before any paste or copy.
        let destination = captureDestinationApp()

        switch outputMode {
        case .clipboard:
            return try await outputViaClipboard(text, destination: destination)
        case .directInsert:
            return try await outputViaDirectInsert(text, destination: destination)
        }
    }

    func pasteText(_ text: String) async throws {
        guard !text.isEmpty else {
            throw OutputManagerError.emptyText
        }

        let destination = captureDestinationApp()
        try await pasteViaClipboard(
            text,
            restoreClipboard: true,
            allowSystemEventsFallback: !isVirtualMachineDestination(destination.bundleID)
        )
    }

    private func captureDestinationApp() -> (name: String?, bundleID: String?) {
        let app = frontmostApplicationProvider()
        return (app?.localizedName, app?.bundleIdentifier)
    }

    /// Clipboard mode is truly copy-only: the transcript is left on the pasteboard
    /// for the user to paste themselves, and the prior contents ride along in the
    /// result so callers can offer Undo. (Historically this mode pasted exactly like
    /// direct insert; users who had it stored were migrated to direct insert when the
    /// semantics were fixed — see SettingsStore.migrateOutputModeToCopyOnlySemanticsIfNeeded.)
    private func outputViaClipboard(
        _ text: String,
        destination: (name: String?, bundleID: String?)
    ) async throws -> OutputResult {
        let snapshot = try copyReplacingClipboard(text)
        return .copiedToClipboard(
            reason: .copyOnlyMode,
            previousClipboardSnapshot: snapshot,
            destinationAppName: destination.name,
            destinationAppBundleID: destination.bundleID
        )
    }

    /// Direct insert is paste-based: one atomic Cmd+V with clipboard snapshot/restore.
    /// (Character-by-character CGEvent typing was removed — the overlay-streaming
    /// architecture inserts final text exactly once, and paste is the only insertion
    /// primitive reliable across apps.) On paste failure the text is left on the
    /// clipboard so the user's words are never lost.
    ///
    /// Known VM hosts never use Unicode `virtualKey: 0` character injection (which
    /// hypervisors interpret as repeating "A"). They always take the clipboard paste
    /// path with explicit physical Command events, and skip System Events fallback.
    private func outputViaDirectInsert(
        _ text: String,
        destination: (name: String?, bundleID: String?)
    ) async throws -> OutputResult {
        guard checkAccessibilityPermission() else {
            let snapshot = try copyReplacingClipboard(text)
            return .copiedToClipboard(
                reason: .accessibilityUnavailable,
                previousClipboardSnapshot: snapshot,
                destinationAppName: destination.name,
                destinationAppBundleID: destination.bundleID
            )
        }

        let isVMHost = isVirtualMachineDestination(destination.bundleID)
        if isVMHost {
            Log.output.info(
                "Frontmost app is a known VM host (\(destination.bundleID ?? "unknown")); using clipboard paste with physical Command modifiers"
            )
        }

        do {
            try await pasteViaClipboard(
                text,
                restoreClipboard: true,
                allowSystemEventsFallback: !isVMHost
            )
            return .pasted(
                destinationAppName: destination.name,
                destinationAppBundleID: destination.bundleID
            )
        } catch is CancellationError {
            // The operation was cancelled before the paste keystroke landed; abort
            // cleanly instead of stomping the clipboard with the transcript.
            throw CancellationError()
        } catch {
            Log.output.error("Direct insert paste failed; leaving text on clipboard: \(error.localizedDescription)")
            try copyToClipboard(text)
            return .copiedToClipboard(
                reason: .pasteFailed,
                destinationAppName: destination.name,
                destinationAppBundleID: destination.bundleID
            )
        }
    }

    private func isVirtualMachineDestination(_ bundleIdentifier: String?) -> Bool {
        virtualMachineHostChecker(bundleIdentifier)
    }

    private func pasteViaClipboard(
        _ text: String,
        restoreClipboard: Bool,
        allowSystemEventsFallback: Bool = true
    ) async throws {
        // A previous paste's restore must land first, or this snapshot would capture
        // that paste's transcript instead of the user's own clipboard.
        await awaitPendingClipboardRestore()

        let previousSnapshot = restoreClipboard ? clipboard.captureSnapshot() : .empty
        let targetApplication = frontmostApplicationProvider()
        let success = clipboard.copyToClipboard(text)

        guard success else {
            Log.output.error("Failed to write to clipboard")
            throw OutputManagerError.clipboardWriteFailed
        }

        let temporaryClipboardChangeCount = clipboard.currentChangeCount()

        do {
            try await waitForHotkeyModifierRelease()
            try await sleeper(Self.prePasteDelayNanoseconds)
            // The target was read as the frontmost app and Pindrop's panels never take
            // focus, so re-activation (and its settle delay) is only a fallback.
            if let targetApplication, !targetApplication.isActive {
                targetApplication.activate(options: [.activateIgnoringOtherApps])
                try await sleeper(Self.activationSettleDelayNanoseconds)
            }
            try await keySimulation.simulatePaste(allowSystemEventsFallback: allowSystemEventsFallback)
        } catch {
            if restoreClipboard && shouldRestoreClipboard(expectedChangeCount: temporaryClipboardChangeCount, insertedText: text) {
                let restored = clipboard.restoreSnapshot(previousSnapshot)
                if !restored {
                    Log.output.error("Failed to restore clipboard snapshot after paste failure")
                }
            }

            throw error
        }

        // The paste keystroke landed — the insertion is committed. The deferred
        // clipboard restore runs in an unstructured task that callers don't wait on:
        // cancelling the surrounding operation can neither skip the restore nor turn
        // this success into a failure, and the dictation pipeline no longer blocks
        // for the restore window.
        guard restoreClipboard else { return }
        schedulePendingClipboardRestore(
            snapshot: previousSnapshot,
            expectedChangeCount: temporaryClipboardChangeCount,
            insertedText: text
        )
    }

    /// Waits (bounded) for the user to let go of hotkey modifiers so a still-held
    /// ⌥/⌃/⇧ can't combine with the synthetic ⌘V in apps that read live modifier state.
    private func waitForHotkeyModifierRelease() async throws {
        let hotkeyModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        var waited: UInt64 = 0
        while waited < Self.modifierReleaseMaxWaitNanoseconds,
              !modifierFlagsProvider().intersection(hotkeyModifiers).isEmpty {
            try await sleeper(Self.modifierReleasePollNanoseconds)
            waited += Self.modifierReleasePollNanoseconds
        }
    }

    // MARK: - Deferred Clipboard Restore

    private func schedulePendingClipboardRestore(
        snapshot: ClipboardSnapshot,
        expectedChangeCount: Int,
        insertedText: String
    ) {
        let id = UUID()
        let sleeper = self.sleeper
        let task = Task { @MainActor [weak self] in
            try? await sleeper(Self.clipboardRestoreDelayNanoseconds)
            self?.completePendingClipboardRestore(id: id)
        }
        pendingClipboardRestore = PendingClipboardRestore(
            id: id,
            snapshot: snapshot,
            expectedChangeCount: expectedChangeCount,
            insertedText: insertedText,
            task: task
        )
    }

    private func completePendingClipboardRestore(id: UUID) {
        guard let pending = pendingClipboardRestore, pending.id == id else { return }
        pendingClipboardRestore = nil

        if shouldRestoreClipboard(expectedChangeCount: pending.expectedChangeCount, insertedText: pending.insertedText) {
            let restored = clipboard.restoreSnapshot(pending.snapshot)
            if !restored {
                Log.output.error("Failed to restore clipboard snapshot")
            }
        } else {
            Log.output.info("Skipping clipboard restore because clipboard changed externally")
        }
    }

    /// Restores the user's clipboard immediately if a paste's deferred restore is still
    /// pending. Call before any other clipboard read or write so none of them see (or
    /// overwrite the snapshot of) a transient transcript.
    func flushPendingClipboardRestore() {
        guard let pending = pendingClipboardRestore else { return }
        pending.task.cancel()
        completePendingClipboardRestore(id: pending.id)
    }

    /// Suspends until any pending deferred clipboard restore has run.
    func awaitPendingClipboardRestore() async {
        while let task = pendingClipboardRestore?.task {
            await task.value
        }
    }

    func copyToClipboard(_ text: String) throws {
        flushPendingClipboardRestore()
        let success = clipboard.copyToClipboard(text)

        guard success else {
            throw OutputManagerError.clipboardWriteFailed
        }
    }

    /// Snapshots the pasteboard, writes `text`, and returns the prior contents for undo.
    @discardableResult
    func copyReplacingClipboard(_ text: String) throws -> ClipboardSnapshot {
        flushPendingClipboardRestore()
        let snapshot = clipboard.captureSnapshot()
        try copyToClipboard(text)
        return snapshot
    }

    func captureClipboardSnapshot() -> ClipboardSnapshot {
        flushPendingClipboardRestore()
        return clipboard.captureSnapshot()
    }

    @discardableResult
    func restoreClipboardSnapshot(_ snapshot: ClipboardSnapshot) -> Bool {
        flushPendingClipboardRestore()
        return clipboard.restoreSnapshot(snapshot)
    }

    func checkAccessibilityPermission() -> Bool {
        accessibilityPermissionChecker()
    }

    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func shouldRestoreClipboard(expectedChangeCount: Int, insertedText: String) -> Bool {
        clipboard.currentChangeCount() == expectedChangeCount
            || clipboard.currentStringContent() == insertedText
    }

}

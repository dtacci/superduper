//
//  SettingsWindowController.swift
//  Pindrop
//
//  Created on 2026-07-09.
//

import AppKit
import Combine
import SwiftData
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case dictation
    case appearance
    case shortcuts
    case privacy
    case about

    var id: String { rawValue }

    func title(locale: Locale) -> String {
        switch self {
        case .general: return localized("General", locale: locale)
        case .dictation: return localized("Dictation", locale: locale)
        case .appearance: return localized("Appearance", locale: locale)
        case .shortcuts: return localized("Shortcuts", locale: locale)
        case .privacy: return localized("Privacy", locale: locale)
        case .about: return localized("About", locale: locale)
        }
    }

    var systemIcon: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic.fill"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    var accessibilityIdentifier: String {
        "settings.tab.\(rawValue)"
    }
}

/// Routes a settings tab to its grouped-form pane view.
struct SettingsPaneContent: View {
    @ObservedObject var settings: SettingsStore
    let tab: SettingsTab
    let launchAtLoginManager: LaunchAtLoginManager
    let updateService: UpdateService
    let meetingsState: MeetingsFeatureState?
    let onConnectGoogleCalendar: () -> Void
    let onConfigureGoogleCalendarClientID: (String) -> Void
    let onDisconnectGoogleCalendar: () -> Void

    init(
        settings: SettingsStore,
        tab: SettingsTab,
        launchAtLoginManager: LaunchAtLoginManager,
        updateService: UpdateService,
        meetingsState: MeetingsFeatureState? = nil,
        onConnectGoogleCalendar: @escaping () -> Void = {},
        onConfigureGoogleCalendarClientID: @escaping (String) -> Void = { _ in },
        onDisconnectGoogleCalendar: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.tab = tab
        self.launchAtLoginManager = launchAtLoginManager
        self.updateService = updateService
        self.meetingsState = meetingsState
        self.onConnectGoogleCalendar = onConnectGoogleCalendar
        self.onConfigureGoogleCalendarClientID = onConfigureGoogleCalendarClientID
        self.onDisconnectGoogleCalendar = onDisconnectGoogleCalendar
    }

    @MainActor
    init(settings: SettingsStore, tab: SettingsTab) {
        self.init(
            settings: settings,
            tab: tab,
            launchAtLoginManager: LaunchAtLoginManager(),
            updateService: UpdateService()
        )
    }

    @ViewBuilder
    var body: some View {
        switch tab {
        case .general:
            GeneralSettingsView(
                settings: settings,
                launchAtLoginManager: launchAtLoginManager,
                updateService: updateService,
                meetingsState: meetingsState,
                onConnectGoogleCalendar: onConnectGoogleCalendar,
                onConfigureGoogleCalendarClientID: onConfigureGoogleCalendarClientID,
                onDisconnectGoogleCalendar: onDisconnectGoogleCalendar
            )
        case .dictation:
            DictationSettingsView(settings: settings)
        case .appearance:
            ThemeSettingsView(settings: settings)
        case .shortcuts:
            HotkeysSettingsView(settings: settings)
        case .privacy:
            PrivacySettingsView(settings: settings)
        case .about:
            AboutSettingsView(settings: settings)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    fileprivate enum Layout {
        static let contentWidth: CGFloat = SettingsLayoutMetrics.windowWidth
        static let minimumContentHeight: CGFloat = SettingsLayoutMetrics.minimumHeight
        static let defaultContentHeight: CGFloat = SettingsLayoutMetrics.defaultHeight
        // Versioned so invalid frames saved by the inherited Pindrop window do
        // not keep reopening this fork below its usable minimum size.
        static let frameAutosaveName = "SuperduperDictationSettings-v2"
    }

    private let settings: SettingsStore
    private let modelContainer: ModelContainer
    private let launchAtLoginManager: LaunchAtLoginManager
    private let updateService: UpdateService
    private let meetingsState: MeetingsFeatureState
    private var onConnectGoogleCalendar: () -> Void
    private var onConfigureGoogleCalendarClientID: (String) -> Void
    private var onDisconnectGoogleCalendar: () -> Void
    private let windowModel = SettingsWindowModel()
    private var settingsObservation: AnyCancellable?
    private var tabObservation: AnyCancellable?
    private var lastLocalizedAppLocale: AppLocale

    init(
        settings: SettingsStore,
        modelContainer: ModelContainer,
        launchAtLoginManager: LaunchAtLoginManager,
        updateService: UpdateService,
        meetingsState: MeetingsFeatureState,
        onConnectGoogleCalendar: @escaping () -> Void = {},
        onConfigureGoogleCalendarClientID: @escaping (String) -> Void = { _ in },
        onDisconnectGoogleCalendar: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.modelContainer = modelContainer
        self.launchAtLoginManager = launchAtLoginManager
        self.updateService = updateService
        self.meetingsState = meetingsState
        self.onConnectGoogleCalendar = onConnectGoogleCalendar
        self.onConfigureGoogleCalendarClientID = onConfigureGoogleCalendarClientID
        self.onDisconnectGoogleCalendar = onDisconnectGoogleCalendar
        self.lastLocalizedAppLocale = settings.selectedAppLocale
        super.init(window: nil)

        settingsObservation = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.reloadLocalizedStringsIfNeeded()
            }
        }
        tabObservation = windowModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.updateWindowTitle()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureGoogleCalendar(
        onConnect: @escaping () -> Void,
        onConfigureClientID: @escaping (String) -> Void,
        onDisconnect: @escaping () -> Void
    ) {
        onConnectGoogleCalendar = onConnect
        onConfigureGoogleCalendarClientID = onConfigureClientID
        onDisconnectGoogleCalendar = onDisconnect
    }

    func show(tab: SettingsTab = .general) {
        ensureWindow()
        repairWindowSizeIfNeeded()
        windowModel.select(tab)
        reloadLocalizedStrings()

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func reloadLocalizedStrings() {
        updateWindowTitle()
        if let window {
            applyInterfaceLayoutDirection(to: window, locale: settings.selectedAppLocale.locale)
        }
        lastLocalizedAppLocale = settings.selectedAppLocale
        // SwiftUI environment(\.locale) tracks settings.selectedAppLocale on the root view.
        windowModel.objectWillChange.send()
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let rootView = SettingsRootHostingView(
            settings: settings,
            model: windowModel,
            modelContainer: modelContainer,
            launchAtLoginManager: launchAtLoginManager,
            updateService: updateService,
            meetingsState: meetingsState,
            onConnectGoogleCalendar: onConnectGoogleCalendar,
            onConfigureGoogleCalendarClientID: onConfigureGoogleCalendarClientID,
            onDisconnectGoogleCalendar: onDisconnectGoogleCalendar
        )
        let hostingController = NSHostingController(rootView: AnyView(rootView))

        let window = SettingsWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Layout.contentWidth,
                height: Layout.defaultContentHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(AppColors.windowBackground)
        // Fixed width; free vertical resize.
        window.contentMinSize = NSSize(
            width: Layout.contentWidth,
            height: Layout.minimumContentHeight
        )
        window.contentMaxSize = NSSize(
            width: Layout.contentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        // Leave room for traffic lights under the transparent titlebar.
        window.titlebarSeparatorStyle = .none

        let restoredFrame = window.setFrameUsingName(Layout.frameAutosaveName)
        let restoredContentSize = restoredFrame
            ? window.contentRect(forFrameRect: window.frame).size
            : nil
        window.setContentSize(
            SettingsWindowSizing.contentSize(restoredSize: restoredContentSize)
        )
        if !restoredFrame {
            window.center()
        } else if let screen = window.screen ?? NSScreen.main {
            window.setFrame(
                window.constrainFrameRect(window.frame, to: screen),
                display: false
            )
        }
        window.setFrameAutosaveName(Layout.frameAutosaveName)
        applyInterfaceLayoutDirection(to: window, locale: settings.selectedAppLocale.locale)

        self.window = window
        updateWindowTitle()
        positionTrafficLights()
        PindropThemeController.shared.apply(to: window)
    }

    private func repairWindowSizeIfNeeded() {
        guard let window else { return }
        let currentSize = window.contentRect(forFrameRect: window.frame).size
        let repairedSize = SettingsWindowSizing.contentSize(restoredSize: currentSize)
        guard currentSize != repairedSize else { return }
        window.setContentSize(repairedSize)
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(
                window.constrainFrameRect(window.frame, to: screen),
                display: false
            )
        }
    }

    /// Centers the standard traffic lights on the title row's text line (spec §13:
    /// lights share the titlebar row with the centered pane title). Real system
    /// controls — only origin is adjusted, mirroring MainWindow.positionTrafficLights.
    private func positionTrafficLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let superview = close.superview else { return }

        let pad = SettingsLayoutMetrics.titlebarSidePadding
        let gap: CGFloat = 8
        let bw = close.frame.width
        let bh = close.frame.height
        // Title text line: top padding + half the 16pt line height.
        let centerFromTop = SettingsLayoutMetrics.titlebarTopPadding + 8
        let y = superview.bounds.height - centerFromTop - bh / 2

        close.setFrameOrigin(NSPoint(x: pad, y: y))
        mini.setFrameOrigin(NSPoint(x: pad + bw + gap, y: y))
        zoom.setFrameOrigin(NSPoint(x: pad + 2 * (bw + gap), y: y))

        for button in [close, mini, zoom] {
            button.autoresizingMask = [.minYMargin]
        }
    }

    private func updateWindowTitle() {
        let title = windowModel.selectedTab.title(locale: settings.selectedAppLocale.locale)
        // Keep accessibility / window-menu title even with hidden titlebar text.
        window?.title = title
    }

    private func reloadLocalizedStringsIfNeeded() {
        guard settings.selectedAppLocale != lastLocalizedAppLocale else { return }
        reloadLocalizedStrings()
    }
}

/// Closes on Escape (cancelOperation reaches the window when no responder handles it —
/// e.g. hotkey capture consumes Esc first, and performClose refuses while a sheet is attached).
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

private struct SettingsRootHostingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: SettingsWindowModel
    let modelContainer: ModelContainer
    let launchAtLoginManager: LaunchAtLoginManager
    let updateService: UpdateService
    let meetingsState: MeetingsFeatureState
    let onConnectGoogleCalendar: () -> Void
    let onConfigureGoogleCalendarClientID: (String) -> Void
    let onDisconnectGoogleCalendar: () -> Void

    var body: some View {
        SettingsShellView(
            settings: settings,
            model: model,
            launchAtLoginManager: launchAtLoginManager,
            updateService: updateService,
            meetingsState: meetingsState,
            onConnectGoogleCalendar: onConnectGoogleCalendar,
            onConfigureGoogleCalendarClientID: onConfigureGoogleCalendarClientID,
            onDisconnectGoogleCalendar: onDisconnectGoogleCalendar
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, settings.selectedAppLocale.locale)
        .environment(\.layoutDirection, settings.selectedAppLocale.layoutDirection)
        .modelContainer(modelContainer)
        // The shell's title row IS the titlebar line (60pt side lanes reserved for
        // the repositioned traffic lights) — ignore the hidden titlebar's safe area
        // or SwiftUI re-adds ~28pt of clearance above the row.
        .ignoresSafeArea(.container, edges: .top)
    }
}

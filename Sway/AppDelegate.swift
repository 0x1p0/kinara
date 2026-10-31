import AppKit
import SwiftUI
import Combine

// Transient session choices never overwrite the user's gesture configuration.
final class SwaySession: ObservableObject {
    static let shared = SwaySession()
    @Published private(set) var pauseUntil: Date?
    private var resumeTimer: Timer?

    func setEnabled(_ enabled: Bool) {
        clearTimedPause()
        TrackpadSettings.shared.isEnabled = enabled
    }

    func pause(for seconds: TimeInterval) {
        clearTimedPause()
        pauseUntil = Date().addingTimeInterval(seconds)
        TrackpadSettings.shared.isEnabled = false
        resumeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.setEnabled(true)
        }
        if let resumeTimer { RunLoop.main.add(resumeTimer, forMode: .common) }
    }

    func clearTimedPause() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        pauseUntil = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var quickControlsWindow: NSWindow?
    private var updatesWindow: NSWindow?
    private let focus = WindowFocusCoordinator()
    private let dockPresence = DockPresenceCoordinator()
    private let dismissal = PopoverDismissalMonitor()
    private let setupProgress = SetupProgress()
    private let presentsSetupOnLaunch: Bool
    private var cancellables = Set<AnyCancellable>()
    private var menuBrightnessTimer: Timer?
    private var menuScrollMonitor: Any?
    private var lastMenuSignature: String?
    private lazy var activeIcon = menuIcon("waveform.path")
    private lazy var pausedIcon = menuIcon("pause.circle")
    private lazy var activeUpdateIcon = badgedMenuIcon("waveform.path")
    private lazy var pausedUpdateIcon = badgedMenuIcon("pause.circle")

    init(presentsSetupOnLaunch: Bool = true) {
        self.presentsSetupOnLaunch = presentsSetupOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockPresence.setEnabled(TrackpadSettings.shared.showDockIcon)
        let controls = ControlCenterModel.shared
        controls.refresh()
        setupMenuBar()
        ExcludedAppsManager.shared.start()
        HotkeyManager.shared.startWithSavedHotkey()
        _ = EdgeMapHUD.shared // Listens for the hold-to-show hotkey.
        installMenuBarScroll()

        TrackpadSettings.shared.$brightnessFollowsPointer.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { BrightnessController.shared.followsPointer = $0 }.store(in: &cancellables)
        TrackpadSettings.shared.$extraDimBelowMinimum.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { if !$0 { GammaDimmer.shared.restoreAll() } }.store(in: &cancellables)

        TrackpadSettings.shared.$isEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    SwaySession.shared.clearTimedPause()
                    TrackpadMonitor.shared.start()
                } else {
                    GestureTelemetry.shared.isTesting = false
                    TrackpadMonitor.shared.stop()
                }
                self?.updateMenuBar()
            }.store(in: &cancellables)

        controls.$hasAccess.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] access in
                if TrackpadSettings.shared.isEnabled {
                    access ? TrackpadMonitor.shared.restart() : TrackpadMonitor.shared.stop()
                }
                self?.updateMenuBar()
            }.store(in: &cancellables)

        TrackpadSettings.shared.$menuBarValueSource.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureMenuReadout()
                self?.updateMenuBar()
            }.store(in: &cancellables)

        TrackpadMonitor.shared.$isRunning.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBar() }.store(in: &cancellables)
        ExcludedAppsManager.shared.$activeAppIsExcluded.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBar() }.store(in: &cancellables)

        TrackpadSettings.shared.$showDockIcon.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self else { return }
                self.dockPresence.setEnabled(show)
                if let window = self.preferredReopenWindow, window.isVisible { self.present(window) }
            }.store(in: &cancellables)

        UpdateChecker.shared.$updateAvailable.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                NSApp.dockTile.badgeLabel = available ? "1" : nil
                self?.updateMenuBar()
            }.store(in: &cancellables)
        UpdateChecker.shared.startPeriodicChecks()

        for name in [Notification.Name.swayAudioStateChanged, .swayDisplayStateChanged] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.updateMenuBar() }.store(in: &cancellables)
        }

        // Only measured, intentional adjustments show an indicator. External
        // hardware notifications update readouts without opening an overlay.
        for name in [Notification.Name.volumeChanged, .brightnessChanged, .topEdgeVolumeChanged, .topEdgeBrightnessChanged, .microphoneLevelChanged] {
            NotificationCenter.default.publisher(for: name)
                .sink { note in
                    guard let value = note.object as? Float, value.isFinite else { return }
                    let type: OSDType = name == .microphoneLevelChanged ? .microphone : name == .volumeChanged || name == .topEdgeVolumeChanged ? .volume : .brightness
                    OSDOverlay.shared.show(type: type, value: value, placement: note.userInfo?["placement"] as? OSDPlacement,
                                           fine: note.userInfo?["fine"] as? Bool ?? false)
                }.store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: .microphoneMuteChanged).sink { note in
            guard let muted = note.object as? Bool else { return }
            OSDOverlay.shared.show(type: .microphoneMute, value: muted ? 1 : 0)
        }.store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                controls.refresh()
                if TrackpadSettings.shared.isEnabled { TrackpadMonitor.shared.restart() }
                self?.configureMenuReadout()
                UpdateChecker.shared.checkIfDue()
            }.store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                TrackpadMonitor.shared.stop()
                self?.menuBrightnessTimer?.invalidate()
                self?.menuBrightnessTimer = nil
            }.store(in: &cancellables)
        // Granting permission in System Settings is reconciled on app switches
        // and while controls are visible, without a permanent background poll.
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in controls.refreshAccess() }.store(in: &cancellables)

        if presentsSetupOnLaunch, setupProgress.shouldPresent(hasAccess: AXIsProcessTrusted()) {
            DispatchQueue.main.async { [weak self] in
                self?.showGettingStarted()
                // Explain the request in a visible window first. Ask once on
                // first launch; denial never causes repeated launch prompts.
                if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "hasRequestedLaunchAccessibility") {
                    UserDefaults.standard.set(true, forKey: "hasRequestedLaunchAccessibility")
                    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                }
            }
        }
    }

    /// Scroll over the menu bar icon: volume, or brightness while holding ⌥.
    /// A local monitor sees only events already addressed to Sway's own
    /// status item window; it never observes other apps.
    private func installMenuBarScroll() {
        menuScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, TrackpadSettings.shared.menuBarScroll,
                  let window = self.statusItem?.button?.window, event.window === window else { return event }
            let raw = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            guard raw.isFinite, raw != 0 else { return nil }
            // Wheels click in sixteenths, like the volume keys; trackpads glide.
            let step = event.hasPreciseScrollingDeltas ? Double(raw) * 0.004 : (raw > 0 ? 1.0 : -1.0) / 16
            let controls = ControlCenterModel.shared
            let action: ZoneAction = event.modifierFlags.contains(.option) ? .brightness : .volume
            // One undo point per trackpad scroll; wheel clicks are each tiny.
            if event.phase == .began { controls.captureUndo(action) }
            controls.adjust(action, to: (action == .volume ? controls.volume : controls.brightness) + step)
            return nil
        }
    }

    // MARK: URL commands

    func application(_ application: NSApplication, open urls: [URL]) {
        guard TrackpadSettings.shared.urlCommandsEnabled else { return }
        for url in urls { if let command = SwayURLCommand.parse(url) { perform(command) } }
    }

    func perform(_ command: SwayURLCommand) {
        let controls = ControlCenterModel.shared
        switch command {
        case let .pause(minutes):
            if let minutes { SwaySession.shared.pause(for: minutes * 60) } else { SwaySession.shared.setEnabled(false) }
        case .resume: SwaySession.shared.setEnabled(true)
        case .toggle: SwaySession.shared.setEnabled(!TrackpadSettings.shared.isEnabled)
        case let .volume(level): controls.captureUndo(.volume); controls.adjust(.volume, to: level)
        case let .brightness(level): controls.captureUndo(.brightness); controls.adjust(.brightness, to: level)
        case .settings: showSettings()
        case .controls: showQuickControls()
        case .edgeMap: EdgeMapHUD.shared.show(autoHide: true)
        }
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel("Sway trackpad controls")
        item.button?.imagePosition = .imageLeading
        let panel = NSPopover()
        // One dismissal owner. Menu tracking is explicitly protected before
        // the native pull-down begins, including the first activation click.
        panel.behavior = .applicationDefined
        panel.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.delegate = self
        // The SwiftUI graph is allocated on open and released after close.
        // NSPopover itself supplies the system's glass background.
        popover = panel
        updateMenuBar()
    }

    private func configureMenuReadout() {
        menuBrightnessTimer?.invalidate()
        menuBrightnessTimer = nil
        let source = TrackpadSettings.shared.menuBarValueSource
        guard source == "brightness" || source == "both" else { return }
        // Only an explicitly selected, always-visible brightness readout needs
        // fallback polling. Default icon and volume modes are event-driven.
        let timer = Timer(timeInterval: 2, repeats: true) { _ in BrightnessController.shared.refresh() }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        menuBrightnessTimer = timer
    }

    @objc func showSettings() {
        let window: NSWindow
        if let existingWindow = settingsWindow {
            window = existingWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sway Settings"
            window.identifier = NSUserInterfaceItemIdentifier("Sway.Settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = FirstClickHostingController(rootView: ContentView())
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            window.setFrameAutosaveName("SwayOrganizedSettingsWindow")
            settingsWindow = window
        }
        ControlCenterModel.shared.setVisible("settings", true)
        ControlCenterModel.shared.refresh()
        present(window)
    }

    @objc func checkForUpdates() {
        let window: NSWindow
        if let existing = updatesWindow { window = existing }
        else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Sway Updates"
            window.identifier = NSUserInterfaceItemIdentifier("Sway.Updates")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let host = FirstClickHostingController(rootView: UpdateWindowView(updates: .shared))
            window.contentViewController = host
            window.setContentSize(host.view.fittingSize)
            window.center()
            updatesWindow = window
        }
        present(window)
        UpdateChecker.shared.check()
    }

    @objc func showGettingStarted() {
        if let welcomeWindow { present(welcomeWindow); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 550),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Sway"
        window.identifier = NSUserInterfaceItemIdentifier("Sway.Welcome")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = FirstClickHostingController(rootView: GettingStartedView(
            openControls: { [weak self] in
                self?.setupProgress.finish(hasAccess: AXIsProcessTrusted())
                self?.welcomeWindow?.close()
                self?.showQuickControls()
            }))
        host.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        window.center()
        welcomeWindow = window
        ControlCenterModel.shared.setVisible("welcome", true)
        ControlCenterModel.shared.refresh()
        present(window)
    }

    /// Reopening from Applications, Spotlight, or the optional Dock icon is a
    /// reliable route even when macOS/a menu-bar manager hides the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if setupProgress.shouldPresent(hasAccess: AXIsProcessTrusted()) { showGettingStarted() }
        else if let window = preferredReopenWindow { present(window) }
        else { showQuickControls() }
        return false // Already handled; do not let AppKit choose another window.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var managedWindows: [NSWindow] {
        [quickControlsWindow, settingsWindow, welcomeWindow, updatesWindow].compactMap { $0 }
    }

    private var preferredReopenWindow: NSWindow? {
        let windows = managedWindows
        return NSApp.orderedWindows.first { candidate in windows.contains { $0 === candidate } } ?? windows.first
    }

    private func present(_ window: NSWindow) {
        dockPresence.windowWillOpen(window)
        focus.show(window, closingPrevious: { self.closePopover() })
    }

    @objc func showQuickControls() {
        if let quickControlsWindow { present(quickControlsWindow); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sway Controls"
        window.identifier = NSUserInterfaceItemIdentifier("Sway.Controls")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = FirstClickHostingController(rootView: MenuBarView(openSettings: { [weak self] in self?.showSettings() }))
        host.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        window.center()
        quickControlsWindow = window
        ControlCenterModel.shared.setVisible("controls", true)
        ControlCenterModel.shared.refresh()
        present(window)
    }

    @objc func revealMenuBar() { showPopover() }

    private func menuIcon(_ name: String) -> NSImage? {
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: "Sway")
        icon?.isTemplate = true
        return icon
    }

    private func badgedMenuIcon(_ name: String) -> NSImage? {
        guard let symbol = menuIcon(name) else { return nil }
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 18, y: 1, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sway — update available"
        return image
    }

    private func updateMenuBar() {
        guard let button = statusItem?.button else { return }
        let settings = TrackpadSettings.shared
        let available = ControlCenterModel.shared.hasAccess && TrackpadMonitor.shared.isRunning
        let paused = !settings.isEnabled || ExcludedAppsManager.shared.activeAppIsExcluded
        let audio = VolumeController.shared
        let display = BrightnessController.shared
        let volume = audio.isAvailable ? "\(Int((audio.getVolume() * 100).rounded()))%" : "—"
        let brightness = display.isAvailable ? "\(Int((display.getBrightness() * 100).rounded()))%" : "—"
        let hasUpdate = UpdateChecker.shared.updateAvailable
        let tooltip = "Sway · \(hasUpdate ? "Update available" : paused ? "Paused" : available ? "Ready" : "Setup needed")\nBrightness \(brightness) · Volume \(audio.isMuted ? "Muted" : volume)"
        let title: String
        switch settings.menuBarValueSource {
        case "volume": title = " \(volume)"
        case "brightness": title = " \(brightness)"
        case "both": title = " ☀︎ \(brightness)  ♪ \(volume)"
        case "name": title = " Sway"
        default: title = ""
        }
        let signature = "\(paused)|\(hasUpdate)|\(title)|\(tooltip)"
        guard signature != lastMenuSignature else { return }
        lastMenuSignature = signature
        button.toolTip = tooltip
        button.image = paused ? (hasUpdate ? pausedUpdateIcon : pausedIcon) : (hasUpdate ? activeUpdateIcon : activeIcon)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
    }

    @objc private func togglePopover() {
        if popover?.isShown == true { closePopover() }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover, visibleStatusAnchor != nil else { showQuickControls(); return }
        if popover.contentViewController == nil {
            let host = FirstClickHostingController(rootView: MenuBarView(openSettings: { [weak self] in self?.showSettings() }))
            host.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
            host.install(in: popover)
        }
        ControlCenterModel.shared.setVisible("popover", true)
        ControlCenterModel.shared.refresh()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        WindowFocusCoordinator.activateApplication()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window { focus.show(window) }
        button.highlight(true)
    }

    private var visibleStatusAnchor: NSRect? {
        guard let button = statusItem?.button, let window = button.window,
              window.isVisible, !button.isHiddenOrHasHiddenAncestor, let screen = window.screen else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screen.frame.intersects(frame) else { return nil }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           frame.maxX > left.maxX && frame.minX < right.minX { return nil }
        return frame
    }

    func popoverDidShow(_ notification: Notification) {
        dismissal.start(panel: { [weak self] in self?.popover?.contentViewController?.view.window },
                        anchor: { [weak self] in self?.visibleStatusAnchor },
                        close: { [weak self] in self?.closePopover() })
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool { !dismissal.isTrackingMenu }

    private func closePopover() {
        dismissal.stop()
        guard popover?.isShown == true else { return }
        focus.cancel()
        // Finish closing before another window gets focus.
        popover?.animates = false
        popover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        dismissal.stop()
        statusItem?.button?.highlight(false)
        ControlCenterModel.shared.setVisible("popover", false)
        popover?.contentViewController = nil
        NotificationCenter.default.post(name: Notification.Name("swayPopoverClosed"), object: nil)
        guard settingsWindow?.isVisible != true || settingsWindow?.isMiniaturized == true else { return }
        TrackpadMonitor.shared.cancelCurrentGesture()
        GestureTelemetry.shared.isTesting = false
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              managedWindows.contains(where: { $0 === closingWindow }) else { return }
        defer { dockPresence.windowWillClose(closingWindow) }
        if let window = notification.object as? NSWindow, window === updatesWindow {
            window.contentViewController = nil
            updatesWindow = nil
            return
        }
        if let window = notification.object as? NSWindow, window === welcomeWindow {
            ControlCenterModel.shared.setVisible("welcome", false)
            window.contentViewController = nil
            welcomeWindow = nil
            return
        }
        if let window = notification.object as? NSWindow, window === quickControlsWindow {
            ControlCenterModel.shared.setVisible("controls", false)
            window.contentViewController = nil
            quickControlsWindow = nil
            return
        }
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        endSettingsInteractions()
        window.contentViewController = nil
        settingsWindow = nil
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === quickControlsWindow {
            ControlCenterModel.shared.setVisible("controls", false)
            return
        }
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        endSettingsInteractions()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === quickControlsWindow {
            ControlCenterModel.shared.setVisible("controls", true)
            ControlCenterModel.shared.refresh()
            return
        }
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        ControlCenterModel.shared.setVisible("settings", true)
        ControlCenterModel.shared.refresh()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === quickControlsWindow || window === welcomeWindow {
            let surface = window === quickControlsWindow ? "controls" : "welcome"
            ControlCenterModel.shared.setVisible(surface, window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden)
            return
        }
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden
        ControlCenterModel.shared.setVisible("settings", visible)
        if visible { ControlCenterModel.shared.refresh() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        focus.didBecomeActive()
        ControlCenterModel.shared.refreshAccess()
    }

    func applicationDidHide(_ notification: Notification) {
        closePopover()
        ControlCenterModel.shared.setVisible("controls", false)
        ControlCenterModel.shared.setVisible("welcome", false)
        ControlCenterModel.shared.setVisible("popover", false)
        endSettingsInteractions()
    }

    func applicationDidUnhide(_ notification: Notification) {
        ControlCenterModel.shared.setVisible("controls", quickControlsWindow?.isVisible == true && quickControlsWindow?.isMiniaturized == false)
        ControlCenterModel.shared.setVisible("welcome", welcomeWindow?.isVisible == true)
        ControlCenterModel.shared.setVisible("popover", popover?.isShown == true)
        if settingsWindow?.isVisible == true && settingsWindow?.isMiniaturized == false {
            ControlCenterModel.shared.setVisible("settings", true)
        }
        ControlCenterModel.shared.refresh()
    }

    private func endSettingsInteractions() {
        ControlCenterModel.shared.setVisible("settings", false)
        GestureTelemetry.shared.isTesting = false
        TrackpadMonitor.shared.cancelCurrentGesture()
        NotificationCenter.default.post(name: Notification.Name("swaySettingsClosed"), object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a display dimmed or an app's audio rerouted after quitting.
        GammaDimmer.shared.restoreAll()
        AppVolumeController.shared.resetAll()
        if let menuScrollMonitor { NSEvent.removeMonitor(menuScrollMonitor) }
        dismissal.stop()
        focus.cancel()
        UpdateChecker.shared.stop()
        ControlCenterModel.shared.setVisible("controls", false)
        ControlCenterModel.shared.setVisible("welcome", false)
        GestureTelemetry.shared.isTesting = false
        TrackpadMonitor.shared.stop()
        ExcludedAppsManager.shared.stop()
        menuBrightnessTimer?.invalidate()
        ControlCenterModel.shared.setVisible("settings", false)
        ControlCenterModel.shared.setVisible("popover", false)
        SwaySession.shared.clearTimedPause()
    }
}

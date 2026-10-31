import AppKit
import SwiftUI

private final class ClickCounterView: NSView {
    var clicks = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
}

private struct SizingFixtureView: View {
    @State private var expanded = false
    var body: some View {
        MoreOptionsButton(isExpanded: expanded) { expanded.toggle() }
            .frame(width: 320, height: expanded ? 420 : 204).fixedSize()
    }
}

@MainActor
private final class PresentationTestDelegate: NSObject, NSApplicationDelegate {
    let runTests: () -> Void
    private var launchWindow: NSWindow?
    private var launchTimeout: Timer?
    init(runTests: @escaping () -> Void) { self.runTests = runTests }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Begin with a genuine click, just like opening Sway from its status
        // item. New macOS deliberately denies unsolicited focus stealing.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sway — safe focus test"
        window.isReleasedWhenClosed = false
        let button = NSButton(title: "Run focus test", target: self, action: #selector(startTests))
        button.frame = NSRect(x: 60, y: 44, width: 220, height: 40)
        button.bezelStyle = .rounded
        window.contentView?.addSubview(button)
        launchWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        WindowFocusCoordinator.activateApplication()
        launchTimeout = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            fputs("FAIL: click Run focus test in the safe preview window to begin.\n", stderr)
            exit(1)
        }
    }
    @objc private func startTests() {
        launchTimeout?.invalidate()
        launchTimeout = nil
        launchWindow?.close()
        launchWindow = nil
        DispatchQueue.main.async { self.runTests() }
    }
}

@main
enum PresentationRegressionTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    @MainActor
    static func main() {
        let live = CommandLine.arguments.contains("--live")
        NSApplication.shared.setActivationPolicy(live ? .accessory : .prohibited)
        if live {
            let delegate = PresentationTestDelegate { runSuite(live: true) }
            NSApp.delegate = delegate
            withExtendedLifetime(delegate) { NSApp.run() }
        } else { runSuite(live: false) }
    }

    @MainActor
    private static func runSuite(live: Bool) {
        let panel = NSRect(x: 100, y: 100, width: 320, height: 240)
        let anchor = NSRect(x: 380, y: 340, width: 30, height: 24)
        expect(!PopoverDismissalMonitor.isOutside(NSPoint(x: 200, y: 200), panel: panel, anchor: anchor), "inside panel remains open")
        expect(!PopoverDismissalMonitor.isOutside(NSPoint(x: 390, y: 350), panel: panel, anchor: anchor), "status click is left to the toggle")
        for point in [NSPoint(x: 0, y: 0), NSPoint(x: -1000, y: 100), NSPoint(x: 2000, y: 400)] {
            expect(PopoverDismissalMonitor.isOutside(point, panel: panel, anchor: anchor), "outside clicks include other displays")
        }
        expect(PopoverDismissalMonitor.isOutside(.zero, panel: nil, anchor: nil), "missing anchor fails closed")
        let host = FirstClickHostingController(rootView: Text("Safe preview").frame(width: 320, height: 204))
        expect(host.view.acceptsFirstMouse(for: nil), "hosting view accepts first click")
        expect(host.preferredContentSize == NSSize(width: 320, height: 204), "first-click host preserves intrinsic popover size")
        let monitor = PopoverDismissalMonitor()
        expect(!monitor.isMonitoring, "no monitor while closed")
        var closes = 0
        monitor.start(panel: { nil }, anchor: { nil }, close: { closes += 1 })
        expect(monitor.isMonitoring, "visible panel installs dismissal monitors")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        expect(closes == 1, "switching apps dismisses the panel")
        monitor.stop()
        expect(!monitor.isMonitoring, "closing removes monitors")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        expect(closes == 1, "removed observers cannot close later windows")
        monitor.start(panel: { nil }, anchor: { nil }, close: { closes += 1 })
        monitor.start(panel: { nil }, anchor: { nil }, close: { closes += 1 })
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        expect(closes == 2, "reopening does not duplicate observers")
        monitor.stop()
        testSetupProgress()
        testNativeControls()
        testMenuDismissal()
        testPopoverSizing()
        testControlsWindowSizing()
        testDockPresence()
        if live {
            Task { @MainActor in
                await runLiveTests(panel: panel, host: host, monitor: monitor)
                print("\(checks) presentation assertions passed. No production app, permission requests, or hardware controls.")
                NSApp.terminate(nil)
            }
        } else {
            print("\(checks) presentation assertions passed. No production app, permission requests, or hardware controls.")
        }
    }

    private static func testSetupProgress() {
        let name = "com.sway.setup-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let progress = SetupProgress(defaults: defaults)
        expect(progress.shouldPresent(hasAccess: false), "new install needs setup")
        expect(progress.shouldPresent(hasAccess: true), "access alone does not finish a new guide")
        progress.finish(hasAccess: false)
        expect(progress.shouldPresent(hasAccess: false), "continuing with sliders leaves setup unfinished")
        expect(!defaults.bool(forKey: "hasFinishedSwaySetup"), "missing permission cannot mark setup complete")
        expect(SetupProgress(defaults: defaults).shouldPresent(hasAccess: true), "unfinished setup survives relaunch even if access arrives later")
        progress.finish(hasAccess: true)
        expect(!SetupProgress(defaults: defaults).shouldPresent(hasAccess: true), "explicit completion persists across relaunch")
        expect(progress.shouldPresent(hasAccess: false), "revoked permission returns the guide")
        defaults.removeObject(forKey: "hasFinishedSwaySetup")
        defaults.set(true, forKey: "hasCompletedSwaySetup")
        expect(progress.shouldPresent(hasAccess: false), "legacy close-without-permission bug is repaired on upgrade")
        expect(!progress.shouldPresent(hasAccess: true), "legacy configured users keep completed setup")
    }

    @MainActor
    private static func firstView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.compactMap { firstView(type, in: $0) }.first
    }

    @MainActor
    private static func testNativeControls() {
        var expanded = false
        let host = FirstClickHostingController(rootView: MoreOptionsButton(isExpanded: false) { expanded.toggle() }.frame(width: 24, height: 20))
        host.view.layoutSubtreeIfNeeded()
        guard let button = firstView(FirstClickButton.self, in: host.view) else {
            expect(false, "more options uses the native first-click button"); return
        }
        expect(button.acceptsFirstMouse(for: nil), "three-dot button accepts the first click")
        expect(button.menu == nil, "overflow creates no popup menu or tracking window")
        button.performClick(nil)
        expect(expanded, "one click expands inline options")
        button.performClick(nil)
        expect(!expanded, "second click collapses inline options")
        expect(SettingsPane.allCases.count == 10, "settings are separated into ten discoverable categories")
        expect(SettingsPane.taps.matches("corner") && SettingsPane.profiles.matches("docked"), "new categories are searchable")
        expect(SettingsPane.levels.matches("airpods") && SettingsPane.general.matches("export"), "new options are searchable")
        expect(SettingsPane.protection.matches("palm rejection"), "palm rejection search")
        expect(SettingsPane.feedback.matches("crisp"), "haptic option search")
        expect(SettingsPane.general.matches("launch login"), "startup search")
        expect(SettingsPane.appearance.matches("DARK"), "case-insensitive theme search")
        expect(SettingsPane.updates.matches("install"), "install updates search")
        expect(!SettingsPane.gestures.matches("nonsense"), "irrelevant search excludes a section")
        var actions = 0
        let actionHost = FirstClickHostingController(rootView: SystemActionButton(title: "GitHub Releases…") { actions += 1 }.fixedSize())
        actionHost.view.layoutSubtreeIfNeeded()
        guard let action = firstView(FirstClickButton.self, in: actionHost.view) else {
            expect(false, "update link uses the native action button"); return
        }
        expect(action.bezelColor == nil && action.contentTintColor == nil, "update button has no forced black bezel or label tint")
        expect(action.bezelStyle == .rounded && action.isEnabled, "update button starts in its standard readable state")
        action.performClick(nil)
        expect(actions == 1, "GitHub button dispatches once")
    }

    @MainActor
    private static func testMenuDismissal() {
        var pending: [() -> Void] = []
        let monitor = PopoverDismissalMonitor(afterMenu: { pending.append($0) })
        let anchor = NSRect(x: 0, y: 0, width: 40, height: 40)
        var active = true
        var point = NSPoint(x: 20, y: 20)
        var closes = 0
        func start() {
            monitor.start(panel: { nil }, anchor: { anchor }, pointer: { point }, applicationIsActive: { active }, close: { closes += 1 })
        }
        func drain() {
            let callbacks = pending
            pending.removeAll()
            callbacks.forEach { $0() }
        }
        start()
        monitor.beginMenuInteraction()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        expect(closes == 0, "first-click activation transition cannot close the menu host")
        let menu = NSMenu(), submenu = NSMenu()
        for item in [menu, submenu] { NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: item) }
        monitor.endMenuInteraction()
        drain()
        expect(closes == 0 && monitor.isTrackingMenu, "tracking notifications preserve the open menu after mouse handling")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        drain()
        expect(closes == 0 && monitor.isTrackingMenu, "closing a submenu does not dismiss its parent")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        drain()
        expect(closes == 0 && !monitor.isTrackingMenu, "returning from a menu with restored activation keeps controls open")
        monitor.beginMenuInteraction()
        active = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        monitor.endMenuInteraction()
        expect(closes == 0, "menu action can run before deferred outside dismissal")
        drain()
        expect(closes == 1, "real application switch dismisses after menu tracking finishes")
        start()
        active = true
        monitor.beginMenuInteraction()
        point = NSPoint(x: 100, y: 100)
        monitor.endMenuInteraction()
        drain()
        expect(closes == 2, "outside click cancellation still dismisses the popover")
        monitor.beginMenuInteraction()
        monitor.endMenuInteraction()
        monitor.stop()
        start()
        drain()
        expect(closes == 2, "stale tracking callback cannot close a newly opened popover")
        monitor.stop()
        expect(!monitor.isTrackingMenu && !monitor.isMonitoring, "closing releases menu guards and monitors")
    }

    @MainActor
    private static func testPopoverSizing() {
        let controller = FirstClickHostingController(rootView: SizingFixtureView())
        let popover = NSPopover()
        controller.install(in: popover)
        // A non-visible backing window supplies layout/drawing without showing
        // UI. The separate renderer also checks a genuinely displayed popover.
        let layoutWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 204),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        layoutWindow.isReleasedWhenClosed = false
        layoutWindow.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(popover.contentViewController === controller, "popover uses the production first-click host")
        expect(popover.contentSize == NSSize(width: 320, height: 204), "popover initially matches its content")
        guard let button = firstView(FirstClickButton.self, in: controller.view) else {
            expect(false, "sizing fixture uses the real overflow button"); return
        }
        for height: CGFloat in [420, 204, 420, 204] {
            button.performClick(nil)
            let deadline = Date().addingTimeInterval(2)
            repeat {
                controller.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while popover.contentSize.height != height && Date() < deadline
            expect(controller.preferredContentSize.height == height, "SwiftUI reports height \(height); preferred=\(controller.preferredContentSize), fitting=\(controller.view.fittingSize), popover=\(popover.contentSize)")
            expect(popover.contentSize == NSSize(width: 320, height: height), "native popover expands and collapses with content, not a fixed frame")
            expect(popover.contentViewController === controller, "resizing never replaces or reopens the host")
        }
        popover.contentViewController = nil
        layoutWindow.contentView = nil
        layoutWindow.close()
    }

    @MainActor
    private static func testControlsWindowSizing() {
        let controller = FirstClickHostingController(rootView: SizingFixtureView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 204),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        guard let button = firstView(FirstClickButton.self, in: controller.view) else {
            expect(false, "standalone controls use the same overflow button"); return
        }
        for height: CGFloat in [420, 204] {
            button.performClick(nil)
            let deadline = Date().addingTimeInterval(2)
            repeat {
                controller.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while window.contentLayoutRect.height != height && Date() < deadline
            expect(window.contentLayoutRect.size == NSSize(width: 320, height: height), "standalone Controls window follows content height \(height)")
            expect(window.contentViewController === controller, "window resizing preserves its controller")
        }
    }

    @MainActor
    private static func testDockPresence() {
        var applied: [NSApplication.ActivationPolicy] = []
        var pending: [() -> Void] = []
        let dock = DockPresenceCoordinator(applyPolicy: { applied.append($0); return true }, afterClose: { pending.append($0) })
        let first = NSWindow(), second = NSWindow(), replacement = NSWindow()
        for window in [first, second, replacement] { window.isReleasedWhenClosed = false }
        func drain() { let work = pending; pending.removeAll(); work.forEach { $0() } }
        dock.setEnabled(true)
        expect(applied == [.accessory], "saved Dock preference alone cannot leave an empty Dock app")
        dock.windowWillOpen(first)
        expect(applied == [.accessory, .regular], "opening a window shows Dock before focus")
        dock.windowWillOpen(first)
        dock.windowWillOpen(second)
        expect(applied.count == 2, "refocusing and multiple windows do not repeat policy changes")
        dock.windowWillClose(first)
        drain()
        expect(applied.last == .regular && applied.count == 2, "closing one window keeps Dock for the remaining window")
        dock.windowWillClose(second)
        expect(applied.last == .regular, "last-close policy waits until AppKit finishes closing")
        dock.windowWillOpen(replacement)
        drain()
        expect(applied.count == 2, "window handoff has no hide/show Dock flicker")
        dock.setEnabled(false)
        expect(applied.last == .accessory, "disabling Dock hides it without closing windows")
        dock.setEnabled(true)
        expect(applied.last == .regular, "reenabling Dock finds the still-open window")
        dock.windowWillClose(replacement)
        drain()
        expect(applied.last == .accessory, "closing last window returns to menu-bar-only mode")
        let afterLastClose = applied.count
        dock.windowWillClose(replacement)
        drain()
        expect(applied.count == afterLastClose && pending.isEmpty, "duplicate/unmanaged closes have no side effects")
        dock.windowWillOpen(first)
        expect(applied.last == .regular, "reopening restores Dock without resetting the saved preference")
        dock.windowWillClose(first)
        drain()
        expect(applied.last == .accessory, "a repeated open/close cycle returns to the menu bar")
    }

    @MainActor
    private static func runLiveTests(panel: NSRect, host: NSViewController, monitor: PopoverDismissalMonitor) async {
        let source = NSWindow(contentRect: panel, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let target = NSWindow(contentRect: panel, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false; target.isReleasedWhenClosed = false
        source.title = "Sway focus test — safe preview"
        target.title = "Sway Settings focus test — safe preview"
        target.contentViewController = host
        let focus = WindowFocusCoordinator()
        source.makeKeyAndOrderFront(nil)
        var didClosePrevious = false
        focus.show(target) { source.close(); didClosePrevious = true }
        await settle()
        focus.didBecomeActive()
        expect(didClosePrevious && !source.isVisible, "previous window closes before destination")
        print("Focus state: visible=\(target.isVisible), key=\(target.isKeyWindow), active=\(NSApp.isActive), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        expect(target.isVisible && target.isKeyWindow && NSApp.isActive, "destination is active and keyboard-focused without a second click")
        target.miniaturize(nil)
        focus.show(target)
        await settle()
        expect(!target.isMiniaturized && target.isKeyWindow, "reopening restores a minimized destination")
        let insideView = ClickCounterView(frame: target.contentView!.bounds)
        target.contentViewController = nil
        target.contentView = insideView
        let outside = NSWindow(contentRect: NSRect(x: 500, y: 100, width: 160, height: 100),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        outside.isReleasedWhenClosed = false
        outside.title = "Outside-click test"
        let outsideView = ClickCounterView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        outside.contentView = outsideView
        outside.orderFront(nil)
        var outsideCloses = 0
        monitor.start(panel: { target }, anchor: { nil }, close: { outsideCloses += 1; monitor.stop() })
        await click(window: target)
        expect(outsideCloses == 0 && insideView.clicks == 1, "inside clicks reach their control without dismissing")
        await click(window: outside)
        expect(outsideCloses == 1, "outside-window click dismisses immediately")
        expect(outsideView.clicks == 1, "outside click is not swallowed or made to require a second click")
        expect(!monitor.isMonitoring, "outside dismissal releases monitors")
        outside.close()
        focus.cancel()
        target.close()
    }

    @MainActor
    private static func settle() async {
        // Yield to the real AppKit loop and main queue. A nested event pump
        // inside a main-queue block prevents queued activation from completing.
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    @MainActor
    private static func click(window: NSWindow) async {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.postEvent(event, atStart: false)
        await settle()
    }
}

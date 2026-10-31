import AppKit
import SwiftUI
import Carbon

/// Deterministic visual inspection of the actual production SwiftUI hierarchy.
/// This executable does not construct AppDelegate, enable monitoring, request
/// permissions, register shortcuts, or alter volume/brightness.
@main
struct RenderUI {
    @MainActor
    static func main() throws {
        if CommandLine.arguments.contains("--verify-native-presentation") {
            NSApplication.shared.setActivationPolicy(.accessory)
            try verifyNativePresentation()
            return
        }
        let previewMenu = CommandLine.arguments.contains("--preview-menu") || Bundle.main.bundleIdentifier == "com.sway.uipreview"
        let previewOSD = CommandLine.arguments.contains("--preview-osd") || Bundle.main.bundleIdentifier == "com.sway.osdpreview"
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/SwayUI")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(previewMenu || previewOSD ? .accessory : .prohibited)
        // The renderer is not an app bundle; show Sway's real icon in logo spots.
        if let icon = NSImage(contentsOfFile: "Sway/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png") {
            NSApplication.shared.applicationIconImage = icon
        }
        if previewOSD {
            showIndicatorPreview()
            return
        }

        let fixtures = [
            Fixture(surface: .actions),
            Fixture(surface: .welcome(.welcome, true)),
            Fixture(surface: .welcome(.access, false)),
            Fixture(surface: .welcome(.access, true)),
            Fixture(surface: .welcome(.practice, true)),
            Fixture(surface: .welcome(.personalize, true)),
            Fixture(surface: .welcome(.done, true)),
            Fixture(surface: .updates),
            Fixture(surface: .updates, suffix: "-inactive"),
            Fixture(surface: .updates, suffix: "-available"),
            Fixture(surface: .menu),
            Fixture(surface: .menu, suffix: "-expanded", reduceTransparency: true),
            Fixture(surface: .menu, suffix: "-reduced-transparency", reduceTransparency: true),
            Fixture(surface: .menu, suffix: "-paused", configure: { $0.isEnabled = false })
        ] + SettingsPane.allCases.map { Fixture(surface: .preferences($0)) } + [
            Fixture(surface: .preferences(.gestures), suffix: "-top-edge", configure: {
                $0.applyGesturePreset(.oneFinger)
                $0.topEdgeEnabled = true
            }),
            Fixture(surface: .preferences(.gestures), suffix: "-extended-actions", configure: {
                $0.leftZoneAction = .microphoneLevel
                $0.rightZoneAction = .customShortcut
            }),
            Fixture(surface: .preferences(.gestures), suffix: "-one-percent", configure: {
                $0.applyGesturePreset(.oneFinger)
                $0.leftZoneWidth = 0.01
                $0.rightZoneWidth = 0.01
                $0.topEdgeEnabled = true
                $0.topEdgeHeight = 0.01
            }),
            Fixture(surface: .preferences(.appearance), suffix: "-vertical-osd", configure: { $0.osdStyle = "vertical" }),
            Fixture(surface: .preferences(.appearance), suffix: "-follow-finger", configure: { $0.osdStyle = "edge" }),
            Fixture(surface: .preferences(.gestures), suffix: "-layers", configure: {
                $0.setBaseBinding(EdgeBinding(.customShortcut, up: HotkeyCombo(keyCode: 17, modifiers: UInt32(cmdKey))), for: "right")
                $0.setBaseBinding(EdgeBinding(.keyboardBrightness), for: EdgeSlot.option("left"))
                $0.setBaseBinding(EdgeBinding(.runShortcut, shortcut: "Desk Lamp Up", downShortcut: "Desk Lamp Down"), for: EdgeSlot.option("right"))
                $0.setBaseBinding(EdgeBinding(.nightShift), for: EdgeSlot.alternate("left"))
            }),
            Fixture(surface: .preferences(.gestures), suffix: "-bottom-edge", configure: {
                $0.applyGesturePreset(.oneFinger)
                $0.bottomEdgeEnabled = true
                $0.bottomEdgeAction = .seek
            }),
            Fixture(surface: .preferences(.taps), suffix: "-assigned", configure: {
                $0.setBaseBinding(EdgeBinding(.playPause), for: "left.doubleTap")
                $0.setBaseBinding(EdgeBinding(.missionControl), for: "right.tapHold")
                $0.setBaseBinding(EdgeBinding(.screenshotTools), for: "topRightCorner.doubleTap")
                $0.setBaseBinding(EdgeBinding(.cheatSheet), for: "bottomLeftCorner.doubleTap")
            }),
            Fixture(surface: .preferences(.profiles), suffix: "-with-profiles", configure: {
                $0.appProfiles["com.apple.Safari"] = ActionProfile(name: "Safari", bindings: ["right": EdgeBinding(.tabs), "left.doubleTap": EdgeBinding(.history)])
                $0.appProfiles["com.apple.FinalCut"] = ActionProfile(name: "Final Cut Pro", bindings: ["left": EdgeBinding(.zoom)])
                $0.dockedProfileEnabled = true
                $0.dockedProfile.bindings["left"] = EdgeBinding(.brightness)
            }),
            Fixture(surface: .preferences(.levels), suffix: "-device-limits", configure: {
                $0.deviceVolumeLimits["preview-device"] = DeviceLimit(name: "MacBook speakers", min: 0.05, max: 0.7)
                $0.deviceVolumeLimits["airpods"] = DeviceLimit(name: "AirPods Pro", min: 0, max: 0.6)
                $0.volumeFavorite = 0.3
                $0.extraDimBelowMinimum = true
            }),
            Fixture(surface: .preferences(.feedback), suffix: "-haptics-off", configure: { $0.hapticFeedback = false }),
            Fixture(surface: .preferences(.feedback), suffix: "-haptics-crisp", configure: {
                $0.hapticStyle = .crisp
                $0.hapticSpacing = .fine
                $0.hapticOnStart = false
            })
        ]
        for (name, scheme, appearanceName) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)
        ] {
            for fixture in fixtures {
                if previewMenu && (fixture.surface.name != "menu" || !fixture.suffix.isEmpty || name != "dark") {
                    continue
                }
                // Isolate every fixture from the app's saved preferences. The
                // preview model uses canned readouts and refuses hardware writes.
                let suiteName = "com.sway.render.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suiteName) else {
                    throw RenderError.preferencesUnavailable
                }
                defer { defaults.removePersistentDomain(forName: suiteName) }
                let settings = TrackpadSettings(defaults: defaults)
                settings.appearanceMode = name
                fixture.configure(settings)
                let content: AnyView
                let width: CGFloat
                var previewSettingsWindow: NSWindow?
                switch fixture.surface {
                case .actions:
                    content = AnyView(EdgeActionLibrary(action: .constant(.microphoneLevel), edgeName: "Left edge action", preview: true))
                    width = 590
                case let .welcome(step, access):
                    content = AnyView(GettingStartedView(settings: settings, preview: true, hasAccess: access, previewStep: step, openControls: {}))
                    width = 560
                case .updates:
                    content = AnyView(UpdateWindowView(updates: UpdateChecker(defaults: defaults, current: "1.0.6"), settings: settings, preview: true, previewUpdateAvailable: fixture.suffix == "-available"))
                    width = 440
                case .menu:
                    content = AnyView(MenuBarView(settings: settings, preview: true,
                        previewStandaloneSurface: !previewMenu,
                        previewReduceTransparency: fixture.reduceTransparency,
                        previewExpandedOptions: fixture.suffix == "-expanded", openSettings: {
                            guard previewMenu else { return }
                            let window = previewSettingsWindow ?? NSWindow(
                                contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
                            if previewSettingsWindow == nil {
                                window.title = "Sway Settings Preview"
                                window.isReleasedWhenClosed = false
                                window.contentViewController = NSHostingController(rootView:
                                    ContentView(initialPane: .gestures, preview: true, settings: settings))
                                window.center()
                                previewSettingsWindow = window
                            }
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }))
                    width = 320
                case .preferences(let tab):
                    content = AnyView(ContentView(initialPane: tab, preview: true, settings: settings,
                                                  updates: UpdateChecker(defaults: defaults, current: "1.0.6")))
                    width = 820
                }
                let root = content
                    .environment(\.colorScheme, scheme)
                    .environment(\.controlActiveState, fixture.suffix == "-inactive" ? .inactive : .key)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                if previewMenu {
                    let mainMenu = NSMenu()
                    let appItem = NSMenuItem()
                    let appMenu = NSMenu()
                    appMenu.addItem(withTitle: "Quit UI Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
                    appItem.submenu = appMenu
                    mainMenu.addItem(appItem)
                    let editItem = NSMenuItem()
                    let editMenu = NSMenu(title: "Edit")
                    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
                    editItem.submenu = editMenu
                    mainMenu.addItem(editItem)
                    NSApp.mainMenu = mainMenu
                    // Match the actual menu-bar container, not a decorative
                    // mock window. This creates no production AppDelegate.
                    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                    statusItem.button?.title = "Sway Preview"
                    let popover = NSPopover()
                    popover.behavior = .applicationDefined
                    let controller = FirstClickHostingController(rootView: root)
                    controller.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
                    controller.view.appearance = NSAppearance(named: appearanceName)
                    controller.install(in: popover)
                    popover.appearance = NSAppearance(named: appearanceName)
                    guard let button = statusItem.button else { throw RenderError.previewAnchorUnavailable }
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    popover.contentViewController?.view.window?.makeKey()
                    print("Live native popover: no hardware controls or gesture monitoring are active. Stop this process to close it.")
                    NSApp.run()
                    NSStatusBar.system.removeStatusItem(statusItem)
                    return
                }
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: appearanceName)
                let fitting = host.fittingSize
                guard fitting.width.isFinite, fitting.height.isFinite,
                      fitting.height > 100, fitting.height < 2000 else {
                    throw RenderError.invalidFittingSize
                }
                let size = NSSize(width: width, height: ceil(fitting.height))
                host.frame = NSRect(origin: .zero, size: size)
                // Give native materials actual neutral content to sample. A
                // background-less bitmap can turn translucent glass black or
                // flatten it completely, obscuring contrast problems.
                let canvas = NeutralBackdropView(frame: NSRect(
                    origin: .zero, size: NSSize(width: size.width + 32, height: size.height + 32)))
                canvas.isDark = scheme == .dark
                canvas.addSubview(host)
                host.setFrameOrigin(NSPoint(x: 16, y: 16))
                let window = NSWindow(contentRect: canvas.frame,
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = host.appearance
                window.contentView = canvas
                window.setContentSize(canvas.frame.size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()

                let stem = "sway-\(fixture.surface.name)-\(name)\(fixture.suffix)"
                try snapshot(canvas, to: output.appendingPathComponent("\(stem).png"))
                print("  Content size: \(Int(size.width)) × \(Int(size.height)) pt")

                // Also inspect every lower part of long pages. Scrolling the
                // hosting scroll view changes no preferences or device state.
                if let scroll = scrollViews(in: host).max(by: { $0.bounds.width < $1.bounds.width }),
                   let document = scroll.documentView {
                    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    var offset: CGFloat = 0
                    var page = 2
                    while offset < maximum - 1 {
                        offset = min(maximum, offset + scroll.contentView.bounds.height * 0.85)
                        let y = document.isFlipped ? offset : maximum - offset
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        host.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                        try snapshot(canvas, to: output.appendingPathComponent("\(stem)-page\(page).png"))
                        page += 1
                    }
                }
                if fixture.surface.name == "menu", fixture.suffix.isEmpty {
                    try verifyInlineOptions(in: host, window: window)
                }
                window.contentView = nil
                window.close()
            }
        }
        try renderIndicators(to: output)
    }

    /// A bounded, graphical-session check of the actual native container, not
    /// just SwiftUI's requested size. Only isolated preview controls are used.
    @MainActor
    private static func verifyNativePresentation() throws {
        func settle(_ view: NSView) {
            for _ in 0..<15 {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                NSApp.updateWindows()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func findMore(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityLabel() == "More options" { return button }
            return view.subviews.lazy.compactMap { findMore($0) }.first
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let anchor = NSWindow(contentRect: NSRect(x: screen.midX - 100, y: screen.maxY - 100, width: 200, height: 40),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        anchor.title = "Sway — safe layout check"
        anchor.isReleasedWhenClosed = false
        defer { anchor.close() }
        let button = NSButton(frame: NSRect(x: 80, y: 10, width: 40, height: 20))
        button.title = "Sway"
        anchor.contentView?.addSubview(button)
        anchor.orderFront(nil)
        for name in ["light", "dark"] {
            let suite = "com.sway.native-layout.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { throw RenderError.preferencesUnavailable }
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = TrackpadSettings(defaults: defaults)
            settings.appearanceMode = name
            let controller = FirstClickHostingController(rootView: MenuBarView(settings: settings, preview: true, openSettings: {}))
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            controller.install(in: popover)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            defer { popover.close(); popover.contentViewController = nil }
            settle(controller.view)
            guard popover.isShown, let more = findMore(controller.view) else { throw RenderError.invalidInlineOptions }
            let collapsed = controller.view.fittingSize.height
            for expanded in [true, false, true, false] {
                more.performClick(nil)
                settle(controller.view)
                let measured = controller.view.fittingSize
                let visible = controller.view.visibleRect
                print("Native \(name) \(expanded ? "expanded" : "collapsed"): fitting=\(measured), popover=\(popover.contentSize), bounds=\(controller.view.bounds.size), visible=\(visible.size)")
                guard popover.isShown, popover.contentViewController === controller,
                      more.accessibilityValue() as? String == (expanded ? "Expanded" : "Collapsed"),
                      expanded ? measured.height > collapsed + 100 : abs(measured.height - collapsed) < 1,
                      abs(popover.contentSize.height - measured.height) < 1,
                      visible.height >= measured.height - 1,
                      visible.width >= measured.width - 1 else { throw RenderError.invalidInlineOptions }
            }
            popover.close()
        }
        let dock = DockPresenceCoordinator()
        dock.setEnabled(true)
        guard NSApp.activationPolicy() == .accessory else { throw RenderError.invalidDockLifecycle }
        dock.windowWillOpen(anchor)
        settle(anchor.contentView!)
        guard NSApp.activationPolicy() == .regular else { throw RenderError.invalidDockLifecycle }
        anchor.miniaturize(nil)
        settle(anchor.contentView!)
        guard anchor.isMiniaturized, NSApp.activationPolicy() == .regular else { throw RenderError.invalidDockLifecycle }
        anchor.deminiaturize(nil)
        settle(anchor.contentView!)
        guard !anchor.isMiniaturized, NSApp.activationPolicy() == .regular else { throw RenderError.invalidDockLifecycle }
        dock.windowWillClose(anchor)
        anchor.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard NSApp.activationPolicy() == .accessory else { throw RenderError.invalidDockLifecycle }
        print("Native expanded/collapsed popover bounds and open/minimize/restore/close Dock policy verified. No production app or hardware controls ran.")
    }

    /// Exercise the real menu hierarchy while its window is not key. The first
    /// action must expand inline without starting an NSMenu tracking session.
    @MainActor
    private static func verifyInlineOptions(in host: NSView, window: NSWindow) throws {
        func findButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityLabel() == "More options" { return button }
            return view.subviews.lazy.compactMap { findButton($0) }.first
        }
        guard let button = findButton(host), button.acceptsFirstMouse(for: nil), button.menu == nil else {
            throw RenderError.invalidInlineOptions
        }
        let collapsed = host.fittingSize.height
        let windows = Set(NSApp.windows.map(\.windowNumber))
        button.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard host.window === window, host.fittingSize.height > collapsed + 80,
              Set(NSApp.windows.map(\.windowNumber)) == windows,
              button.accessibilityValue() as? String == "Expanded" else {
            throw RenderError.invalidInlineOptions
        }
        button.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard abs(host.fittingSize.height - collapsed) < 1,
              button.accessibilityValue() as? String == "Collapsed" else {
            throw RenderError.invalidInlineOptions
        }
        print("Verified first-action expansion and collapse in the production menu hierarchy; no popup window created.")
    }

    /// This uses the production AppKit indicator content and material. Bitmap
    /// caching verifies geometry, but only the live fixture verifies refraction.
    @MainActor
    private static func renderIndicators(to output: URL) throws {
        let content = OSDContentView(horizontal: true)
        for (value, expected) in [(Double(-2), "0 percent"), (0, "0 percent"),
                                  (0.005, "1 percent"), (0.425, "43 percent"),
                                  (1, "100 percent"), (2, "100 percent"),
                                  (Double.nan, "100 percent"), (Double.infinity, "100 percent")] {
            content.update(type: .volume, value: value)
            guard content.accessibilityValue() as? String == expected else {
                throw RenderError.invalidIndicatorValue
            }
        }
        content.update(type: .brightness, value: 0.68)
        guard content.accessibilityLabel() == "Brightness",
              content.accessibilityValue() as? String == "68 percent" else {
            throw RenderError.invalidIndicatorValue
        }
        content.update(type: .microphone, value: 0.42)
        guard content.accessibilityLabel() == "Microphone input level",
              content.accessibilityValue() as? String == "42 percent" else { throw RenderError.invalidIndicatorValue }
        content.update(type: .microphoneMute, value: 1)
        guard content.accessibilityValue() as? String == "Mute on" else { throw RenderError.invalidIndicatorValue }
        content.update(type: .microphoneMute, value: 0)
        guard content.accessibilityValue() as? String == "Mute off" else { throw RenderError.invalidIndicatorValue }
        print("12 native indicator value/accessibility checks passed.")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for horizontal in [false, true] {
                for reduced in [false, true] {
                    let size = horizontal ? NSSize(width: 240, height: 48) : NSSize(width: 52, height: 208)
                    let surface = OSDSurfaceView(horizontal: horizontal, forceReduceTransparency: reduced)
                    surface.frame = NSRect(origin: NSPoint(x: 32, y: 32), size: size)
                    surface.appearance = NSAppearance(named: appearance)
                    surface.content.update(type: horizontal ? .brightness : .volume, value: horizontal ? 0.68 : 0.42)
                    let canvas = NeutralBackdropView(frame: NSRect(origin: .zero,
                        size: NSSize(width: size.width + 64, height: size.height + 64)))
                    canvas.isDark = name == "dark"
                    canvas.addSubview(surface)
                    let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = surface.appearance
                    window.contentView = canvas
                    window.setContentSize(canvas.frame.size)
                    canvas.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    canvas.layoutSubtreeIfNeeded()
                    let orientation = horizontal ? "horizontal" : "vertical"
                    let suffix = reduced ? "-reduced-transparency" : ""
                    try snapshot(canvas, to: output.appendingPathComponent("sway-indicator-\(orientation)-\(name)\(suffix).png"))
                    if #available(macOS 26.0, *), !reduced {
                        guard let glass = surface.subviews.first as? NSGlassEffectView,
                              glass.contentView === surface.content,
                              surface.layer?.masksToBounds != true else {
                            throw RenderError.invalidGlassHierarchy
                        }
                    }
                    window.contentView = nil
                    window.close()
                }
            }
        }
        print("Native indicator layouts and unmasked glass content hierarchy verified.")
    }

    @MainActor
    private static func showIndicatorPreview() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 370),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sway Indicator Preview — no hardware changes"
        window.isReleasedWhenClosed = false
        let delegate = IndicatorPreviewDelegate()
        window.delegate = delegate
        window.contentView = IndicatorBackdropView(frame: NSRect(x: 0, y: 0, width: 740, height: 370))
        window.center()
        window.makeKeyAndOrderFront(nil)
        let origin = window.convertToScreen(NSRect(x: 0, y: 0, width: 740, height: 370)).origin
        var indicators: [OSDWindow] = []
        for (index, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            for horizontal in [false, true] {
                let size = horizontal ? NSSize(width: 240, height: 48) : NSSize(width: 52, height: 208)
                let local = NSPoint(x: CGFloat(index) * 370 + (370 - size.width) / 2,
                                    y: horizontal ? 38 : 120)
                let indicator = OSDWindow(contentRect: NSRect(
                    origin: NSPoint(x: origin.x + local.x, y: origin.y + local.y), size: size))
                indicator.level = .normal
                indicator.appearance = NSAppearance(named: appearance)
                let surface = OSDSurfaceView(horizontal: horizontal)
                indicator.contentView = surface
                surface.content.update(type: horizontal ? .brightness : .volume, value: horizontal ? 0.68 : 0.42)
                window.addChildWindow(indicator, ordered: .above)
                indicators.append(indicator)
            }
        }
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Indicator Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true)
        print("Live native indicators over light and dark backdrops. No gestures, device changes, or production preferences are active.")
        withExtendedLifetime((indicators, delegate)) { NSApp.run() }
    }

    private struct Fixture {
        let surface: Surface
        var suffix = ""
        var reduceTransparency = false
        var configure: (TrackpadSettings) -> Void = { _ in }
    }

    private enum Surface {
        case actions
        case welcome(GettingStartedView.Step, Bool)
        case updates
        case menu
        case preferences(SettingsPane)

        var name: String {
            switch self {
            case .actions: return "action-library"
            case let .welcome(step, access): return "welcome-\(step)" + (step == .access && !access ? "-needed" : "")
            case .updates: return "updates"
            case .menu: return "menu"
            case .preferences(let tab): return "settings-\(tab.rawValue)"
            }
        }
    }

    @MainActor
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    @MainActor
    private static func snapshot(_ view: NSView, to target: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RenderError.bitmapUnavailable
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngUnavailable
        }
        try png.write(to: target)
        print(target.path)
    }

    enum RenderError: Error {
        case preferencesUnavailable
        case bitmapUnavailable
        case pngUnavailable
        case invalidFittingSize
        case previewAnchorUnavailable
        case invalidGlassHierarchy
        case invalidIndicatorValue
        case invalidInlineOptions
        case invalidDockLifecycle
    }
}

private final class IndicatorPreviewDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

private final class IndicatorBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let half = bounds.width / 2
        NSColor(white: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: half, height: bounds.height).fill()
        NSColor(white: 0.04, alpha: 1).setFill()
        NSRect(x: half, y: 0, width: half, height: bounds.height).fill()
        // Quiet contrasting stripes make live refraction observable without
        // pretending the fixture is an image of the user's real desktop.
        for index in 0..<2 {
            let color = NSColor(white: index == 0 ? 0.70 : 0.24, alpha: 1)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * half + 25, y: 168,
                width: half - 50, height: 46), xRadius: 18, yRadius: 18).fill()
        }
    }
}

/// A deliberately quiet backdrop, not a decorative mock wallpaper. Everything
/// inside the inset is the unmodified production view and its real material.
private final class NeutralBackdropView: NSView {
    var isDark = false

    override func draw(_ dirtyRect: NSRect) {
        let low: CGFloat = isDark ? 0.15 : 0.79
        let high: CGFloat = isDark ? 0.29 : 0.96
        NSGradient(starting: NSColor(white: low, alpha: 1),
                   ending: NSColor(white: high, alpha: 1))?.draw(in: bounds, angle: 35)
    }
}

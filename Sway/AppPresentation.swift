import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case gestures, taps, profiles, protection, levels, feedback, appearance, general, updates, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gestures: return "Gestures"
        case .taps: return "Taps & corners"
        case .profiles: return "Profiles"
        case .protection: return "Palm protection"
        case .levels: return "Volume & brightness"
        case .feedback: return "Haptics"
        case .appearance: return "Appearance"
        case .general: return "General"
        case .updates: return "Software updates"
        case .about: return "About & help"
        }
    }
    var icon: String {
        switch self {
        case .gestures: return "hand.draw"
        case .taps: return "hand.tap"
        case .profiles: return "square.stack"
        case .protection: return "hand.raised"
        case .levels: return "slider.horizontal.3"
        case .feedback: return "waveform.path"
        case .appearance: return "paintbrush"
        case .general: return "gearshape"
        case .updates: return "arrow.down.circle"
        case .about: return "questionmark.circle"
        }
    }
    var detail: String {
        switch self {
        case .gestures: return "Assign edges, layers, and how swipes feel."
        case .taps: return "Double-tap or tap-and-hold edges and corners."
        case .profiles: return "Change edges for specific apps or when docked."
        case .protection: return "Tune intent checks and try gestures safely."
        case .levels: return "Limits, favorite levels, devices, and displays."
        case .feedback: return "Choose the taps you feel on your trackpad."
        case .appearance: return "Customize the menu bar and on-screen indicator."
        case .general: return "Startup, shortcuts, automation, and your settings file."
        case .updates: return "Check, download, and install signed updates."
        case .about: return "Setup help, version information, and reset."
        }
    }
    private var keywords: String {
        switch self {
        case .gestures: return "preset finger fingers one two edge zones width narrow sensitivity direction top bottom left right swipe reverse action volume brightness microphone keyboard backlight media playback track tab navigation zoom window desktop workspace shortcut screenshot emoji spotlight mute precision fine scrub speed acceleration flick layer option modifier tile shortcuts night shift true tone dim seek output app volume map"
        case .taps: return "tap double-tap hold tap-and-hold corner corners hot click"
        case .profiles: return "app apps profile profiles per-app docked dock external monitor display override"
        case .protection: return "palm rejection strict balanced typing cooldown activation distance test diagnostics permission accessibility"
        case .levels: return "volume brightness audio display minimum maximum limit mute zero favorite notch device airpods headphones external monitor ddc pointer extra dim"
        case .feedback: return "haptic feedback soft standard crisp tap vibration strength spacing steps preview notch notches detent sound click"
        case .appearance: return "theme dark light system liquid glass indicator osd pill vertical horizontal position width menu bar icon follow finger edge now playing artwork scroll"
        case .general: return "login launch startup dock spotlight shortcut hotkey pause exclude excluded apps cheat sheet edge map url automation export import backup settings file"
        case .updates: return "github update release install download version automatic daily"
        case .about: return "help welcome setup guide accessibility permission reset version"
        }
    }
    func matches(_ query: String) -> Bool {
        let haystack = "\(title) \(detail) \(keywords)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// Closing a guide is not completing setup. Legacy completion is respected
/// only while Accessibility is actually granted; denied/revoked access returns
/// the guide on the next launch or explicit reopen, never on a polling timer.
final class SetupProgress {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func shouldPresent(hasAccess: Bool) -> Bool {
        !hasAccess || !(defaults.bool(forKey: "hasFinishedSwaySetup") || defaults.bool(forKey: "hasCompletedSwaySetup"))
    }
    func finish(hasAccess: Bool) {
        guard hasAccess else { return }
        defaults.set(true, forKey: "hasFinishedSwaySetup")
    }
}

/// Native controls own first-click handling, drawing, and menu tracking.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SystemActionButton: NSViewRepresentable {
    let title: String
    var isEnabled = true
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func invoke(_ sender: Any?) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> FirstClickButton {
        let button = FirstClickButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        // Do not translate SwiftUI's monochrome tint into a solid black bezel.
        button.bezelColor = nil
        button.contentTintColor = nil
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: FirstClickButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
        button.invalidateIntrinsicContentSize()
    }
}

/// Expands options inside the existing popover: no second window, menu tracking
/// loop, or asynchronous activation handoff can consume the first click.
struct MoreOptionsButton: NSViewRepresentable {
    var isExpanded: Bool
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func toggle(_ sender: Any?) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> FirstClickButton {
        let button = FirstClickButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("More options")
        return button
    }
    func updateNSView(_ button: FirstClickButton, context: Context) {
        context.coordinator.action = action
        button.state = isExpanded ? .on : .off
        button.toolTip = isExpanded ? "Hide options" : "Show options"
        button.setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// Explicit monochrome foreground/background pairing, including macOS 26's
/// prominent-button rendering. A semantic primary tint alone is not sufficient.
struct MonochromePrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(scheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 9))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.72 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Accept controls on the first click before an accessory app becomes active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    var sizeDidChange: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // SwiftUI can change its ideal size without another NSView.layout().
        sizeDidChange?()
    }
    override func layout() {
        super.layout()
        sizeDidChange?()
    }
}

/// NSHostingController creates its own hosting view during initialization;
/// overriding loadView does not reliably replace that view. Own the host here.
final class FirstClickHostingController<Content: View>: NSViewController {
    private let host: FirstClickHostingView<AnyView>
    private weak var sizingPopover: NSPopover?
    private var sizeUpdatePending = false
    var sizingOptions: NSHostingSizingOptions = [.intrinsicContentSize, .preferredContentSize] {
        didSet { host.sizingOptions = sizingOptions }
    }
    init(rootView: Content) {
        let content: AnyView
        if #available(macOS 15, *) { content = AnyView(rootView.allowsWindowActivationEvents(true)) }
        else { content = AnyView(rootView) }
        host = FirstClickHostingView(rootView: content)
        super.init(nibName: nil, bundle: nil)
        host.sizingOptions = sizingOptions
        view = host
        preferredContentSize = host.fittingSize
        host.setFrameSize(preferredContentSize)
        host.sizeDidChange = { [weak self] in self?.scheduleContentSizeUpdate() }
    }
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }
    override func loadView() { view = host }

    /// A popover owns its private window hierarchy. Updating the hosting
    /// controller alone does not reliably resize that hierarchy on macOS.
    func install(in popover: NSPopover) {
        sizingPopover = popover
        popover.contentViewController = self
        popover.contentSize = preferredContentSize
    }

    private func scheduleContentSizeUpdate() {
        guard !sizeUpdatePending else { return }
        sizeUpdatePending = true
        // Coalesce SwiftUI layout changes outside the active layout pass.
        // No timer, polling, or close/reopen cycle is needed to resize.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeUpdatePending = false
            // fittingSize can reflect the container's previous constraints.
            // intrinsicContentSize is SwiftUI's new ideal content size.
            let measured = self.host.intrinsicContentSize
            guard measured.width.isFinite, measured.height.isFinite, measured.width > 0, measured.height > 0 else { return }
            let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
            guard self.preferredContentSize != size else { return }
            self.preferredContentSize = size
            if let popover = self.sizingPopover, popover.contentViewController === self {
                if popover.contentSize != size { popover.contentSize = size }
            } else if let window = self.view.window, window.contentViewController === self, !window.inLiveResize {
                window.setContentSize(size)
            }
        }
    }
}

/// Dock presence follows open utility windows, never the menu popover or HUD.
/// Minimized/hidden windows remain registered so a Dock click can restore them.
final class DockPresenceCoordinator {
    private var enabled = false
    private var windows = Set<ObjectIdentifier>()
    private var appliedPolicy: NSApplication.ActivationPolicy?
    private var closeUpdatePending = false
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Bool
    private let afterClose: (@escaping () -> Void) -> Void

    init(applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = { NSApp.setActivationPolicy($0) },
         afterClose: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.applyPolicy = applyPolicy
        self.afterClose = afterClose
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        reconcile()
    }

    func windowWillOpen(_ window: NSWindow) {
        windows.insert(ObjectIdentifier(window))
        reconcile()
    }

    func windowWillClose(_ window: NSWindow) {
        guard windows.remove(ObjectIdentifier(window)) != nil, !closeUpdatePending else { return }
        closeUpdatePending = true
        // A welcome → controls handoff must not flash the Dock icon off/on.
        afterClose { [weak self] in
            guard let self else { return }
            self.closeUpdatePending = false
            self.reconcile()
        }
    }

    private func reconcile() {
        let policy: NSApplication.ActivationPolicy = enabled && !windows.isEmpty ? .regular : .accessory
        guard appliedPolicy != policy else { return }
        if applyPolicy(policy) { appliedPolicy = policy }
    }
}

/// Close the old surface before activating and focusing its destination.
final class WindowFocusCoordinator {
    private weak var pendingWindow: NSWindow?

    func show(_ window: NSWindow, closingPrevious: () -> Void = {}) {
        closingPrevious()
        pendingWindow = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        Self.activateApplication()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.pendingWindow === window,
                  window.isVisible, !window.isMiniaturized, NSApp.isActive else { return }
            window.makeKeyAndOrderFront(nil)
            self.pendingWindow = nil
        }
    }

    func didBecomeActive() {
        guard let window = pendingWindow, window.isVisible, !window.isMiniaturized else { return }
        pendingWindow = nil
        window.makeKeyAndOrderFront(nil)
    }

    func cancel() { pendingWindow = nil }

    static func activateApplication() {
        if #available(macOS 14, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// These observers exist only while the popover is visible. Outside clicks are
/// observed, never swallowed: the destination app receives the original click.
final class PopoverDismissalMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var trackedMenus = Set<ObjectIdentifier>()
    private var generation = 0
    private var menuInteractionDepth = 0
    private var close: (() -> Void)?
    private var pointerIsOutside: (() -> Bool)?
    private var applicationIsActive: () -> Bool = { NSApp.isActive }
    private var pendingOutsideClick = false
    private var pendingDeactivation = false
    private let afterMenu: (@escaping () -> Void) -> Void

    init(afterMenu: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.afterMenu = afterMenu
    }
    var isTrackingMenu: Bool { menuInteractionDepth > 0 || !trackedMenus.isEmpty }

    func beginMenuInteraction() { menuInteractionDepth += 1 }
    func endMenuInteraction() {
        menuInteractionDepth = max(0, menuInteractionDepth - 1)
        reconcileAfterMenu()
    }

    private func requestClose(forOutsideClick: Bool) {
        if isTrackingMenu {
            if forOutsideClick { pendingOutsideClick = true }
            else { pendingDeactivation = true }
        } else { close?() }
    }

    private func reconcileAfterMenu() {
        let identity = generation
        // Let NSMenu deliver the selected action before releasing its host.
        afterMenu { [weak self] in
            guard let self, self.generation == identity, !self.isTrackingMenu else { return }
            let shouldClose = self.pendingOutsideClick || (self.pendingDeactivation && !self.applicationIsActive())
                || (self.pointerIsOutside?() ?? false)
            self.pendingOutsideClick = false
            self.pendingDeactivation = false
            if shouldClose { self.close?() }
        }
    }

    static func isOutside(_ point: NSPoint, panel: NSRect?, anchor: NSRect?) -> Bool {
        !(panel?.contains(point) ?? false) && !(anchor?.contains(point) ?? false)
    }

    func start(panel: @escaping () -> NSWindow?, anchor: @escaping () -> NSRect?,
               pointer: @escaping () -> NSPoint = { NSEvent.mouseLocation },
               applicationIsActive: @escaping () -> Bool = { NSApp.isActive }, close: @escaping () -> Void) {
        stop()
        self.close = close
        self.applicationIsActive = applicationIsActive
        pointerIsOutside = { Self.isOutside(pointer(), panel: panel()?.frame, anchor: anchor()) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, !self.isTrackingMenu { close(); return nil }
            } else if !self.isTrackingMenu {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                if Self.isOutside(point, panel: panel()?.frame, anchor: anchor()) { close() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.requestClose(forOutsideClick: true)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            if let menu = note.object as? NSMenu { self?.trackedMenus.insert(ObjectIdentifier(menu)) }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
            if let menu = note.object as? NSMenu { self?.trackedMenus.remove(ObjectIdentifier(menu)) }
            self?.reconcileAfterMenu()
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.requestClose(forOutsideClick: false)
        })
    }

    func stop() {
        generation += 1
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        trackedMenus.removeAll()
        menuInteractionDepth = 0
        pendingOutsideClick = false
        pendingDeactivation = false
        close = nil
        pointerIsOutside = nil
    }

    deinit { stop() }
    var isMonitoring: Bool { localMonitor != nil || globalMonitor != nil }
}

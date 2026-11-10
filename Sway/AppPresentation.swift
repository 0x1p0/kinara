import AppKit
import SwiftUI

/// Six places, each a plain noun: what you'd look for, not how it's built.
enum SettingsPane: String, CaseIterable, Identifiable {
    case home, edges, feel, sound, apps, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .edges: return "Edges & corners"
        case .feel: return "Feel"
        case .sound: return "Sound & display"
        case .apps: return "Apps"
        case .general: return "General"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .edges: return "hand.tap.fill"
        case .feel: return "waveform"
        case .sound: return "speaker.wave.2.fill"
        case .apps: return "square.stack.fill"
        case .general: return "gearshape.fill"
        }
    }
    /// The sidebar tile's gradient, top to bottom.
    var colors: (top: Color, bottom: Color) {
        switch self {
        case .home: return (Color(red: 0.36, green: 0.64, blue: 1), Color(red: 0.04, green: 0.45, blue: 0.98))
        case .edges: return (Color(red: 0.74, green: 0.55, blue: 1), Color(red: 0.53, green: 0.31, blue: 0.93))
        case .feel: return (Color(red: 1, green: 0.72, blue: 0.27), Color(red: 1, green: 0.53, blue: 0.02))
        case .sound: return (Color(red: 1, green: 0.45, blue: 0.55), Color(red: 0.96, green: 0.19, blue: 0.34))
        case .apps: return (Color(red: 0.38, green: 0.82, blue: 0.96), Color(red: 0.11, green: 0.62, blue: 0.87))
        case .general: return (Color(white: 0.68), Color(white: 0.52))
        }
    }
    /// Pages with options most people never need keep them in a sheet.
    var hasAdvanced: Bool { [.edges, .feel, .sound, .general].contains(self) }
    var detail: String {
        switch self {
        case .home: return "What Kinara is doing, at a glance."
        case .edges: return "Choose what each edge and corner does."
        case .feel: return "How gestures feel, and what you see when you use them."
        case .sound: return "Limits for volume and brightness, and a fader for every app."
        case .apps: return "Different edges in different apps, or when you’re docked."
        case .general: return "Startup, look, clipboard, shortcuts, updates and help."
        }
    }
    private var keywords: String {
        switch self {
        case .home: return "overview home status summary quick toggle"
        case .edges: return "edge edges corner corners tap double-tap hold tap-and-hold swipe slide action actions zone width size preset finger fingers one two top bottom left right layer option modifier shortcut custom palm rejection strict balanced typing cooldown activation distance test safely paste mission control"
        case .feel: return "haptic haptics feedback soft standard crisp strongest tap vibration strength spacing steps notch notches detent sound click indicator osd pill vertical follow finger position width light edge corner glow colour color aurora sunset ember mint mono ambient screensaver fine control precision speed curve acceleration sensitivity reverse direction pointer hold now playing artwork"
        case .sound: return "volume brightness audio display limit limits minimum maximum mute zero favorite device output airpods headphones external monitor ddc pointer extra dim mixer app apps per-app solo call calls ducking duck meeting speakers boost faders"
        case .apps: return "app apps profile profiles per-app docked dock external monitor override exclude excluded pause"
        case .general: return "login launch startup dock command-tab spotlight theme dark light system menu bar icon scroll clipboard history copies images pictures screenshots search shortcut hotkey pause edge map cheat sheet update updates install download version automatic github links url automation export import backup settings file help guide getting started diagnostic log reset about"
        }
    }

    func matches(_ query: String) -> Bool {
        let haystack = "\(title) \(detail) \(keywords)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// Sway's mark for the menu bar: a trackpad outline whose right edge carries
/// the swipe, matching the app icon. A template image, so macOS tints it for
/// light, dark and tinted menu bars. Paused keeps the outline, dims the swipe.
enum SwayGlyph {
    static func image(active: Bool, badge: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: badge ? 24 : 19, height: 16), flipped: false) { _ in
            let pad = NSBezierPath(roundedRect: NSRect(x: 1, y: 2.25, width: 17, height: 11.5), xRadius: 3.4, yRadius: 3.4)
            pad.lineWidth = 1.4
            NSColor.black.setStroke()
            pad.stroke()
            // The quiet left track and the swipe rising on the right edge.
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: 3.7, y: 4.5, width: 2.2, height: 7), xRadius: 1.1, yRadius: 1.1).fill()
            NSColor.black.withAlphaComponent(active ? 1 : 0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12.9, y: 4.5, width: 2.4, height: active ? 7 : 3.4), xRadius: 1.2, yRadius: 1.2).fill()
            if badge {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 20, y: 1, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badge ? "Kinara — update available" : "Kinara"
        return image
    }
}

/// The app icon wherever Sway shows its own logo inside its windows.
struct SwayLogo: View {
    var size: CGFloat = 32
    var dimmed = false
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.55 : 1)
            .accessibilityHidden(true)
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
/// Label-colored fill with window-colored text. Both are dynamic AppKit
/// colors resolved by the view's own appearance at draw time, so the pair can
/// never disagree (white on white) while a window's appearance settles.
struct MonochromePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(nsColor: .labelColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// A soft, springy press for tiles and other custom buttons.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.68), value: configuration.isPressed)
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

/// How a RevealDriver reaches the menu's popover. While it drives, the
/// popover's own sizing waits, so one frame never gets two heights.
enum PopoverSizing {
    static var isDriven = false
    static var currentHeight: (() -> CGFloat?)?
    static var setHeight: ((CGFloat) -> Void)?
    /// Hands sizing back to the content once a reveal ends.
    static var settle: (() -> Void)?
}

/// Unfolds content one display frame at a time. Each frame sets the content's
/// progress and the popover's height together, on one fixed-length curve, so
/// the glass and the content can't drift apart, overshoot, or crawl in at
/// the end the way a spring's tail does in whole points.
final class RevealDriver: NSObject, ObservableObject {
    @Published private(set) var progress: CGFloat
    /// The revealed content's full height, measured by its view.
    var contentHeight: CGFloat = 0
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var start: CFTimeInterval?
    private var duration: CFTimeInterval = 0
    private var baseHeight: CGFloat = 0
    private var running = false
    /// Kept for the driver's life and only paused in between, so a reveal
    /// starts on the very next frame instead of waiting for a new link.
    private var link: AnyObject?

    init(progress: CGFloat) { self.progress = progress }

    deinit {
        if #available(macOS 14, *), let link = link as? CADisplayLink { link.invalidate() }
        (link as? Timer)?.invalidate()
    }

    /// A critically damped spring from rest, scaled to land exactly on time:
    /// it eases out of a standstill and settles softly, with no tail to crawl.
    static func curve(_ t: Double) -> Double {
        let stiffness = 7.4
        func spring(_ s: Double) -> Double { 1 - (1 + stiffness * s) * exp(-stiffness * s) }
        return min(1, spring(max(0, t)) / spring(1))
    }

    func animate(to target: CGFloat, duration: CFTimeInterval) {
        from = progress
        to = target
        self.duration = duration
        // The clock starts on the first frame drawn, so a busy first moment
        // delays the motion rather than skipping part of it.
        start = nil
        // The popover's height without the revealed part; each frame adds back what shows.
        if let height = PopoverSizing.currentHeight?(), contentHeight > 0 {
            baseHeight = height - contentHeight * progress
            PopoverSizing.isDriven = true
        }
        running = true
        runLink()
    }

    func set(_ value: CGFloat) {
        running = false
        pauseLink()
        finish()
        progress = value
    }

    fileprivate func step() {
        guard running else { return }
        let now = CACurrentMediaTime()
        let startedAt = start ?? now
        start = startedAt
        let t = duration > 0 ? min(1, (now - startedAt) / duration) : 1
        progress = from + (to - from) * CGFloat(Self.curve(t))
        guard t >= 1 else {
            if PopoverSizing.isDriven { PopoverSizing.setHeight?(baseHeight + contentHeight * progress) }
            return
        }
        // The last frame in whole points, as the popover sizes itself, so handing back changes nothing.
        if PopoverSizing.isDriven { PopoverSizing.setHeight?(ceil(baseHeight + contentHeight * to)) }
        running = false
        pauseLink()
        finish()
    }

    private func runLink() {
        if #available(macOS 14, *) {
            if let link = link as? CADisplayLink {
                link.isPaused = false
                return
            }
            if let screen = NSScreen.main {
                let link = screen.displayLink(target: RevealFrameTarget(self), selector: #selector(RevealFrameTarget.frame(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                self.link = link
                return
            }
        }
        guard link == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, target: RevealFrameTarget(self), selector: #selector(RevealFrameTarget.tick(_:)),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        link = timer
    }

    private func pauseLink() {
        if #available(macOS 14, *), let link = link as? CADisplayLink { link.isPaused = true }
        if let timer = link as? Timer {
            timer.invalidate()
            link = nil
        }
    }

    private func finish() {
        guard PopoverSizing.isDriven else { return }
        PopoverSizing.isDriven = false
        PopoverSizing.settle?()
    }
}

/// The display link holds its target strongly; this keeps that from holding the driver.
private final class RevealFrameTarget: NSObject {
    private weak var driver: RevealDriver?
    init(_ driver: RevealDriver) { self.driver = driver }
    @available(macOS 14, *)
    @objc func frame(_ link: CADisplayLink) { driver?.step() }
    @objc func tick(_ timer: Timer) { driver?.step() }
}

/// Shows the top `progress` of its content, laid out at full height, so the
/// height can change every frame and the popover grow with it.
struct RevealLayout: Layout {
    var progress: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * max(0, min(1, progress)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        content.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

struct RevealModifier: ViewModifier {
    var progress: CGFloat
    func body(content: Content) -> some View {
        RevealLayout(progress: progress) { content }
            .clipped()
            .opacity(Double(max(0, min(1, progress))))
    }
}

private struct RevealHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Content unfolded by a RevealDriver. Only this view follows the driver's
/// frames, so the rest of the menu isn't rebuilt sixty times a second.
struct RevealContainer<Content: View>: View {
    @ObservedObject var driver: RevealDriver
    let content: Content
    var body: some View {
        content
            .background(GeometryReader { proxy in Color.clear.preference(key: RevealHeightKey.self, value: proxy.size.height) })
            .modifier(RevealModifier(progress: driver.progress))
            .onPreferenceChange(RevealHeightKey.self) { driver.contentHeight = $0 }
    }
}

extension View {
    func revealed(by driver: RevealDriver) -> some View { RevealContainer(driver: driver, content: self) }
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
        PopoverSizing.currentHeight = { [weak self] in self?.sizingPopover?.contentSize.height }
        PopoverSizing.setHeight = { [weak self] height in self?.drive(height: height) }
        PopoverSizing.settle = { [weak self] in self?.scheduleContentSizeUpdate() }
    }

    /// One frame of a RevealDriver: the popover's height, in device pixels,
    /// with no animation of the popover's own.
    private func drive(height: CGFloat) {
        guard let popover = sizingPopover, popover.contentViewController === self, height.isFinite, height > 0 else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = NSSize(width: popover.contentSize.width, height: (height * scale).rounded() / scale)
        guard popover.contentSize != size else { return }
        let animates = popover.animates
        popover.animates = false
        popover.contentSize = size
        popover.animates = animates
        preferredContentSize = size
    }

    private func scheduleContentSizeUpdate() {
        guard !sizeUpdatePending else { return }
        sizeUpdatePending = true
        // Coalesce SwiftUI layout changes outside the active layout pass.
        // No timer, polling, or close/reopen cycle is needed to resize.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeUpdatePending = false
            // A RevealDriver is sizing the popover this frame; it settles up when done.
            if PopoverSizing.isDriven && self.sizingPopover != nil { return }
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

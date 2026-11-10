import AppKit
import Combine
import SwiftUI

/// Feedback where the gesture happened, as one piece of glass in the matching
/// corner (or edge) of the screen, the way the Dynamic Island works: the first
/// tap of a double-tap draws a small bead out of the corner; the second
/// stretches that same bead into a pill naming the action, and its text
/// arrives once the shape settles. Leaving runs it backwards into the corner.
/// Resting a finger shows the pill without doing anything.
final class CornerBloom {
    static let shared = CornerBloom()
    /// The panel spans this much of the screen around the drop.
    static let size = NSSize(width: 460, height: 200)
    /// A first tap's drop waits about as long as a second tap may take.
    static let armedLife: TimeInterval = 0.45

    let model = BloomModel()
    private var panel: NSWindow?
    private var theme: String?
    private var leaving: DispatchWorkItem?
    private var hiding: DispatchWorkItem?
    private var bloomUntil: TimeInterval = 0
    private var firedAt: TimeInterval = -.infinity
    /// A result with no placement (a mute state, the track) still belongs to a
    /// tap that fired this recently.
    static let resultWindow: TimeInterval = 2
    /// Where the current pill is, so a message from the same tap lands in it.
    private var placement: OSDPlacement?

    private var enabled: Bool { TrackpadSettings.shared.cornerEffects }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The first tap of a double-tap: a bead that sinks back unless the second follows.
    func arm(_ region: TapRegion) {
        guard enabled, model.phase != .bloom else { return }
        present(region)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.72)) {
            model.phase = .armed
        }
        scheduleLeave(after: Self.armedLife)
    }

    /// The action fired: the bead stretches into a pill naming it. A nil title
    /// keeps it a bead for a moment (a picker opens in the middle instead).
    func fire(_ region: TapRegion, title: String?, icon: String, detail: String?) {
        guard enabled else { return }
        present(region)
        placement = TrackpadMonitor.placement(for: region)
        model.title = title
        model.icon = icon
        model.detail = detail
        // A little overshoot, like liquid finding its shape.
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.72)) {
            model.phase = title == nil ? .armed : .bloom
        }
        let hold: TimeInterval = title == nil ? 0.35 : detail == nil ? 1.5 : 2.5
        firedAt = ProcessInfo.processInfo.systemUptime
        bloomUntil = firedAt + hold
        scheduleLeave(after: hold)
    }

    /// A finger resting on the spot: show what its taps do, do nothing.
    func preview(_ region: TapRegion, title: String, icon: String, detail: String) {
        guard enabled, model.phase != .bloom else { return }
        present(region)
        model.title = title
        model.icon = icon
        model.detail = detail
        leaving?.cancel()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.8)) {
            model.phase = .preview
        }
    }

    func endPreview() {
        guard model.phase == .preview else { return }
        scheduleLeave(after: 0)
    }

    /// A pill naming a tap action is showing, so its result belongs in it.
    var isShowingTap: Bool { enabled && model.phase == .bloom && model.title != nil }

    /// The result of the action that just bloomed ("Safari muted", "Microphone
    /// muted", the track) replaces the pill's words, so a tap is answered once,
    /// where it happened, instead of in a second indicator.
    func absorb(_ text: String, icon: String, detail: String? = nil, placement: OSDPlacement?) -> Bool {
        let recent = ProcessInfo.processInfo.systemUptime - firedAt <= Self.resultWindow
        guard isShowingTap, placement.map({ $0 == self.placement }) ?? recent else { return false }
        // The pill resizes to the new words in the same motion.
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)) {
            model.title = text
            model.icon = icon
            model.detail = detail
        }
        // A second line needs the same reading time as a fresh pill with one.
        let remaining = max(detail == nil ? 1.4 : 2.5, bloomUntil - ProcessInfo.processInfo.systemUptime)
        bloomUntil = ProcessInfo.processInfo.systemUptime + remaining
        scheduleLeave(after: remaining)
        return true
    }

    // MARK: Window

    private func present(_ region: TapRegion) {
        hiding?.cancel()
        hiding = nil
        let anchor = BloomAnchor(region)
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let panel = self.panel ?? OSDWindow(contentRect: .zero, shadow: false)
        self.panel = panel
        let settings = TrackpadSettings.shared
        if theme != settings.appearanceMode || panel.contentView == nil {
            // Built once per theme; the model drives every state after that.
            theme = settings.appearanceMode
            panel.contentView = NSHostingView(rootView: BloomView(model: model).preferredColorScheme(settings.resolvedColorScheme))
        }
        panel.appearance = TrackpadSettings.shared.themeAppearance
        if model.anchor != anchor || model.phase == .hidden {
            var noAnimation = Transaction()
            noAnimation.disablesAnimations = true
            withTransaction(noAnimation) {
                model.anchor = anchor
                if model.phase != .hidden { model.phase = .hidden }
            }
        }
        panel.setFrame(anchor.frame(in: screen.visibleFrame, size: Self.size), display: false)
        panel.orderFrontRegardless()
    }

    /// Backwards out: the text goes, the pill draws back into the bead, and the
    /// bead sinks into the corner.
    private func scheduleLeave(after delay: TimeInterval) {
        leaving?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let expanded = self.model.phase == .bloom || self.model.phase == .preview
            if expanded && !self.reduceMotion {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { self.model.phase = .armed }
                let sink = DispatchWorkItem { [weak self] in self?.sink() }
                self.hiding = sink
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: sink)
            } else {
                self.sink()
            }
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sink() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeIn(duration: 0.2)) { model.phase = .leaving }
        let hide = DispatchWorkItem { [weak self] in
            guard let self, self.model.phase == .leaving else { return }
            self.model.phase = .hidden
            self.placement = nil
            self.panel?.orderOut(nil)
        }
        hiding = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: hide)
    }
}

/// Which corner or edge of the screen the drop sits in.
enum BloomAnchor: Equatable {
    case topLeft, topRight, bottomLeft, bottomRight, left, right, top, bottom

    init(_ region: TapRegion) {
        switch region {
        case .topLeftCorner: self = .topLeft
        case .topRightCorner: self = .topRight
        case .bottomLeftCorner: self = .bottomLeft
        case .bottomRightCorner: self = .bottomRight
        case .left: self = .left
        case .right: self = .right
        case .top: self = .top
        case .bottom: self = .bottom
        }
    }

    var isRight: Bool { [.topRight, .bottomRight, .right].contains(self) }
    var isLeft: Bool { [.topLeft, .bottomLeft, .left].contains(self) }
    var isTop: Bool { [.topLeft, .topRight, .top].contains(self) }
    var isBottom: Bool { [.bottomLeft, .bottomRight, .bottom].contains(self) }

    /// The panel's frame: flush with this corner or edge of the visible screen.
    func frame(in visible: NSRect, size: NSSize) -> NSRect {
        let x = isLeft ? visible.minX : isRight ? visible.maxX - size.width : visible.midX - size.width / 2
        let y = isBottom ? visible.minY : isTop ? visible.maxY - size.height : visible.midY - size.height / 2
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// Where the glass grows from.
    var unitPoint: UnitPoint {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    /// The panel content's alignment, so the glass sits in the corner itself.
    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }
}

final class BloomModel: ObservableObject {
    enum Phase { case hidden, armed, bloom, preview, leaving }
    @Published var phase: Phase = .hidden
    @Published var anchor: BloomAnchor = .topRight
    @Published var title: String?
    @Published var icon = "hand.tap"
    @Published var detail: String?
}

struct BloomView: View {
    @ObservedObject var model: BloomModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let bead: CGFloat = 20
    /// Render checks only: offscreen captures cannot see glass composited by the system.
    static var renderOpaque = false

    private var expanded: Bool { model.phase == .bloom || model.phase == .preview }
    private var present: Bool { model.phase != .hidden && model.phase != .leaving }

    var body: some View {
        island
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.anchor.alignment)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// One shape throughout: a bead when armed, a pill when expanded. Its size
    /// is layout, so the change between them animates as one continuous stretch.
    private var island: some View {
        content
            .opacity(expanded ? (model.phase == .preview ? 0.92 : 1) : 0)
            .blur(radius: expanded || reduceMotion ? 0 : 5)
            // The words arrive once the glass has nearly settled, and leave first.
            .animation(expanded ? .easeOut(duration: 0.24).delay(reduceMotion ? 0 : 0.12) : .easeIn(duration: 0.1), value: expanded)
            .frame(width: expanded ? nil : Self.bead, height: expanded ? nil : Self.bead)
            .clipShape(Capsule(style: .continuous))
            .background(BloomGlass(shape: Capsule(style: .continuous), opaque: Self.renderOpaque))
            .scaleEffect(present || reduceMotion ? 1 : 0.15, anchor: model.anchor.unitPoint)
            .opacity(present ? 1 : 0)
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: model.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let detail = model.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: model.detail == nil ? 44 : 50)
        .fixedSize()
    }
}

/// The glass every Kinara surface uses, in any shape.
struct BloomGlass<S: Shape>: View {
    let shape: S
    var opaque = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency || opaque {
            shape.fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape).shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        } else {
            shape.fill(.regularMaterial).shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

/// While an edge slide adjusts something, a soft light runs along the matching
/// screen edge at the finger's height, so you can tell which edge you're on
/// before you read any number. Core Animation only; moved, never redrawn.
final class EdgeGlow {
    static let shared = EdgeGlow()
    private static let length: CGFloat = 180
    private static let depth: CGFloat = 30
    private var panel: NSWindow?
    private var light: CALayer?
    private var edge: String?
    private var colors: [NSColor] = []
    private var drawn: [NSColor] = []
    private var shown = false

    /// `along` is the finger's 0…1 position along the edge (bottom to top, left
    /// to right); `tint` is the colour of what the slide adjusts, read once per slide.
    func update(edge: String, along: Double, tint: @autoclosure () -> NSColor? = nil) {
        let settings = TrackpadSettings.shared
        // Follow finger already puts the indicator on that edge.
        guard settings.edgeLight, settings.osdStyle != "edge", along.isFinite else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        // The colours are chosen as a slide begins and kept until it ends.
        if !shown { colors = settings.edgeLightColor.colors(tint: tint()) }
        var panel = prepared(edge: edge)
        place(panel, edge: edge, along: along, in: screen.visibleFrame)
        // Ordered in and faded in once per slide; after that, every frame only moves it.
        guard !shown else { return }
        shown = true
        if !panel.isVisible { panel.alphaValue = 0 }
        // Every slide, even mid-fade: the Space may have changed since the last one.
        panel.orderFrontRegardless()
        if !panel.isOnActiveSpace {
            // Seen over a full-screen video: ordered in and opaque, yet missing from
            // that Space. A fresh window joins it, as leaving full screen and coming
            // back did.
            KinaraLog.warning(.output, "Edge light missed the active Space; replaced its window")
            panel.orderOut(nil)
            self.panel = nil
            panel = prepared(edge: edge)
            place(panel, edge: edge, along: along, in: screen.visibleFrame)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    /// The window, its light drawn for this edge in this slide's colours.
    private func prepared(edge: String) -> NSWindow {
        let panel = self.panel ?? makePanel()
        if self.edge != edge || drawn != colors || light?.superlayer !== panel.contentView?.layer {
            layout(edge: edge, in: panel)
        }
        return panel
    }

    /// Flush with `edge` of the visible screen, centred on the finger's position along it.
    private func place(_ panel: NSWindow, edge: String, along: Double, in frame: NSRect) {
        let vertical = edge == "left" || edge == "right"
        let size = vertical ? NSSize(width: Self.depth, height: Self.length) : NSSize(width: Self.length, height: Self.depth)
        let alongY = min(max(frame.minY + CGFloat(along) * frame.height - size.height / 2, frame.minY), frame.maxY - size.height)
        let alongX = min(max(frame.minX + CGFloat(along) * frame.width - size.width / 2, frame.minX), frame.maxX - size.width)
        let origin: NSPoint
        switch edge {
        case "left": origin = NSPoint(x: frame.minX, y: alongY)
        case "right": origin = NSPoint(x: frame.maxX - size.width, y: alongY)
        case "top": origin = NSPoint(x: alongX, y: frame.maxY - size.height)
        default: origin = NSPoint(x: alongX, y: frame.minY)
        }
        if panel.frame.size != size { panel.setContentSize(size) }
        if abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 { panel.setFrameOrigin(origin) }
    }

    func end() {
        guard shown, let panel else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new slide may have started during the fade; then it stays.
            guard self?.shown == false else { return }
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSWindow {
        let panel = OSDWindow(contentRect: NSRect(x: 0, y: 0, width: Self.depth, height: Self.length), shadow: false)
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        self.panel = panel
        return panel
    }

    /// A tube of light flush with the edge, its ends fading, glowing inward.
    private func layout(edge: String, in panel: NSWindow) {
        self.edge = edge
        drawn = colors
        let light = EdgeLightStyle.layer(edge: edge, length: Self.length, depth: Self.depth, colors: colors)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.light?.removeFromSuperlayer()
        panel.contentView?.layer?.addSublayer(light)
        CATransaction.commit()
        self.light = light
    }
}

extension ZoneAction {
    /// The edge light's colour when it follows the action: blue for sound, gold
    /// for brightness, and so on. Everything else glows in the accent colour.
    var lightTint: NSColor? {
        switch self {
        case .volume, .outputMute: return .systemBlue
        case .brightness, .keyboardBrightness: return .systemYellow
        case .microphoneLevel, .microphoneMute: return .systemGreen
        case .appVolume, .muteApp, .soloApp, .audioApps: return .systemTeal
        case .nightShift: return .systemOrange
        case .extraDim: return .systemIndigo
        case .seek, .mediaTracks, .playPause, .nowPlaying: return .systemPink
        default: return nil
        }
    }
}

/// The edge light, set free: one soft light that laps the edges of the screen,
/// slowly, in the edge light's colours, until a key, a click or the same tap
/// stops it. A screensaver you can keep working beside; it changes nothing.
final class AmbientLight: ObservableObject {
    static let shared = AmbientLight()
    @Published private(set) var isRunning = false
    private var window: NSWindow?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var colorChange: AnyCancellable?

    /// Returns whether it is now running.
    @discardableResult
    func toggle() -> Bool {
        isRunning ? stop() : start()
        return isRunning
    }

    func start() {
        guard !isRunning, let screen = Self.screen() else { return }
        isRunning = true
        show(on: screen)
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping () -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }))
        }
        // Follow you to another Space, full-screen ones included; resize with the
        // screen; stop when the screen sleeps or you switch user.
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.rejoin(force: false) }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.rejoin(force: true) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.stop() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.stop() }
        // A new colour in Settings shows at once, so you can pick while it runs.
        colorChange = TrackpadSettings.shared.$edgeLightColor.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rejoin(force: true) }
        KinaraLog.info(.output, "Ambient light on")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        colorChange = nil
        KinaraLog.info(.output, "Ambient light off")
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Started again during the fade: that run has its own window.
            guard let self, !self.isRunning || self.window !== window else { return }
            window.orderOut(nil)
            if self.window === window { self.window = nil }
        })
    }

    private static func screen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
    }

    /// A fresh window over the whole screen, fading in; it never takes a click.
    private func show(on screen: NSScreen) {
        let old = window
        let window = OSDWindow(contentRect: screen.frame, shadow: false)
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.layer?.addSublayer(EdgeLightStyle.ambient(in: view.bounds, colors: TrackpadSettings.shared.edgeLightColor.colors(), still: still))
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = old == nil ? 0.6 : 0.2
            window.animator().alphaValue = 1
        }
        old?.orderOut(nil)
        self.window = window
    }

    /// Back on the Space you're looking at, at the screen's size, in the current colours.
    private func rejoin(force: Bool) {
        guard isRunning, force || window?.isOnActiveSpace != true, let screen = Self.screen() else { return }
        show(on: screen)
    }
}

/// The edge light's sibling for taps: a line of light hugging the matching
/// corner of the screen (or the middle of an edge) that runs out from the
/// spot and fades. Faint and short for the first tap of a double-tap, bright
/// when the action fires, and a steady glow while a resting finger previews it.
final class CornerLight {
    static let shared = CornerLight()
    /// How far the light runs along each edge from the corner.
    static let reach: CGFloat = 150
    let model = CornerLightModel()
    private var panel: NSWindow?
    private var work: [DispatchWorkItem] = []
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func flash(_ region: TapRegion, strength: Double, spread: Double) {
        guard TrackpadSettings.shared.edgeLight else { return }
        present(region)
        model.spread = reduceMotion ? spread : 0
        withAnimation(.easeOut(duration: 0.1)) { model.intensity = strength }
        if !reduceMotion { withAnimation(.easeOut(duration: 0.32)) { model.spread = spread } }
        schedule(after: 0.22) { [weak self] in withAnimation(.easeIn(duration: 0.55)) { self?.model.intensity = 0 } }
        schedule(after: 0.85) { [weak self] in self?.panel?.orderOut(nil) }
    }

    /// A finger resting on the spot: the light stays on, softly, until released.
    func hold(_ region: TapRegion) {
        guard TrackpadSettings.shared.edgeLight else { return }
        present(region)
        withAnimation(.easeOut(duration: 0.3)) {
            model.intensity = 0.5
            model.spread = 0.7
        }
    }

    func release() {
        guard model.intensity > 0, panel?.isVisible == true else { return }
        withAnimation(.easeIn(duration: 0.4)) { model.intensity = 0 }
        schedule(after: 0.45) { [weak self] in self?.panel?.orderOut(nil) }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        let item = DispatchWorkItem(block: action)
        work.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func present(_ region: TapRegion) {
        work.forEach { $0.cancel() }
        work.removeAll()
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        if model.region != region {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                model.region = region
                model.intensity = 0
                model.spread = 0
            }
        }
        panel.setFrame(CornerLightShape.frame(for: region, in: screen.frame, reach: Self.reach), display: false)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSWindow {
        let panel = OSDWindow(contentRect: .zero, shadow: false)
        panel.contentView = NSHostingView(rootView: CornerLightView(model: model))
        self.panel = panel
        return panel
    }
}

final class CornerLightModel: ObservableObject {
    @Published var region: TapRegion = .topRightCorner
    @Published var intensity = 0.0
    /// How far the light has run out from the spot, 0…1.
    @Published var spread = 0.0
}

/// The line the light travels: from one edge, around the screen's rounded
/// corner, to the other, with the corner exactly halfway (or along an edge,
/// centred). Trimming outward from 0.5 makes the light run out from the spot.
struct CornerLightShape: Shape {
    let region: TapRegion
    /// The tube's centre line, so the whole tube sits flush with the edge.
    static let inset: CGFloat = EdgeLightStyle.inset + EdgeLightStyle.tube / 2
    static let cornerRadius: CGFloat = 12

    /// The panel that holds the light: flush with the corner, or centred on the edge.
    static func frame(for region: TapRegion, in screen: NSRect, reach: CGFloat) -> NSRect {
        let span = reach * 2 + 16, depth: CGFloat = 26, square = reach + 12
        switch region {
        case .topLeftCorner: return NSRect(x: screen.minX, y: screen.maxY - square, width: square, height: square)
        case .topRightCorner: return NSRect(x: screen.maxX - square, y: screen.maxY - square, width: square, height: square)
        case .bottomLeftCorner: return NSRect(x: screen.minX, y: screen.minY, width: square, height: square)
        case .bottomRightCorner: return NSRect(x: screen.maxX - square, y: screen.minY, width: square, height: square)
        case .left: return NSRect(x: screen.minX, y: screen.midY - span / 2, width: depth, height: span)
        case .right: return NSRect(x: screen.maxX - depth, y: screen.midY - span / 2, width: depth, height: span)
        case .top: return NSRect(x: screen.midX - span / 2, y: screen.maxY - depth, width: span, height: depth)
        case .bottom: return NSRect(x: screen.midX - span / 2, y: screen.minY, width: span, height: depth)
        }
    }

    /// Where the light comes from, in the view's own unit space (SwiftUI: y grows downward).
    var origin: UnitPoint {
        switch region {
        case .topLeftCorner: return .topLeading
        case .topRightCorner: return .topTrailing
        case .bottomLeftCorner: return .bottomLeading
        case .bottomRightCorner: return .bottomTrailing
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    func path(in rect: CGRect) -> Path {
        let i = Self.inset, r = Self.cornerRadius
        var path = Path()
        switch region {
        case .left, .right:
            let x = region == .left ? rect.minX + i : rect.maxX - i
            path.move(to: CGPoint(x: x, y: rect.minY + 8))
            path.addLine(to: CGPoint(x: x, y: rect.maxY - 8))
        case .top, .bottom:
            let y = region == .top ? rect.minY + i : rect.maxY - i
            path.move(to: CGPoint(x: rect.minX + 8, y: y))
            path.addLine(to: CGPoint(x: rect.maxX - 8, y: y))
        default:
            // SwiftUI coordinates: the corner point, and the two far ends along its edges.
            let right = region == .topRightCorner || region == .bottomRightCorner
            let top = region == .topLeftCorner || region == .topRightCorner
            let cornerX = right ? rect.maxX - i : rect.minX + i
            let cornerY = top ? rect.minY + i : rect.maxY - i
            let farX = right ? rect.minX : rect.maxX
            let farY = top ? rect.maxY : rect.minY
            let corner = CGPoint(x: cornerX, y: cornerY)
            path.move(to: CGPoint(x: farX, y: cornerY))
            path.addArc(tangent1End: corner, tangent2End: CGPoint(x: cornerX, y: farY), radius: r)
            path.addLine(to: CGPoint(x: cornerX, y: farY))
        }
        return path
    }
}

struct CornerLightView: View {
    @ObservedObject var model: CornerLightModel
    var body: some View {
        let shape = CornerLightShape(region: model.region)
        let half = model.spread / 2
        let trimmed = shape.trim(from: 0.5 - half, to: 0.5 + half)
        let palette = TrackpadSettings.shared.edgeLightColor.colors()
        let accent = palette[palette.count / 2]
        // The edge light's tube: rim, coloured body, white-hot core, fading as it runs out.
        let fading = { (color: NSColor) in
            RadialGradient(colors: [Color(nsColor: color), Color(nsColor: color).opacity(0.75), Color(nsColor: color).opacity(0)],
                           center: shape.origin, startRadius: 0, endRadius: CornerLight.reach)
        }
        let style = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        ZStack {
            trimmed.stroke(fading(EdgeLightStyle.rim(accent)), style: style(EdgeLightStyle.tube))
                .shadow(color: Color(nsColor: accent).opacity(0.95), radius: 8)
                .shadow(color: Color(nsColor: accent).opacity(0.5), radius: 16)
            trimmed.stroke(fading(accent), style: style(EdgeLightStyle.body))
            trimmed.stroke(fading(.white), style: style(EdgeLightStyle.core))
        }
        .opacity(model.intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

import AppKit
import SwiftUI

extension Notification.Name {
    /// A slide was accepted, or a tap fired, for real. The object is the edge
    /// ("right") or the tap slot ("bottomRightCorner.doubleTap").
    static let kinaraGestureUsed = Notification.Name("kinaraGestureUsed")
}

/// The first-run tour's guide, drawn on the screen itself: the screen stands
/// in for the trackpad, so the spot to touch shows where it maps. A slide gets
/// a glass rail on the matching screen edge with a bead travelling along it;
/// a corner double-tap gets a bead in the matching corner that presses twice.
/// Doing it for real turns the pill into "Nice".
final class TourGuide {
    static let shared = TourGuide()
    let model = TourGuideModel()
    private var panel: NSPanel?
    private var hiding: DispatchWorkItem?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(_ step: TourStep, on screen: NSScreen?) {
        hiding?.cancel()
        hiding = nil
        guard let screen = screen ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        panel.appearance = TrackpadSettings.shared.themeAppearance
        panel.setFrame(screen.visibleFrame, display: false)
        panel.orderFrontRegardless()
        // A new stop arrives fresh: the old one leaves first, then this one settles in.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            model.visible = false
            model.succeeded = false
            model.step = step
        }
        DispatchQueue.main.async { [self] in
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.8)) { model.visible = true }
        }
    }

    func succeed() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.72)) { model.succeeded = true }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        withAnimation(.easeIn(duration: 0.22)) { model.visible = false }
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: TourGuideView(model: model)
            .preferredColorScheme(TrackpadSettings.shared.resolvedColorScheme))
        self.panel = panel
        return panel
    }
}

final class TourGuideModel: ObservableObject {
    @Published var step: TourStep?
    @Published var visible = false
    @Published var succeeded = false
}

/// The tour's one motion vocabulary, shared by the screen guide and the
/// trackpad picture in the window, so both always move together.
enum TourMotion {
    /// A finger sliding up the edge: 0 (bottom) to 1 (top), fading in and out.
    static func slide(at date: Date) -> (progress: Double, opacity: Double) {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.0)
        let p = min(1, t / 1.35)
        let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        let opacity = min(min(1, t / 0.18), max(0, 1 - (t - 1.25) / 0.35))
        return (eased, opacity)
    }

    /// A double-tap: 1 at rest, pressing in twice in quick succession.
    static func press(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8)
        func dip(_ start: Double) -> Double {
            let x = (t - start) / 0.16
            return x > 0 && x < 1 ? sin(x * .pi) : 0
        }
        return 1 - 0.2 * max(dip(0.1), dip(0.36))
    }

    /// Tap and hold: one quick tap, then a press that stays down a moment.
    static func hold(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.3)
        if t > 0.1 && t < 0.26 { return 1 - 0.2 * sin((t - 0.1) / 0.16 * .pi) }
        let down = min(1, max(0, (t - 0.5) / 0.1)), up = min(1, max(0, (t - 1.5) / 0.12))
        return 1 - 0.2 * (down - up)
    }

    /// Where a tap region sits, on the screen or on the trackpad picture.
    static func alignment(_ region: String) -> Alignment {
        switch region {
        case "topLeftCorner": return .topLeading
        case "topRightCorner": return .topTrailing
        case "bottomLeftCorner": return .bottomLeading
        case "bottomRightCorner": return .bottomTrailing
        case "left": return .leading
        case "right": return .trailing
        case "top": return .top
        default: return .bottom
        }
    }

    static func unitPoint(_ region: String) -> UnitPoint {
        switch region {
        case "topLeftCorner": return .topLeading
        case "topRightCorner": return .topTrailing
        case "bottomLeftCorner": return .bottomLeading
        case "bottomRightCorner": return .bottomTrailing
        case "left": return .leading
        case "right": return .trailing
        case "top": return .top
        default: return .bottom
        }
    }
}

struct TourGuideView: View {
    @ObservedObject var model: TourGuideModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Render checks only: offscreen captures cannot see glass composited by the system.
    static var renderOpaque = false

    var body: some View {
        ZStack {
            if let step = model.step, model.visible {
                guide(step)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: TourMotion.unitPoint(step.region))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func guide(_ step: TourStep) -> some View {
        switch step.kind {
        case let .slide(side):
            GeometryReader { geometry in
                let height = geometry.size.height * 0.42
                HStack(spacing: 16) {
                    if side == "right" { pill(step, title: "Slide here") }
                    rail(height: height)
                    if side == "left" { pill(step, title: "Slide here") }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == "left" ? .leading : .trailing)
            }
        case .doubleTap, .tapHold:
            let region = step.region
            let hold: Bool = { if case .tapHold = step.kind { return true }; return false }()
            let title = hold ? "Tap, then hold here" : "Double-tap here"
            let right = region.contains("Right") || region == "right"
            Group {
                if region == "top" || region == "bottom" {
                    VStack(spacing: 12) {
                        if region == "bottom" { pill(step, title: title) }
                        bead(hold: hold)
                        if region == "top" { pill(step, title: title) }
                    }
                } else {
                    HStack(spacing: 14) {
                        if right { pill(step, title: title) }
                        bead(hold: hold)
                        if !right { pill(step, title: title) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: TourMotion.alignment(region))
        }
    }

    /// A glass rail with a bead travelling up it, the way a finger slides.
    private func rail(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            BloomGlass(shape: Capsule(style: .continuous), opaque: Self.renderOpaque).frame(width: 10, height: height)
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(model.succeeded ? 0.9 : 0.28))
                .frame(width: 3, height: height - 10)
                .padding(.bottom, 5)
            if !model.succeeded {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
                    let motion = reduceMotion ? (progress: 0.5, opacity: 1.0) : TourMotion.slide(at: context.date)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: Color.accentColor.opacity(0.9), radius: 8)
                        .offset(y: -CGFloat(motion.progress) * (height - 24) - 5)
                        .opacity(motion.opacity)
                }
                .frame(width: 14, height: height, alignment: .bottom)
            }
        }
        .frame(width: 16, height: height)
    }

    /// A glass bead that presses in twice like a double-tap, or taps then holds.
    private func bead(hold: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || model.succeeded)) { context in
            let scale = reduceMotion || model.succeeded ? 1 : hold ? TourMotion.hold(at: context.date) : TourMotion.press(at: context.date)
            ZStack {
                Circle().fill(Color.accentColor).blur(radius: 10)
                    .opacity(model.succeeded ? 0.55 : 0.18 + (1 - scale) * 2)
                BloomGlass(shape: Circle(), opaque: Self.renderOpaque)
                Circle().fill(Color.accentColor.opacity(model.succeeded ? 1 : 0.85)).frame(width: 9, height: 9)
            }
            .frame(width: 30, height: 30)
            .scaleEffect(scale)
        }
    }

    private func pill(_ step: TourStep, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.succeeded ? "checkmark" : step.action.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(model.succeeded ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.08)))
                .contentTransition(.interpolate)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.succeeded ? "Nice" : title).font(.system(size: 13, weight: .semibold))
                Text(model.succeeded ? step.action.label : "\(step.place.prefix(1).uppercased())\(step.place.dropFirst()) of your trackpad · \(step.action.label)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 50)
        .background(BloomGlass(shape: Capsule(style: .continuous), opaque: Self.renderOpaque))
        .fixedSize()
    }
}

/// The trackpad in the tour window: the zone to use, lit, with the same
/// motion as the guide on the screen.
struct TourTrackpad: View {
    let step: TourStep?
    let succeeded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let size = CGSize(width: 300, height: 188)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.05))
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            if let step { zone(step) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityElement()
        .accessibilityLabel(step.map { "Use \($0.place) of your trackpad" } ?? "Trackpad")
    }

    @ViewBuilder private func zone(_ step: TourStep) -> some View {
        let width = Self.size.width, height = Self.size.height
        switch step.kind {
        case let .slide(side):
            let strip = width * 0.2
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(succeeded ? 0.28 : 0.12))
                if !succeeded {
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
                        let motion = reduceMotion ? (progress: 0.5, opacity: 1.0) : TourMotion.slide(at: context.date)
                        Circle().fill(Color.accentColor).frame(width: 18, height: 18)
                            .offset(y: -CGFloat(motion.progress) * (height - 60) - 18)
                            .opacity(motion.opacity)
                    }
                } else {
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.accentColor)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: strip - 12, height: height - 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == "left" ? .leading : .trailing)
            .padding(6)
        case .doubleTap, .tapHold:
            let region = step.region
            let hold: Bool = { if case .tapHold = step.kind { return true }; return false }()
            let corner = region.hasSuffix("Corner")
            let vertical = region == "left" || region == "right"
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(succeeded ? 0.28 : 0.12))
                if succeeded {
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.accentColor)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
                        Circle().fill(Color.accentColor).frame(width: 18, height: 18)
                            .scaleEffect(reduceMotion ? 1 : hold ? TourMotion.hold(at: context.date) : TourMotion.press(at: context.date))
                    }
                }
            }
            .frame(width: corner ? width * 0.2 : vertical ? width * 0.2 - 12 : width * 0.5,
                   height: corner ? width * 0.2 : vertical ? height * 0.4 : height * 0.2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: TourMotion.alignment(region))
            .padding(6)
        }
    }
}

import AppKit
import SwiftUI

/// What every edge does right now, resolved exactly as a gesture would be:
/// the frontmost app's profile, then the docked profile, then everyday.
struct EdgeMapEntry: Identifiable, Equatable {
    let slot: String
    let title: String
    let action: ZoneAction
    let source: BindingSource
    var id: String { slot }

    static func resolve(settings: TrackpadSettings, appBundleID: String?, docked: Bool) -> [EdgeMapEntry] {
        var slots = ["left", "right"]
        if settings.topEdgeEnabled { slots += settings.topEdgeSwipeDirection == "horizontal" ? ["topLeft", "topRight"] : ["top"] }
        if settings.bottomEdgeEnabled { slots.append("bottom") }
        slots += EdgeSlot.sides.map(EdgeSlot.option) + EdgeSlot.sides.map(EdgeSlot.alternate) + EdgeSlot.allTaps
        return slots.compactMap { slot in
            let resolved = settings.resolvedBinding(slot, appBundleID: appBundleID, docked: docked)
            // Swipe edges are always listed; optional layers and taps only when set.
            guard resolved.binding.action != .disabled || EdgeSlot.swipe.contains(slot) else { return nil }
            return EdgeMapEntry(slot: slot, title: EdgeSlot.title(slot), action: resolved.binding.action, source: resolved.source)
        }
    }
}

final class EdgeMapHUD {
    static let shared = EdgeMapHUD()
    private var panel: NSPanel?
    private var observer: NSObjectProtocol?
    private var hideTimer: Timer?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .swayCheatSheetHotkey, object: nil, queue: .main) { [weak self] note in
            (note.object as? Bool) == true ? self?.show(autoHide: false) : self?.hide()
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show(autoHide: true) }

    /// From the hotkey it stays while held; from a gesture or menu it hides
    /// itself after a few seconds, with one timer that exists only while shown.
    func show(autoHide: Bool) {
        let settings = TrackpadSettings.shared
        let apps = ExcludedAppsManager.shared
        let entries = EdgeMapEntry.resolve(settings: settings, appBundleID: apps.currentAppBundleID,
                                           docked: BrightnessController.shared.hasExternalDisplayConnected)
        let view = EdgeMapView(appName: apps.currentAppName, entries: entries, settings: settings)
            .preferredColorScheme(settings.resolvedColorScheme)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        panel.setContentSize(size)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        hideTimer?.invalidate()
        hideTimer = nil
        if autoHide {
            let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in self?.hide() }
            RunLoop.main.add(timer, forMode: .common)
            hideTimer = timer
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        // Release the view tree; the next show builds a fresh, current one.
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct EdgeMapView: View {
    let appName: String
    let entries: [EdgeMapEntry]
    @ObservedObject var settings: TrackpadSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private func entry(_ slot: String) -> EdgeMapEntry? { entries.first { $0.slot == slot } }
    private var extras: [EdgeMapEntry] { entries.filter { !EdgeSlot.swipe.contains($0.slot) } }
    private var usesProfile: Bool { entries.contains { $0.source != .everyday } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Edges in \(appName)").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 16)
                if usesProfile { Text("Profile active").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            }
            trackpad.frame(width: 360, height: 200)
            if !extras.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(extras) { item in
                        HStack(spacing: 9) {
                            Image(systemName: item.action.icon).frame(width: 18)
                            Text(item.title).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(item.action.label).fontWeight(.medium)
                            sourceMark(item.source)
                        }.font(.system(size: 12))
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .modifier(EdgeMapSurface(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sway edge map")
    }

    private var trackpad: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            let top = settings.topEdgeEnabled ? height * settings.topEdgeHeight : 0
            let bottom = settings.bottomEdgeEnabled ? height * settings.bottomEdgeHeight : 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.15))
                zone(entry("left"), width: width * settings.leftZoneWidth, height: height - top - bottom).offset(y: top)
                zone(entry("right"), width: width * settings.rightZoneWidth, height: height - top - bottom)
                    .offset(x: width * (1 - settings.rightZoneWidth), y: top)
                if settings.topEdgeEnabled {
                    if settings.topEdgeSwipeDirection == "horizontal" {
                        zone(entry("topLeft"), width: width / 2, height: top)
                        zone(entry("topRight"), width: width / 2, height: top).offset(x: width / 2)
                    } else { zone(entry("top"), width: width, height: top) }
                }
                if settings.bottomEdgeEnabled { zone(entry("bottom"), width: width, height: bottom).offset(y: height - bottom) }
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func zone(_ item: EdgeMapEntry?, width: CGFloat, height: CGFloat) -> some View {
        let action = item?.action ?? .disabled
        return VStack(spacing: 5) {
            Image(systemName: action.icon).font(.system(size: 15))
            if width > 54 && height > 46 {
                Text(action.label).font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
            }
            if let item, item.source != .everyday { sourceMark(item.source) }
        }
        .foregroundStyle(Color.primary.opacity(action == .disabled ? 0.35 : 0.9))
        .padding(4)
        .frame(width: max(0, width), height: max(0, height))
        .background(Color.primary.opacity(action == .disabled ? 0.02 : 0.09))
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
    }

    @ViewBuilder private func sourceMark(_ source: BindingSource) -> some View {
        switch source {
        case .app: Image(systemName: "app.badge").font(.system(size: 9)).help("From this app's profile")
        case .docked: Image(systemName: "display").font(.system(size: 9)).help("From the docked profile")
        case .everyday: EmptyView()
        }
    }
}

private struct EdgeMapSurface: ViewModifier {
    let reduceTransparency: Bool
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 24))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

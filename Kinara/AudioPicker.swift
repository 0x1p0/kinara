import AppKit
import Combine
import SwiftUI

/// A picker the trackpad drives while it's up: the clipboard and the audio
/// picker. The monitor routes touches, keys and clicks to whichever is open.
protocol TrackpadPicker: AnyObject {
    var isOpen: Bool { get }
    /// Opened by a tap: the next slide chooses and its lift applies.
    var isTouchMode: Bool { get }
    /// Tap-to-click that follows a choosing lift belongs to the picker.
    var claimsClicksUntil: Double { get }
    func handle(contacts: [GestureContact], at timestamp: Double)
    func handleKey(code: Int64, characters: String?, flags: CGEventFlags) -> Bool
    func commit()
    func cancel()
}

enum TrackpadPickers {
    static var all: [TrackpadPicker] { [ClipboardPicker.shared, AudioAppPicker.shared] }
    static var open: TrackpadPicker? { all.first { $0.isOpen } }
    static func claimsClick(at time: Double) -> Bool { all.contains { $0.isOpen || time <= $0.claimsClicksUntil } }
}

extension ClipboardPicker: TrackpadPicker {
    var isTouchMode: Bool { mode == .touch }
}

/// The audio picker: every app making sound, one finger away. It opens like
/// the clipboard picker (a swipe that keeps choosing, or a tap and then a
/// slide). Slide to choose an app and lift to mute or unmute it; slide right
/// first to play only that app; slide up past the first app to cancel.
final class AudioAppPicker: TrackpadPicker {
    static let shared = AudioAppPicker()
    enum Mode { case swipe, touch }
    /// Sideways travel that arms "Only this", about a centimetre; half of it disarms.
    static let soloTravel = 0.09

    let model = AudioPickerModel()
    private(set) var isOpen = false
    private(set) var mode: Mode = .touch
    private(set) var claimsClicksUntil = -Double.infinity
    var isTouchMode: Bool { mode == .touch }
    private var panel: PickerPanel?
    private var position = 0.0
    private var idleTimer: Timer?
    private var touchY: Double?
    private var anchorX: Double?
    private var touched = false
    private var closing: DispatchWorkItem?
    private var updates: AnyCancellable?

    var selectedApp: AudioPickerApp? {
        model.apps.indices.contains(model.selection) ? model.apps[model.selection] : nil
    }

    /// Render checks only, as for the clipboard picker.
    static var renderOrigin: NSPoint?
    static var renderOpaque = false

    // MARK: Lifecycle

    func open(mode: Mode, application: pid_t, apps sample: [AudioPickerApp]? = nil) {
        ClipboardPicker.shared.cancel()
        closing?.cancel()
        closing = nil
        self.mode = mode
        model.mode = mode
        model.soloArmed = false
        model.applied = false
        let mixer = MixerModel.shared
        if let sample {
            model.authorized = true
            model.apps = AudioPickerRules.ordered(sample)
        } else {
            mixer.setPickerVisible(true)
            model.authorized = mixer.permission == .authorized
            model.apps = AudioPickerRules.ordered(Self.snapshot(mixer))
            // Channels come and go, and each one's state changes on its own.
            updates = mixer.$channels
                .map { channels in Publishers.MergeMany(channels.map { $0.objectWillChange.map { _ in () } }).prepend(()) }
                .switchToLatest()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refresh() }
        }
        model.selection = model.apps.isEmpty ? -1 : 0
        position = Double(model.selection)
        touchY = nil
        anchorX = nil
        touched = false
        if !isOpen { present() }
        isOpen = true
        if mode == .touch {
            TrackpadMonitor.shared.holdPointer(true)
            resetIdleTimer()
        }
    }

    private static func snapshot(_ mixer: MixerModel) -> [AudioPickerApp] {
        mixer.channels.map {
            AudioPickerApp(id: $0.id, name: $0.name, icon: $0.icon, isPlaying: $0.isPlaying, isMuted: $0.isMuted,
                           isSoloed: $0.isSoloed, isSilencedBySolo: $0.isSilencedBySolo, hasPlayed: $0.hasPlayed, volume: $0.volume)
        }
    }

    private func refresh() {
        guard isOpen, !model.applied else { return }
        let mixer = MixerModel.shared
        let apps = AudioPickerRules.ordered(Self.snapshot(mixer))
        let authorized = mixer.permission == .authorized
        if authorized != model.authorized { model.authorized = authorized }
        guard apps != model.apps else { return }
        let selection = AudioPickerRules.selection(keeping: selectedApp?.id, previous: model.selection, in: apps)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            model.apps = apps
            model.selection = selection
        }
        if ClipboardPicker.selection(at: position) != selection { position = Double(selection) }
    }

    /// Down travel chooses later apps, up earlier ones and then Cancel.
    func scroll(by delta: Double) {
        guard isOpen, delta.isFinite, !model.apps.isEmpty else { return }
        position = ClipboardPicker.advance(position, by: delta, count: model.apps.count)
        let selection = ClipboardPicker.selection(at: position)
        guard selection != model.selection else { return }
        model.selection = selection
        anchorX = nil
        if model.soloArmed { withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { model.soloArmed = false } }
        if TrackpadSettings.shared.hapticFeedback { HapticOutput.shared.play(.soft) }
    }

    private func armSolo(_ armed: Bool) {
        guard armed != model.soloArmed, !armed || selectedApp != nil else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { model.soloArmed = armed }
        if TrackpadSettings.shared.hapticFeedback { HapticOutput.shared.play(.crisp) }
    }

    func handle(contacts: [GestureContact], at timestamp: Double) {
        guard isOpen, mode == .touch else { return }
        guard !contacts.isEmpty else {
            guard touched else { return }
            claimsClicksUntil = timestamp + 0.45
            commit()
            return
        }
        let y = contacts.reduce(0) { $0 + $1.y } / Double(contacts.count)
        let x = contacts.reduce(0) { $0 + $1.x } / Double(contacts.count)
        guard y.isFinite, x.isFinite else { return }
        if let previous = touchY { scroll(by: y - previous) }
        touchY = y
        // Sideways from where this app was chosen: right arms solo, back disarms.
        if let anchor = anchorX {
            let travel = x - anchor
            armSolo(model.soloArmed ? travel > Self.soloTravel / 2 : travel > Self.soloTravel)
        } else {
            anchorX = x
        }
        touched = true
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func commit() {
        guard isOpen else { return }
        guard model.authorized else {
            // Lifting on the permission card asks macOS, once.
            close(applied: false)
            DispatchQueue.main.async { MixerModel.shared.requestPermission() }
            return
        }
        let app = model.selection >= 0 ? selectedApp : nil
        let solo = model.soloArmed
        close(applied: app != nil)
        guard let app else { return }
        DispatchQueue.main.async {
            let mixer = MixerModel.shared
            let message: (String, String)
            if solo {
                let soloed = mixer.setSoloed(nil, forApp: app.id)
                message = soloed ? ("Only \(app.name) is playing", "headphones") : ("Solo off", "headphones")
            } else {
                let muted = mixer.setMuted(nil, forApp: app.id)
                message = muted ? ("\(app.name) muted", "speaker.slash.fill") : ("\(app.name) unmuted", "speaker.wave.2.fill")
            }
            OSDOverlay.shared.show(type: .message(message.0, icon: message.1), value: 1)
        }
    }

    func cancel() { if isOpen { close(applied: false) } }

    private func close(applied: Bool) {
        isOpen = false
        updates = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if mode == .touch { TrackpadMonitor.shared.holdPointer(false) }
        MixerModel.shared.setPickerVisible(false)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeIn(duration: 0.16)) {
            model.visible = false
            model.applied = applied
        }
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.contentView = nil
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in self?.cancel() }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// Keys arrive through Kinara's input tap; the app in front keeps focus.
    func handleKey(code: Int64, characters: String?, flags: CGEventFlags) -> Bool {
        guard isOpen else { return false }
        switch code {
        case 53: cancel()                                          // Escape
        case 36, 76: commit()                                      // Return, Enter
        case 125: scroll(by: -ClipboardPicker.travelPerItem)       // Down arrow
        case 126: scroll(by: ClipboardPicker.travelPerItem)        // Up arrow
        case 124: armSolo(true)                                    // Right arrow
        case 123: armSolo(false)                                   // Left arrow
        default:
            guard let digit = Int(characters ?? ""), (1...9).contains(digit), digit <= model.apps.count else { return false }
            model.selection = digit - 1
            commit()
        }
        return true
    }

    private func present() {
        let host = NSHostingView(rootView: AudioPickerView(model: model)
            .preferredColorScheme(TrackpadSettings.shared.resolvedColorScheme))
        let panel = self.panel ?? PickerPanel()
        panel.appearance = TrackpadSettings.shared.themeAppearance
        panel.contentView = host
        let size = NSSize(width: 460, height: host.fittingSize.height)
        panel.setContentSize(size)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let origin = Self.renderOrigin {
            panel.setFrameOrigin(origin)
        } else if let frame = screen?.visibleFrame {
            // Where the clipboard picker opens: one place for every picker.
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.08))
        }
        model.visible = false
        model.applied = false
        panel.orderFrontRegardless()
        self.panel = panel
        DispatchQueue.main.async { [model] in
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.8)) { model.visible = true }
        }
    }
}

final class AudioPickerModel: ObservableObject {
    @Published var apps: [AudioPickerApp] = []
    /// -1 is Cancel; 0 is the first app.
    @Published var selection = 0
    @Published var soloArmed = false
    @Published var authorized = true
    @Published var visible = false
    @Published var applied = false
    @Published var mode: AudioAppPicker.Mode = .touch
}

struct AudioPickerView: View {
    @ObservedObject var model: AudioPickerModel
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let rowHeight: CGFloat = 54
    private static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 13, weight: .semibold))
                Text("Audio").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.authorized && !model.apps.isEmpty {
                    Text(counter).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            if !model.authorized {
                message("Let Kinara control app audio",
                        detail: "macOS asks once for System Audio Recording. Kinara never records or saves audio. Lift to ask now.")
            } else if model.apps.isEmpty {
                message("Nothing is playing", detail: "Apps appear here while they make sound, so you can mute one without finding it.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            row(index: -1) { cancelRow }
                            ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                                row(index: index) { appRow(app, index: index) }
                            }
                        }
                    }
                    .frame(height: Self.rowHeight * CGFloat(min(Self.visibleRows, model.apps.count + 1)))
                    .onChange(of: model.selection) { selection in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                            proxy.scrollTo(selection, anchor: .center)
                        }
                    }
                    .onAppear { proxy.scrollTo(model.selection, anchor: .center) }
                }
            }
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 460)
        .background(PickerSurface(opaque: AudioAppPicker.renderOpaque))
        .padding(24)
        .scaleEffect(model.visible || reduceMotion ? 1 : (model.applied ? 1.03 : 0.92))
        .opacity(model.visible ? 1 : 0)
        .blur(radius: model.visible || reduceMotion ? 0 : 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apps playing audio")
    }

    private var counter: String {
        guard model.selection >= 0 else { return "Cancel" }
        let playing = model.apps.filter { $0.isPlaying && !$0.isMuted }.count
        return playing == 1 ? "1 playing" : "\(playing) playing"
    }

    private var hint: String {
        if !model.authorized { return "Lift to allow · esc to cancel" }
        if model.apps.isEmpty { return "Lift or press esc to close" }
        return model.mode == .touch ? "Slide to choose · slide right for only this app · lift to apply"
                                    : "Keep sliding to choose · lift to apply · slide up to cancel"
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 6)
    }

    private func row<Content: View>(index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .frame(height: Self.rowHeight - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if model.selection == index {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.11))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                }
            }
            .id(index)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selection = index
                index >= 0 ? AudioAppPicker.shared.commit() : AudioAppPicker.shared.cancel()
            }
    }

    private var cancelRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle").font(.system(size: 15)).frame(width: 26)
            Text("Cancel").font(.system(size: 13, weight: .medium))
            Spacer()
            Text("Change nothing").font(.system(size: 11)).foregroundStyle(.secondary)
        }.foregroundStyle(model.selection == -1 ? .primary : .secondary)
    }

    private func appRow(_ app: AudioPickerApp, index: Int) -> some View {
        let selected = index == model.selection
        return HStack(spacing: 10) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "app").font(.system(size: 15)).foregroundStyle(.secondary) }
            }
            .frame(width: 26, height: 26)
            .opacity(app.isMuted || app.isSilencedBySolo ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                    .foregroundStyle(app.isMuted ? .secondary : .primary)
                Text(app.status).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if app.isMuted {
                Image(systemName: "speaker.slash.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if app.isPlaying && !app.isSilencedBySolo {
                LevelBars(animating: !reduceMotion).frame(width: 14, height: 12)
            }
            if selected {
                actionChip(app.action(solo: model.soloArmed), solo: model.soloArmed)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
    }

    private func actionChip(_ title: String, solo: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(solo ? Color.white : Color.primary)
            .padding(.horizontal, 10).frame(height: 22)
            .background(Capsule().fill(solo ? Color.accentColor : Color.primary.opacity(0.1)))
            .contentTransition(.interpolate)
            .accessibilityLabel("Lift to \(title.lowercased())")
    }
}

/// Three soft bars that move while an app is sounding, like a level meter at rest.
private struct LevelBars: View {
    let animating: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { bar in
                    let phase = t * (3.1 + Double(bar) * 1.3) + Double(bar) * 1.7
                    let level = animating ? 0.35 + 0.65 * abs(sin(phase)) : [0.6, 1, 0.45][bar]
                    Capsule().fill(Color.secondary).frame(width: 3, height: max(3, 12 * level))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

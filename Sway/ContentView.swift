import SwiftUI
import AppKit
import Carbon
import Combine
import UniformTypeIdentifiers

// Semantic monochrome colors follow macOS appearance and accessibility settings.
enum SwayTheme {
    static let brand = Color.primary
    static let accent = Color.primary
    static let brightness = Color.primary
    static let volume = Color.primary
    static let canvas = Color(nsColor: .controlBackgroundColor)
}

extension ZoneAction {
    var tint: Color {
        switch self {
        case .brightness: return SwayTheme.brightness
        case .volume: return SwayTheme.volume
        case .disabled: return .secondary
        default: return .primary
        }
    }
}

// One lightweight model survives panel closures; view trees do not. Hardware
// listeners update cached values, with a visible-only display/permission refresh.
final class ControlCenterModel: ObservableObject {
    static let shared = ControlCenterModel(settings: .shared, preview: false)

    struct UndoChange {
        let action: ZoneAction
        let value: Double
        let device: String
        let muted: Bool
    }
    @Published var volume: Double = 0
    @Published var brightness: Double = 0
    @Published var volumeAvailable = false
    @Published var brightnessAvailable = false
    @Published var volumeDevice = "Audio output"
    @Published var brightnessDevice = "Built-in display"
    @Published var hasAccess = false
    @Published var isMuted = false
    @Published var message: String?
    @Published var undoValues: UndoChange?
    private var lastAudibleVolume: Double = 0.35
    private var cancellables = Set<AnyCancellable>()
    private var visibleSurfaces = Set<String>()
    private var visibleTimer: Timer?
    private var interactionEpoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var pendingAudio: (revision: UInt64, target: String)?
    private var pendingDisplay: (revision: UInt64, target: String)?
    let preview: Bool
    private let settings: TrackpadSettings
    private let injectedAudio: VolumeController?
    private let injectedDisplay: BrightnessController?
    private var audioController: VolumeController { injectedAudio ?? .shared }
    private var displayController: BrightnessController { injectedDisplay ?? .shared }

    init(settings: TrackpadSettings, preview: Bool,
         audio: VolumeController? = nil, display: BrightnessController? = nil) {
        self.settings = settings
        self.preview = preview
        injectedAudio = audio
        injectedDisplay = display
        if preview {
            volume = 0.28; brightness = 0.72
            volumeAvailable = true; brightnessAvailable = true
            volumeDevice = "MacBook speakers"; brightnessDevice = "Built-in display"
            hasAccess = true
        } else {
            NotificationCenter.default.publisher(for: .swayGestureBegan)
                .sink { [weak self] note in
                    guard let raw = note.userInfo?["action"] as? String, let action = ZoneAction(rawValue: raw) else { return }
                    self?.captureUndo(action)
                }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: .swayAudioStateChanged)
                .sink { [weak self] _ in self?.refreshAudio() }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: .swayDisplayStateChanged)
                .sink { [weak self] _ in self?.refreshDisplay() }.store(in: &cancellables)
        }
    }

    deinit { visibleTimer?.invalidate() }

    private func assign<Value: Equatable>(_ key: ReferenceWritableKeyPath<ControlCenterModel, Value>, _ value: Value) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    func refreshAccess() {
        guard !preview else { return }
        // Asked fresh: AXIsProcessTrusted() alone can stay yes after access is taken away.
        assign(\.hasAccess, TrackpadMonitor.accessIsLive())
    }

    func refresh() {
        guard !preview else { return }
        refreshAccess()
        refreshAudio()
        refreshDisplay()
        audioController.refresh()
        displayController.refresh()
    }

    func setVisible(_ surface: String, _ visible: Bool) {
        guard !preview else { return }
        if visible { visibleSurfaces.insert(surface) } else { visibleSurfaces.remove(surface) }
        if visibleSurfaces.isEmpty {
            visibleTimer?.invalidate()
            visibleTimer = nil
        } else if visibleTimer == nil {
            // DisplayServices has no public scalar-change listener. Poll only
            // while a user is looking at the controls, never for hidden panels.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.refreshAccess()
                self?.displayController.refresh()
            }
            timer.tolerance = 0.15
            RunLoop.main.add(timer, forMode: .common)
            visibleTimer = timer
        }
    }

    private func refreshAudio() {
        let audio = audioController
        assign(\.volumeAvailable, audio.isAvailable)
        assign(\.volumeDevice, audio.deviceName)
        if let pending = pendingAudio, pending.target != audio.targetIdentifier {
            pendingAudio = nil
        }
        if pendingAudio == nil {
            assign(\.volume, Double(audio.getVolume()))
            assign(\.isMuted, audio.isMuted)
        }
        if audio.getVolume() > 0.01 { lastAudibleVolume = Double(audio.getVolume()) }
    }

    private func refreshDisplay() {
        let display = displayController
        assign(\.brightnessAvailable, display.isAvailable)
        assign(\.brightnessDevice, display.deviceName)
        if let pending = pendingDisplay, pending.target != display.targetIdentifier {
            pendingDisplay = nil
        }
        if pendingDisplay == nil { assign(\.brightness, Double(display.getBrightness())) }
    }

    func captureUndo(_ action: ZoneAction) {
        guard !preview, action == .volume || action == .brightness else { return }
        interactionEpoch &+= 1
        pendingAudio = nil
        pendingDisplay = nil
        guard action == .volume ? audioController.isAvailable : displayController.isAvailable,
              let identifier = action == .volume ? audioController.targetIdentifier : displayController.targetIdentifier else { return }
        undoValues = UndoChange(action: action,
            value: action == .volume ? Double(audioController.getVolume()) : Double(displayController.getBrightness()),
            device: identifier,
            muted: action == .volume && audioController.isMuted)
    }

    /// The slider responds immediately; only measured driver success emits OSD
    /// feedback. Slow output devices cannot stall the main thread or build a
    /// backlog of obsolete values.
    @discardableResult
    func adjust(_ action: ZoneAction, to value: Double, restoringMute: Bool? = nil, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard !preview, value.isFinite else { return false }
        revision &+= 1
        let request = revision
        let epoch = interactionEpoch
        switch action {
        case .volume:
            let audio = audioController
            guard audio.isAvailable, let target = audio.targetIdentifier else { return false }
            let limits = settings.volumeLimits(forDevice: audio.deviceUID)
            let bounded = min(limits.upperBound, max(limits.lowerBound, value))
            pendingAudio = (request, target)
            assign(\.volume, bounded)
            if let restoringMute { assign(\.isMuted, restoringMute) }
            else if bounded > 0 { assign(\.isMuted, false) }
            audio.requestVolume(Float(bounded), muteAtZero: settings.muteAtZero, restoringMute: restoringMute, expectedTargetIdentifier: target) { [weak self] result in
                guard let self else { return }
                let latest = self.pendingAudio?.revision == request
                if latest { self.pendingAudio = nil; self.refreshAudio() }
                guard self.interactionEpoch == epoch else { completion?(false); return }
                switch result {
                case let .applied(actual, muted, identifier):
                    guard identifier == audio.targetIdentifier else { completion?(false); return }
                    if latest { self.assign(\.message, nil) }
                    NotificationCenter.default.post(name: .volumeChanged, object: muted ? Float(0) : actual, userInfo: ["source": "control"])
                    completion?(true)
                case .failed:
                    if latest { self.assign(\.message, "This audio output did not accept the change. Check its controls or connection.") }
                    completion?(false)
                case .cancelled: completion?(false)
                }
            }
        case .brightness:
            let display = displayController
            guard display.isAvailable, let target = display.targetIdentifier else { return false }
            let bounded = min(settings.brightnessMax, max(settings.brightnessMin, value))
            pendingDisplay = (request, target)
            assign(\.brightness, bounded)
            display.requestBrightness(Float(bounded), expectedTargetIdentifier: target) { [weak self] result in
                guard let self else { return }
                let latest = self.pendingDisplay?.revision == request
                if latest { self.pendingDisplay = nil; self.refreshDisplay() }
                guard self.interactionEpoch == epoch else { completion?(false); return }
                switch result {
                case let .applied(actual, identifier):
                    guard identifier == display.targetIdentifier else { completion?(false); return }
                    if latest { self.assign(\.message, nil) }
                    NotificationCenter.default.post(name: .brightnessChanged, object: actual, userInfo: ["source": "control"])
                    completion?(true)
                case .failed:
                    if latest { self.assign(\.message, "This display did not accept the change. Check its controls or connection.") }
                    completion?(false)
                case .cancelled: completion?(false)
                }
            }
        default: return false
        }
        return true
    }

    private func changeMute(_ muted: Bool, target: String, completion: ((Bool) -> Void)? = nil) {
        revision &+= 1
        let request = revision
        let epoch = interactionEpoch
        pendingAudio = (request, target)
        assign(\.isMuted, muted)
        let audio = audioController
        audio.requestMuted(muted, expectedTargetIdentifier: target) { [weak self] result in
            guard let self else { return }
            let latest = self.pendingAudio?.revision == request
            if latest { self.pendingAudio = nil; self.refreshAudio() }
            guard self.interactionEpoch == epoch else { completion?(false); return }
            switch result {
            case let .applied(value, actualMute, identifier):
                guard identifier == audio.targetIdentifier else { completion?(false); return }
                if latest { self.assign(\.message, nil) }
                NotificationCenter.default.post(name: .volumeChanged, object: actualMute ? Float(0) : value, userInfo: ["source": "control"])
                completion?(true)
            case .failed:
                if latest { self.assign(\.message, "This output did not accept the mute change.") }
                completion?(false)
            case .cancelled: completion?(false)
            }
        }
    }

    func toggleMute() {
        guard !preview, let target = audioController.targetIdentifier else { return }
        // Preserve the latest displayed intention even if a slow driver has
        // not acknowledged the preceding click or slider move yet.
        let restoreFromZero = volume <= 0.01
        let nextMute = !isMuted
        captureUndo(.volume)
        if restoreFromZero {
            adjust(.volume, to: max(0.1, lastAudibleVolume))
        } else if audioController.supportsMute {
            changeMute(nextMute, target: target)
        } else {
            adjust(.volume, to: 0)
        }
    }

    func undo() {
        guard !preview, let saved = undoValues else { return }
        let currentDevice = saved.action == .volume ? audioController.targetIdentifier : displayController.targetIdentifier
        guard currentDevice == saved.device else {
            assign(\.message, "The active device changed. Undo is no longer available.")
            undoValues = nil
            return
        }
        interactionEpoch &+= 1
        let epoch = interactionEpoch
        let restoreMute = saved.action == .volume && audioController.supportsMute ? saved.muted : nil
        adjust(saved.action, to: saved.value, restoringMute: restoreMute) { [weak self] success in
            guard let self, self.interactionEpoch == epoch, success else { return }
            self.undoValues = nil
        }
    }

    #if SWAY_CONTROL_TESTS
    var visibleRefreshActiveForTesting: Bool { visibleTimer != nil }
    #endif
}

// MARK: - Quick controls

/// The menu bar is for immediate adjustments. Configuration lives in a window.
struct MenuBarView: View {
    @ObservedObject private var settings: TrackpadSettings
    @ObservedObject private var session = SwaySession.shared
    @ObservedObject private var monitor = TrackpadMonitor.shared
    private let telemetry = GestureTelemetry.shared
    @ObservedObject private var exclusions = ExcludedAppsManager.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var mixer: MixerModel
    @StateObject private var controls: ControlCenterModel
    @State private var showsMoreOptions = false
    @StateObject private var moreOptionsReveal: RevealDriver
    @State private var hoveringMore = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let preview: Bool
    private let previewStandaloneSurface: Bool
    private let previewReduceTransparency: Bool
    private let openSettings: () -> Void

    init(settings: TrackpadSettings = .shared, preview: Bool = false, previewStandaloneSurface: Bool = false, previewReduceTransparency: Bool = false, previewExpandedOptions: Bool = false, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.preview = preview
        self.previewStandaloneSurface = preview && previewStandaloneSurface
        self.previewReduceTransparency = preview && previewReduceTransparency
        self.openSettings = openSettings
        _showsMoreOptions = State(initialValue: preview && previewExpandedOptions)
        _moreOptionsReveal = StateObject(wrappedValue: RevealDriver(progress: preview && previewExpandedOptions ? 1 : 0))
        _controls = StateObject(wrappedValue: preview ? ControlCenterModel(settings: settings, preview: true) : .shared)
        mixer = preview ? .preview : .shared
    }

    /// Light chosen in Sway on a dark Mac, or the reverse. The popover's
    /// glass passes the system-colored content behind it straight through.
    private var themeDiffersFromSystem: Bool {
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (settings.appearanceMode == "light" && systemDark) || (settings.appearanceMode == "dark" && !systemDark)
    }

    private var statusLine: String {
        if !controls.hasAccess { return "Needs Accessibility" }
        if !settings.isEnabled { return session.pauseUntil == nil || preview ? "Paused" : "Paused for a while" }
        if exclusions.activeAppIsExcluded && !preview { return "Paused in \(exclusions.currentAppName)" }
        if let id = exclusions.currentAppBundleID, let profile = settings.appProfiles[id], !preview { return "\(profile.name) profile" }
        return "Edges ready"
    }

    /// The options unfold from under the button and the popover's glass grows
    /// with them, both set on every display frame; closing folds them back.
    private func setMoreOptions(_ shown: Bool) {
        showsMoreOptions = shown
        if reduceMotion { moreOptionsReveal.set(shown ? 1 : 0) }
        else { moreOptionsReveal.animate(to: shown ? 1 : 0, duration: shown ? 0.42 : 0.34) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                SwayLogo(size: 30, dimmed: !settings.isEnabled)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kinara").font(.system(size: 14, weight: .semibold))
                    Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                // More lives up here, beside the switch, so the menu needs no footer of its own.
                MoreOptionsButton(isExpanded: showsMoreOptions) { setMoreOptions(!showsMoreOptions) }
                    .frame(width: 24, height: 20)
                    .foregroundStyle(.secondary)
                    // A quiet pill behind the dots: a hint on hover, held while open.
                    .background(Capsule().fill(Color.primary.opacity(showsMoreOptions ? 0.12 : hoveringMore ? 0.06 : 0))
                        .frame(width: 30, height: 22))
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) { hoveringMore = hovering }
                    }
                Toggle("Enable trackpad gestures", isOn: Binding(get: { settings.isEnabled }, set: {
                    if preview { settings.isEnabled = $0 } else { session.setEnabled($0) }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(settings.isEnabled ? "Pause edge gestures; sliders stay available" : "Resume edge gestures")
            }

            VStack(spacing: 14) {
                QuickLevelRow(action: .brightness,
                    value: Binding(get: { controls.brightness }, set: { controls.adjust(.brightness, to: $0) }),
                    available: controls.brightnessAvailable, device: controls.brightnessDevice,
                    bounds: settings.brightnessMin...max(settings.brightnessMin, settings.brightnessMax),
                    onBegin: { controls.captureUndo(.brightness) })
                QuickLevelRow(action: .volume,
                    value: Binding(get: { controls.volume }, set: { controls.adjust(.volume, to: $0) }),
                    available: controls.volumeAvailable, device: controls.volumeDevice,
                    bounds: preview ? settings.volumeMin...max(settings.volumeMin, settings.volumeMax)
                                    : settings.volumeLimits(forDevice: VolumeController.shared.deviceUID),
                    muted: controls.isMuted,
                    muteAvailable: preview || settings.volumeMin == 0 || VolumeController.shared.supportsMute,
                    onBegin: { controls.captureUndo(.volume) }, onMute: { controls.toggleMute() })
            }

            if (MixerModel.isSupported || preview) && mixer.showInMenu {
                MenuHairline()
                MixerMenuSection(mixer: mixer)
            }

            if !controls.hasAccess {
                Button(action: openSettings) {
                    Label("Allow trackpad access…", systemImage: "lock.shield")
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Open Settings to enable Accessibility access")
            } else if settings.isEnabled && !monitor.isRunning && !preview {
                HStack(alignment: .top, spacing: 8) {
                    Label(monitor.statusMessage, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Retry") { monitor.restart() }.controlSize(.small)
                }
            } else if telemetry.isTesting && !preview {
                Label("Testing · gestures won’t change levels", systemImage: "waveform.path")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let until = session.pauseUntil, !preview {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text("Resumes in")
                    Text(until, style: .timer).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            } else if exclusions.activeAppIsExcluded && !preview {
                Text("Gestures paused in \(exclusions.currentAppName)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let message = controls.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updates.updateAvailable, let version = updates.latestVersion, !preview {
                Button { (NSApp.delegate as? AppDelegate)?.checkForUpdates() } label: {
                    Label("Kinara \(version) available…", systemImage: "arrow.down.circle")
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Review and install the signed update")
            }
            // Spacing lives inside this stack, where it can grow with what it separates.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    MenuTile(title: "Edge map", icon: "map") { if !preview { EdgeMapHUD.shared.show(autoHide: true) } }
                    if settings.isEnabled {
                        MenuTile(title: "Pause 15 min", icon: "pause.circle") { if !preview { session.pause(for: 15 * 60) } else { settings.isEnabled = false } }
                    } else {
                        MenuTile(title: "Resume", icon: "play.circle") { if preview { settings.isEnabled = true } else { session.setEnabled(true) } }
                    }
                    MenuTile(title: "Settings", icon: "gearshape", action: openSettings)
                        .keyboardShortcut(",", modifiers: .command)
                }
                if controls.undoValues != nil {
                    Button { controls.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .help("Undo your last adjustment").accessibilityLabel("Undo last adjustment")
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.top, 15)
                }
                VStack(alignment: .leading, spacing: 15) {
                    MenuHairline()
                    VStack(alignment: .leading, spacing: 12) {
                        Button { if !preview { (NSApp.delegate as? AppDelegate)?.showQuickControls() } } label: {
                            Label("Open Controls…", systemImage: "macwindow").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { if !preview { (NSApp.delegate as? AppDelegate)?.checkForUpdates() } } label: {
                            Label("Software Updates…", systemImage: "arrow.down.circle").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { if !preview { (NSApp.delegate as? AppDelegate)?.showGettingStarted() } } label: {
                            Label("Getting Started…", systemImage: "questionmark.circle").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { if !preview { KinaraLog.revealInFinder() } } label: {
                            Label("Diagnostic Log…", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            Text("Pause gestures").foregroundStyle(.secondary)
                            Spacer()
                            ForEach([5, 15, 60], id: \.self) { minutes in
                                Button(minutes == 60 ? "1 hr" : "\(minutes) min") {
                                    if !preview { session.pause(for: TimeInterval(minutes * 60)) }
                                    setMoreOptions(false)
                                }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        MenuHairline()
                        Button("Quit Kinara") { if !preview { NSApp.terminate(nil) } }.keyboardShortcut(showsMoreOptions ? KeyboardShortcut("q") : nil)
                    }.font(.system(size: 12)).buttonStyle(.plain)
                }
                // Always in place, folded to nothing when closed: a removed view
                // leaves the layout at once, so closing would snap shut. The
                // stack's spacing folds with it, so the glass never jumps.
                .padding(.top, 15)
                .revealed(by: moreOptionsReveal)
                .disabled(!showsMoreOptions)
                .accessibilityHidden(!showsMoreOptions)
            }
        }
        .padding(17)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuGlassSurface(standalone: previewStandaloneSurface, forceOpaque: previewReduceTransparency,
                                   themeDiffersFromSystem: !preview && themeDiffersFromSystem))
        // While the popover's glass grows or shrinks to the new height, the
        // menu stays pinned to the top. Centered, the header would jump up
        // and slide back down with every change. A zero minimum lets the frame
        // be shorter than the menu; its ideal height is still the menu's.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .tint(.primary)
        .preferredColorScheme(settings.resolvedColorScheme)
    }
}

/// The menu's separator: a half-point hairline, as in macOS's own menus. A full
/// Divider reads as a heavy rule on the menu's glass.
private struct MenuHairline: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5).accessibilityHidden(true)
    }
}

private struct QuickLevelRow: View {
    let action: ZoneAction
    @Binding var value: Double
    let available: Bool
    let device: String
    let bounds: ClosedRange<Double>
    var muted = false
    var muteAvailable = false
    let onBegin: () -> Void
    var onMute: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                if let onMute {
                    Button(action: onMute) {
                        Image(systemName: muted || value <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain).disabled(!available || !muteAvailable)
                    .help(muted || value <= 0.01 ? "Restore audio" : "Mute audio")
                    .accessibilityLabel(muted || value <= 0.01 ? "Restore audio" : "Mute audio")
                } else {
                    Image(systemName: action.icon).frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(action.label).fontWeight(.medium)
                    Text(device).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(available ? (muted ? "Muted" : "\(Int((value * 100).rounded()))%") : "Unavailable")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12.5))
            Slider(value: $value, in: bounds, onEditingChanged: { if $0 { onBegin() } })
                .controlSize(.small).disabled(!available)
                .accessibilityLabel(action.label)
                .accessibilityValue(available ? "\(Int(value * 100)) percent\(muted ? ", muted" : "")" : "Unavailable")
                .help(available ? device : "Use this device’s hardware controls")
        }
    }
}

/// A compact action in the menu: one icon, one word, one click.
private struct MenuTile: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(PressableButtonStyle()).accessibilityLabel(title)
    }
}

private struct MenuGlassSurface: ViewModifier {
    var standalone = false
    var forceOpaque = false
    var themeDiffersFromSystem = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if !standalone && themeDiffersFromSystem {
            // Clear glass shows the system-colored windows behind it, so a
            // Light choice on a dark Mac turned into a flat grey slab. A
            // frosted backing in the chosen mode keeps it clean and legible.
            content.background(.thickMaterial)
        } else if !standalone {
            // NSPopover owns its native glass when Sway follows the system.
            // Another material here would flatten it.
            content
        } else if reduceTransparency || forceOpaque {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(PopoverMaterial().clipShape(RoundedRectangle(cornerRadius: 12)))
        }
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Separate settings window

struct ContentView: View {
    @ObservedObject private var settings: TrackpadSettings
    @ObservedObject private var monitor = TrackpadMonitor.shared
    @ObservedObject private var ambient = AmbientLight.shared
    // Not observed: touch samples publish up to 30 times a second, and the
    // whole window must not redraw for them. The map and the safe-test panel
    // observe it themselves; this reads only rarely-changing flags.
    private let telemetry = GestureTelemetry.shared
    @ObservedObject private var exclusions = ExcludedAppsManager.shared
    @ObservedObject private var login = LoginItemManager.shared
    @ObservedObject private var updates: UpdateChecker
    @ObservedObject private var mixer: MixerModel
    @StateObject private var controls: ControlCenterModel
    @State private var pane: SettingsPane
    @State private var search = ""
    @State private var showsSafeTest = false
    @State private var showAppPicker = false
    @State private var confirmReset = false
    @State private var presetMessage: String?
    /// The edge or corner chosen on the map, edited below it.
    @State private var selectedZone = "left"
    /// The page whose Advanced sheet is open.
    @State private var advancedPane: SettingsPane?
    /// Whether the page has scrolled under the title, which then gets its hairline.
    @State private var scrolled = false
    @State private var askedForAccess = false
    @State private var editingProfile: ProfileTarget?
    @Namespace private var sidebarSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var transferMessage: String?
    private let preview: Bool
    /// Renders lay a page's advanced options out under it: a sheet can't be captured.
    private let previewAdvanced: Bool

    init(initialPane: SettingsPane = .home, spot: String = "left", showsAdvanced: Bool = false, preview: Bool = false,
         settings: TrackpadSettings = .shared, updates: UpdateChecker = .shared) {
        self.preview = preview
        self.previewAdvanced = preview && showsAdvanced
        self.settings = settings
        self.updates = updates
        _pane = State(initialValue: initialPane)
        _selectedZone = State(initialValue: spot)
        _controls = StateObject(wrappedValue: preview ? ControlCenterModel(settings: settings, preview: true) : .shared)
        mixer = preview ? .preview : .shared
    }

    private var visiblePanes: [SettingsPane] { SettingsPane.allCases.filter { $0.matches(search) } }

    /// One line that says what Sway is doing right now.
    private var status: (title: String, detail: String, icon: String) {
        if !controls.hasAccess { return ("Needs access", "Allow Accessibility to use gestures", "lock") }
        if !settings.isEnabled { return ("Paused", "Sliders still work", "pause.circle") }
        if exclusions.activeAppIsExcluded && !preview { return ("Paused here", "Excluded in \(exclusions.currentAppName)", "pause.circle") }
        if let id = exclusions.currentAppBundleID, settings.appProfiles[id] != nil, !preview {
            return ("Active", "\(settings.appProfiles[id]?.name ?? exclusions.currentAppName) profile", "checkmark.circle.fill")
        }
        return ("Active", "Edges are ready", "checkmark.circle.fill")
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 214)
                .frame(maxHeight: .infinity)
                .background(SidebarMaterial(preview: preview))
            Divider()
            content
        }
        .frame(minWidth: 820, idealWidth: 820, maxWidth: .infinity, minHeight: 520, idealHeight: 660, maxHeight: .infinity)
        .background(GroupedBackground())
        // The sidebar runs up under the window's buttons, as in System Settings.
        .ignoresSafeArea()
        // One gentle transaction for page changes: the content settles in and
        // the sidebar highlight glides, wherever the change came from.
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.88), value: pane)
        .preferredColorScheme(settings.resolvedColorScheme)
        .onChange(of: pane) { value in
            if value != .edges { endTesting() }
            advancedPane = nil
            scrolled = false
            updateLiveView(value)
        }
        .onAppear { updateLiveView(pane) }
        .onChange(of: search) { _ in
            if !visiblePanes.contains(pane), let first = visiblePanes.first { pane = first }
            if visiblePanes.isEmpty { endTesting() }
        }
        .onChange(of: showsSafeTest) { if !$0 { endTesting() } }
        .onDisappear { endTesting(); if !preview { telemetry.isLiveViewing = false } }
        .sheet(isPresented: $showAppPicker) { AppPickerSheet(excludedApps: $settings.excludedApps) }
        .sheet(item: $editingProfile) { target in ProfileEditor(settings: settings, target: target) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's own buttons sit in this strip.
            Color.clear.frame(height: 52)
            SearchField(text: $search).padding(.horizontal, 10)
            HStack(spacing: 10) {
                SwayLogo(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kinara").font(.system(size: 13, weight: .semibold))
                    Text(status.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Toggle("Gestures", isOn: Binding(get: { settings.isEnabled }, set: { value in
                    if preview { settings.isEnabled = value } else { SwaySession.shared.setEnabled(value) }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .help(settings.isEnabled ? "Pause edge gestures" : "Resume edge gestures")
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visiblePanes) { item in sidebarRow(item) }
                }.padding(.horizontal, 10)
            }.scrollIndicators(.never)
        }
    }

    private func sidebarRow(_ item: SettingsPane) -> some View {
        let selected = pane == item
        let key = activeState != .inactive
        return Button { pane = item } label: {
            HStack(spacing: 8) {
                PaneIcon(pane: item)
                Text(item.title).font(.system(size: 13))
                    .foregroundStyle(selected && key ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(key ? Color.accentColor : Color.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "sidebar", in: sidebarSelection)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(visiblePanes.isEmpty ? "Search" : pane.title)
                .font(.system(size: 15, weight: .semibold))
                .frame(height: 52).padding(.horizontal, 24)
            Divider().opacity(scrolled ? 1 : 0)
            if visiblePanes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    Text("No Results for “\(search)”").font(.system(size: 15, weight: .semibold))
                    Text("Try haptics, paste, corner or updates.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        notices
                        page
                    }
                    .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("settingsPage")).minY)
                    })
                }
                .coordinateSpace(name: "settingsPage")
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    let now = offset < -1
                    if now != scrolled { scrolled = now }
                }
                .id(pane)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $advancedPane) { item in
            AdvancedSheet(title: item.title) { advancedSections(item) }
                .preferredColorScheme(settings.resolvedColorScheme)
                .onDisappear { showsSafeTest = false; endTesting() }
        }
    }

    @ViewBuilder private var notices: some View {
        if !controls.hasAccess && [.edges, .general].contains(pane) { permissionCard }
        if controls.hasAccess && settings.isEnabled && !monitor.isRunning && !preview && pane == .edges {
            HStack(spacing: 12) {
                Notice(monitor.statusMessage, icon: "exclamationmark.triangle", tint: .primary)
                Button("Reconnect") { monitor.restart() }
            }
        }
        if let message = controls.message { Notice(message, icon: "exclamationmark.triangle", tint: .primary) }
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .home: homePage
        case .edges: edgesPage
        case .feel: feelPage
        case .sound: soundPage
        case .apps: appsPage
        case .general: generalPage
        }
        if pane.hasAdvanced {
            HStack {
                Spacer()
                Button("Advanced…") { advancedPane = pane }
            }
        }
        if previewAdvanced { advancedSections(pane) }
    }

    @ViewBuilder private func advancedSections(_ item: SettingsPane) -> some View {
        switch item {
        case .edges: edgesAdvanced
        case .feel: feelAdvanced
        case .sound: soundAdvanced
        case .general: generalAdvanced
        case .home, .apps: EmptyView()
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatusGlyph(icon: "lock.fill", color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Accessibility").font(.system(size: 13, weight: .semibold))
                    Text(askedForAccess ? "Switch on Kinara in System Settings." : "So Kinara can feel your edges. Sliders work without it.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if askedForAccess {
                    Button("Check Again") { controls.refresh(); if controls.hasAccess { monitor.restart() } }
                }
                Button("Allow…", action: askForAccessibility).buttonStyle(.borderedProminent)
            }
            if askedForAccess {
                Button("No prompt? Open Accessibility Settings", action: openAccessibilitySettings)
                    .buttonStyle(.link).font(.system(size: 11.5))
            }
            AccessibilityRecoveryHelp()
        }
        .padding(14).modifier(CardSurface())
    }

    // MARK: Home

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            statusCard
            VStack(spacing: 12) {
                TrackpadMap(settings: settings, selectedZone: nil, telemetry: telemetry, showsTouches: telemetry.isLiveViewing,
                            onSelect: { zone in
                                selectSpot(zone)
                                pane = .edges
                            }, showsCorners: true)
                    .frame(width: 400, height: 240)
                Text("Click an edge or corner to change it").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick settings").font(.system(size: 13, weight: .semibold)).padding(.leading, 2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    QuickTile(title: "Haptics", value: settings.hapticFeedback ? settings.hapticStyle.label : "Off", icon: "waveform", isOn: settings.hapticFeedback) {
                        settings.hapticFeedback.toggle()
                    }
                    QuickTile(title: "Fine control", value: settings.precisionEnabled ? "On" : "Off", icon: "scope", isOn: settings.precisionEnabled) {
                        settings.precisionEnabled.toggle()
                    }
                    QuickTile(title: "50% notch", value: settings.midpointNotch ? "On" : "Off", icon: "dial.medium", isOn: settings.midpointNotch) {
                        settings.midpointNotch.toggle()
                    }
                    QuickTile(title: "Indicator", value: settings.osdStyle == "edge" ? "Follows finger" : settings.osdStyle == "off" ? "Off" : "Pill", icon: "capsule.portrait", isOn: settings.osdStyle != "off") {
                        settings.osdStyle = settings.osdStyle == "edge" ? "horizontal" : "edge"
                    }
                    QuickTile(title: "Speed curve", value: settings.accelerationEnabled ? "On" : "Off", icon: "gauge.with.dots.needle.67percent", isOn: settings.accelerationEnabled) {
                        settings.accelerationEnabled.toggle()
                    }
                    QuickTile(title: "Menu bar scroll", value: settings.menuBarScroll ? "On" : "Off", icon: "computermouse", isOn: settings.menuBarScroll) {
                        settings.menuBarScroll.toggle()
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            StatusGlyph(icon: !controls.hasAccess ? "lock.fill" : settings.isEnabled ? "checkmark" : "pause.fill",
                        color: !controls.hasAccess ? .orange : settings.isEnabled ? .green : .gray, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(controls.hasAccess ? (settings.isEnabled ? "Kinara is ready" : "Gestures are paused") : "One step left")
                    .font(.system(size: 15, weight: .semibold))
                Text(controls.hasAccess
                     ? (settings.isEnabled ? (status.detail == "Edges are ready" ? "Slide along an edge, or double-tap a corner." : "\(status.detail) is on for the app in front.")
                                           : "Your sliders still work. Turn gestures back on anytime.")
                     : "Allow Accessibility so Kinara can feel your edges. Touch data stays on your Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // As in the guide: macOS's own prompt, then a way on if it doesn't come up.
                if !controls.hasAccess && askedForAccess {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Switch on Kinara in System Settings.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.top, 4)
                    Button("No prompt? Open Accessibility Settings", action: openAccessibilitySettings)
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            Spacer(minLength: 8)
            if !controls.hasAccess {
                Button("Allow…", action: askForAccessibility).buttonStyle(.borderedProminent).controlSize(.large)
            } else if !settings.isEnabled {
                Button("Resume") { if !preview { SwaySession.shared.setEnabled(true) } else { settings.isEnabled = true } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(16).modifier(CardSurface())
    }

    private var everydayBinding: (String) -> Binding<EdgeBinding> {
        { slot in Binding(get: { settings.baseBinding(slot) }, set: { settings.setBaseBinding($0, for: slot) }) }
    }
    private var otherFingerCount: String { settings.minimumFingers == 1 ? "2 fingers" : "1 finger" }
    private var usesSharedShortcuts: Bool {
        EdgeSlot.swipe.contains { slot in
            let binding = settings.baseBinding(slot)
            return binding.action == .customShortcut && binding.up.isEmpty && binding.down.isEmpty
        }
    }

    // MARK: Edges & corners

    /// A spot chosen on the map is edited right below it. The top edge's two
    /// halves are one spot.
    private func selectSpot(_ zone: String) {
        let spot = zone.hasPrefix("top") && !zone.hasSuffix("Corner") ? "top" : zone
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) { selectedZone = spot }
    }

    /// One trackpad, one inspector: click a spot, and everything it does is below it.
    private var edgesPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 14) {
                TrackpadMap(settings: settings, selectedZone: selectedZone, telemetry: telemetry,
                            showsTouches: telemetry.isTesting || telemetry.isLiveViewing, onSelect: { selectSpot($0) }, showsCorners: true)
                    .frame(width: 400, height: 240)
                HStack(spacing: 8) {
                    Text("Slide with").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("Slide with", selection: $settings.minimumFingers) {
                        Text("1 finger").tag(1); Text("2 fingers").tag(2)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .onChange(of: settings.minimumFingers) { value in
                    if value != 1 { settings.topEdgeEnabled = false; settings.bottomEdgeEnabled = false }
                }
            }.frame(maxWidth: .infinity)
            spotEditor
        }
    }

    /// What the chosen spot does: an edge's slide and taps, or a corner's taps.
    private var spotEditor: some View {
        let spot = selectedZone
        return SettingsSection("") {
            HStack(spacing: 12) {
                SpotGlyph(spot: spot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(EdgeSlot.title(spot)).font(.system(size: 13, weight: .semibold))
                    Text(spotHint(spot)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(12)
            RowDivider()
            switch spot {
            case "left", "right":
                SlotEditor(title: "Slide", binding: everydayBinding(spot), sharedFallback: true)
                RowDivider()
                tapRegionEditors(spot)
                RowDivider()
                EdgeWidthSlider(title: "Width", value: spot == "left" ? $settings.leftZoneWidth : $settings.rightZoneWidth,
                                range: TrackpadSettings.sideZoneWidthRange)
            case "top", "bottom":
                extraEdgeEditor(top: spot == "top")
            default:
                tapRegionEditors(spot)
                RowDivider()
                LabeledSlider("Size", value: $settings.tapCornerSize, range: TrackpadSettings.cornerSizeRange,
                              display: "\(Int((settings.tapCornerSize * 100).rounded()))%")
            }
        }
        .id(spot)
        .transition(.opacity)
    }

    private func spotHint(_ spot: String) -> String {
        switch spot {
        case "left", "right": return "Slide up or down along the \(spot) side."
        case "top": return settings.topEdgeSwipeDirection == "horizontal" ? "Slide left or right along the top." : "Slide up or down at the top."
        case "bottom": return "Slide left or right along the bottom."
        default: return "Double-tap, or tap and hold, in this corner."
        }
    }

    @ViewBuilder private func extraEdgeEditor(top: Bool) -> some View {
        let on = top ? settings.topEdgeEnabled : settings.bottomEdgeEnabled
        ToggleRow(top ? "Use the top edge" : "Use the bottom edge", detail: on ? nil : "Takes one finger.",
                  value: Binding(get: { on }, set: { value in
                      if value { settings.minimumFingers = 1 }
                      if top { settings.topEdgeEnabled = value } else { settings.bottomEdgeEnabled = value }
                  }))
        if on {
            RowDivider()
            if top {
                SettingRow("Slide") {
                    Picker("Top slide direction", selection: $settings.topEdgeSwipeDirection) {
                        Text("Left and right").tag("horizontal"); Text("Up and down").tag("vertical")
                    }.pickerStyle(.segmented).fixedSize()
                }
                RowDivider()
                if settings.topEdgeSwipeDirection == "horizontal" {
                    SlotEditor(title: "Left half", binding: everydayBinding("topLeft"))
                    RowDivider()
                    SlotEditor(title: "Right half", binding: everydayBinding("topRight"))
                } else {
                    SlotEditor(title: "Slide action", binding: everydayBinding("top"))
                }
                RowDivider()
                EdgeWidthSlider(title: "Height", value: $settings.topEdgeHeight, range: TrackpadSettings.topEdgeHeightRange)
            } else {
                SlotEditor(title: "Slide", binding: everydayBinding("bottom"))
                RowDivider()
                EdgeWidthSlider(title: "Height", value: $settings.bottomEdgeHeight, range: TrackpadSettings.topEdgeHeightRange)
            }
            RowDivider()
            tapRegionEditors(top ? "top" : "bottom")
        }
    }

    private var edgesAdvanced: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Presets", footer: presetMessage) {
                SettingRow("Start from a preset") {
                    Menu("Choose…") {
                        ForEach(GesturePreset.allCases) { preset in
                            Button(preset.title) {
                                settings.applyGesturePreset(preset)
                                presetMessage = "\(preset.title) applied. You can change any edge after."
                            }
                        }
                    }.fixedSize()
                }
            }
            SettingsSection("More edges") {
                ToggleRow("Top edge", detail: "Takes one finger.", value: Binding(get: { settings.topEdgeEnabled }, set: { on in
                    if on { settings.minimumFingers = 1 }
                    settings.topEdgeEnabled = on
                    if on { selectSpot("top") }
                }))
                RowDivider()
                ToggleRow("Bottom edge", detail: "Takes one finger. Leave it off if your thumb rests there.", value: Binding(get: { settings.bottomEdgeEnabled }, set: { on in
                    if on { settings.minimumFingers = 1 }
                    settings.bottomEdgeEnabled = on
                    if on { selectSpot("bottom") }
                }))
            }
            SettingsSection("Second actions", footer: "Hold ⌥ while you slide, or slide with \(otherFingerCount). Off changes nothing.") {
                SlotEditor(title: "Left edge with ⌥", binding: everydayBinding(EdgeSlot.option("left")))
                RowDivider()
                SlotEditor(title: "Right edge with ⌥", binding: everydayBinding(EdgeSlot.option("right")))
                RowDivider()
                SlotEditor(title: "Left edge with \(otherFingerCount)", binding: everydayBinding(EdgeSlot.alternate("left")))
                RowDivider()
                SlotEditor(title: "Right edge with \(otherFingerCount)", binding: everydayBinding(EdgeSlot.alternate("right")))
            }
            if settings.minimumFingers == 2 {
                SettingsSection("Corner taps") {
                    SettingRow("Tap corners with") {
                        Picker("Fingers for corner taps", selection: $settings.cornerTapFingers) {
                            Text("2 fingers").tag(0); Text("1 finger").tag(1)
                        }.pickerStyle(.segmented).fixedSize()
                    }
                }
            }
            if usesSharedShortcuts {
                SettingsSection("Custom shortcuts", footer: "Used by edges set to Custom shortcut until you record keys there.") {
                    HotkeyRecorder(hotkey: $settings.swipeUpShortcut, title: "Slide up or right", detail: "Sent once per slide.", showsRegistrationError: false)
                    RowDivider()
                    HotkeyRecorder(hotkey: $settings.swipeDownShortcut, title: "Slide down or left", detail: "Sent once per slide.", showsRegistrationError: false)
                }
            }
            SettingsSection("Palm protection", footer: "Palms are always ignored, typing or not. Where a spot has a tap action, tap-to-click there belongs to Kinara; pressing the trackpad still clicks.") {
                SettingRow("Checks") {
                    Picker("Palm protection", selection: $settings.palmRejectionMode) {
                        Text("Balanced").tag("balanced"); Text("Strict").tag("strict")
                    }.pickerStyle(.segmented).fixedSize()
                }
                RowDivider()
                LabeledSlider("Pause after typing", value: $settings.typingCooldown, range: 0.2...1, display: String(format: "%.2f s", settings.typingCooldown))
                RowDivider()
                LabeledSlider("Start distance", value: $settings.activationThreshold, range: 0...12,
                              display: String(format: "%.1f%%", max(settings.palmRejectionMode == "strict" ? 1.4 : 0.8, settings.activationThreshold / 5 * (settings.palmRejectionMode == "strict" ? 1.3 : 1))))
            }
            SettingsSection("Test safely") {
                DisclosureGroup("Try gestures without running them", isExpanded: $showsSafeTest) {
                    SafeTestPanel(settings: settings, controls: controls, preview: preview, endTesting: endTesting).padding(.top, 12)
                }
                .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
    }

    // MARK: Feel

    private var feelPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Haptics") {
                ToggleRow("Haptic feedback", value: $settings.hapticFeedback)
                if settings.hapticFeedback {
                    RowDivider()
                    SettingRow("Strength") {
                        HStack(spacing: 8) {
                            Picker("Haptic strength", selection: $settings.hapticStyle) {
                                ForEach(HapticStyle.allCases) { style in Text(style.label).tag(style) }
                            }.pickerStyle(.menu).fixedSize()
                            Button("Try") { if !preview, !telemetry.isTesting { HapticOutput.shared.play(settings.hapticStyle) } }
                                .disabled(telemetry.isTesting)
                                .help("Rest a finger on the trackpad, then click Try.")
                        }
                    }
                }
            }
            SettingsSection("On screen") {
                SettingRow("Indicator") {
                    Picker("Indicator style", selection: $settings.osdStyle) {
                        Text("Pill").tag("horizontal"); Text("Vertical").tag("vertical"); Text("Follows finger").tag("edge"); Text("Off").tag("off")
                    }.pickerStyle(.menu).fixedSize()
                }
                RowDivider()
                SettingRow("Tap results") {
                    Picker("Tap feedback", selection: $settings.cornerEffects) {
                        Text("In the corner").tag(true); Text("In the indicator").tag(false)
                    }.pickerStyle(.menu).fixedSize()
                }
                RowDivider()
                ToggleRow("Edge light", detail: "A soft glow follows your finger along the screen’s edge.", value: $settings.edgeLight)
                RowDivider()
                SettingRow("Light colour", detail: "For the edge light, the corner light and the ambient light.") {
                    EdgeLightSwatches(selection: $settings.edgeLightColor)
                }
                RowDivider()
                SettingRow("Ambient light", detail: "The light laps your screen’s edges until you press a key or click. Put it on a corner double-tap in Edges & corners.") {
                    Button(ambient.isRunning ? "Stop" : "Start") { if !preview { AmbientLight.shared.toggle() } }
                }
            }
            SettingsSection("Levels") {
                ToggleRow("Fine control", detail: "Slide inward from the edge for small steps.", value: $settings.precisionEnabled)
                RowDivider()
                ToggleRow("Speed curve", detail: "Slow slides make small changes; a flick covers more.", value: $settings.accelerationEnabled)
                RowDivider()
                ToggleRow("Notch at 50%", value: $settings.midpointNotch)
                RowDivider()
                ToggleRow("Reverse direction", value: $settings.invertScrollDirection)
            }
        }
    }

    private var feelAdvanced: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Slides") {
                LabeledSlider("Sensitivity", value: $settings.sensitivity, range: 0.3...3, display: String(format: "%.1f×", settings.sensitivity))
                RowDivider()
                ToggleRow("Hold the pointer while sliding", value: $settings.cursorFreezeOnOneFinger)
                    .disabled(settings.minimumFingers != 1 && !EdgeSlot.sides.contains { settings.slotIsAssigned(EdgeSlot.alternate($0)) })
            }
            if settings.hapticFeedback {
                SettingsSection("Haptics") {
                    SettingRow("Steps") {
                        Picker("Haptic level spacing", selection: $settings.hapticSpacing) {
                            ForEach(HapticSpacing.allCases) { spacing in Text(spacing.label).tag(spacing) }
                        }.pickerStyle(.segmented).fixedSize()
                    }
                    RowDivider()
                    ToggleRow("Tap when a slide starts", value: $settings.hapticOnStart)
                }
            }
            SettingsSection("Indicator") {
                if settings.osdStyle == "horizontal" {
                    LabeledSlider("Width", value: $settings.osdHorizontalWidth, range: 160...320, display: "\(Int(settings.osdHorizontalWidth)) pt")
                    RowDivider()
                } else if settings.osdStyle == "vertical" {
                    SettingRow("Position") {
                        Picker("Indicator position", selection: $settings.osdPosition) {
                            ForEach(OSDPosition.allCases) { item in Text(item.label).tag(item) }
                        }.pickerStyle(.menu).fixedSize()
                    }
                    RowDivider()
                }
                if settings.osdStyle != "off" {
                    SettingRow("See it as it looks now") {
                        Button("Preview") { if !preview { OSDOverlay.shared.show(type: .volume, value: Float(controls.volume)) } }
                    }
                    RowDivider()
                }
                ToggleRow("Now Playing card", detail: "Artwork and title when you skip or pause.", value: $settings.nowPlayingHUD)
                RowDivider()
                SettingRow("Volume click") {
                    Picker("Volume feedback sound", selection: $settings.volumeFeedbackSound) {
                        Text("Like macOS").tag("system"); Text("On").tag("on"); Text("Off").tag("off")
                    }.pickerStyle(.segmented).fixedSize()
                }
            }
        }
    }

    // MARK: Sound & display

    private var soundPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Volume") {
                LimitEditor(action: .volume, lower: $settings.volumeMin, upper: $settings.volumeMax)
                RowDivider()
                ToggleRow("Mute at zero", value: $settings.muteAtZero)
            }
            SettingsSection("Brightness") {
                LimitEditor(action: .brightness, lower: $settings.brightnessMin, upper: $settings.brightnessMax)
                RowDivider()
                ToggleRow("Follow the pointer", detail: "Changes the display the pointer is on. Now: \(controls.brightnessDevice).", value: $settings.brightnessFollowsPointer)
                RowDivider()
                ToggleRow("Extra dim", detail: "Slide past the lowest level to dim further.", value: $settings.extraDimBelowMinimum)
            }
            if !MixerModel.isSupported && !preview {
                Notice("The app mixer needs macOS 14.2 or later.", icon: "info.circle", tint: .primary)
            } else {
                mixerSection
            }
        }
    }

    private var mixerSection: some View {
        SettingsSection("Apps") {
            if mixer.permission != .authorized {
                MixerPermissionRow(mixer: mixer).padding(12)
                RowDivider()
            }
            let list = mixer.playingChannels + (mixer.showOtherApps ? mixer.otherChannels : [])
            if list.isEmpty {
                Text("Apps show up here when they play sound, each with its own fader.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 11)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    MixerBanners(mixer: mixer)
                    ForEach(list) { MixerChannelRow(channel: $0, mixer: mixer, large: true) }
                }.padding(12)
            }
            RowDivider()
            ToggleRow("Lower other apps during calls", value: $mixer.duckDuringCalls)
        }
    }

    private var soundAdvanced: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("This output", footer: "Handy for keeping headphones quieter.") { outputLimits }
            SettingsSection("Favorite levels", footer: "Slides pause at a favorite with a soft tap.") {
                FavoriteLevelRow(action: .volume, favorite: $settings.volumeFavorite, current: controls.volume)
                RowDivider()
                FavoriteLevelRow(action: .brightness, favorite: $settings.brightnessFavorite, current: controls.brightness)
            }
            if MixerModel.isSupported || preview {
                SettingsSection("Mixer", footer: "Kinara reroutes an app only while you’ve changed it. Audio is never recorded or saved.") {
                    ToggleRow("Faders in the menu bar", value: $mixer.showInMenu)
                    RowDivider()
                    ToggleRow("Allow boost to 150%", value: $mixer.allowBoost)
                    RowDivider()
                    ToggleRow("List apps before they play", detail: "Mute an app before its next sound.", value: $mixer.showOtherApps)
                    if mixer.duckDuringCalls {
                        RowDivider()
                        LabeledSlider("Other apps during calls", value: $mixer.duckLevel, range: 0.05...0.8,
                                      display: "\(Int((mixer.duckLevel * 100).rounded()))%")
                    }
                    RowDivider()
                    SettingRow("Every app back to 100%") { Button("Reset") { mixer.resetAllChannels() } }
                }
            }
        }
    }

    @ViewBuilder private var outputLimits: some View {
        ToggleRow("Own limits for \(controls.volumeDevice)", value: Binding(get: {
            currentDeviceUID.map { settings.deviceVolumeLimits[$0] != nil } ?? false
        }, set: { on in
            guard let uid = currentDeviceUID else { return }
            settings.deviceVolumeLimits[uid] = on ? DeviceLimit(name: controls.volumeDevice, min: settings.volumeMin, max: settings.volumeMax) : nil
        }))
        .disabled(currentDeviceUID == nil)
        if let uid = currentDeviceUID, let limit = settings.deviceVolumeLimits[uid] {
            RowDivider()
            LimitEditor(action: .volume,
                        lower: Binding(get: { limit.min }, set: { settings.deviceVolumeLimits[uid] = DeviceLimit(name: limit.name, min: $0, max: settings.deviceVolumeLimits[uid]?.max ?? limit.max) }),
                        upper: Binding(get: { limit.max }, set: { settings.deviceVolumeLimits[uid] = DeviceLimit(name: limit.name, min: settings.deviceVolumeLimits[uid]?.min ?? limit.min, max: $0) }))
        }
        let others = settings.deviceVolumeLimits.filter { $0.key != currentDeviceUID }.sorted { $0.value.name < $1.value.name }
        ForEach(others, id: \.key) { item in
            RowDivider()
            HStack {
                Text(item.value.name).font(.system(size: 13))
                Spacer()
                Text("\(Int(item.value.min * 100))–\(Int(item.value.max * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                Button { settings.deviceVolumeLimits.removeValue(forKey: item.key) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Forget limits for \(item.value.name)")
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    // MARK: Apps

    private var appsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            profilesPage
            SettingsSection("Paused apps") {
                SettingRow(settings.excludedApps.isEmpty ? "Kinara works in every app"
                           : settings.excludedApps.count == 1 ? "Paused in 1 app" : "Paused in \(settings.excludedApps.count) apps") {
                    Button("Manage…") { showAppPicker = true }
                }
                if let id = exclusions.currentAppBundleID, !preview, !settings.excludedApps.contains(id) {
                    RowDivider()
                    SettingRow(exclusions.currentAppName) {
                        Button("Pause Here") { settings.excludedApps.append(id) }
                    }
                }
            }
        }
    }

    // MARK: General

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection("") {
                ToggleRow("Open at login", value: $settings.launchAtLogin)
                if login.lastError != nil || login.status == .requiresApproval || login.status == .notFound {
                    Text(login.statusMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.bottom, 10)
                }
                RowDivider()
                ToggleRow("Show in the Dock while Settings is open", value: $settings.showDockIcon)
            }
            SettingsSection("Appearance") {
                SettingRow("Theme") {
                    Picker("Theme", selection: $settings.appearanceMode) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }.pickerStyle(.segmented).fixedSize()
                }
                RowDivider()
                SettingRow("Menu bar shows") {
                    Picker("Menu bar display", selection: $settings.menuBarValueSource) {
                        Text("Kinara icon").tag("icon"); Text("Kinara name").tag("name"); Text("Volume").tag("volume"); Text("Brightness").tag("brightness"); Text("Both levels").tag("both")
                    }.pickerStyle(.menu).fixedSize()
                }
                RowDivider()
                ToggleRow("Scroll the icon to change volume", detail: "Hold ⌥ for brightness.", value: $settings.menuBarScroll)
            }
            clipboardSection
            SettingsSection("Shortcuts") {
                HotkeyRecorder(hotkey: $settings.toggleHotkey, title: "Pause or resume", detail: "")
                RowDivider()
                HotkeyRecorder(hotkey: $settings.cheatSheetHotkey, title: "Show the edge map", detail: "Hold it to see what every edge does.", usesCheatSheetError: true)
            }
            SettingsSection("Updates") { UpdatePreferencesContent(updates: updates, preview: preview) }
            SettingsSection("Help") {
                SettingRow("Getting started") {
                    Button("Open Guide") { if !preview { (NSApp.delegate as? AppDelegate)?.showGettingStarted() } }
                }
                RowDivider()
                SettingRow("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var generalAdvanced: some View {
        VStack(alignment: .leading, spacing: 22) {
            automationSection
            SettingsSection("Troubleshooting") {
                SettingRow("Diagnostic log") { Button("Show in Finder") { if !preview { KinaraLog.revealInFinder() } } }
                RowDivider()
                SettingRow("Controls in a window") {
                    Button("Open") { if !preview { (NSApp.delegate as? AppDelegate)?.showQuickControls() } }
                }
                RowDivider()
                SettingRow("Every edge and corner as new") { Button("Reset…") { confirmReset = true } }
            }
            .alert("Reset gesture settings?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) { }
                Button("Reset gestures", role: .destructive) { settings.resetGestureSettings() }
            } message: { Text("Edges, corners, layers, feel, palm protection, haptics and limits go back to how Kinara starts. Profiles, shortcuts, paused apps and appearance stay.") }
        }
    }

    private var tapEdges: [String] {
        ["left", "right"] + (settings.topEdgeEnabled ? ["top"] : []) + (settings.bottomEdgeEnabled ? ["bottom"] : [])
    }

    /// A spot's double-tap and tap-and-hold.
    private func tapRegionEditors(_ region: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SlotEditor(title: "Double-tap", binding: everydayBinding(EdgeSlot.tap(region, "doubleTap")), tapOnly: true)
            RowDivider()
            SlotEditor(title: "Tap and hold", binding: everydayBinding(EdgeSlot.tap(region, "tapHold")), tapOnly: true)
        }
    }

    // MARK: Profiles

    private var profilesPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection("App profiles", footer: "A profile changes only the edges you pick, while that app is in front.") {
                if settings.appProfiles.isEmpty {
                    Text("Give an app its own edges, like switching tabs in Safari.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 11)
                    RowDivider()
                }
                ForEach(settings.appProfiles.keys.sorted { (settings.appProfiles[$0]?.name ?? $0).localizedCaseInsensitiveCompare(settings.appProfiles[$1]?.name ?? $1) == .orderedAscending }, id: \.self) { id in
                    profileRow(id)
                    RowDivider()
                }
                HStack(spacing: 8) {
                    Button("Add App…", action: addProfileApp)
                    if let id = exclusions.currentAppBundleID, settings.appProfiles[id] == nil, !preview {
                        Button("Add \(exclusions.currentAppName)") {
                            settings.appProfiles[id] = ActionProfile(name: exclusions.currentAppName)
                            editingProfile = .app(id)
                        }
                    }
                    Spacer()
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }
            SettingsSection("When docked", footer: "Kinara uses the app’s profile first, then the docked one, then your everyday edges.") {
                ToggleRow("Docked profile", detail: "While an external display is connected\(BrightnessController.shared.hasExternalDisplayConnected && !preview ? ", like now" : "").",
                          value: $settings.dockedProfileEnabled)
                if settings.dockedProfileEnabled {
                    RowDivider()
                    SettingRow(Self.changeSummary(settings.dockedProfile.bindings.count)) {
                        Button("Edit…") { editingProfile = .docked }
                    }
                }
            }
        }
    }

    private func profileRow(_ id: String) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.appIcon(id)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.appProfiles[id]?.name ?? id).font(.system(size: 13))
                Text(Self.profileSummary(settings.appProfiles[id])).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Fingers in \(settings.appProfiles[id]?.name ?? "this app")", selection: Binding(
                get: { settings.appProfiles[id]?.fingers ?? 0 },
                set: { settings.appProfiles[id]?.fingers = $0 == 0 ? nil : $0 })) {
                Text("Everyday fingers").tag(0)
                Divider()
                Text("1 finger").tag(1)
                Text("2 fingers").tag(2)
            }.labelsHidden().pickerStyle(.menu).fixedSize().help("How many fingers edge gestures take while this app is in front")
            Button("Edit…") { editingProfile = .app(id) }
            Button { settings.appProfiles.removeValue(forKey: id) } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove profile")
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private static func changeSummary(_ count: Int) -> String {
        count == 0 ? "Uses your everyday setup" : count == 1 ? "1 change" : "\(count) changes"
    }

    private static func profileSummary(_ profile: ActionProfile?) -> String {
        let count = profile?.bindings.count ?? 0
        guard let fingers = profile?.fingers else { return changeSummary(count) }
        let hand = fingers == 1 ? "1 finger" : "2 fingers"
        return count == 0 ? hand : "\(hand) · \(changeSummary(count))"
    }

    static func appIcon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    private func addProfileApp() {
        guard !preview else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add profile"
        panel.begin { response in
            guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            if settings.appProfiles[id] == nil {
                settings.appProfiles[id] = ActionProfile(name: url.deletingPathExtension().lastPathComponent)
            }
            editingProfile = .app(id)
        }
    }

    private var currentDeviceUID: String? { preview ? "preview-device" : VolumeController.shared.deviceUID }

    /// What clipboard history keeps. It runs only while a clipboard action
    /// is on an edge or corner, and forgets everything when Kinara quits.
    private var clipboardSection: some View {
        let running = preview || ClipboardHistory.shared.isEnabled
        return SettingsSection("Clipboard history", footer: running
                               ? "Type to search when the picker opens. ⌘1 to ⌘9 paste the first nine."
                               : "Put Clipboard history on an edge or corner, and Kinara starts keeping your copies.") {
            SettingRow("Keep") {
                Picker("Copies to keep", selection: $settings.clipboardLimit) {
                    ForEach(TrackpadSettings.clipboardLimits, id: \.self) { Text("\($0) copies").tag($0) }
                }.pickerStyle(.menu).fixedSize()
            }
            RowDivider()
            ToggleRow("Include images", detail: "Up to 256 MB of them; the oldest go first.", value: $settings.clipboardImages)
            RowDivider()
            SettingRow("Kept in memory, never on disk") {
                Button("Clear History") { if !preview { ClipboardHistory.shared.clear() } }
            }
        }
    }

    private var automationSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Automation", footer: settings.urlCommandsEnabled ? "For example kinara://pause?minutes=15 or kinara://volume?level=40. Links can’t change your setup." : nil) {
                ToggleRow("Kinara links", detail: "Let Shortcuts and scripts pause Kinara or set levels.", value: $settings.urlCommandsEnabled)
            }
            SettingsSection("Your settings", footer: transferMessage ?? "Move your setup, profiles included, to another Mac, or keep a backup.") {
                SettingRow("Settings file") {
                    HStack(spacing: 8) {
                        Button("Export…", action: exportSettings)
                        Button("Import…", action: importSettings)
                    }
                }
            }
        }
    }

    private func exportSettings() {
        guard !preview else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kinara Settings.plist"
        panel.allowedContentTypes = [.propertyList]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try settings.exportData().write(to: url, options: .atomic)
                transferMessage = "Saved to \(url.lastPathComponent)."
            } catch { transferMessage = "Could not save the settings file: \(error.localizedDescription)" }
        }
    }

    private func importSettings() {
        guard !preview else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.prompt = "Import"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try settings.importData(try Data(contentsOf: url))
                transferMessage = "Imported \(url.lastPathComponent). Login and setup choices on this Mac are unchanged."
            } catch let error as TrackpadSettings.ImportError {
                transferMessage = error.description
            } catch { transferMessage = "Could not read that file: \(error.localizedDescription)" }
        }
    }

    /// Live finger dots only while a page with a map is on screen.
    private func updateLiveView(_ value: SettingsPane) {
        guard !preview else { return }
        telemetry.isLiveViewing = value == .home || value == .edges
    }

    private func endTesting() {
        guard !preview, telemetry.isTesting else { return }
        monitor.cancelCurrentGesture()
        telemetry.isTesting = false
    }

    /// What the guide does: only macOS's own prompt, which adds Kinara to the
    /// list and has its own button to System Settings.
    private func askForAccessibility() {
        askedForAccess = true
        guard !preview else { return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private func openAccessibilitySettings() {
        guard !preview else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

}

/// Shared update controls for General settings and the focused update window.
struct UpdatePreferencesContent: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject private var installer = InAppUpdater.shared
    var preview = false
    var previewUpdateAvailable = false
    private var showsPreviewUpdate: Bool { preview && previewUpdateAvailable }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow("Check automatically", detail: "Once a day. Nothing installs without you.",
                      value: Binding(get: { updates.automaticallyChecks }, set: { if !preview { updates.automaticallyChecks = $0 } }))
            RowDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text(showsPreviewUpdate ? "A new version of Kinara is available." : updates.status).font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Update status: \(updates.status)")
                if let checked = updates.lastChecked {
                    Text("Last checked: \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if showsPreviewUpdate || (updates.updateAvailable && installer.isConfigured) {
                    SystemActionButton(title: installer.isBusy ? "Update in progress…" : "Install update…", isEnabled: !installer.isBusy) {
                        if !preview { installer.installUpdate() }
                    }.fixedSize()
                }
                HStack {
                    SystemActionButton(title: updates.isChecking ? "Checking…" : "Check now", isEnabled: !updates.isChecking) {
                        if !preview { updates.check() }
                    }.fixedSize()
                    SystemActionButton(title: updates.updateAvailable ? "View update…" : "GitHub Releases…") {
                        if !preview { updates.openReleasePage() }
                    }.fixedSize()
                }
                if let error = installer.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Updates are verified before they install, and Kinara restarts when you confirm.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12)
        }
    }
}

struct UpdateWindowView: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var settings: TrackpadSettings = .shared
    var preview = false
    var previewUpdateAvailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Software updates", systemImage: "arrow.down.circle")
                .font(.system(size: 21, weight: .semibold))
            UpdatePreferencesContent(updates: updates, preview: preview, previewUpdateAvailable: previewUpdateAvailable)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }.padding(24).frame(width: 440)
            .background(Color(nsColor: .windowBackgroundColor)).tint(.primary)
            .preferredColorScheme(settings.resolvedColorScheme)
    }
}

/// First launch is a real, focused window, not a hidden menu-bar popover.
private struct AccessibilityRecoveryHelp: View {
    var body: some View {
        DisclosureGroup("Already enabled, but gestures don’t work?") {
            Text("If Kinara is switched on in the list but gestures still don’t work, that entry belongs to an older copy. In Accessibility, remove the Kinara entry with −, then use + to add Kinara from Applications and switch it on. If macOS still reports the old state, quit and reopen Kinara once. Your other apps’ permissions stay untouched.")
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

/// First run, one calm step at a time. macOS's permission prompt appears
/// only when the person chooses Allow, never by surprise at launch, and the
/// guide notices the grant by itself while it is on screen.
struct GettingStartedView: View {
    enum Step: Int, CaseIterable { case welcome, access, tour, personalize, done }

    @ObservedObject var settings: TrackpadSettings
    @StateObject private var controls: ControlCenterModel
    @ObservedObject private var telemetry = GestureTelemetry.shared
    @ObservedObject private var monitor = TrackpadMonitor.shared
    @State private var step: Step
    @State private var requestedAccess = false
    /// When Allow was pressed, to recognize an old entry that never applies.
    @State private var requestedAt: Date?
    @State private var now = Date()
    /// The tour: its stops, which one is up, and whether that one was just done.
    @State private var tourSteps: [TourStep] = []
    @State private var tourIndex = 0
    @State private var tourSucceeded = false
    @State private var tourDone: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let preview: Bool
    private let animatesInPreview: Bool
    let openControls: () -> Void

    init(settings: TrackpadSettings = .shared, preview: Bool = false, hasAccess: Bool? = nil,
         previewStep: Step? = nil, animatesInPreview: Bool = false, openControls: @escaping () -> Void) {
        self.settings = settings
        self.preview = preview
        self.animatesInPreview = animatesInPreview
        self.openControls = openControls
        let controls = preview ? ControlCenterModel(settings: settings, preview: true) : .shared
        if preview, let hasAccess { controls.hasAccess = hasAccess }
        _controls = StateObject(wrappedValue: controls)
        _step = State(initialValue: previewStep ?? (preview && hasAccess == false ? .access : .welcome))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .access: access
                case .tour: tour
                case .personalize: personalize
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 36).padding(.vertical, 20)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            footer
        }
        .frame(width: 560, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(settings.resolvedColorScheme)
        .tint(.primary)
        .onChange(of: controls.hasAccess) { granted in
            // Granted in System Settings while the guide waits: move on by itself.
            guard granted, step == .access else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { go(to: .tour) }
        }
        .onChange(of: step) { value in setTouring(value == .tour) }
        .onReceive(NotificationCenter.default.publisher(for: .kinaraGestureUsed)) { note in tourSaw(note.object as? String) }
        .onAppear {
            // Someone new starts on Kinara's picks; an existing setup is never touched.
            if !preview, settings.offersRecommendedSetup { settings.applyRecommendedSetup(appAudio: AppVolumeController.isSupported) }
            if step == .tour { if preview { tourSteps = settings.tourSteps() } else { setTouring(true) } }
        }
        .background {
            if step == .access && !controls.hasAccess && !preview {
                // Checks once a second only while this step waits, even with
                // System Settings in front; gone as soon as access arrives.
                AccessWatcher { now = Date(); controls.refreshAccess() }
            }
        }
        .onDisappear { setTouring(false) }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            OnboardingTrackpad(animate: !reduceMotion && (!preview || animatesInPreview)).frame(width: 300, height: 190)
            VStack(spacing: 8) {
                Text("Meet Kinara").font(.system(size: 30, weight: .bold))
                Text("The edges of your trackpad become controls: volume, brightness, media, windows, and anything Shortcuts can do.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("hand.draw", "Slide an edge", settings.minimumFingers == 1 ? "One finger along the side, like a slider." : "Two fingers along the side, just like scrolling.")
                feature("hand.tap", "Tap a corner", "Double-tap to paste, open Mission Control, and more.")
                feature("waveform.path", "Feels built in", "Haptic notches, a native indicator, almost no battery.")
            }.frame(maxWidth: 400)
        }
    }

    private var access: some View {
        VStack(spacing: 20) {
            Image(systemName: controls.hasAccess ? "checkmark.seal.fill" : "hand.raised.fingers.spread")
                .font(.system(size: 40, weight: .regular))
                .frame(width: 88, height: 88)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentTransition(.opacity)
            VStack(spacing: 8) {
                Text(controls.hasAccess ? "You’re all set" : "Let Kinara feel your trackpad").font(.system(size: 24, weight: .bold))
                Text(controls.hasAccess ? "Accessibility is on. Let’s try a swipe."
                                        : "macOS asks you to allow Accessibility for apps that respond to gestures. Kinara uses it only to recognize edge swipes and keep them from scrolling.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430)
            }
            if !controls.hasAccess {
                VStack(alignment: .leading, spacing: 10) {
                    privacyLine("lock", "Touch data never leaves your Mac and is never saved.")
                    privacyLine("eye.slash", "Kinara never reads what you type, only that you’re typing.")
                    privacyLine("arrow.uturn.backward", "You can turn it off anytime in System Settings.")
                }.padding(16).frame(maxWidth: 430, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if requestedAccess {
                    if staleEntryLikely {
                        // Switched on, but for an older copy: macOS keeps the
                        // old entry and never applies it to this one.
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Already switched on, but nothing happens?", systemImage: "exclamationmark.circle")
                                .font(.system(size: 13, weight: .semibold))
                            Text("That entry belongs to an older copy of Kinara. In the list, select Kinara and click −. Then choose Allow Accessibility here and switch the new entry on.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Open Accessibility Settings", action: openAccessibilitySettings).buttonStyle(.bordered).controlSize(.small)
                        }
                        .padding(14).frame(maxWidth: 430, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Switch on Kinara in System Settings. This page continues by itself.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Button("No prompt? Open Accessibility Settings", action: openAccessibilitySettings)
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).underline()
                    }
                }
            }
        }
    }

    private var staleEntryLikely: Bool {
        guard let requestedAt, !controls.hasAccess else { return false }
        return now.timeIntervalSince(requestedAt) > 12
    }

    private func openAccessibilitySettings() {
        guard !preview else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// The screen stands in for the trackpad: each stop is lit on the matching
    /// screen edge or corner, and moves on once you've done it for real.
    private var tour: some View {
        VStack(spacing: 18) {
            if !controls.hasAccess && !preview {
                VStack(spacing: 8) {
                    Text("Try it later").font(.system(size: 24, weight: .bold))
                    Text("Gestures need Accessibility. Once it’s on, open Getting Started from Kinara’s menu to take the tour.")
                        .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430)
                }
            } else if let current = currentTourStep {
                VStack(spacing: 8) {
                    Text(tourSucceeded ? "Nice" : tourTitle(current)).font(.system(size: 26, weight: .bold))
                        .contentTransition(.opacity)
                    Text(tourDetail(current))
                        .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430, minHeight: 40, alignment: .top)
                }
                TourTrackpad(step: current, succeeded: tourSucceeded)
                Label("Watch \(current.place) of your screen: it shows where your finger goes.", systemImage: "rectangle.dashed")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    Text("You’ve got it").font(.system(size: 26, weight: .bold))
                    Text("That’s the whole idea. Rest a finger in a corner any time to see what it does, and change anything in Settings.")
                        .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430)
                }
                TourTrackpad(step: nil, succeeded: true)
            }
            if !tourSteps.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(tourSteps.enumerated()), id: \.offset) { index, item in
                        let done = tourDone.contains(item.slot)
                        Image(systemName: done ? "checkmark" : item.action.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.primary.opacity(done ? 0.14 : 0.05)))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(index == tourIndex ? 0.7 : 0), lineWidth: 1.5))
                            .foregroundStyle(done || index == tourIndex ? .primary : .secondary)
                            .accessibilityLabel("\(item.action.label), \(done ? "done" : index == tourIndex ? "now" : "next")")
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tourIndex)
            }
        }
    }

    private var currentTourStep: TourStep? { tourSteps.indices.contains(tourIndex) ? tourSteps[tourIndex] : nil }

    private func tourTitle(_ step: TourStep) -> String {
        switch step.kind {
        case .slide: return "Slide \(step.place)"
        case .doubleTap: return "Double-tap \(step.place)"
        case .tapHold: return "Tap and hold \(step.place)"
        }
    }

    private func tourDetail(_ step: TourStep) -> String {
        let fingers = settings.minimumFingers == 1 ? "one finger" : "two fingers"
        if tourSucceeded {
            if step.action.opensPanel { return "That’s \(step.action.label). Press esc to close it." }
            if step.action.undoesByRepeating { return "That’s \(step.action.label). Do it again to put it back." }
            return "That’s \(step.action.label), for real."
        }
        // "to change volume", "to open Clipboard history", "for Play / pause".
        let purpose = step.action.isContinuous ? "to change \(step.action.label.lowercased())"
                    : step.action.opensPanel ? "to open \(step.action.label)" : "for \(step.action.label)"
        switch step.kind {
        case let .slide(side): return "Put \(fingers) on the \(side) edge of your trackpad and slide up or down \(purpose)."
        case .doubleTap: return "Tap twice, quickly, \(step.region.hasSuffix("Corner") ? "in" : "on") \(step.place) of your trackpad \(purpose)."
        case .tapHold: return "Tap once in \(step.place) of your trackpad, then touch again and hold still \(purpose)."
        }
    }

    private var personalize: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Make it yours").font(.system(size: 24, weight: .bold))
                Text("You can change everything later in Settings.").font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(GesturePreset.allCases) { preset in
                    Button { settings.applyGesturePreset(preset) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: preset.icon).font(.system(size: 18))
                            Text(preset.title).font(.system(size: 13, weight: .semibold))
                            Text(preset.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading).padding(12)
                        .background(Color.primary.opacity(currentPreset == preset ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(currentPreset == preset ? 0.7 : 0.08), lineWidth: currentPreset == preset ? 1.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityAddTraits(currentPreset == preset ? [.isSelected] : [])
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Haptic strength").font(.system(size: 13, weight: .semibold))
                HStack {
                    Picker("Haptic strength", selection: $settings.hapticStyle) {
                        ForEach(HapticStyle.allCases) { style in Text(style.label).tag(style) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Button("Feel it") { if !preview { HapticOutput.shared.play(settings.hapticStyle) } }.buttonStyle(.bordered)
                }
                Text("Rest a finger on the trackpad, then press Feel it.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Corners").font(.system(size: 13, weight: .semibold))
                HStack(alignment: .firstTextBaseline) {
                    Text(cornerSummary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Use Kinara’s picks") { if !preview { settings.applyRecommendedSetup(appAudio: AppVolumeController.isSupported) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Indicator").font(.system(size: 13, weight: .semibold))
                Picker("Indicator", selection: $settings.osdStyle) {
                    Text("Pill").tag("horizontal"); Text("Follow finger").tag("edge"); Text("Off").tag("off")
                }.pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    private var done: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                Spacer()
                Image(nsImage: SwayGlyph.image(active: true)).renderingMode(.template)
                    .padding(7).background(Color.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Kinara menu bar icon")
                Image(systemName: "wifi").foregroundStyle(.secondary)
                Image(systemName: "battery.75percent").foregroundStyle(.secondary)
                Text("9:41").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(maxWidth: 420)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(spacing: 8) {
                Text("Kinara lives in your menu bar").font(.system(size: 24, weight: .bold))
                Text("Click Kinara’s icon for volume and brightness, quick options, and Settings. Scroll over it to change the volume.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430)
            }
            Button("Show me") { if !preview { (NSApp.delegate as? AppDelegate)?.revealMenuBar() } }.buttonStyle(.bordered)
            VStack(spacing: 0) {
                onboardingSwitch("Open Kinara when you log in", icon: "power", value: $settings.launchAtLogin)
                Divider().padding(.leading, 44)
                onboardingSwitch("Show in the Dock and ⌘-Tab while windows are open", icon: "dock.rectangle", value: $settings.showDockIcon)
            }
            .frame(maxWidth: 430)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: Footer

    // Three columns: side columns share the remaining width equally, so the
    // dots stay centered and no label can slide underneath them.
    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 18) {
                if step != .welcome {
                    Button("Back") { go(to: Step(rawValue: step.rawValue - 1) ?? .welcome) }
                }
                if step == .access && !controls.hasAccess {
                    Button("Skip for now") { go(to: .personalize) }
                }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(Color.primary.opacity(item == step ? 0.85 : 0.18))
                        .frame(width: item == step ? 18 : 7, height: 7)
                }
            }
            .fixedSize()
            .accessibilityElement().accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(MonochromePrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(Color.primary.opacity(0.025))
        .overlay(Divider(), alignment: .top)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .access: return controls.hasAccess ? "Continue" : "Allow Accessibility"
        case .tour: return currentTourStep == nil || !controls.hasAccess ? "Continue" : "Skip"
        case .personalize: return "Continue"
        case .done: return "Done"
        }
    }

    private func primaryAction() {
        switch step {
        case .welcome: go(to: controls.hasAccess ? .tour : .access)
        case .access:
            if controls.hasAccess { go(to: .tour); return }
            requestedAccess = true
            requestedAt = Date()
            guard !preview else { return }
            // One system surface per press: macOS's own prompt, which adds
            // Sway to the list and has its own button to System Settings.
            // If macOS doesn't show it again, the link below opens Settings.
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .tour:
            if currentTourStep == nil || !controls.hasAccess { go(to: .personalize) } else { advanceTour() }
        case .personalize: go(to: .done)
        case .done: openControls()
        }
    }

    private func go(to next: Step) {
        if reduceMotion { step = next } else { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = next } }
    }

    // MARK: Helpers

    /// What each corner's double-tap does, in a line.
    private var cornerSummary: String {
        let names = [("topLeftCorner", "Top left"), ("topRightCorner", "Top right"), ("bottomLeftCorner", "Bottom left"), ("bottomRightCorner", "Bottom right")]
        let set = names.compactMap { slot, name -> String? in
            let action = settings.baseBinding("\(slot).doubleTap").action
            return action == .disabled ? nil : "\(name): \(action.label)"
        }
        return set.isEmpty ? "No corner taps yet. Kinara’s picks put the clipboard, app audio, play/pause and Mission Control there." : set.joined(separator: " · ")
    }

    private var currentPreset: GesturePreset {
        if settings.minimumFingers == 1 { return .oneFinger }
        return settings.palmRejectionMode == "strict" ? .precise : .everyday
    }

    /// The tour uses Kinara for real (not the safe test), so each gesture does what it will every day.
    private func setTouring(_ on: Bool) {
        guard !preview else { return }
        if on {
            tourSteps = settings.tourSteps()
            tourIndex = 0
            tourDone = []
            tourSucceeded = false
            if telemetry.isTesting { monitor.cancelCurrentGesture(); telemetry.isTesting = false }
            if controls.hasAccess, settings.isEnabled { monitor.start() }
            showTourGuide()
        } else {
            TourGuide.shared.hide()
        }
    }

    private func showTourGuide() {
        guard !preview, step == .tour, controls.hasAccess, let current = currentTourStep else { TourGuide.shared.hide(); return }
        let screen = NSApp.windows.first { $0.identifier?.rawValue == "Sway.Welcome" }?.screen
        TourGuide.shared.show(current, on: screen)
    }

    /// A gesture done for real: if it's this stop's, celebrate, then move on.
    private func tourSaw(_ slot: String?) {
        guard step == .tour, !tourSucceeded, let current = currentTourStep, slot == current.slot else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { tourSucceeded = true }
        TourGuide.shared.succeed()
        DispatchQueue.main.asyncAfter(deadline: .now() + (current.action.opensPanel ? 2.2 : 1.3)) { [current] in
            guard step == .tour, currentTourStep == current else { return }
            advanceTour()
        }
    }

    private func advanceTour() {
        if let current = currentTourStep, tourSucceeded { tourDone.insert(current.slot) }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            tourSucceeded = false
            tourIndex += 1
        }
        showTourGuide()
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func onboardingSwitch(_ title: String, icon: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 20)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func privacyLine(_ icon: String, _ text: String) -> some View {
        Label { Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: icon).frame(width: 18)
        }
    }
}

private struct AccessWatcher: View {
    let tick: () -> Void
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View { Color.clear.onReceive(timer) { _ in tick() } }
}

/// The welcome illustration: a finger glides up the right edge while the
/// level fills. The loop is attached only to those two shapes and starts
/// after the window's first layout; a looping transaction started during
/// layout would make every other view in the window animate forever too.
private struct OnboardingTrackpad: View {
    let animate: Bool
    @State private var raised = false
    private static let loop = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.05))
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                Rectangle().fill(Color.primary.opacity(0.09)).frame(width: width * 0.2, height: height)
                    .offset(x: width * 0.8)
                Rectangle().fill(Color.primary.opacity(0.05)).frame(width: width * 0.2, height: height)
                HStack(spacing: 6) {
                    Circle().fill(Color.primary.opacity(0.85)).frame(width: 18, height: 18)
                    Circle().fill(Color.primary.opacity(0.85)).frame(width: 18, height: 18)
                }
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .offset(x: width * 0.83, y: raised ? height * 0.18 : height * 0.68)
                .animation(animate ? Self.loop : nil, value: raised)
                // The level the swipe is changing.
                VStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 13, weight: .semibold))
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.primary.opacity(0.12)).frame(width: 6, height: 70)
                        Capsule().fill(Color.primary.opacity(0.85)).frame(width: 6, height: raised ? 60 : 18)
                            .animation(animate ? Self.loop : nil, value: raised)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .offset(x: width * 0.42, y: height * 0.2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .accessibilityHidden(true)
        .onAppear {
            guard animate else { raised = true; return }
            // Next run-loop pass: the window has its final size and appearance.
            DispatchQueue.main.async { raised = true }
        }
    }
}


/// The trackpad as a chooser. Each edge is a rail along the side, labeled
/// with what it does; each corner is a button. The chosen one glows like
/// Kinara's edge light, and its real area shows faintly behind it, so its
/// width or size reads too. Hovering names a spot in the middle.
private struct TrackpadMap: View {
    @ObservedObject var settings: TrackpadSettings
    let selectedZone: String?
    @ObservedObject var telemetry: GestureTelemetry
    let showsTouches: Bool
    let onSelect: ((String) -> Void)?
    var showsCorners = false
    @State private var trail: [CGPoint] = []
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let radius: CGFloat = 20
    private let inset: CGFloat = 12
    private let button: CGFloat = 30
    private static let corners = ["topLeftCorner", "topRightCorner", "bottomLeftCorner", "bottomRightCorner"]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(surface)
                footprint(in: size)
                caption.frame(width: size.width, height: size.height).allowsHitTesting(false)
                ForEach(edgeKeys, id: \.self) { key in edge(key, in: size) }
                if showsCorners {
                    ForEach(Self.corners, id: \.self) { key in corner(key, in: size) }
                }
                if showsTouches { touches(in: size) }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(rim, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.1), radius: 18, y: 9)
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.06), radius: 2, y: 1)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: selectedZone)
        .onChange(of: telemetry.sampleCount) { count in
            guard showsTouches else { return }
            if count <= 1 { trail.removeAll(keepingCapacity: true) }
            if telemetry.fingerCount > 0 {
                trail.append(CGPoint(x: telemetry.x, y: telemetry.y))
                if trail.count > 80 { trail.removeFirst(trail.count - 80) }
            }
        }
        .onChange(of: showsTouches) { _ in trail.removeAll() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trackpad gesture map")
    }

    /// Side edges always; top and bottom once they're on. The top's two halves are one spot.
    private var edgeKeys: [String] {
        ["left", "right"] + (settings.topEdgeEnabled ? ["top"] : []) + (settings.bottomEdgeEnabled ? ["bottom"] : [])
    }

    /// Brushed glass, a little lighter at the top as if lit from above.
    private var surface: LinearGradient {
        LinearGradient(colors: scheme == .dark ? [Color(white: 0.24), Color(white: 0.185)] : [Color(white: 1), Color(white: 0.94)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var rim: LinearGradient {
        LinearGradient(colors: scheme == .dark ? [Color.white.opacity(0.2), Color.white.opacity(0.05)] : [Color.black.opacity(0.05), Color.black.opacity(0.13)],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: Edges

    private func edgeFrame(_ key: String, in size: CGSize) -> CGRect {
        // Clear of the corner buttons, so every spot has its own target.
        let reach = inset + button + 6
        let band: CGFloat = 46
        switch key {
        case "left": return CGRect(x: 0, y: reach, width: size.width * 0.34, height: size.height - reach * 2)
        case "right": return CGRect(x: size.width * 0.66, y: reach, width: size.width * 0.34, height: size.height - reach * 2)
        case "top": return CGRect(x: reach, y: 0, width: size.width - reach * 2, height: band)
        default: return CGRect(x: reach, y: size.height - band, width: size.width - reach * 2, height: band)
        }
    }

    private func isLive(_ key: String) -> Bool {
        guard showsTouches else { return false }
        let zone = telemetry.activeZone
        return zone == key || (key == "top" && (zone == "topLeft" || zone == "topRight"))
    }

    /// What an edge's label says: one action, or the top's two halves.
    private func labels(_ key: String) -> [ZoneAction] {
        switch key {
        case "left": return [settings.leftZoneAction]
        case "right": return [settings.rightZoneAction]
        case "bottom": return [settings.bottomEdgeAction]
        default:
            return settings.topEdgeSwipeDirection == "horizontal" ? [settings.topLeftAction, settings.topRightAction] : [settings.topEdgeAction]
        }
    }

    private func edge(_ key: String, in size: CGSize) -> some View {
        let frame = edgeFrame(key, in: size)
        let horizontal = key == "top" || key == "bottom"
        let on = selectedZone == key
        let live = isLive(key)
        let lit = hovered == key && onSelect != nil
        let side: Edge.Set = key == "left" ? .leading : key == "right" ? .trailing : key == "top" ? .top : .bottom
        let alignment: Alignment = key == "left" ? .leading : key == "right" ? .trailing : key == "top" ? .top : .bottom
        let actions = labels(key)
        return ZStack(alignment: alignment) {
            Color.clear
            Capsule()
                .fill(on || live ? Color.accentColor : Color.primary.opacity(lit ? 0.3 : 0.15))
                .frame(width: horizontal ? frame.width : 4, height: horizontal ? 4 : frame.height)
                .shadow(color: on || live ? Color.accentColor.opacity(0.9) : .clear, radius: 5)
                .shadow(color: on || live ? Color.accentColor.opacity(0.45) : .clear, radius: 14)
                .padding(side, 6)
            Group {
                if horizontal && actions.count == 2 {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        chip(actions[0], on: on, lit: lit)
                        Spacer(minLength: 0)
                        Spacer(minLength: 0)
                        chip(actions[1], on: on, lit: lit)
                        Spacer(minLength: 0)
                    }
                } else {
                    chip(actions[0], on: on, lit: lit)
                }
            }
            .padding(side, horizontal ? 16 : 18)
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?(key) }
        .onHover { inside in hover(key, inside) }
        .offset(x: frame.minX, y: frame.minY)
        .allowsHitTesting(onSelect != nil)
        .accessibilityElement()
        .accessibilityLabel("\(EdgeSlot.title(key)): \(actions.map(\.label).joined(separator: ", "))")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect?(key) }
        .help("\(EdgeSlot.title(key)) · click to change")
    }

    private func chip(_ action: ZoneAction, on: Bool, lit: Bool) -> some View {
        let assigned = action != .disabled
        return HStack(spacing: 5) {
            Image(systemName: assigned ? action.icon : "plus").font(.system(size: 10, weight: .semibold))
            Text(assigned ? action.label : "Add").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(on ? Color.white : assigned ? Color.primary : Color.secondary)
        .padding(.horizontal, 9).frame(height: 24)
        .frame(maxWidth: 132)
        .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(lit ? 0.12 : 0.065)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.06), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Corners

    private func corner(_ key: String, in size: CGSize) -> some View {
        let tap = settings.baseBinding(EdgeSlot.tap(key, "doubleTap")).action
        let hold = settings.baseBinding(EdgeSlot.tap(key, "tapHold")).action
        let shown = tap != .disabled ? tap : hold
        let assigned = shown != .disabled
        let on = selectedZone == key
        let lit = hovered == key && onSelect != nil
        let x = key.contains("Right") ? size.width - inset - button : inset
        let y = key.hasPrefix("bottom") ? size.height - inset - button : inset
        return Image(systemName: assigned ? shown.icon : "plus")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(on ? Color.white : assigned ? Color.primary.opacity(0.85) : Color.secondary.opacity(lit ? 1 : 0.55))
            .frame(width: button, height: button)
            .background(Circle().fill(on ? Color.accentColor
                                      : Color.primary.opacity(assigned ? (lit ? 0.15 : 0.085) : (lit ? 0.09 : 0.035))))
            .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0 : 0.07), lineWidth: 1))
            .shadow(color: on ? Color.accentColor.opacity(0.75) : .clear, radius: 8)
            .contentShape(Circle().inset(by: -6))
            .onTapGesture { onSelect?(key) }
            .onHover { inside in hover(key, inside) }
            .offset(x: x, y: y)
            .allowsHitTesting(onSelect != nil)
            .accessibilityElement()
            .accessibilityLabel("\(EdgeSlot.title(key)): \(shown.label)")
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect?(key) }
            .help("\(EdgeSlot.title(key)) · click to set its taps")
    }

    // MARK: Footprint, caption, touches

    /// Where the chosen spot really is on your trackpad, at its real size.
    @ViewBuilder private func footprint(in size: CGSize) -> some View {
        if let spot = selectedZone, let rect = area(of: spot, in: size) {
            RoundedRectangle(cornerRadius: min(12, rect.width / 2, rect.height / 2), style: .continuous)
                .fill(Color.accentColor.opacity(scheme == .dark ? 0.2 : 0.11))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func area(of spot: String, in size: CGSize) -> CGRect? {
        let top = settings.topEdgeEnabled ? size.height * settings.topEdgeHeight : 0
        let bottom = settings.bottomEdgeEnabled ? size.height * settings.bottomEdgeHeight : 0
        switch spot {
        case "left":
            return CGRect(x: 0, y: top, width: max(3, size.width * settings.leftZoneWidth), height: size.height - top - bottom)
        case "right":
            let width = max(3, size.width * settings.rightZoneWidth)
            return CGRect(x: size.width - width, y: top, width: width, height: size.height - top - bottom)
        case "top":
            return CGRect(x: 0, y: 0, width: size.width, height: max(3, top))
        case "bottom":
            return CGRect(x: 0, y: size.height - max(3, bottom), width: size.width, height: max(3, bottom))
        default:
            guard spot.hasSuffix("Corner") else { return nil }
            let width = size.width * settings.tapCornerSize, height = size.height * settings.tapCornerSize
            return CGRect(x: spot.contains("Right") ? size.width - width : 0, y: spot.hasPrefix("bottom") ? size.height - height : 0,
                          width: width, height: height)
        }
    }

    private var caption: some View {
        VStack(spacing: 3) {
            if let key = hovered {
                Text(EdgeSlot.title(key)).font(.system(size: 12, weight: .semibold))
                Text(summary(key)).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Point & scroll").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func summary(_ key: String) -> String {
        if key.hasSuffix("Corner") {
            let tap = settings.baseBinding(EdgeSlot.tap(key, "doubleTap")).action
            let hold = settings.baseBinding(EdgeSlot.tap(key, "tapHold")).action
            if tap != .disabled { return "Double-tap: \(tap.label)" }
            if hold != .disabled { return "Tap and hold: \(hold.label)" }
            return "Nothing yet"
        }
        let actions = labels(key).filter { $0 != .disabled }
        return actions.isEmpty ? "Nothing yet" : "Slide: " + actions.map(\.label).joined(separator: " · ")
    }

    @ViewBuilder private func touches(in size: CGSize) -> some View {
        Path { path in
            for (index, point) in trail.enumerated() {
                let position = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
        }
        .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
        if telemetry.fingerCount > 0 {
            Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: Color.accentColor.opacity(0.6), radius: 6)
                .position(x: telemetry.x * size.width, y: (1 - telemetry.y) * size.height)
                .allowsHitTesting(false)
        }
    }

    private func hover(_ key: String, _ inside: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if inside { hovered = key } else if hovered == key { hovered = nil }
        }
    }
}

/// A chosen spot, drawn small: a white trackpad on an accent tile, the spot lit.
private struct SpotGlyph: View {
    let spot: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor], startPoint: .top, endPoint: .bottom))
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.75), lineWidth: 1.4)
                mark.padding(3.5)
            }
            .frame(width: 26, height: 18)
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }
    private var alignment: Alignment {
        switch spot {
        case "left": return .leading
        case "right": return .trailing
        case "top": return .top
        case "bottom": return .bottom
        case "topLeftCorner": return .topLeading
        case "topRightCorner": return .topTrailing
        case "bottomLeftCorner": return .bottomLeading
        default: return .bottomTrailing
        }
    }
    @ViewBuilder private var mark: some View {
        switch spot {
        case "left", "right": Capsule().fill(Color.white).frame(width: 2.5, height: 9)
        case "top", "bottom": Capsule().fill(Color.white).frame(width: 13, height: 2.5)
        default: Circle().fill(Color.white).frame(width: 4.5, height: 4.5)
        }
    }
}

// MARK: - Consistent settings primitives

/// The page behind the grouped cards: Apple's grouped background, a step
/// darker than the cards in light mode and a step darker still in dark.
private struct GroupedBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { scheme == .dark ? Color(white: 0.115) : Color(white: 0.955) }
}

/// One surface for every card: the grouped cell color, continuous corners and a hairline.
private struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(scheme == .dark ? Color(white: 0.17) : Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.07 : 0.06), lineWidth: 1))
    }
}

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View { content.padding(15).modifier(CardSurface()) }
}

private extension View { func swayCard() -> some View { modifier(CardModifier()) } }

/// The sidebar's own translucent material, as in System Settings.
private struct SidebarMaterial: View {
    let preview: Bool
    var body: some View {
        if preview {
            // Offscreen captures can't see behind the window; this is the material's resting tone.
            Color.primary.opacity(0.035)
        } else {
            SidebarEffect()
        }
    }
}

private struct SidebarEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A page's sidebar icon: a white symbol on its own colored tile.
private struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: pane.icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [pane.colors.top, pane.colors.bottom], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
    }
}

/// A status in one glance: a white symbol on a colored disc.
private struct StatusGlyph: View {
    let icon: String
    let color: Color
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .top, endPoint: .bottom)))
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused).accessibilityLabel("Find a setting")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(focused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.05), lineWidth: focused ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { focused = true }
        // Opening Settings shouldn't put the cursor in the search field.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = false } }
    }
}

/// Options most people never need, in a sheet of their own.
private struct AdvancedSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text("Advanced").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
            Divider()
            ScrollView {
                content().padding(.horizontal, 22).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }.padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(width: 560, height: 580)
        .background(GroupedBackground())
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct Notice: View {
    let text: String
    let icon: String
    let tint: Color
    init(_ text: String, icon: String, tint: Color) { self.text = text; self.icon = icon; self.tint = tint }
    var body: some View {
        Label { Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(tint) }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .modifier(CardSurface())
    }
}

/// A heading, one card of rows, and an optional note under it.
private struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: () -> Content
    init(_ title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.footer = footer; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !title.isEmpty {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 2)
            }
            SettingsCard(content: content)
            if let footer, !footer.isEmpty {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

/// Rows are separated by an inset hairline, as in System Settings.
/// The light's colours as swatches, like macOS's own accent colour picker:
/// the chosen one has a dot, and its name sits beside the row.
private struct EdgeLightSwatches: View {
    @Binding var selection: EdgeLightColor
    var body: some View {
        HStack(spacing: 6) {
            Text(selection.label).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(EdgeLightColor.allCases) { option in
                Button { selection = option } label: {
                    Circle().fill(Self.fill(option))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                        .overlay(Circle().fill(option == .mono ? Color.black.opacity(0.55) : Color.white)
                            .frame(width: 6, height: 6).opacity(selection == option ? 1 : 0))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel("\(option.label) light")
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
    }

    private static func fill(_ option: EdgeLightColor) -> AnyShapeStyle {
        if option == .byAction {
            // Each action's own colour: sound, brightness, the microphone, media.
            let tints: [NSColor] = [.systemBlue, .systemYellow, .systemGreen, .systemPink, .systemBlue]
            return AnyShapeStyle(AngularGradient(colors: tints.map { Color(nsColor: $0) }, center: .center))
        }
        let colors = option.colors().map { Color(nsColor: $0) }
        return colors.count == 1 ? AnyShapeStyle(colors[0])
                                 : AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

private struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control
    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) { self.title = title; self.detail = detail; self.control = control }
    var body: some View {
        // Side by side when it fits; otherwise the control moves under its
        // title instead of running past the card's edge.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                control().labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                control().labelsHidden()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 38)
    }
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13))
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var value: Bool
    init(_ title: String, detail: String? = nil, value: Binding<Bool>) { self.title = title; self.detail = detail; _value = value }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            // The switch sits at the trailing edge, like System Settings.
            Toggle(title, isOn: $value).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 38)
    }
}

private struct LabeledSlider: View {
    let title: String
    let detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    init(_ title: String, detail: String? = nil, value: Binding<Double>, range: ClosedRange<Double>, display: String) {
        self.title = title; self.detail = detail; _value = value; self.range = range; self.display = display
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 13)).fixedSize()
                Spacer(minLength: 12)
                Slider(value: $value, in: range).controlSize(.small).frame(maxWidth: 220)
                    .accessibilityLabel(title).accessibilityValue(display)
                Text(display).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 38)
    }
}

private struct ActionPicker: View {
    @Binding var action: ZoneAction
    let label: String
    var tapOnly = false
    @State private var showsLibrary = false
    @State private var hovering = false
    var body: some View {
        Button { showsLibrary = true } label: {
            HStack(spacing: 6) {
                if action != .disabled {
                    Image(systemName: action.icon).font(.system(size: 11, weight: .medium)).frame(width: 14)
                }
                Text(action.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .foregroundStyle(action == .disabled ? Color.secondary : Color.primary)
            .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.055)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(label): \(action.label)")
        .help("Choose what this does")
        .popover(isPresented: $showsLibrary, arrowEdge: .bottom) {
            EdgeActionLibrary(action: $action, edgeName: label, tapOnly: tapOnly, close: { showsLibrary = false })
        }
    }
}

/// Every action in a compact grid, one category at a time, like the Shortcuts
/// action library. It opens on the current action's category, search reaches
/// all of them, and pointing at a tile says what it does. A click chooses and closes.
struct EdgeActionLibrary: View {
    @Binding var action: ZoneAction
    let edgeName: String
    var tapOnly = false
    var preview = false
    var close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category: String
    @State private var hovered: ZoneAction?
    @State private var unavailable: [ZoneAction: String] = [:]
    @FocusState private var searching: Bool

    static let categories = ZoneAction.categories.filter { $0 != "Other" }

    init(action: Binding<ZoneAction>, edgeName: String, tapOnly: Bool = false, preview: Bool = false, close: (() -> Void)? = nil) {
        _action = action
        self.edgeName = edgeName
        self.tapOnly = tapOnly
        self.preview = preview
        self.close = close
        let current = action.wrappedValue.category
        _category = State(initialValue: Self.categories.contains(current) ? current : Self.categories[0])
    }

    private var shown: [ZoneAction] {
        let terms = search.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return ZoneAction.allCases.filter { $0.category == category } }
        return ZoneAction.allCases.filter { item in
            item != .disabled && terms.allSatisfy {
                "\(item.label) \(item.category) \(item.guidance)".localizedCaseInsensitiveContains(String($0))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 160)
                Divider()
                grid
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 470)
        .onAppear {
            guard !preview else { return }
            DispatchQueue.main.async { searching = true }
            VolumeController.microphone.refresh()
            KeyboardBacklightCapability.shared.refresh()
            refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .swayInputStateChanged)) { _ in refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: .swayAudioStateChanged)) { _ in refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: .swayKeyboardCapabilityChanged)) { _ in refreshAvailability() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(edgeName).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("Search actions", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                    .focused($searching)
                    .accessibilityLabel("Search edge actions")
                    // Return takes the first match.
                    .onSubmit { if let first = shown.first(where: { unavailable[$0] == nil }) { choose(first) } }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            .frame(width: 250)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.categories, id: \.self) { item in
                let on = search.isEmpty && category == item
                Button {
                    search = ""
                    category = item
                } label: {
                    HStack(spacing: 8) {
                        CategoryTile(category: item)
                        Text(CategoryTile.name(item)).font(.system(size: 13)).lineLimit(1)
                            .foregroundStyle(on ? Color.white : Color.primary)
                        Spacer(minLength: 0)
                        // Where the current choice lives.
                        if action.category == item && action != .disabled {
                            Circle().fill(on ? Color.white : Color.accentColor).frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.primary.opacity(0.025))
    }

    private var grid: some View {
        ScrollView {
            if shown.isEmpty {
                VStack(spacing: 6) {
                    Text("No actions match “\(search)”").font(.system(size: 13, weight: .semibold))
                    Text("Try microphone, tabs, zoom or paste.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 90)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(shown) { item in tile(item) }
            }
            .padding(12)
        }
    }

    private func tile(_ item: ZoneAction) -> some View {
        let on = action == item
        let blocked = unavailable[item] != nil
        let lit = hovered == item && !blocked
        return Button { choose(item) } label: {
            VStack(spacing: 7) {
                Image(systemName: item.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(LinearGradient(colors: [CategoryTile.colors(item.category).top, CategoryTile.colors(item.category).bottom],
                                                             startPoint: .top, endPoint: .bottom)))
                Text(item.label).font(.system(size: 11.5, weight: .medium))
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
            }
            .padding(.top, 12).padding(.bottom, 8).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(lit ? 0.08 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                if on {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor).padding(6)
                } else if blocked {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.secondary).padding(6)
                }
            }
            .opacity(blocked ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) {
                if inside { hovered = item } else if hovered == item { hovered = nil }
            }
        }
        .accessibilityLabel(item.label)
        .accessibilityHint(unavailable[item] ?? item.guidance)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// What the action under the pointer does, or the current choice.
    private var footer: some View {
        let item = hovered ?? (action != .disabled ? action : nil)
        return HStack(spacing: 10) {
            if let item {
                Image(systemName: item.icon).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.system(size: 12.5, weight: .semibold))
                    Text(unavailable[item] ?? item.guidance).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Point at an action to see what it does.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if action != .disabled {
                Button("Turn Off") { choose(.disabled) }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }

    private func choose(_ item: ZoneAction) {
        guard unavailable[item] == nil else { return }
        action = item
        if let close { close() } else { dismiss() }
    }

    private func refreshAvailability() {
        guard !preview else { return }
        var next: [ZoneAction: String] = [:]
        if !VolumeController.microphone.isAvailable { next[.microphoneLevel] = "The current input has no writable gain control. Select a compatible input in macOS Sound settings." }
        if !VolumeController.microphone.supportsMute { next[.microphoneMute] = "The current input has no verified hardware mute control. Kinara never substitutes gain zero or claims to mute other microphones." }
        if !VolumeController.shared.supportsMute { next[.outputMute] = "The current output has no hardware mute control. Volume remains available on compatible outputs." }
        if !KeyboardBacklightCapability.shared.isAvailable { next[.keyboardBrightness] = KeyboardBacklightCapability.shared.checked ? "No supported backlit keyboard detected. This uses a private read-only capability API that can change with macOS." : "Checking keyboard support…" }
        if !AppVolumeController.isSupported {
            next[.appVolume] = "App volume needs macOS 14.2 or later."
            next[.muteApp] = "Muting one app needs macOS 14.2 or later."
            next[.soloApp] = "Solo needs macOS 14.2 or later."
        }
        if !NightShiftController.shared.isAvailable { next[.nightShift] = "Night Shift isn’t available on this Mac, or macOS changed its private interface." }
        if !TrueToneController.shared.isAvailable { next[.trueTone] = "No display with True Tone is connected." }
        if !ShortcutsRunner.isAvailable { next[.runShortcut] = "The Shortcuts command-line tool isn’t available on this Mac." }
        unavailable = next
    }
}

/// An action category's own color and symbol, as in the Shortcuts library.
private struct CategoryTile: View {
    let category: String
    var size: CGFloat = 20
    var body: some View {
        Image(systemName: Self.icon(category))
            .font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Self.colors(category).top, Self.colors(category).bottom], startPoint: .top, endPoint: .bottom)))
    }
    /// One word each, so the list reads at a glance.
    static func name(_ category: String) -> String {
        switch category {
        case "Display & keyboard": return "Display"
        case "Audio & microphone": return "Sound"
        case "Windows & desktops": return "Windows"
        case "Tools & shortcuts": return "Tools"
        default: return category
        }
    }
    static func icon(_ category: String) -> String {
        switch category {
        case "Display & keyboard": return "sun.max.fill"
        case "Audio & microphone": return "speaker.wave.2.fill"
        case "Media": return "play.fill"
        case "Editing": return "doc.on.clipboard.fill"
        case "Navigation": return "arrow.left.arrow.right"
        case "Windows & desktops": return "macwindow.on.rectangle"
        case "Tools & shortcuts": return "wrench.and.screwdriver.fill"
        default: return "circle.slash"
        }
    }
    static func colors(_ category: String) -> (top: Color, bottom: Color) {
        switch category {
        case "Display & keyboard": return (Color(red: 1, green: 0.78, blue: 0.25), Color(red: 1, green: 0.57, blue: 0.02))
        case "Audio & microphone": return (Color(red: 1, green: 0.45, blue: 0.55), Color(red: 0.96, green: 0.19, blue: 0.34))
        case "Media": return (Color(red: 0.86, green: 0.5, blue: 1), Color(red: 0.69, green: 0.27, blue: 0.92))
        case "Editing": return (Color(red: 0.36, green: 0.64, blue: 1), Color(red: 0.04, green: 0.45, blue: 0.98))
        case "Navigation": return (Color(red: 0.32, green: 0.83, blue: 0.79), Color(red: 0.08, green: 0.64, blue: 0.62))
        case "Windows & desktops": return (Color(red: 0.52, green: 0.54, blue: 1), Color(red: 0.34, green: 0.33, blue: 0.91))
        case "Tools & shortcuts": return (Color(red: 0.4, green: 0.84, blue: 0.5), Color(red: 0.16, green: 0.67, blue: 0.32))
        default: return (Color(white: 0.68), Color(white: 0.52))
        }
    }
}

/// A Control Center–style switch: a disc that fills with the accent color when on.
private struct QuickTile: View {
    let title: String
    let value: String
    let icon: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .background(Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.09)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(value).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .modifier(CardSurface())
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .animation(.easeInOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title).accessibilityValue(value).accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// One slot: an action plus whatever that action needs (recorded keys or
/// Shortcut names). Used for layers, taps, top and bottom edges, and profiles.
private struct SlotEditor: View {
    let title: String
    @Binding var binding: EdgeBinding
    var detail: String? = nil
    var tapOnly = false
    /// Side edges set to Custom shortcut fall back to the shared pair.
    var sharedFallback = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let detail = detail ?? (tapOnly && binding.action.slidesAfterTap ? "Tap, then slide along that side to adjust." : nil) {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                ActionPicker(action: $binding.action, label: title, tapOnly: tapOnly)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 38)
            BindingExtras(binding: $binding, sharedFallback: sharedFallback, tap: tapOnly)
        }
    }
}

private struct BindingExtras: View {
    @Binding var binding: EdgeBinding
    var sharedFallback: Bool
    var tap = false
    var body: some View {
        if binding.action == .customShortcut {
            VStack(alignment: .leading, spacing: 0) {
                HotkeyRecorder(hotkey: $binding.up, title: tap ? "Shortcut" : "Up / right shortcut",
                               detail: sharedFallback && binding.up.isEmpty && binding.down.isEmpty ? "Uses the shared pair until you record one here." : "Sent once, to the app in front.",
                               showsRegistrationError: false)
                if !tap {
                    HotkeyRecorder(hotkey: $binding.down, title: "Down / left shortcut", detail: "Sent once, to the app in front.", showsRegistrationError: false)
                }
            }.background(Color.primary.opacity(0.025))
        } else if binding.action == .runShortcut {
            VStack(alignment: .leading, spacing: 8) {
                ShortcutNameField(title: tap ? "Shortcut" : "Up / right", name: $binding.shortcut)
                if !tap { ShortcutNameField(title: "Down / left", name: $binding.downShortcut, placeholder: "Same as up / right") }
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}

private struct ShortcutNameField: View {
    let title: String
    @Binding var name: String
    var placeholder = "Shortcut name"
    @State private var names: [String] = []
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            TextField(placeholder, text: $name).textFieldStyle(.roundedBorder).font(.system(size: 12))
            Menu {
                if names.isEmpty { Text("No Shortcuts found") }
                ForEach(names, id: \.self) { item in Button(item) { name = item } }
            } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize().help("Choose from your Shortcuts")
        }
        .onAppear { ShortcutsRunner.list { names = $0 } }
    }
}

private struct FavoriteLevelRow: View {
    let action: ZoneAction
    @Binding var favorite: Double
    let current: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { favorite >= 0 }, set: { favorite = $0 ? max(0, min(1, current)) : -1 })) {
                Text("Favorite \(action.label.lowercased())").font(.system(size: 13))
            }.toggleStyle(.switch).controlSize(.small)
            if favorite >= 0 {
                HStack {
                    Slider(value: Binding(get: { favorite }, set: { favorite = ($0 * 100).rounded() / 100 }), in: 0...1)
                        .accessibilityLabel("Favorite \(action.label)").accessibilityValue("\(Int(favorite * 100)) percent")
                    Text("\(Int((favorite * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 38)
                    Button("Use current") { favorite = max(0, min(1, (current * 100).rounded() / 100)) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 9)
    }
}

enum ProfileTarget: Identifiable, Equatable {
    case app(String), docked
    var id: String { if case let .app(bundle) = self { return bundle }; return "docked" }
}

struct ProfileEditor: View {
    @ObservedObject var settings: TrackpadSettings
    let target: ProfileTarget
    @Environment(\.dismiss) private var dismiss

    private var name: String {
        if case let .app(bundle) = target { return settings.appProfiles[bundle]?.name ?? bundle }
        return "Docked"
    }
    private var groups: [(title: String, slots: [String], taps: Bool)] {
        var swipes = ["left", "right"]
        if settings.topEdgeEnabled { swipes += settings.topEdgeSwipeDirection == "horizontal" ? ["topLeft", "topRight"] : ["top"] }
        if settings.bottomEdgeEnabled { swipes.append("bottom") }
        return [("Swipes", swipes, false),
                ("Layers", EdgeSlot.sides.map(EdgeSlot.option) + EdgeSlot.sides.map(EdgeSlot.alternate), false),
                ("Taps", EdgeSlot.allTaps.filter { settings.slotIsAssigned($0) || override(for: $0) != nil || $0.hasPrefix("left") || $0.hasPrefix("right") }, true)]
    }

    private func override(for slot: String) -> EdgeBinding? {
        switch target {
        case let .app(bundle): return settings.appProfiles[bundle]?.bindings[slot]
        case .docked: return settings.dockedProfile.bindings[slot]
        }
    }
    private func setOverride(_ binding: EdgeBinding?, for slot: String) {
        switch target {
        case let .app(bundle): settings.appProfiles[bundle]?.bindings[slot] = binding
        case .docked: settings.dockedProfile.bindings[slot] = binding
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if case let .app(bundle) = target { Image(nsImage: ContentView.appIcon(bundle)).resizable().frame(width: 34, height: 34) }
                else { Image(systemName: "display").font(.system(size: 26)) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 21, weight: .semibold))
                    Text(target == .docked ? "While an external display is connected" : "While \(name) is in front")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Turn on only the slots you want to change. Everything else keeps your everyday setup.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(group.slots, id: \.self) { slot in
                                ProfileSlotRow(title: EdgeSlot.title(slot), everyday: settings.baseBinding(slot), tapOnly: group.taps,
                                               override: Binding(get: { override(for: slot) }, set: { setOverride($0, for: slot) }))
                                if slot != group.slots.last { Divider() }
                            }
                        }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.trailing, 5)
            }
        }.padding(24).frame(width: 580, height: 620)
    }
}

private struct ProfileSlotRow: View {
    let title: String
    let everyday: EdgeBinding
    let tapOnly: Bool
    @Binding var override: EdgeBinding?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle(isOn: Binding(get: { override != nil }, set: { override = $0 ? everyday : nil })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        Text(override == nil ? "Everyday: \(everyday.action.label)" : "Changed in this profile")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).controlSize(.small)
                Spacer()
                if override != nil {
                    ActionPicker(action: Binding(get: { override?.action ?? .disabled }, set: { override?.action = $0 }), label: title, tapOnly: tapOnly).labelsHidden()
                }
            }.padding(12)
            if let current = override {
                BindingExtras(binding: Binding(get: { override ?? current }, set: { override = $0 }), sharedFallback: false, tap: tapOnly)
            }
        }
    }
}

private struct EdgeWidthSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    private var percent: Binding<Double> {
        Binding(get: { value * 100 }, set: { entered in
            guard entered.isFinite else { return }
            value = min(range.upperBound, max(range.lowerBound, entered / 100))
        })
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).fixedSize()
            Spacer(minLength: 12)
            // Snap to half-percent changes without drawing dozens of tick marks.
            // The text field still accepts finer values such as 1.2%.
            Slider(value: Binding(get: { value }, set: {
                value = min(range.upperBound, max(range.lowerBound, ($0 * 200).rounded() / 200))
            }), in: range)
                .controlSize(.small).frame(maxWidth: 200)
                .accessibilityLabel(title)
                .accessibilityValue("\(value * 100, specifier: "%.1f") percent")
            HStack(spacing: 2) {
                TextField(title, value: percent, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width: 42).accessibilityLabel("Exact \(title.lowercased()) in percent")
                Text("%").foregroundStyle(.secondary)
            }.font(.system(size: 12)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 7).frame(minHeight: 38)
        .help("\(Int(range.lowerBound * 100))–\(Int(range.upperBound * 100))%. Type an exact value, including decimals.")
    }
}

/// A level's lowest and highest points, one row each.
private struct LimitEditor: View {
    let action: ZoneAction
    @Binding var lower: Double
    @Binding var upper: Double
    var body: some View {
        VStack(spacing: 0) {
            row("Lowest", value: Binding(get: { lower }, set: { lower = min($0, upper - 0.05) }), range: 0...0.95)
            RowDivider()
            row("Highest", value: Binding(get: { upper }, set: { upper = max($0, lower + 0.05) }), range: 0.05...1)
        }
    }
    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).fixedSize()
            Spacer(minLength: 12)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * 100).rounded() / 100 }), in: range)
                .controlSize(.small).frame(maxWidth: 220)
                .accessibilityLabel("\(title) \(action.label.lowercased())")
            Text("\(Int((value.wrappedValue * 100).rounded()))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 38)
    }
}

/// The only part of Settings that redraws with every touch sample.
private struct SafeTestPanel: View {
    @ObservedObject var settings: TrackpadSettings
    @ObservedObject var controls: ControlCenterModel
    @ObservedObject private var telemetry = GestureTelemetry.shared
    private let monitor = TrackpadMonitor.shared
    let preview: Bool
    let endTesting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "testtube.2").font(.system(size: 24)).foregroundStyle(SwayTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(telemetry.isTesting ? "Test running" : "Safe test")
                        .font(.system(size: 14, weight: .semibold))
                    Text("All actions are disabled during testing. No device changes or shortcuts are sent.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(telemetry.isTesting ? "Stop test" : "Start test") {
                    guard !preview else { return }
                    if telemetry.isTesting { endTesting() }
                    else { monitor.cancelCurrentGesture(); telemetry.resetCounters(); telemetry.isTesting = true; monitor.start() }
                }
                .buttonStyle(.bordered)
                .disabled(!controls.hasAccess || !settings.isEnabled)
            }.swayCard()
            if !settings.isEnabled {
                HStack {
                    Text("Gestures are paused.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { if !preview { SwaySession.shared.setEnabled(true) } }.buttonStyle(.bordered)
                }
            }
            TrackpadMap(settings: settings, selectedZone: nil, telemetry: telemetry, showsTouches: telemetry.isTesting, onSelect: nil)
                .frame(height: 145)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(telemetry.isTesting ? telemetry.phase : "Ready to test", systemImage: telemetry.phase == "Accepted" && telemetry.isTesting ? "checkmark.circle.fill" : "waveform.path")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(SwayTheme.accent)
                    Spacer()
                    Text("\(telemetry.acceptedCount) accepted · \(telemetry.rejectedCount) stopped" + (telemetry.palmsIgnored > 0 ? " · \(telemetry.palmsIgnored) palms ignored" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(telemetry.isTesting ? telemetry.reason : "Start a test, then begin a deliberate swipe inside an edge zone.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) {
                    EvidenceMetric(label: "Contacts", value: "\(telemetry.fingerCount)")
                    EvidenceMetric(label: "Travel", value: String(format: "%.1f%%", telemetry.displacement * 100))
                    EvidenceMetric(label: "Straightness", value: telemetry.sampleCount > 1 ? "\(Int(telemetry.straightness * 100))%" : "—")
                    EvidenceMetric(label: "Duration", value: "\(telemetry.elapsedMilliseconds) ms")
                }
            }.swayCard()
        }
    }
}

private struct EvidenceMetric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shortcuts and app exclusions

private struct HotkeyRecorder: View {
    @Binding var hotkey: HotkeyCombo
    var title = "Pause / resume shortcut"
    var detail = "Works while any app is active."
    var showsRegistrationError = true
    var usesCheatSheetError = false
    @ObservedObject private var manager = HotkeyManager.shared
    @State private var recording = false
    @State private var eventMonitor: Any?
    @State private var hint: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if recording || !detail.isEmpty {
                        Text(recording ? "Press a shortcut. Escape cancels." : detail)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(recording ? "Cancel" : hotkey.isEmpty ? "Record…" : hotkey.displayString) {
                    recording ? stop() : start()
                }.buttonStyle(.bordered)
                if !recording && !hotkey.isEmpty {
                    Button { hotkey = .none } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear shortcut")
                }
            }
            if let message = hint ?? (usesCheatSheetError ? manager.cheatSheetError : showsRegistrationError ? manager.registrationError : nil) {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 38).onDisappear(perform: stop)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("swayPopoverClosed"))) { _ in stop() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("swaySettingsClosed"))) { _ in stop() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }
    private func start() {
        stop(); recording = true; hint = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !flags.intersection([.command, .control, .option]).isEmpty else {
                hint = "Include Command, Control, or Option."; return nil
            }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            hotkey = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stop(); return nil
        }
    }
    private func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil; recording = false
    }
}

struct AppPickerSheet: View {
    @Binding var excludedApps: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [AppInfo] = []
    @State private var search = ""
    @State private var loading = true
    private var filtered: [AppInfo] {
        let matching = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
        return matching.sorted { a, b in
            let ae = excludedApps.contains(a.bundleID), be = excludedApps.contains(b.bundleID)
            return ae != be ? ae : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Excluded apps").font(.system(size: 21, weight: .semibold))
                    Text("Kinara pauses gestures whenever these apps are active.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.defaultAction)
            }
            TextField("Search applications", text: $search).textFieldStyle(.roundedBorder).controlSize(.large)
            if loading {
                ProgressView("Finding applications…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No applications found").font(.system(size: 15, weight: .semibold))
                    Text("Try another name or add an app below.").font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { app in
                            Toggle(isOn: Binding(get: { excludedApps.contains(app.bundleID) }, set: { enabled in
                                if enabled { if !excludedApps.contains(app.bundleID) { excludedApps.append(app.bundleID) } }
                                else { excludedApps.removeAll { $0 == app.bundleID } }
                            })) {
                                HStack(spacing: 10) {
                                    Image(nsImage: app.icon).resizable().frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).font(.system(size: 14, weight: .medium))
                                        Text(app.bundleID).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                            }.toggleStyle(.switch).controlSize(.small).padding(10)
                        }
                    }
                }
            }
            HStack {
                Button("Add application…", action: addApplication).buttonStyle(.bordered)
                Spacer()
                Text("\(excludedApps.count) excluded").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 520, height: 540)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let discovered = ExcludedAppsManager.installedApps()
                DispatchQueue.main.async {
                    apps = discovered
                    for id in excludedApps where !apps.contains(where: { $0.bundleID == id }) {
                        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                        let name = url?.deletingPathExtension().lastPathComponent ?? id
                        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
                        apps.append(AppInfo(name: name, bundleID: id, icon: icon))
                    }
                    loading = false
                }
            }
        }
    }
    private func addApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                if !excludedApps.contains(id) { excludedApps.append(id) }
                if !apps.contains(where: { $0.bundleID == id }) {
                    apps.append(AppInfo(name: url.deletingPathExtension().lastPathComponent, bundleID: id, icon: NSWorkspace.shared.icon(forFile: url.path)))
                }
            }
        }
    }
}

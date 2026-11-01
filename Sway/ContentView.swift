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
        assign(\.hasAccess, AXIsProcessTrusted())
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

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                SwayLogo(size: 30, dimmed: !settings.isEnabled)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sway").font(.system(size: 14, weight: .semibold))
                    Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
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
                Divider()
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
                    Label("Sway \(version) available…", systemImage: "arrow.down.circle")
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Review and install the signed update")
            }
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
            Divider()
            HStack {
                if controls.undoValues != nil {
                    Button { controls.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .help("Undo your last adjustment").accessibilityLabel("Undo last adjustment")
                }
                Spacer()
                MoreOptionsButton(isExpanded: showsMoreOptions) { showsMoreOptions.toggle() }
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            if showsMoreOptions {
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
                    HStack {
                        Text("Pause gestures").foregroundStyle(.secondary)
                        Spacer()
                        ForEach([5, 15, 60], id: \.self) { minutes in
                            Button(minutes == 60 ? "1 hr" : "\(minutes) min") {
                                if !preview { session.pause(for: TimeInterval(minutes * 60)) }
                                showsMoreOptions = false
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    Divider()
                    Button("Quit Sway") { if !preview { NSApp.terminate(nil) } }.keyboardShortcut("q")
                }.font(.system(size: 12)).buttonStyle(.plain)
            }
        }
        .padding(17)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuGlassSurface(standalone: previewStandaloneSurface, forceOpaque: previewReduceTransparency,
                                   themeDiffersFromSystem: !preview && themeDiffersFromSystem))
        .tint(.primary)
        .preferredColorScheme(settings.resolvedColorScheme)
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
    @State private var selectedZone = "left"
    @State private var editingProfile: ProfileTarget?
    @Namespace private var sidebarSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var transferMessage: String?
    private let preview: Bool

    init(initialPane: SettingsPane = .overview, preview: Bool = false, settings: TrackpadSettings = .shared, updates: UpdateChecker = .shared) {
        self.preview = preview
        self.settings = settings
        self.updates = updates
        _pane = State(initialValue: initialPane)
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    SwayLogo(size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sway").font(.system(size: 15, weight: .semibold))
                        Label(status.title, systemImage: status.icon).font(.system(size: 11)).foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer(minLength: 4)
                    Toggle("Gestures", isOn: Binding(get: { settings.isEnabled }, set: { value in
                        if preview { settings.isEnabled = value } else { SwaySession.shared.setEnabled(value) }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .help(settings.isEnabled ? "Pause edge gestures" : "Resume edge gestures")
                }
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Find a setting")
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SettingsPane.groups, id: \.self) { group in
                            let items = visiblePanes.filter { $0.group == group }
                            if !items.isEmpty {
                                if !group.isEmpty {
                                    Text(group).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
                                }
                                ForEach(items) { item in sidebarRow(item) }
                            }
                        }
                    }
                }.scrollIndicators(.never)
                if visiblePanes.isEmpty { Text("No matching settings").font(.system(size: 12)).foregroundStyle(.secondary) }
                Button { if !preview { (NSApp.delegate as? AppDelegate)?.showGettingStarted() } } label: {
                    Label("Getting started", systemImage: "sparkles").font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(14).frame(width: 224)
            .background(Color.primary.opacity(0.03))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if visiblePanes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("No settings found").font(.headline)
                        Text("Try a word like haptics, paste, corner, or updates.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Clear search") { search = "" }.buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                VStack(alignment: .leading, spacing: 0) {
                PageTitle(pane.title, subtitle: pane.detail, icon: pane.icon).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !controls.hasAccess && [.gestures, .protection, .about].contains(pane) { permissionCard }
                        if controls.hasAccess && settings.isEnabled && !monitor.isRunning && !preview && pane == .gestures {
                            VStack(alignment: .leading, spacing: 10) {
                                Notice(monitor.statusMessage, icon: "exclamationmark.triangle", tint: .primary)
                                Button("Reconnect trackpad") { monitor.restart() }.buttonStyle(.bordered)
                            }
                        }
                        if let message = controls.message { Notice(message, icon: "exclamationmark.triangle", tint: .primary) }
                        switch pane {
                        case .overview: overviewPage
                        case .gestures: gesturesPage
                        case .taps: tapsPage
                        case .profiles: profilesPage
                        case .protection: protectionPage
                        case .levels: levelsPage
                        case .mixer: mixerPage
                        case .feedback: feedbackPage
                        case .appearance: appearancePage
                        case .general: generalPage
                        case .updates: SettingsSection("Updates") { UpdatePreferencesContent(updates: updates, preview: preview) }
                        case .about: aboutPage
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading)
                }
                }
                .id(pane)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 820, height: 660)
        // One gentle transaction for page changes: the content settles in and
        // the sidebar highlight glides, wherever the change came from.
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.88), value: pane)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(settings.resolvedColorScheme)
        .tint(SwayTheme.accent)
        .onChange(of: pane) { value in
            if value != .protection { endTesting() }
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
        .alert("Reset gesture settings?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) { }
            Button("Reset gestures", role: .destructive) { settings.resetGestureSettings() }
        } message: { Text("Restores zone assignments, layers, taps, feel, sensitivity, palm protection, haptics, and limits. Your app profiles, recorded shortcuts, excluded apps, and appearance stay as they are.") }
    }

    private func sidebarRow(_ item: SettingsPane) -> some View {
        Button { pane = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon).font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(pane == item ? Color(nsColor: .windowBackgroundColor) : .primary)
                    .background(pane == item ? Color.primary : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(item.title).font(.system(size: 13, weight: pane == item ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background {
                if pane == item {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08))
                        .matchedGeometryEffect(id: "sidebar", in: sidebarSelection)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(pane == item ? [.isSelected] : [])
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow trackpad gestures", systemImage: "lock.shield")
                .font(.system(size: 15, weight: .semibold))
            Text("Enable Sway in System Settings → Privacy & Security → Accessibility. Menu-bar sliders work without this permission.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Accessibility Settings", action: openAccessibility).buttonStyle(.bordered)
                Button("Check again") { controls.refresh(); if controls.hasAccess { monitor.restart() } }.buttonStyle(.bordered)
            }
            .controlSize(.regular)
            AccessibilityRecoveryHelp()
        }
        .padding(14).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }


    // MARK: Overview

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: status.icon).font(.system(size: 26, weight: .medium))
                    .frame(width: 54, height: 54)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(controls.hasAccess ? (settings.isEnabled ? "Sway is ready" : "Gestures are paused") : "One step left")
                        .font(.system(size: 18, weight: .semibold))
                    Text(controls.hasAccess ? (settings.isEnabled ? (status.detail == "Edges are ready" ? "Swipe an edge, or double-tap a corner." : "\(status.detail) is active for the app in front.") : "Your sliders still work. Turn gestures back on anytime.")
                                            : "Allow Accessibility so Sway can feel your edge swipes. Touch data stays on your Mac.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !controls.hasAccess {
                    Button("Allow…", action: openAccessibility).buttonStyle(MonochromePrimaryButtonStyle())
                } else if !settings.isEnabled {
                    Button("Resume") { if !preview { SwaySession.shared.setEnabled(true) } else { settings.isEnabled = true } }
                        .buttonStyle(MonochromePrimaryButtonStyle())
                }
            }.swayCard()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your trackpad").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Click a zone to change it").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 4)
                TrackpadMap(settings: settings, selectedZone: nil, telemetry: telemetry, showsTouches: telemetry.isLiveViewing,
                            onSelect: { zone in
                                if ["left", "right"].contains(zone) { selectedZone = zone }
                                pane = zone == "bottom" || zone.hasPrefix("top") || ["left", "right"].contains(zone) ? .gestures : .taps
                            }, showsCorners: true)
                    .frame(height: 190)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick settings").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    QuickTile(title: "Haptics", value: settings.hapticFeedback ? settings.hapticStyle.label : "Off", icon: "waveform.path", isOn: settings.hapticFeedback) {
                        settings.hapticFeedback.toggle()
                    }
                    QuickTile(title: "Fine control", value: settings.precisionEnabled ? "On" : "Off", icon: "scope", isOn: settings.precisionEnabled) {
                        settings.precisionEnabled.toggle()
                    }
                    QuickTile(title: "Notches", value: settings.notchesEnabled ? "At 50%" : "Off", icon: "dial.medium", isOn: settings.notchesEnabled) {
                        settings.notchesEnabled.toggle()
                    }
                    QuickTile(title: "Indicator", value: settings.osdStyle == "edge" ? "Follows finger" : settings.osdStyle == "off" ? "Off" : "Pill", icon: "rectangle.portrait.on.rectangle.portrait", isOn: settings.osdStyle != "off") {
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

            let ideas = suggestions
            if !ideas.isEmpty {
                SettingsSection("Try next") {
                    ForEach(Array(ideas.enumerated()), id: \.offset) { index, idea in
                        HStack(spacing: 12) {
                            Image(systemName: idea.icon).font(.system(size: 14)).frame(width: 30, height: 30)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(idea.title).font(.system(size: 13.5, weight: .medium))
                                Text(idea.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button("Set up") { pane = idea.pane }.buttonStyle(.bordered).controlSize(.small)
                        }.padding(.horizontal, 16).padding(.vertical, 11)
                        if index < ideas.count - 1 { Divider().padding(.leading, 58) }
                    }
                }
            }
        }
    }

    /// Next steps that match what isn't set up yet, never more than three.
    private var suggestions: [(title: String, detail: String, icon: String, pane: SettingsPane)] {
        var ideas: [(String, String, String, SettingsPane)] = []
        if !EdgeSlot.allTaps.contains(where: { settings.slotIsAssigned($0) }) {
            ideas.append(("Double-tap a corner to paste", "Corners make great buttons: paste, Mission Control, a Shortcut.", "hand.tap", .taps))
        }
        if settings.appProfiles.isEmpty {
            ideas.append(("Give an app its own edges", "Switch tabs in your browser, scrub in your editor.", "square.stack", .profiles))
        }
        if !EdgeSlot.sides.contains(where: { settings.slotIsAssigned(EdgeSlot.option($0)) }) {
            ideas.append(("Hold ⌥ for a second action", "Each side edge can do two things.", "option", .gestures))
        }
        if settings.cheatSheetHotkey.isEmpty {
            ideas.append(("Peek at your edges", "Hold a shortcut to see what every edge does in the app you’re using.", "map", .general))
        }
        return Array(ideas.prefix(3)).map { (title: $0.0, detail: $0.1, icon: $0.2, pane: $0.3) }
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

    private var gesturesPage: some View {
        Group {
            SettingsCard {
                SettingRow("Preset", detail: presetMessage ?? "Choose a starting point, then fine-tune.") {
                    Menu("Choose…") {
                        ForEach(GesturePreset.allCases) { preset in
                            Button(preset.title) {
                                settings.applyGesturePreset(preset)
                                presetMessage = "\(preset.title) applied."
                            }
                        }
                    }.frame(width: 145)
                }
                Divider()
                SettingRow("Finger count", detail: "Use the same number throughout a swipe.") {
                    Picker("Finger count", selection: $settings.minimumFingers) {
                        Text("1 finger").tag(1); Text("2 fingers").tag(2)
                    }.pickerStyle(.segmented).fixedSize()
                }
                .onChange(of: settings.minimumFingers) { value in
                    if value != 1 { settings.topEdgeEnabled = false; settings.bottomEdgeEnabled = false }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Trackpad edges").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(telemetry.isLiveViewing ? "Live: touch your trackpad to see it here" : "Start inside an edge to adjust")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                TrackpadMap(settings: settings, selectedZone: selectedZone, telemetry: telemetry,
                            showsTouches: telemetry.isTesting || telemetry.isLiveViewing, onSelect: { selectedZone = $0 })
                    .frame(height: 118)
                SettingsCard {
                    ZoneEditor(title: "Left edge", slot: "left", settings: settings, width: $settings.leftZoneWidth, selected: selectedZone == "left")
                    Divider()
                    ZoneEditor(title: "Right edge", slot: "right", settings: settings, width: $settings.rightZoneWidth, selected: selectedZone == "right")
                }
                Text("Choose from \(ZoneAction.allCases.count - 1) actions on any edge. Direction notes use Up/Down; horizontal edges use Right/Left. Reverse swipe direction reverses both.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if usesSharedShortcuts {
                SettingsSection("Shared custom shortcuts") {
                    SettingsCard {
                        HotkeyRecorder(hotkey: $settings.swipeUpShortcut, title: "Up / right swipe", detail: "Sent once after an intentional swipe.", showsRegistrationError: false)
                        Divider()
                        HotkeyRecorder(hotkey: $settings.swipeDownShortcut, title: "Down / left swipe", detail: "Sent once after an intentional swipe.", showsRegistrationError: false)
                    }
                    Text("Edges set to Custom shortcuts use this pair until you record a pair for that edge. Shortcuts follow the frontmost app and are not globally registered hotkeys. Avoid destructive commands.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsSection("Feel") {
                ToggleRow("Fine control", detail: "While swiping, slide inward from the edge to adjust in small steps, like scrubbing a video. A soft tap tells you it’s on.", value: $settings.precisionEnabled)
                Divider()
                ToggleRow("Speed-sensitive levels", detail: "Slow swipes make small changes; a quick flick covers more of the range.", value: $settings.accelerationEnabled)
                Divider()
                LabeledSlider("Sensitivity", detail: "How quickly levels change or repeatable actions step.", value: $settings.sensitivity, range: 0.3...3, display: String(format: "%.1f×", settings.sensitivity))
                Divider()
                ToggleRow("Reverse swipe direction", detail: settings.invertScrollDirection ? "Down increases. Up decreases." : "Up increases. Down decreases.", value: $settings.invertScrollDirection)
                Divider()
                ToggleRow("Hold pointer while adjusting", detail: "Only during a confirmed one-finger gesture.", value: $settings.cursorFreezeOnOneFinger)
                    .disabled(settings.minimumFingers != 1 && !EdgeSlot.sides.contains { settings.slotIsAssigned(EdgeSlot.alternate($0)) })
            }
            SettingsSection("Layers") {
                Text("Give each side edge more actions. Hold ⌥ while you swipe, or use \(otherFingerCount) instead of \(settings.minimumFingers == 1 ? "1" : "2"). Layers you leave Off change nothing.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(14)
                Divider()
                SlotEditor(title: "Left edge + ⌥", binding: everydayBinding(EdgeSlot.option("left")))
                Divider()
                SlotEditor(title: "Right edge + ⌥", binding: everydayBinding(EdgeSlot.option("right")))
                Divider()
                SlotEditor(title: "Left edge, \(otherFingerCount)", binding: everydayBinding(EdgeSlot.alternate("left")),
                           detail: settings.minimumFingers == 2 ? "One finger that starts in this edge and moves along it adjusts instead of pointing." : nil)
                Divider()
                SlotEditor(title: "Right edge, \(otherFingerCount)", binding: everydayBinding(EdgeSlot.alternate("right")))
            }
            SettingsCard {
                ToggleRow("Top edge gestures", detail: "One finger; side edges remain available.", value: Binding(get: { settings.topEdgeEnabled }, set: { value in if value { settings.minimumFingers = 1 }; settings.topEdgeEnabled = value }))
                if settings.topEdgeEnabled {
                    Divider()
                    SettingRow("Swipe direction") {
                        Picker("Top swipe direction", selection: $settings.topEdgeSwipeDirection) {
                            Text("Horizontal").tag("horizontal"); Text("Vertical").tag("vertical")
                        }.pickerStyle(.segmented).fixedSize()
                    }
                    if settings.topEdgeSwipeDirection == "horizontal" {
                        SlotEditor(title: "Top left", binding: everydayBinding("topLeft"))
                        SlotEditor(title: "Top right", binding: everydayBinding("topRight"))
                    } else {
                        SlotEditor(title: "Top edge action", binding: everydayBinding("top"))
                    }
                    EdgeWidthSlider(title: "Top height", value: $settings.topEdgeHeight, range: TrackpadSettings.topEdgeHeightRange)
                        .padding(14)
                }
            }
            SettingsCard {
                ToggleRow("Bottom edge gestures", detail: "One finger, swiping left or right along the bottom. Leave it off if you rest your thumb there.", value: Binding(get: { settings.bottomEdgeEnabled }, set: { value in if value { settings.minimumFingers = 1 }; settings.bottomEdgeEnabled = value }))
                if settings.bottomEdgeEnabled {
                    Divider()
                    SlotEditor(title: "Bottom edge action", binding: everydayBinding("bottom"))
                    EdgeWidthSlider(title: "Bottom height", value: $settings.bottomEdgeHeight, range: TrackpadSettings.topEdgeHeightRange)
                        .padding(14)
                }
            }
        }
    }

    // MARK: Taps & corners

    private var tapsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tap twice quickly for a double-tap. Tap once, then touch again and hold still for tap-and-hold. Both start with a short, still tap, so a resting palm never triggers them. Edge taps use \(settings.minimumFingers == 1 ? "one finger" : "two fingers"), like your swipes\(settings.minimumFingers == 2 && settings.cornerTapFingers == 1 ? "; corners use one finger" : "").")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TrackpadMap(settings: settings, selectedZone: nil, telemetry: telemetry,
                        showsTouches: telemetry.isLiveViewing, onSelect: nil, showsCorners: true)
                .frame(height: 118)
            SettingsSection("Edges") {
                ForEach(tapEdges, id: \.self) { region in
                    SlotEditor(title: "\(EdgeSlot.title(region)) double-tap", binding: everydayBinding(EdgeSlot.tap(region, "doubleTap")), tapOnly: true)
                    Divider()
                    SlotEditor(title: "\(EdgeSlot.title(region)) tap and hold", binding: everydayBinding(EdgeSlot.tap(region, "tapHold")), tapOnly: true)
                    if region != tapEdges.last { Divider() }
                }
            }
            SettingsSection("Corners") {
                LabeledSlider("Corner size", detail: "Corners with a tap action take this much of each edge, for taps only. Swipes still start from the side edges.", value: $settings.tapCornerSize, range: TrackpadSettings.cornerSizeRange, display: "\(Int((settings.tapCornerSize * 100).rounded()))%")
                if settings.minimumFingers == 2 {
                    Divider()
                    SettingRow("Fingers for corner taps", detail: settings.cornerTapFingers == 1 ? "One finger in a corner, two fingers on the edges. Tap-to-click in a corner with an action belongs to Sway." : "Same as your swipes: two fingers.") {
                        Picker("Fingers for corner taps", selection: $settings.cornerTapFingers) {
                            Text("Like swipes").tag(0); Text("1 finger").tag(1)
                        }.pickerStyle(.segmented).fixedSize()
                    }
                }
                ForEach(["topLeftCorner", "topRightCorner", "bottomLeftCorner", "bottomRightCorner"], id: \.self) { corner in
                    Divider()
                    SlotEditor(title: "\(EdgeSlot.title(corner)) double-tap", binding: everydayBinding(EdgeSlot.tap(corner, "doubleTap")), tapOnly: true)
                    Divider()
                    SlotEditor(title: "\(EdgeSlot.title(corner)) tap and hold", binding: everydayBinding(EdgeSlot.tap(corner, "tapHold")), tapOnly: true)
                }
            }
            Text("Where an edge or corner has a tap action, tap-to-click there no longer clicks what’s under the pointer. Pressing the trackpad always clicks. Nothing runs during a safe gesture test.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tapEdges: [String] {
        ["left", "right"] + (settings.topEdgeEnabled ? ["top"] : []) + (settings.bottomEdgeEnabled ? ["bottom"] : [])
    }

    // MARK: Profiles

    private var profilesPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("App profiles") {
                if settings.appProfiles.isEmpty {
                    Text("No app profiles yet. A profile changes only the edges you pick, while that app is in front. For example: tabs in your browser, the timeline in your video editor.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(14)
                }
                ForEach(settings.appProfiles.keys.sorted { (settings.appProfiles[$0]?.name ?? $0).localizedCaseInsensitiveCompare(settings.appProfiles[$1]?.name ?? $1) == .orderedAscending }, id: \.self) { id in
                    HStack(spacing: 10) {
                        Image(nsImage: Self.appIcon(id)).resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(settings.appProfiles[id]?.name ?? id).font(.system(size: 14, weight: .medium))
                            Text(Self.changeSummary(settings.appProfiles[id]?.bindings.count ?? 0)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editingProfile = .app(id) }.buttonStyle(.bordered)
                        Button { settings.appProfiles.removeValue(forKey: id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove profile")
                    }.padding(14)
                    Divider()
                }
                HStack {
                    Button("Add app…", action: addProfileApp).buttonStyle(.bordered)
                    if let id = exclusions.currentAppBundleID, settings.appProfiles[id] == nil, !preview {
                        Button("Add \(exclusions.currentAppName)") {
                            settings.appProfiles[id] = ActionProfile(name: exclusions.currentAppName)
                            editingProfile = .app(id)
                        }.buttonStyle(.bordered)
                    }
                    Spacer()
                }.padding(14)
            }
            SettingsSection("When docked") {
                ToggleRow("Docked profile", detail: "Applies while an external display is connected. \(BrightnessController.shared.hasExternalDisplayConnected && !preview ? "Connected now." : "Not connected now.")", value: $settings.dockedProfileEnabled)
                if settings.dockedProfileEnabled {
                    Divider()
                    HStack {
                        Text(Self.changeSummary(settings.dockedProfile.bindings.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit…") { editingProfile = .docked }.buttonStyle(.bordered)
                    }.padding(14)
                }
            }
            Text("Sway checks the app in front first, then the docked profile, then your everyday setup. The edge map shows which one is active.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func changeSummary(_ count: Int) -> String {
        count == 0 ? "Uses your everyday setup" : count == 1 ? "1 change" : "\(count) changes"
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

    private var protectionPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard {
                    SettingRow("Intent checks", detail: settings.palmRejectionMode == "strict" ? "More travel and consistency before activation." : "Balanced response with deliberate movement.") {
                        Picker("Palm protection", selection: $settings.palmRejectionMode) {
                            Text("Balanced").tag("balanced"); Text("Strict").tag("strict")
                        }.pickerStyle(.segmented).fixedSize()
                    }
                    DisclosureGroup("Fine-tune protection") {
                        LabeledSlider("Pause after typing", detail: "Prevents a resting hand from starting a gesture after a keypress.", value: $settings.typingCooldown, range: 0.2...1, display: String(format: "%.2f s", settings.typingCooldown))
                        LabeledSlider("Start distance", detail: "Minimum travel across the trackpad before a swipe can activate.", value: $settings.activationThreshold, range: 0...12, display: String(format: "%.1f%%", max(settings.palmRejectionMode == "strict" ? 1.4 : 0.8, settings.activationThreshold / 5 * (settings.palmRejectionMode == "strict" ? 1.3 : 1))))
                    }.font(.system(size: 12)).padding(14)
                }
                Text("These are measured intent checks, not a claim that macOS identifies every palm. Straightness is net travel divided by total travel. No touch data is saved.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Test gestures safely", isExpanded: $showsSafeTest) {
                SafeTestPanel(settings: settings, controls: controls, preview: preview, endTesting: endTesting).padding(.top, 14)
            }.font(.system(size: 13, weight: .medium))
        }
    }

    private var currentDeviceUID: String? { preview ? "preview-device" : VolumeController.shared.deviceUID }

    private var levelsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Comfort limits") {
                LimitEditor(action: .brightness, lower: $settings.brightnessMin, upper: $settings.brightnessMax)
                Divider()
                LimitEditor(action: .volume, lower: $settings.volumeMin, upper: $settings.volumeMax)
                Divider()
                ToggleRow("Mute at zero", detail: "Mute audio when the volume reaches 0%.", value: $settings.muteAtZero)
            }
            SettingsSection("This audio output") {
                ToggleRow("Limits just for \(controls.volumeDevice)", detail: "Sway remembers these for this device and uses them whenever it’s the output. Handy for keeping headphones quieter.", value: Binding(get: {
                    currentDeviceUID.map { settings.deviceVolumeLimits[$0] != nil } ?? false
                }, set: { on in
                    guard let uid = currentDeviceUID else { return }
                    settings.deviceVolumeLimits[uid] = on ? DeviceLimit(name: controls.volumeDevice, min: settings.volumeMin, max: settings.volumeMax) : nil
                }))
                .disabled(currentDeviceUID == nil)
                if let uid = currentDeviceUID, let limit = settings.deviceVolumeLimits[uid] {
                    Divider()
                    LimitEditor(action: .volume,
                                lower: Binding(get: { limit.min }, set: { settings.deviceVolumeLimits[uid] = DeviceLimit(name: limit.name, min: $0, max: settings.deviceVolumeLimits[uid]?.max ?? limit.max) }),
                                upper: Binding(get: { limit.max }, set: { settings.deviceVolumeLimits[uid] = DeviceLimit(name: limit.name, min: settings.deviceVolumeLimits[uid]?.min ?? limit.min, max: $0) }))
                }
                let others = settings.deviceVolumeLimits.filter { $0.key != currentDeviceUID }.sorted { $0.value.name < $1.value.name }
                ForEach(others, id: \.key) { item in
                    Divider()
                    HStack {
                        Text(item.value.name).font(.system(size: 13))
                        Spacer()
                        Text("\(Int(item.value.min * 100))–\(Int(item.value.max * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        Button { settings.deviceVolumeLimits.removeValue(forKey: item.key) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Forget limits for \(item.value.name)")
                    }.padding(14)
                }
            }
            SettingsSection("Favorite levels") {
                FavoriteLevelRow(action: .volume, favorite: $settings.volumeFavorite, current: controls.volume)
                Divider()
                FavoriteLevelRow(action: .brightness, favorite: $settings.brightnessFavorite, current: controls.brightness)
                Text(settings.notchesEnabled ? "Swipes settle on a favorite with a crisp tap, like a notch at 50%." : "Turn on notches in Haptics to feel your favorites.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding([.horizontal, .bottom], 14)
            }
            SettingsSection("Displays") {
                ToggleRow("Brightness follows the pointer", detail: "Adjusts the display the pointer is on: Apple displays directly, other monitors over DDC/CI where they support it. Otherwise the built-in display.", value: $settings.brightnessFollowsPointer)
                Text("Now adjusting: \(controls.brightnessDevice)").font(.system(size: 12)).foregroundStyle(.secondary).padding([.horizontal, .bottom], 14)
                Divider()
                ToggleRow("Extra dim below minimum", detail: "Keep swiping down past the lowest brightness to dim further, for late nights. Quitting Sway restores normal brightness.", value: $settings.extraDimBelowMinimum)
            }
        }
    }

    private var mixerPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !MixerModel.isSupported && !preview {
                Notice("The mixer needs macOS 14.2 or later.", icon: "info.circle", tint: .primary)
            } else {
                if mixer.permission != .authorized {
                    SettingsSection("Access") { MixerPermissionRow(mixer: mixer).padding(16) }
                }
                SettingsSection("Apps") {
                    let list = mixer.playingChannels + (mixer.showOtherApps ? mixer.otherChannels : [])
                    if list.isEmpty {
                        Text("Apps appear here when they play sound. Play something to try it.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(16)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            MixerBanners(mixer: mixer)
                            ForEach(list) { MixerChannelRow(channel: $0, mixer: mixer, large: true) }
                        }.padding(16)
                    }
                }
                SettingsSection("Calls") {
                    ToggleRow("Lower other apps during calls", detail: "When an app uses your microphone, everything else fades down, and comes back when the call ends.", value: $mixer.duckDuringCalls)
                    Divider()
                    LabeledSlider("Keep other apps at", detail: "How loud other apps stay while you’re on a call.", value: $mixer.duckLevel,
                                  range: 0.05...0.8, display: "\(Int((mixer.duckLevel * 100).rounded()))%")
                        .disabled(!mixer.duckDuringCalls)
                }
                SettingsSection("Options") {
                    ToggleRow("Show the mixer in the menu bar", detail: "Every app that plays sound gets a fader in Sway’s menu.", value: $mixer.showInMenu)
                    Divider()
                    ToggleRow("Allow boost to 150%", detail: "Faders can go past full level, with a soft limiter so loud parts don’t crackle.", value: $mixer.allowBoost)
                    Divider()
                    ToggleRow("List apps that haven’t played yet", detail: "Mute an app before its next sound, such as a chat app’s pings.", value: $mixer.showOtherApps)
                    Divider()
                    SettingRow("Forget every app’s settings", detail: "Puts every app back at 100%, unmuted, on the default output.") {
                        Button("Reset") { mixer.resetAllChannels() }
                    }
                }
                Text("Sway reroutes an app only while you’ve changed it: a level other than 100%, muted, solo, lowered for a call, or another output. Every other app plays untouched. Audio is never recorded or saved.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var feedbackPage: some View {
        VStack(alignment: .leading, spacing: 18) {
        SettingsSection("Notches and sound") {
            ToggleRow("Notches", detail: "Levels rest briefly at 50% and your favorite levels, with a crisp tap, so you can find them without looking.", value: $settings.notchesEnabled)
            Divider()
            SettingRow("Volume sound", detail: "The click macOS plays after you change the volume.") {
                Picker("Volume feedback sound", selection: $settings.volumeFeedbackSound) {
                    Text("Like macOS").tag("system"); Text("On").tag("on"); Text("Off").tag("off")
                }.pickerStyle(.segmented).fixedSize()
            }
        }
        SettingsSection("Trackpad haptics") {
            ToggleRow("Haptic feedback", detail: "Feel confirmed edge gestures and level changes.", value: $settings.hapticFeedback)
            if settings.hapticFeedback {
                Divider()
                SettingRow("Tap style") {
                    Picker("Haptic tap style", selection: $settings.hapticStyle) {
                        ForEach(HapticStyle.allCases) { style in Text(style.label).tag(style) }
                    }.pickerStyle(.segmented).fixedSize()
                }
                Divider()
                SettingRow("Level steps", detail: "Smaller steps give more taps.") {
                    Picker("Haptic level spacing", selection: $settings.hapticSpacing) {
                        ForEach(HapticSpacing.allCases) { spacing in Text(spacing.label).tag(spacing) }
                    }.pickerStyle(.segmented).fixedSize()
                }
                Divider()
                ToggleRow("Tap at gesture start", detail: "Know when Sway accepts your swipe.", value: $settings.hapticOnStart)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Button("Try this tap") {
                        if !preview, !telemetry.isTesting { HapticOutput.shared.play(settings.hapticStyle) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(telemetry.isTesting)
                    .help("Click while keeping a finger on your Force Touch trackpad.")
                    Text(telemetry.isTesting ? "Stop the gesture test to preview haptics." : settings.hapticStyle == .strong ? "Strongest drives the trackpad’s actuator directly for the firmest click it can make. It uses a private macOS interface and falls back to Crisp where unavailable." : "Keep a finger resting on your Force Touch trackpad. These are tap patterns; macOS controls the strength and may suppress feedback.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(14)
            }
        }
        }
    }

    private var appearancePage: some View {
        SettingsSection("Appearance") {
            SettingRow("Indicator") {
                Picker("Indicator style", selection: $settings.osdStyle) {
                    Text("Pill").tag("horizontal"); Text("Vertical").tag("vertical"); Text("Follow finger").tag("edge"); Text("Off").tag("off")
                }.pickerStyle(.segmented).fixedSize()
            }
            if settings.osdStyle == "edge" {
                Text("Hugs the side of the screen that matches the edge you’re touching, and moves with your finger. Sliders and the menu bar show the pill.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding([.horizontal, .bottom], 14)
            }
            if settings.osdStyle == "horizontal" {
                LabeledSlider("Indicator width", detail: "Shown at the bottom of the active display.", value: $settings.osdHorizontalWidth, range: 160...320, display: "\(Int(settings.osdHorizontalWidth)) pt")
            } else if settings.osdStyle == "vertical" {
                SettingRow("Position") {
                    Picker("Indicator position", selection: $settings.osdPosition) {
                        ForEach(OSDPosition.allCases) { item in Text(item.label).tag(item) }
                    }.frame(width: 140)
                }
            }
            if settings.osdStyle != "off" {
                Button("Preview indicator") { if !preview { OSDOverlay.shared.show(type: .volume, value: Float(controls.volume)) } }
                    .buttonStyle(.bordered).padding([.horizontal, .bottom], 14)
            }
            Divider()
            ToggleRow("Now Playing display", detail: "Shows artwork, title and progress when you skip, play, pause or seek with a gesture.", value: $settings.nowPlayingHUD)
            Divider()
            SettingRow("Theme") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }.pickerStyle(.segmented).fixedSize()
            }
            Divider()
            SettingRow("Menu bar") {
                Picker("Menu bar display", selection: $settings.menuBarValueSource) {
                    Text("Sway icon").tag("icon"); Text("Sway name").tag("name"); Text("Volume").tag("volume"); Text("Brightness").tag("brightness"); Text("Both levels").tag("both")
                }.frame(width: 150)
            }
            Divider()
            ToggleRow("Scroll on the menu bar icon", detail: "Scroll over Sway’s icon to change the volume; hold ⌥ for brightness.", value: $settings.menuBarScroll)
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 18) {
        SettingsSection("Stay out of the way") {
            ToggleRow("Show in Dock while windows are open", detail: "Close the last window to hide the Dock icon. Sway keeps running in the menu bar.", value: $settings.showDockIcon)
            Divider()
            HStack {
                Text("You can also reopen Sway from Spotlight or Applications.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open controls") { if !preview { (NSApp.delegate as? AppDelegate)?.showQuickControls() } }
                    .buttonStyle(.bordered)
            }.padding(14)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded apps").font(.system(size: 14, weight: .medium))
                    Text(settings.excludedApps.isEmpty ? "Gestures work in every app." : "\(settings.excludedApps.count) apps pause gestures automatically.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage…") { showAppPicker = true }.buttonStyle(.bordered)
            }.padding(14)
            if let id = exclusions.currentAppBundleID, !preview, !settings.excludedApps.contains(id) {
                Button("Exclude \(exclusions.currentAppName)") {
                    settings.excludedApps.append(id)
                }.buttonStyle(.plain).foregroundStyle(SwayTheme.accent).font(.system(size: 12)).padding([.horizontal, .bottom], 14)
            }
            Divider()
            HotkeyRecorder(hotkey: $settings.toggleHotkey)
            Divider()
            HotkeyRecorder(hotkey: $settings.cheatSheetHotkey, title: "Edge map shortcut", detail: "Hold it to see what every edge does in the app you’re using.", usesCheatSheetError: true)
            Divider()
            ToggleRow("Launch at login", detail: "Have Sway ready when you sign in.", value: $settings.launchAtLogin)
            if login.lastError != nil || login.status == .requiresApproval || login.status == .notFound {
                Text(login.statusMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding([.horizontal, .bottom], 14)
            }
        }
        automationSection
        }
    }

    private var automationSection: some View {
        SettingsSection("Automation and your settings") {
            ToggleRow("Sway links", detail: "Let Shortcuts, scripts and launchers use sway:// links: pause, resume or toggle gestures, set volume or brightness within your limits, or show the edge map. Links can’t change your setup.", value: $settings.urlCommandsEnabled)
            if settings.urlCommandsEnabled {
                Text("Examples: sway://pause?minutes=15 · sway://volume?level=40 · sway://edge-map")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding([.horizontal, .bottom], 14)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings file").font(.system(size: 14, weight: .medium))
                    Text(transferMessage ?? "Save your setup, including profiles, to move it to another Mac or keep a backup.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Export…", action: exportSettings).buttonStyle(.bordered)
                Button("Import…", action: importSettings).buttonStyle(.bordered)
            }.padding(14)
        }
    }

    private func exportSettings() {
        guard !preview else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sway Settings.plist"
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

    private var aboutPage: some View {
        SettingsSection("About Sway") {
            HStack {
                Text("Sway").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Getting started").font(.system(size: 14))
                    Text("Find Sway and set up trackpad access.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open guide…") { if !preview { (NSApp.delegate as? AppDelegate)?.showGettingStarted() } }
                    .buttonStyle(.bordered)
            }.padding(14)
            Divider()
            HStack {
                Text("Gesture setup").font(.system(size: 14))
                Spacer()
                Button("Reset…") { confirmReset = true }.buttonStyle(.bordered)
            }.padding(14)
        }
    }

    /// Live finger dots only while a page with a map is on screen.
    private func updateLiveView(_ value: SettingsPane) {
        guard !preview else { return }
        telemetry.isLiveViewing = value == .overview || value == .gestures || value == .taps
    }

    private func endTesting() {
        guard !preview, telemetry.isTesting else { return }
        monitor.cancelCurrentGesture()
        telemetry.isTesting = false
    }

    private func openAccessibility() {
        guard !preview else { return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
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
            ToggleRow("Check automatically", detail: "Check GitHub daily. Downloads stay in your control.",
                      value: Binding(get: { updates.automaticallyChecks }, set: { if !preview { updates.automaticallyChecks = $0 } }))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(showsPreviewUpdate ? "A new version of Sway is available." : updates.status).font(.system(size: 13))
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
                Text("Install updates here without dragging a new app. Downloads and release information are verified before installation. Sway restarts when you confirm.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14)
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
            Text("If Sway is switched on in the list but gestures still don’t work, that entry belongs to an older copy. In Accessibility, remove the Sway entry with −, then use + to add Sway from Applications and switch it on. If macOS still reports the old state, quit and reopen Sway once. Your other apps’ permissions stay untouched.")
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

/// First run, one calm step at a time. macOS's permission prompt appears
/// only when the person chooses Allow, never by surprise at launch, and the
/// guide notices the grant by itself while it is on screen.
struct GettingStartedView: View {
    enum Step: Int, CaseIterable { case welcome, access, practice, personalize, done }

    @ObservedObject var settings: TrackpadSettings
    @StateObject private var controls: ControlCenterModel
    @ObservedObject private var telemetry = GestureTelemetry.shared
    @ObservedObject private var monitor = TrackpadMonitor.shared
    @State private var step: Step
    @State private var requestedAccess = false
    /// When Allow was pressed, to recognize an old entry that never applies.
    @State private var requestedAt: Date?
    @State private var now = Date()
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
                case .practice: practice
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { go(to: .practice) }
        }
        .onChange(of: step) { value in setPracticing(value == .practice) }
        .background {
            if step == .access && !controls.hasAccess && !preview {
                // Checks once a second only while this step waits, even with
                // System Settings in front; gone as soon as access arrives.
                AccessWatcher { now = Date(); controls.refreshAccess() }
            }
        }
        .onDisappear { setPracticing(false) }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            OnboardingTrackpad(animate: !reduceMotion && (!preview || animatesInPreview)).frame(width: 300, height: 190)
            VStack(spacing: 8) {
                Text("Meet Sway").font(.system(size: 30, weight: .bold))
                Text("The edges of your trackpad become controls: volume, brightness, media, windows, and anything Shortcuts can do.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("hand.draw", "Swipe an edge", "Two fingers along the side, just like scrolling.")
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
                Text(controls.hasAccess ? "You’re all set" : "Let Sway feel your trackpad").font(.system(size: 24, weight: .bold))
                Text(controls.hasAccess ? "Accessibility is on. Let’s try a swipe."
                                        : "macOS asks you to allow Accessibility for apps that respond to gestures. Sway uses it only to recognize edge swipes and keep them from scrolling.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430)
            }
            if !controls.hasAccess {
                VStack(alignment: .leading, spacing: 10) {
                    privacyLine("lock", "Touch data never leaves your Mac and is never saved.")
                    privacyLine("eye.slash", "Sway never reads what you type, only that you’re typing.")
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
                            Text("That entry belongs to an older copy of Sway. In the list, select Sway and click −. Then choose Allow Accessibility here and switch the new entry on.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Open Accessibility Settings", action: openAccessibilitySettings).buttonStyle(.bordered).controlSize(.small)
                        }
                        .padding(14).frame(maxWidth: 430, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Switch on Sway in System Settings. This page continues by itself.")
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

    private var practice: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(practiced ? "That’s it" : "Try a swipe").font(.system(size: 24, weight: .bold))
                Text(practiceInstruction).font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430)
            }
            TrackpadMap(settings: settings, selectedZone: practiced ? nil : "right", telemetry: telemetry,
                        showsTouches: telemetry.isTesting, onSelect: nil)
                .frame(width: 440, height: 250)
            Label(practiced ? "Recognized. Nothing on your Mac changed during practice." : controls.hasAccess ? "Practice mode: no levels change yet." : "Gestures need Accessibility. You can practice later in Palm protection.",
                  systemImage: practiced ? "checkmark.circle.fill" : "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
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
                    .accessibilityLabel("Sway menu bar icon")
                Image(systemName: "wifi").foregroundStyle(.secondary)
                Image(systemName: "battery.75percent").foregroundStyle(.secondary)
                Text("9:41").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).frame(maxWidth: 420)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(spacing: 8) {
                Text("Sway lives in your menu bar").font(.system(size: 24, weight: .bold))
                Text("Click Sway’s icon for volume and brightness, quick options, and Settings. Scroll over it to change the volume.")
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430)
            }
            Button("Show me") { if !preview { (NSApp.delegate as? AppDelegate)?.revealMenuBar() } }.buttonStyle(.bordered)
            VStack(spacing: 0) {
                onboardingSwitch("Open Sway when you log in", icon: "power", value: $settings.launchAtLogin)
                Divider().padding(.leading, 44)
                onboardingSwitch("Show in the Dock while windows are open", icon: "dock.rectangle", value: $settings.showDockIcon)
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
        case .practice: return practiced || !controls.hasAccess ? "Continue" : "Skip"
        case .personalize: return "Continue"
        case .done: return "Done"
        }
    }

    private func primaryAction() {
        switch step {
        case .welcome: go(to: controls.hasAccess ? .practice : .access)
        case .access:
            if controls.hasAccess { go(to: .practice); return }
            requestedAccess = true
            requestedAt = Date()
            guard !preview else { return }
            // One system surface per press: macOS's own prompt, which adds
            // Sway to the list and has its own button to System Settings.
            // If macOS doesn't show it again, the link below opens Settings.
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .practice: go(to: .personalize)
        case .personalize: go(to: .done)
        case .done: openControls()
        }
    }

    private func go(to next: Step) {
        if reduceMotion { step = next } else { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = next } }
    }

    // MARK: Helpers

    private var practiced: Bool { telemetry.isTesting && telemetry.acceptedCount > 0 }

    private var practiceInstruction: String {
        if practiced { return "Sway recognized your swipe. On the right edge that would change your \(settings.rightZoneAction.label.lowercased())." }
        let fingers = settings.minimumFingers == 1 ? "one finger" : "two fingers"
        return "Place \(fingers) inside the highlighted right edge, then swipe up."
    }

    private var currentPreset: GesturePreset {
        if settings.minimumFingers == 1 { return .oneFinger }
        return settings.palmRejectionMode == "strict" ? .precise : .everyday
    }

    /// Practice uses the safe test: gestures are recognized, nothing changes.
    private func setPracticing(_ on: Bool) {
        guard !preview else { return }
        if on, controls.hasAccess, settings.isEnabled {
            monitor.cancelCurrentGesture()
            telemetry.resetCounters()
            telemetry.isTesting = true
            monitor.start()
        } else if !on, telemetry.isTesting {
            monitor.cancelCurrentGesture()
            telemetry.isTesting = false
        }
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


// Geometry describes real physical zones. Text stays outside narrow strips.
private struct TrackpadMap: View {
    @ObservedObject var settings: TrackpadSettings
    let selectedZone: String?
    @ObservedObject var telemetry: GestureTelemetry
    let showsTouches: Bool
    let onSelect: ((String) -> Void)?
    var showsCorners = false
    @State private var trail: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let topHeight = settings.topEdgeEnabled ? height * settings.topEdgeHeight : 0
            let bottomHeight = settings.bottomEdgeEnabled ? height * settings.bottomEdgeHeight : 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 17).fill(SwayTheme.canvas)
                RoundedRectangle(cornerRadius: 17).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                zone("left", action: settings.leftZoneAction, width: width * settings.leftZoneWidth, height: height - topHeight - bottomHeight)
                    .offset(y: topHeight)
                zone("right", action: settings.rightZoneAction, width: width * settings.rightZoneWidth, height: height - topHeight - bottomHeight)
                    .offset(x: width * (1 - settings.rightZoneWidth), y: topHeight)
                if settings.bottomEdgeEnabled {
                    zone("bottom", action: settings.bottomEdgeAction, width: width, height: bottomHeight).offset(y: height - bottomHeight)
                }
                if showsCorners {
                    ForEach(["topLeftCorner", "topRightCorner", "bottomLeftCorner", "bottomRightCorner"], id: \.self) { key in
                        corner(key, width: width, height: height)
                    }
                }
                if settings.topEdgeEnabled {
                    if settings.topEdgeSwipeDirection == "horizontal" {
                        zone("topLeft", action: settings.topLeftAction, width: width / 2, height: topHeight)
                        zone("topRight", action: settings.topRightAction, width: width / 2, height: topHeight).offset(x: width / 2)
                    } else {
                        zone("top", action: settings.topEdgeAction, width: width, height: topHeight)
                    }
                }
                VStack(spacing: 6) {
                    Image(systemName: showsTouches ? "waveform.path" : "cursorarrow")
                        .font(.system(size: 16, weight: .light)).foregroundStyle(.secondary)
                    Text(showsTouches ? "Live touch view" : "Free space")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    if !showsTouches { Text("Point & scroll").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                .frame(width: width * max(0.12, 1 - settings.leftZoneWidth - settings.rightZoneWidth), height: max(0, height - topHeight - bottomHeight))
                .offset(x: width * settings.leftZoneWidth, y: topHeight)
                .allowsHitTesting(false)
                if showsTouches {
                    Path { path in
                        for (index, point) in trail.enumerated() {
                            let position = CGPoint(x: point.x * width, y: (1 - point.y) * height)
                            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                    }
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                    if telemetry.fingerCount > 0 {
                        Circle().fill(Color.primary).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .position(x: telemetry.x * width, y: (1 - telemetry.y) * height)
                            .allowsHitTesting(false)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 17))
        }
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

    private func corner(_ key: String, width: CGFloat, height: CGFloat) -> some View {
        let size = settings.tapCornerSize
        let action = settings.baseBinding(EdgeSlot.tap(key, "doubleTap")).action
        let hold = settings.baseBinding(EdgeSlot.tap(key, "tapHold")).action
        let shown = action != .disabled ? action : hold
        return ZStack {
            Rectangle().fill(Color.primary.opacity(shown == .disabled ? 0.04 : 0.18))
            Rectangle().strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            if shown != .disabled { Image(systemName: shown.icon).font(.system(size: 11, weight: .semibold)) }
        }
        .frame(width: width * size, height: height * size)
        .offset(x: key.contains("Right") ? width * (1 - size) : 0, y: key.hasPrefix("bottom") ? height * (1 - size) : 0)
        .allowsHitTesting(false)
        .accessibilityLabel("\(EdgeSlot.title(key)): \(shown.label)")
    }

    private func zone(_ key: String, action: ZoneAction, width: CGFloat, height: CGFloat) -> some View {
        let selected = selectedZone == key || (showsTouches && telemetry.activeZone == key)
        let isTop = key.hasPrefix("top") || key == "bottom"
        return Button { onSelect?(key) } label: {
            ZStack {
                Rectangle().fill(Color.primary.opacity(action == .disabled ? 0.025 : selected ? 0.16 : 0.075))
                Rectangle().strokeBorder(Color.primary.opacity(selected ? 0.6 : 0.2), lineWidth: selected ? 1.5 : 0.5)
                if width >= 38 && height >= 28 {
                    if isTop {
                        Image(systemName: key == "bottom" || settings.topEdgeSwipeDirection == "horizontal" ? "arrow.left.and.right" : "arrow.up.and.down")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: action.icon).font(.system(size: 15))
                            Image(systemName: "arrow.up.and.down").font(.system(size: 12, weight: .medium))
                        }.foregroundStyle(Color.primary.opacity(action == .disabled ? 0.35 : 0.85))
                    }
                }
            }.frame(width: max(0, width), height: max(0, height))
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil)
        .accessibilityLabel("\(EdgeSlot.title(key)): \(action.label)")
        .help("\(action.label) · click to configure")
    }
}

// MARK: - Consistent settings primitives

private struct PageTitle: View {
    let title: String
    let subtitle: String
    let icon: String?
    init(_ title: String, subtitle: String, icon: String? = nil) { self.title = title; self.subtitle = subtitle; self.icon = icon }
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One surface for every card: continuous corners, a hairline, and in light
/// mode a barely-there lift, so cards read as objects without decoration.
private struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(scheme == .dark ? Color.white.opacity(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.09 : 0.06), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 3, y: 1)
    }
}

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View { content.padding(15).modifier(CardSurface()) }
}

private extension View { func swayCard() -> some View { modifier(CardModifier()) } }


private struct Notice: View {
    let text: String
    let icon: String
    let tint: Color
    init(_ text: String, icon: String, tint: Color) { self.text = text; self.icon = icon; self.tint = tint }
    var body: some View {
        Label { Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(tint) }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .modifier(CardSurface())
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            SettingsCard(content: content)
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control
    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) { self.title = title; self.detail = detail; self.control = control }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Side by side when it fits; otherwise the control moves under
            // its title instead of running past the card's edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).fixedSize()
                    Spacer(minLength: 12)
                    control().labelsHidden()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 13.5, weight: .medium))
                    control().labelsHidden()
                }
            }
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(.horizontal, 16).padding(.vertical, 13)
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var value: Bool
    init(_ title: String, detail: String, value: Binding<Bool>) { self.title = title; self.detail = detail; _value = value }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // The switch sits at the trailing edge, like System Settings.
            Toggle(title, isOn: $value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(.horizontal, 16).padding(.vertical, 13)
    }
}

private struct LabeledSlider: View {
    let title: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    init(_ title: String, detail: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) {
        self.title = title; self.detail = detail; _value = value; self.range = range; self.display = display
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Spacer()
                Text(display).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Slider(value: $value, in: range).accessibilityLabel(title).accessibilityValue(display)
        }.padding(.horizontal, 16).padding(.vertical, 13)
    }
}

private struct ActionPicker: View {
    @Binding var action: ZoneAction
    let label: String
    var tapOnly = false
    @State private var showsLibrary = false
    var body: some View {
        Button { showsLibrary = true } label: {
            HStack(spacing: 7) {
                Text(action.label).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }.frame(width: 160)
        }.buttonStyle(.bordered).accessibilityLabel("\(label): \(action.label)")
            .help("Choose an edge action")
            .sheet(isPresented: $showsLibrary) { EdgeActionLibrary(action: $action, edgeName: label, tapOnly: tapOnly) }
    }
}

struct EdgeActionLibrary: View {
    @Binding var action: ZoneAction
    let edgeName: String
    var tapOnly = false
    var preview = false
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var unavailable: [ZoneAction: String] = [:]
    private var matching: [ZoneAction] {
        ZoneAction.allCases.filter { item in
            (!tapOnly || item.worksAsTap) && search.split(whereSeparator: \.isWhitespace).allSatisfy {
                "\(item.label) \(item.category) \(item.guidance)".localizedCaseInsensitiveContains(String($0))
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose an action").font(.system(size: 23, weight: .semibold))
                    Text(edgeName).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search actions, apps, or controls", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search edge actions")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if matching.isEmpty {
                        Text("No matching actions. Try microphone, tabs, zoom, or shortcuts.")
                            .foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    ForEach(ZoneAction.categories, id: \.self) { category in
                        let items = matching.filter { $0.category == category }
                        if !items.isEmpty {
                            Text(category).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(items) { item in
                                    Button {
                                        action = item
                                        dismiss()
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: item.icon).font(.system(size: 17)).frame(width: 24).padding(.top, 2)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(item.label).font(.system(size: 14, weight: .medium))
                                                Text(unavailable[item] ?? item.guidance).font(.system(size: 12)).foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer(minLength: 0)
                                            if action == item { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Selected") }
                                            else if unavailable[item] != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary) }
                                        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(action == item ? Color.primary.opacity(0.07) : .clear)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(unavailable[item] != nil)
                                    if item != items.last { Divider().padding(.leading, 49) }
                                }
                            }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.padding(.trailing, 5)
            }
            Text("App actions use standard macOS shortcuts. Availability depends on the active app, keyboard layout, and your shortcut settings. One-shot actions require lifting before they can run again.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 590, height: 600)
            .onAppear {
                guard !preview else { return }
                VolumeController.microphone.refresh()
                KeyboardBacklightCapability.shared.refresh()
                refreshAvailability()
            }
            .onReceive(NotificationCenter.default.publisher(for: .swayInputStateChanged)) { _ in refreshAvailability() }
            .onReceive(NotificationCenter.default.publisher(for: .swayAudioStateChanged)) { _ in refreshAvailability() }
            .onReceive(NotificationCenter.default.publisher(for: .swayKeyboardCapabilityChanged)) { _ in refreshAvailability() }
    }
    private func refreshAvailability() {
        guard !preview else { return }
        var next: [ZoneAction: String] = [:]
        if !VolumeController.microphone.isAvailable { next[.microphoneLevel] = "The current input has no writable gain control. Select a compatible input in macOS Sound settings." }
        if !VolumeController.microphone.supportsMute { next[.microphoneMute] = "The current input has no verified hardware mute control. Sway never substitutes gain zero or claims to mute other microphones." }
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

private struct ZoneEditor: View {
    let title: String
    let slot: String
    @ObservedObject var settings: TrackpadSettings
    @Binding var width: Double
    let selected: Bool
    private var binding: Binding<EdgeBinding> {
        Binding(get: { settings.baseBinding(slot) }, set: { settings.setBaseBinding($0, for: slot) })
    }
    var body: some View {
        let action = settings.baseBinding(slot).action
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(title, systemImage: action.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(action.tint)
                    Spacer()
                    ActionPicker(action: binding.action, label: "\(title) action").labelsHidden()
                }
                Text(action.guidance).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                EdgeWidthSlider(title: "\(title) width", value: $width, range: TrackpadSettings.sideZoneWidthRange)
            }.padding(14)
            BindingExtras(binding: binding, sharedFallback: true)
        }.background(selected ? action.tint.opacity(0.045) : .clear)
    }
}

/// A square quick-setting: tap to flip, with its current state underneath.
private struct QuickTile: View {
    let title: String
    let value: String
    let icon: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(isOn ? Color(nsColor: .windowBackgroundColor) : .primary)
                    .background(isOn ? Color.primary : Color.primary.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(value).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .modifier(CardSurface())
            .contentShape(RoundedRectangle(cornerRadius: 13))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(title, systemImage: binding.action.icon).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(binding.action == .disabled ? .secondary : .primary)
                    Spacer()
                    ActionPicker(action: $binding.action, label: title, tapOnly: tapOnly).labelsHidden()
                }
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(14)
            BindingExtras(binding: $binding, sharedFallback: false, tap: tapOnly)
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
            }.padding(.horizontal, 14).padding(.bottom, 12)
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
                Label("Favorite \(action.label.lowercased())", systemImage: action.icon).font(.system(size: 14, weight: .medium))
            }.toggleStyle(.switch).controlSize(.small)
            if favorite >= 0 {
                HStack {
                    Slider(value: Binding(get: { favorite }, set: { favorite = ($0 * 100).rounded() / 100 }), in: 0...1)
                        .accessibilityLabel("Favorite \(action.label)").accessibilityValue("\(Int(favorite * 100)) percent")
                    Text("\(Int((favorite * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 38)
                    Button("Use current") { favorite = max(0, min(1, (current * 100).rounded() / 100)) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }.padding(14)
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
                Toggle(isOn: Binding(get: { override != nil }, set: { override = $0 ? (tapOnly && !everyday.action.worksAsTap ? EdgeBinding(.disabled) : everyday) : nil })) {
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
            Text(title == "Top height" ? "Height" : "Width").font(.system(size: 12)).foregroundStyle(.secondary)
            // Snap to half-percent changes without drawing dozens of tick marks.
            // The text field still accepts finer values such as 1.2%.
            Slider(value: Binding(get: { value }, set: {
                value = min(range.upperBound, max(range.lowerBound, ($0 * 200).rounded() / 200))
            }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(value * 100, specifier: "%.1f") percent")
            HStack(spacing: 3) {
                TextField(title, value: percent, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width: 43).accessibilityLabel("Exact \(title.lowercased()) in percent")
                Text("%").foregroundStyle(.secondary)
            }.font(.system(size: 12)).monospacedDigit()
        }
        .help("\(Int(range.lowerBound * 100))–\(Int(range.upperBound * 100))%. Type an exact value, including decimals.")
    }
}

private struct LimitEditor: View {
    let action: ZoneAction
    @Binding var lower: Double
    @Binding var upper: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(action.label, systemImage: action.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(action.tint)
                Spacer()
                Text("\(Int(lower * 100))–\(Int(upper * 100))%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            HStack {
                Text("Min").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                Slider(value: Binding(get: { lower }, set: { lower = min($0, upper - 0.05) }), in: 0...0.95, step: 0.01).accessibilityLabel("Minimum \(action.label)")
            }
            HStack {
                Text("Max").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                Slider(value: Binding(get: { upper }, set: { upper = max($0, lower + 0.05) }), in: 0.05...1, step: 0.01).accessibilityLabel("Maximum \(action.label)")
            }
        }.padding(14).tint(action.tint)
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
                    Text("\(telemetry.acceptedCount) accepted · \(telemetry.rejectedCount) stopped")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(recording ? "Press a shortcut. Escape cancels." : detail)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
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
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).onDisappear(perform: stop)
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
                    Text("Sway pauses gestures whenever these apps are active.")
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

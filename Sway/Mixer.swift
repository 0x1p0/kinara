import AppKit
import Combine
import CoreAudio

// The mixer: every app that plays sound gets a fader, with mute, solo, call
// ducking, per-app speakers and boost. Ported from Faders and built on Sway's
// own tap engine (AppVolumeController), so there is only ever one tap per app.
//
// Sway only reroutes an app while it needs it: when its level isn't 100%,
// it's muted, silenced by solo, lowered for a call, or sent to another
// output. Every other app plays on its normal path, untouched.

/// What the user chose for one app. Saved per bundle identifier.
struct MixerChannelSettings: Codable, Equatable {
    var volume: Float = 1
    var isMuted = false
    /// nil follows the default output.
    var deviceUID: String?
    var isDefault: Bool { self == MixerChannelSettings() }
}

/// The mixer's state for one app, as the rules see it.
struct MixerState: Equatable {
    var volume: Float
    var isMuted = false
    var deviceUID: String?
    var isUsingMicrophone = false
    var hasPlayed = true
}

/// The outcome of the mixing rules for one app.
struct MixerDecision: Equatable {
    var mix: AppMix
    var isSoloed = false
    var isSilencedBySolo = false
    var isDucked = false
}

enum MixerRules {
    /// Pure: what one app should sound like, given the whole mixer. Solo
    /// silences everyone else; a call lowers apps that aren't on it (or
    /// soloed); mute and solo win over everything.
    static func decide(_ state: MixerState, id: String, soloID: String?, ducking: Bool, duckLevel: Float) -> MixerDecision {
        let soloed = soloID == id
        let silenced = soloID != nil && !soloed && state.hasPlayed
        let ducked = ducking && !state.isUsingMicrophone && !soloed && state.hasPlayed
        var gain = state.isMuted || silenced ? 0 : state.volume
        if ducked { gain *= min(max(duckLevel, 0), 1) }
        return MixerDecision(mix: AppMix(gain: gain, route: state.deviceUID), isSoloed: soloed, isSilencedBySolo: silenced, isDucked: ducked)
    }

    /// Plain-English status, most important first.
    static func status(isSoloed: Bool, isUsingMicrophone: Bool, isMuted: Bool, isSilencedBySolo: Bool, isDucked: Bool, isPlaying: Bool) -> String {
        if isSoloed { return "Solo" }
        if isUsingMicrophone { return "On a call" }
        if isMuted { return "Muted" }
        if isSilencedBySolo { return "Silenced by solo" }
        if isDucked { return "Lowered for your call" }
        return isPlaying ? "Playing" : "Not playing"
    }

    /// Settings worth remembering (default settings are forgotten).
    static func store(_ settings: MixerChannelSettings, for id: String, in values: inout [String: MixerChannelSettings]) {
        values[id] = settings.isDefault ? nil : settings
    }
}

/// One app's strip on the mixer.
final class MixerChannel: ObservableObject, Identifiable {
    let id: String
    @Published var name: String
    let icon: NSImage
    @Published var isPlaying = false
    @Published var isUsingMicrophone = false
    /// Has made a sound since Sway started (or since the app launched).
    @Published var hasPlayed = false
    @Published var volume: Float
    @Published var isMuted: Bool
    @Published var deviceUID: String?
    @Published var isSoloed = false
    @Published var isSilencedBySolo = false
    @Published var isDucked = false
    /// Why the last change didn't apply, if it didn't.
    @Published var problem: String?
    /// Has audio processes right now, so it can be rerouted.
    var hasAudio = false

    init(id: String, name: String, icon: NSImage, settings: MixerChannelSettings) {
        self.id = id
        self.name = name
        self.icon = icon
        volume = settings.volume
        isMuted = settings.isMuted
        deviceUID = settings.deviceUID
    }

    var settings: MixerChannelSettings { MixerChannelSettings(volume: volume, isMuted: isMuted, deviceUID: deviceUID) }
    var state: MixerState { MixerState(volume: volume, isMuted: isMuted, deviceUID: deviceUID, isUsingMicrophone: isUsingMicrophone, hasPlayed: hasPlayed) }
    var status: String {
        MixerRules.status(isSoloed: isSoloed, isUsingMicrophone: isUsingMicrophone, isMuted: isMuted,
                          isSilencedBySolo: isSilencedBySolo, isDucked: isDucked, isPlaying: isPlaying)
    }
}

/// One app in the audio picker, copied from its mixer channel.
struct AudioPickerApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?
    var isPlaying = false
    var isMuted = false
    var isSoloed = false
    var isSilencedBySolo = false
    var hasPlayed = false
    var volume: Float = 1

    static func == (lhs: AudioPickerApp, rhs: AudioPickerApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isPlaying == rhs.isPlaying && lhs.isMuted == rhs.isMuted
            && lhs.isSoloed == rhs.isSoloed && lhs.isSilencedBySolo == rhs.isSilencedBySolo
            && lhs.hasPlayed == rhs.hasPlayed && lhs.volume == rhs.volume
    }

    /// What lifting does to this app: mute or unmute, or (slid right) solo.
    func action(solo: Bool) -> String {
        solo ? (isSoloed ? "End solo" : "Only this") : (isMuted ? "Unmute" : "Mute")
    }

    var status: String {
        if isSoloed { return "Only this app is playing" }
        if isMuted { return "Muted" }
        if isSilencedBySolo { return "Quiet while another app plays alone" }
        if isPlaying { return volume < 0.995 ? "Playing · \(Int((volume * 100).rounded()))%" : "Playing" }
        return "Not playing right now"
    }
}

/// Which apps the audio picker offers, and in what order.
enum AudioPickerRules {
    /// Apps worth offering: playing now, muted or soloed (so they can be undone),
    /// or heard from since Kinara started. Sounding apps first, then the rest.
    static func ordered(_ apps: [AudioPickerApp]) -> [AudioPickerApp] {
        func rank(_ app: AudioPickerApp) -> Int {
            if app.isPlaying && !app.isMuted && !app.isSilencedBySolo { return 0 }
            if app.isMuted || app.isSoloed || app.isSilencedBySolo { return 1 }
            return 2
        }
        return apps.filter { $0.isPlaying || $0.isMuted || $0.isSoloed || $0.hasPlayed }.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Keeps the highlight on the same app when the list changes under it.
    static func selection(keeping id: String?, previous: Int, in apps: [AudioPickerApp]) -> Int {
        if previous < 0 || apps.isEmpty { return apps.isEmpty ? -1 : previous }
        if let id, let index = apps.firstIndex(where: { $0.id == id }) { return index }
        return min(previous, apps.count - 1)
    }
}

/// An output the user can send an app to.
struct MixerOutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("homepod") { return "homepod.fill" }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeBuiltIn: return lower.contains("headphone") ? "headphones" : "laptopcomputer"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// "System Audio Recording" is what macOS calls the permission process taps
/// need. There's no public preflight, so this uses TCC's optional SPI (as
/// Apple's sample tools do); without it, macOS prompts on the first tap.
enum MixerPermission {
    enum Status { case unknown, authorized, denied }
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW | RTLD_LOCAL)
    private static let preflight: Preflight? = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
    private static let request: Request? = handle.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: Request.self) }

    static var status: Status {
        switch preflight?(service, nil) {
        case 0?: return .authorized
        case 1?: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let request else { completion(true); return }
        request(service, nil) { granted in DispatchQueue.main.async { completion(granted) } }
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

final class MixerModel: ObservableObject {
    static let shared = MixerModel()
    static var isSupported: Bool { AppVolumeController.isSupported }

    @Published private(set) var channels: [MixerChannel] = []
    @Published private(set) var devices: [MixerOutputDevice] = []
    @Published private(set) var defaultDeviceName = ""
    @Published private(set) var permission: MixerPermission.Status = .unknown
    @Published private(set) var soloID: String?
    @Published private(set) var callers: [MixerChannel] = []
    /// The user chose "Don't lower" for the current call.
    @Published private(set) var duckingPaused = false

    @Published var showInMenu: Bool { didSet { defaults.set(showInMenu, forKey: Keys.showInMenu) } }
    @Published var duckDuringCalls: Bool { didSet { defaults.set(duckDuringCalls, forKey: Keys.duck); updateMonitoring(); applyMix() } }
    /// How loud other apps stay during a call, 0…1.
    @Published var duckLevel: Double { didSet { defaults.set(duckLevel, forKey: Keys.duckLevel); applyMix() } }
    /// Lets faders go past 100 %, with a soft limiter.
    @Published var allowBoost: Bool {
        didSet {
            defaults.set(allowBoost, forKey: Keys.boost)
            if !allowBoost { channels.filter { $0.volume > 1 }.forEach { setVolume(1, for: $0) } }
        }
    }
    /// List apps that haven't made a sound yet (so you can mute them first).
    @Published var showOtherApps: Bool { didSet { defaults.set(showOtherApps, forKey: Keys.others) } }

    var maxVolume: Float { allowBoost ? AppVolumeController.boostLimit : 1 }
    var isDucking: Bool { duckDuringCalls && !duckingPaused && !callers.isEmpty }
    var playingChannels: [MixerChannel] { channels.filter(\.hasPlayed) }
    var otherChannels: [MixerChannel] { channels.filter { !$0.hasPlayed } }
    var soloChannel: MixerChannel? { soloID.flatMap { id in channels.first { $0.id == id } } }

    private enum Keys {
        static let showInMenu = "mixerShowInMenu", duck = "mixerDuckDuringCalls", duckLevel = "mixerDuckLevel"
        static let boost = "mixerAllowBoost", others = "mixerShowOtherApps", channels = "mixerChannels.v1"
    }
    private let defaults: UserDefaults
    private let preview: Bool
    private var stored: [String: MixerChannelSettings] = [:]
    private var channelsByID: [String: MixerChannel] = [:]
    private var heardFrom: Set<String> = []
    /// The last mix sent to the engine per app; nil means "untouched".
    private var sent: [String: AppMix] = [:]
    private var monitor: MixerProcessMonitor?
    private var deviceListeners: [MixerPropertyListener] = []
    private var panelVisible = false
    private var pickerVisible = false
    private var rechecks = 0
    private var reportedUnnamed: Set<pid_t> = []
    private static let maxRechecks = 4
    /// Where the mixer says what it hears. The app sends it to Kinara's log.
    static var log: ((String) -> Void)?
    private var saveScheduled = false

    init(defaults: UserDefaults = .standard, preview: Bool = false) {
        self.defaults = defaults
        self.preview = preview
        defaults.register(defaults: [Keys.showInMenu: true, Keys.duck: false, Keys.duckLevel: 0.3, Keys.boost: false, Keys.others: false])
        showInMenu = defaults.bool(forKey: Keys.showInMenu)
        duckDuringCalls = defaults.bool(forKey: Keys.duck)
        duckLevel = min(max(defaults.double(forKey: Keys.duckLevel), 0.05), 0.8)
        allowBoost = defaults.bool(forKey: Keys.boost)
        showOtherApps = defaults.bool(forKey: Keys.others)
        if let data = defaults.data(forKey: Keys.channels),
           let decoded = try? JSONDecoder().decode([String: MixerChannelSettings].self, from: data) {
            stored = decoded.filter { !$0.value.isDefault && $0.value.volume.isFinite }
        }
        if preview { loadPreviewChannels() }
    }

    /// Call once at launch. Does nothing on macOS before 14.2.
    func start() {
        guard Self.isSupported, !preview else { return }
        permission = MixerPermission.status
        refreshDevices()
        updateMonitoring()
    }

    func shutdown() {
        save()
        monitor = nil
        deviceListeners.removeAll()
    }

    /// The menu bar panel opened or closed. Listing apps needs the monitor.
    func setPanelVisible(_ visible: Bool) {
        guard Self.isSupported, !preview else { return }
        panelVisible = visible
        if visible {
            refreshPermission()
            refreshDevices()
        }
        updateMonitoring()
    }

    /// The audio picker is up: it lists apps, so the process list must be watched.
    func setPickerVisible(_ visible: Bool) {
        guard Self.isSupported, !preview else { return }
        pickerVisible = visible
        if visible { refreshPermission() }
        updateMonitoring()
    }

    /// Watches the HAL's process list only while it can matter: the panel or
    /// audio picker is open, ducking is on, an app has saved settings, or solo is active.
    private func updateMonitoring() {
        guard Self.isSupported, !preview else { return }
        let needed = panelVisible || pickerVisible || duckDuringCalls || !stored.isEmpty || soloID != nil
        if needed, monitor == nil {
            let monitor = MixerProcessMonitor()
            monitor.onChange = { [weak self] processes in self?.processesChanged(processes) }
            self.monitor = monitor
            monitor.start()
        } else if !needed, monitor != nil {
            monitor = nil
        }
    }

    // MARK: Permission

    func refreshPermission() {
        let status = MixerPermission.status
        // The SPI can report "unknown" after a grant until relaunch; never downgrade.
        guard status != permission, !(permission == .authorized && status == .unknown) else { return }
        permission = status
        if status == .authorized { resendAll() }
    }

    func requestPermission() {
        guard !preview else { return }
        if permission == .denied { MixerPermission.openSystemSettings(); return }
        MixerPermission.request { [weak self] granted in
            guard let self else { return }
            permission = granted ? .authorized : .denied
            if granted { resendAll() }
        }
    }

    // MARK: Processes → channels

    private struct Group {
        var app: MixerApp
        var playing = false
        var usingMicrophone = false
    }

    private func processesChanged(_ processes: [MixerAudioProcess]) {
        let ownPID = getpid(), ownBundleID = Bundle.main.bundleIdentifier
        var groups: [String: Group] = [:]
        var unnamed: [MixerAudioProcess] = []
        for process in processes where process.pid != ownPID {
            guard let app = MixerAppResolver.resolve(process) else {
                if process.isRunningOutput || process.isRunningInput { unnamed.append(process) }
                continue
            }
            guard app.key != ownBundleID, !app.key.hasPrefix("pid.") else { continue }
            var group = groups[app.key] ?? Group(app: app)
            if process.isRunningOutput { group.playing = true }
            if process.isRunningInput { group.usingMicrophone = true }
            groups[app.key] = group
        }
        MixerAppResolver.prune(keeping: Set(processes.map(\.pid)))
        // A sounding app that just launched may not be nameable yet: look
        // again a few times rather than waiting for its next start or stop.
        if unnamed.isEmpty {
            rechecks = 0
        } else if rechecks < Self.maxRechecks {
            rechecks += 1
            monitor?.recheck(after: 1.1)
            for process in unnamed where !reportedUnnamed.contains(process.pid) {
                reportedUnnamed.insert(process.pid)
                Self.log?("Sound from pid \(process.pid) (\(process.bundleID ?? "no bundle ID")) has no app to show yet")
            }
        }
        reportedUnnamed.formIntersection(processes.map(\.pid))
        for (id, group) in groups where group.playing { heardFrom.insert(id) }
        heardFrom.formIntersection(groups.keys)

        // Apps that have played, have saved settings, or are ordinary Dock apps.
        let visible = groups.filter { id, group in heardFrom.contains(id) || stored[id] != nil || group.app.isRegular }
        for (id, channel) in channelsByID where visible[id] == nil {
            channel.hasAudio = false
            channelsByID[id] = nil
            // The engine drops a tap by itself once the app's processes are gone.
            sent[id] = nil
        }
        for (id, group) in visible {
            let channel = channelsByID[id] ?? MixerChannel(id: id, name: group.app.name, icon: group.app.icon, settings: stored[id] ?? MixerChannelSettings())
            channelsByID[id] = channel
            if !channel.hasAudio { sent[id] = nil }
            channel.hasAudio = true
            if channel.name != group.app.name { channel.name = group.app.name }
            if channel.isPlaying != group.playing {
                channel.isPlaying = group.playing
                Self.log?("\(group.app.name) \(group.playing ? "started" : "stopped") playing")
            }
            if channel.isUsingMicrophone != group.usingMicrophone { channel.isUsingMicrophone = group.usingMicrophone }
            let played = heardFrom.contains(id)
            if channel.hasPlayed != played { channel.hasPlayed = played }
        }
        let sorted = channelsByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sorted.map(\.id) != channels.map(\.id) { channels = sorted }
        applyMix()
    }

    // MARK: Changes from the mixer

    func setVolume(_ volume: Float, for channel: MixerChannel) {
        let clamped = min(max(volume.isFinite ? volume : 1, 0), maxVolume)
        guard clamped != channel.volume else { return }
        channel.volume = clamped
        if clamped > 0, channel.isMuted { channel.isMuted = false }
        remember(channel)
        apply(channel, userInitiated: true)
    }

    func toggleMute(_ channel: MixerChannel) {
        channel.isMuted.toggle()
        remember(channel)
        apply(channel, userInitiated: true)
    }

    func setRoute(_ uid: String?, for channel: MixerChannel) {
        guard channel.deviceUID != uid else { return }
        channel.deviceUID = uid
        remember(channel)
        apply(channel, userInitiated: true)
    }

    func toggleSolo(_ channel: MixerChannel) {
        soloID = soloID == channel.id ? nil : channel.id
        updateMonitoring()
        applyMix(userInitiated: true)
    }

    func endSolo() {
        guard soloID != nil else { return }
        soloID = nil
        updateMonitoring()
        applyMix(userInitiated: true)
    }

    func pauseDuckingForThisCall() {
        duckingPaused = true
        applyMix()
    }

    func resetAllChannels() {
        soloID = nil
        for channel in channels {
            channel.volume = 1
            channel.isMuted = false
            channel.deviceUID = nil
        }
        stored.removeAll()
        scheduleSave()
        updateMonitoring()
        applyMix(userInitiated: true)
    }

    // MARK: Edge actions (the app in front)

    func volume(forApp id: String) -> Float { channelsByID[id]?.volume ?? stored[id]?.volume ?? 1 }

    /// The "App volume" edge action. Applies right away and reports the level
    /// the user set (not the ducked level), or why it couldn't.
    func adjustVolume(_ volume: Float, forApp id: String, completion: @escaping (AppVolumeResult) -> Void) {
        let channel = channel(forApp: id)
        let previous = channel.settings
        // Edges work in 0…100%; boost stays a mixer-only extra.
        channel.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
        if channel.volume > 0, channel.isMuted { channel.isMuted = false }
        let decision = decide(channel)
        AppVolumeController.shared.requestMix(decision.mix, for: id, maximumGain: maxVolume) { [weak self] result in
            guard let self else { return }
            switch result {
            case .applied:
                sent[id] = decision.mix
                remember(channel)
                completion(.applied(channel.volume))
            case let .failed(message):
                channel.volume = previous.volume
                channel.isMuted = previous.isMuted
                completion(.failed(message))
            case .cancelled:
                completion(.cancelled)
            }
        }
    }

    /// Mute or unmute the app in front; nil toggles. Returns the new state.
    @discardableResult
    func setMuted(_ muted: Bool?, forApp id: String, remember keep: Bool = true) -> Bool {
        let channel = channel(forApp: id)
        channel.isMuted = muted ?? !channel.isMuted
        // A playback hold mutes only for a moment; it isn't a setting to keep.
        if keep { remember(channel) }
        apply(channel, userInitiated: true)
        return channel.isMuted
    }

    /// Solo the app in front, or end solo; nil toggles. Returns whether it's soloed.
    @discardableResult
    func setSoloed(_ soloed: Bool?, forApp id: String) -> Bool {
        let channel = channel(forApp: id)
        let on = soloed ?? (soloID != id)
        soloID = on ? channel.id : (soloID == id ? nil : soloID)
        updateMonitoring()
        applyMix(userInitiated: true)
        return on
    }

    /// Apps sending sound out right now, read once from the HAL. Main thread
    /// only (the resolver's cache). Apps in a call, recording too, are left out.
    static func soundingApps() -> Set<String> {
        var output = Set<String>(), calling = Set<String>()
        for (app, process) in audioProcesses(includingQuiet: false) {
            if process.isRunningOutput { output.insert(app) }
            if process.isRunningInput { calling.insert(app) }
        }
        return output.subtracting(calling)
    }

    /// Apps with audio set up, quiet or not: a paused player keeps it. Main thread only.
    static func audioApps() -> Set<String> {
        Set(audioProcesses(includingQuiet: true).map(\.app))
    }

    private static func audioProcesses(includingQuiet: Bool) -> [(app: String, process: MixerAudioProcess)] {
        guard isSupported else { return [] }
        let own = Bundle.main.bundleIdentifier
        var processes: [(app: String, process: MixerAudioProcess)] = []
        for id in MixerHAL.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = MixerHAL.value(id, kAudioProcessPropertyPID, default: -1)
            let out = MixerHAL.value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            let input = MixerHAL.value(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0
            guard pid > 0, pid != getpid(), out || input || includingQuiet else { continue }
            let process = MixerAudioProcess(objectID: id, pid: pid, bundleID: MixerHAL.string(id, kAudioProcessPropertyBundleID),
                                            isRunningOutput: out, isRunningInput: input)
            guard let app = MixerAppResolver.resolve(process), app.isRegular, app.key != own, !app.key.hasPrefix("pid.") else { continue }
            processes.append((app.key, process))
        }
        return processes
    }

    func displayName(forApp id: String) -> String {
        channelsByID[id]?.name ?? NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? "This app"
    }

    private func channel(forApp id: String) -> MixerChannel {
        if let channel = channelsByID[id] { return channel }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        let channel = MixerChannel(id: id, name: running?.localizedName ?? "This app",
                                   icon: running?.icon ?? NSWorkspace.shared.icon(for: .application),
                                   settings: stored[id] ?? MixerChannelSettings())
        channel.hasAudio = true
        channel.hasPlayed = true
        heardFrom.insert(id)
        channelsByID[id] = channel
        channels = channelsByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return channel
    }

    // MARK: Mixing

    private func decide(_ channel: MixerChannel) -> MixerDecision {
        MixerRules.decide(channel.state, id: channel.id, soloID: soloID, ducking: isDucking, duckLevel: Float(duckLevel))
    }

    /// Recomputes solo/ducking and sends each changed mix to the engine.
    private func applyMix(userInitiated: Bool = false) {
        if let soloID, channelsByID[soloID] == nil { self.soloID = nil; updateMonitoring() }
        let newCallers = channels.filter(\.isUsingMicrophone)
        if newCallers.map(\.id) != callers.map(\.id) { callers = newCallers }
        if callers.isEmpty, duckingPaused { duckingPaused = false }
        for channel in channelsByID.values { apply(channel, userInitiated: userInitiated) }
    }

    private func apply(_ channel: MixerChannel, userInitiated: Bool) {
        let decision = decide(channel)
        if channel.isSoloed != decision.isSoloed { channel.isSoloed = decision.isSoloed }
        if channel.isSilencedBySolo != decision.isSilencedBySolo { channel.isSilencedBySolo = decision.isSilencedBySolo }
        if channel.isDucked != decision.isDucked { channel.isDucked = decision.isDucked }
        guard !preview, channel.hasAudio, (sent[channel.id] ?? AppMix(gain: 1)) != decision.mix else { return }
        // Changes the user didn't make (saved settings, ducking) only apply once
        // macOS has granted access, so Sway never prompts out of the blue.
        guard userInitiated || permission == .authorized else { return }
        let id = channel.id
        sent[id] = decision.mix
        AppVolumeController.shared.requestMix(decision.mix, for: id, maximumGain: maxVolume) { [weak self, weak channel] result in
            guard let self, let channel else { return }
            switch result {
            case .applied:
                if channel.problem != nil { channel.problem = nil }
            case let .failed(message):
                if sent[id] == decision.mix { sent[id] = nil }
                // An app that isn't playing yet picks its settings up when it starts.
                channel.problem = message.contains("isn't playing") ? nil : message
            case .cancelled: break
            }
        }
    }

    private func resendAll() {
        sent.removeAll()
        applyMix()
    }

    private func remember(_ channel: MixerChannel) {
        let had = stored[channel.id] != nil
        MixerRules.store(channel.settings, for: channel.id, in: &stored)
        scheduleSave()
        if had != (stored[channel.id] != nil) { updateMonitoring() }
    }

    private func scheduleSave() {
        guard !saveScheduled, !preview else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.save() }
    }

    private func save() {
        saveScheduled = false
        guard !preview, let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Keys.channels)
    }

    // MARK: Devices

    private func refreshDevices() {
        if deviceListeners.isEmpty {
            deviceListeners = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice].map {
                MixerPropertyListener(AudioObjectID(kAudioObjectSystemObject), MixerHAL.address($0)) { [weak self] in self?.refreshDevices() }
            }
        }
        let list = MixerHAL.outputDevices()
        if list != devices { devices = list }
        let defaultID = MixerHAL.defaultOutputID()
        let name = list.first { $0.id == defaultID }?.name ?? ""
        if name != defaultDeviceName { defaultDeviceName = name }
    }

    func device(uid: String?) -> MixerOutputDevice? { uid.flatMap { uid in devices.first { $0.uid == uid } } }

    // MARK: Preview (RenderUI and tests; never touches Core Audio)

    private func loadPreviewChannels() {
        let demo: [(String, String, Float, Bool, Bool, Bool)] = [
            ("com.apple.Music", "Music", 0.7, false, true, false),
            ("com.apple.Safari", "Safari", 1, false, true, false),
            ("com.apple.FaceTime", "FaceTime", 1, false, false, true),
            ("com.tinyspeck.slackmacgap", "Slack", 0.35, true, false, false),
        ]
        permission = .authorized
        devices = [MixerOutputDevice(id: 1, uid: "built-in", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
                   MixerOutputDevice(id: 2, uid: "airpods", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)]
        defaultDeviceName = "MacBook Pro Speakers"
        for (id, name, volume, muted, playing, call) in demo {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .application)
            let channel = MixerChannel(id: id, name: name, icon: icon, settings: MixerChannelSettings(volume: volume, isMuted: muted))
            channel.isPlaying = playing
            channel.hasPlayed = true
            channel.isUsingMicrophone = call
            channelsByID[id] = channel
        }
        channels = channelsByID.values.sorted { $0.name < $1.name }
        callers = channels.filter(\.isUsingMicrophone)
        applyMix()
    }
}

// MARK: - Processes and apps

/// A process known to the audio HAL.
struct MixerAudioProcess: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

/// The user-facing app an audio process belongs to.
struct MixerApp {
    let key: String
    let name: String
    let icon: NSImage
    /// A normal Dock app, as opposed to a menu bar extra or background agent.
    var isRegular = true
}

/// Watches the HAL's process list and each process's output and input state.
/// Event-driven: there are no timers, and it only exists while needed.
final class MixerProcessMonitor {
    /// What a process object announces when its audio starts or stops. Core
    /// Audio posts "is running" and "devices" changes, but not the output and
    /// input properties themselves, so listening only to those missed every
    /// start and stop of an app already connected, such as a browser's audio
    /// helper. Those two stay in case a later macOS posts them; the values
    /// themselves read correctly either way.
    static let stateSelectors: [AudioObjectPropertySelector] = [
        kAudioProcessPropertyIsRunning, kAudioProcessPropertyDevices,
        kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput,
    ]
    var onChange: (([MixerAudioProcess]) -> Void)?
    private var listListener: MixerPropertyListener?
    private var stateListeners: [AudioObjectID: [MixerPropertyListener]] = [:]
    private var reloadScheduled = false
    private var recheckScheduled = false

    func start() {
        listListener = MixerPropertyListener(AudioObjectID(kAudioObjectSystemObject), MixerHAL.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.scheduleReload()
        }
        reload()
    }

    /// Looks again shortly, for a sounding process whose app couldn't be named yet.
    func recheck(after delay: TimeInterval) {
        guard !recheckScheduled else { return }
        recheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.recheckScheduled = false
            self?.reload()
        }
    }

    /// Coalesces bursts of HAL notifications into one reload.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    private func reload() {
        let ids = MixerHAL.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        let current = Set(ids)
        for id in stateListeners.keys where !current.contains(id) { stateListeners[id] = nil }
        for id in ids where stateListeners[id] == nil {
            stateListeners[id] = Self.stateSelectors.map {
                MixerPropertyListener(id, MixerHAL.address($0)) { [weak self] in self?.scheduleReload() }
            }
        }
        let processes = ids.compactMap { id -> MixerAudioProcess? in
            let pid: pid_t = MixerHAL.value(id, kAudioProcessPropertyPID, default: -1)
            guard pid > 0 else { return nil }
            return MixerAudioProcess(objectID: id, pid: pid, bundleID: MixerHAL.string(id, kAudioProcessPropertyBundleID),
                                     isRunningOutput: MixerHAL.value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0,
                                     isRunningInput: MixerHAL.value(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0)
        }
        onChange?(processes)
    }
}

/// What each process resolved to. A miss is tried again after a moment: an
/// app that just launched isn't known to Launch Services until it checks in,
/// and remembering that first miss hid its audio for as long as it ran.
struct ResolutionCache<Value> {
    var retryAfter: TimeInterval = 1
    private var hits: [pid_t: Value] = [:]
    private var misses: [pid_t: TimeInterval] = [:]

    mutating func value(for pid: pid_t, now: TimeInterval, lookup: () -> Value?) -> Value? {
        if let hit = hits[pid] { return hit }
        if let missed = misses[pid], now - missed < retryAfter { return nil }
        guard let found = lookup() else {
            misses[pid] = now
            return nil
        }
        misses[pid] = nil
        hits[pid] = found
        return found
    }

    mutating func prune(keeping pids: Set<pid_t>) {
        hits = hits.filter { pids.contains($0.key) }
        misses = misses.filter { pids.contains($0.key) }
    }
}

/// Maps helper processes (Chrome Helper, WebKit.WebContent, Electron
/// renderers…) to the app the user sees.
enum MixerAppResolver {
    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: Responsible? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)
    }()
    private static var cache = ResolutionCache<MixerApp>()

    static func resolve(_ process: MixerAudioProcess) -> MixerApp? {
        cache.value(for: process.pid, now: ProcessInfo.processInfo.systemUptime) { lookup(process) }
    }

    static func prune(keeping pids: Set<pid_t>) { cache.prune(keeping: pids) }

    private static func lookup(_ process: MixerAudioProcess) -> MixerApp? {
        // Credit, in order: the responsible process (what Activity Monitor
        // attributes helpers to), the process itself, then its parents (for
        // command-line tools such as afplay in Terminal).
        var seeds = [pid_t]()
        if let responsible = responsiblePID?(process.pid), responsible > 0, responsible != process.pid { seeds.append(responsible) }
        seeds.append(process.pid)
        var candidates = seeds
        for seed in seeds {
            var pid = seed
            for _ in 0..<8 {
                guard let parent = parentPID(of: pid) else { break }
                candidates.append(parent)
                pid = parent
            }
        }
        for pid in candidates {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if let host = hostApp(containing: app) { return host }
            // Bare XPC services (WebKit.GPU and friends) aren't something a user would recognise.
            if app.activationPolicy != .prohibited, app.bundleURL?.pathExtension == "app" { return make(app) }
        }
        if let bundleID = process.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.activationPolicy != .prohibited }) {
            return make(app)
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// Helpers nested inside another bundle (Foo.app/Contents/Frameworks/Foo Helper.app) belong to the outer app.
    private static func hostApp(containing app: NSRunningApplication) -> MixerApp? {
        guard let path = app.bundleURL?.path, let range = path.range(of: ".app/") else { return nil }
        let hostPath = String(path[..<range.lowerBound]) + ".app"
        guard let bundleID = Bundle(path: hostPath)?.bundleIdentifier else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { return make(running) }
        let name = FileManager.default.displayName(atPath: hostPath).replacingOccurrences(of: ".app", with: "")
        return MixerApp(key: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: hostPath), isRegular: false)
    }

    private static func make(_ app: NSRunningApplication) -> MixerApp {
        MixerApp(key: app.bundleIdentifier ?? "pid.\(app.processIdentifier)",
                 name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "PID \(app.processIdentifier)",
                 icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
                 isRegular: app.activationPolicy == .regular)
    }
}

// MARK: - HAL helpers

enum MixerHAL {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var address = address(selector, scope: scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func defaultOutputID() -> AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    /// Real outputs a user can pick: never Sway's own private aggregates.
    static func outputDevices() -> [MixerOutputDevice] {
        objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard !objectIDs(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("com.sway."),
                  let name = string(id, kAudioObjectPropertyName),
                  value(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput, default: UInt32(0)) != 0
            else { return nil }
            return MixerOutputDevice(id: id, uid: uid, name: name, transport: value(id, kAudioDevicePropertyTransportType, default: UInt32(0)))
        }
    }
}

/// Registers a Core Audio property listener for its lifetime; callbacks arrive on main.
final class MixerPropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var isActive = false

    init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        block = { _, _ in handler() }
        isActive = AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block) == noErr
    }

    deinit {
        guard isActive else { return }
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}

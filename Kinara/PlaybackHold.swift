import AppKit

/// The Play / pause action, made predictable with several apps playing (see
/// PlaybackRules in NowPlaying.swift). One press quiets everything that's
/// playing; the next brings back exactly that. With a single app it behaves
/// as before, except that Music and Spotify are paused directly.
final class PlaybackHoldController {
    static let shared = PlaybackHoldController()
    /// Long enough for a player to act on the key and report it.
    static let settle: TimeInterval = 0.35
    /// How long a press meant to start something has to make a sound.
    static let startWindow: TimeInterval = 1.2
    /// How long after "asleep" the next press opens the app instead.
    static let wakeWindow: TimeInterval = 30

    // Main-thread state.
    private var hold: PlaybackHold?
    /// The app whose sleeping page the next press opens (PlaybackRules.sleepingPage).
    private var sleeper: (id: String, until: TimeInterval)?
    /// The apps the key paused, for naming them when they come back.
    private var keyApps: Set<String> = []
    private var busy = false
    // Worker-confined: NSAppleScript instances are only touched here.
    private let worker = DispatchQueue(label: "com.kinara.playback-hold", qos: .userInitiated)
    private var scripts: [String: NSAppleScript] = [:]

    private init() {}

    /// The app the next press opens to wake its page, while that's still the
    /// way to start playback.
    var appToWake: String? {
        guard let sleeper, ProcessInfo.processInfo.systemUptime < sleeper.until, MixerModel.soundingApps().isEmpty else { return nil }
        return sleeper.id
    }

    /// Returns false only when nothing could be sent. `nowPlaying` shows the
    /// track HUD for single-app changes; several apps get one message instead.
    @discardableResult
    func toggle(placement: OSDPlacement?, nowPlaying: @escaping () -> Void) -> Bool {
        guard !busy else { return true }
        if let id = appToWake {
            wake(id)
            return true
        }
        sleeper = nil
        let running = NowPlayingPlayer.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
        let sounding = MixerModel.soundingApps()
        // Nothing Kinara can pause itself and nothing held: exactly the old behavior.
        guard !running.isEmpty || !(hold?.isEmpty ?? true) else {
            guard sendKey() else { return false }
            nowPlaying()
            if sounding.isEmpty { confirmStart(placement: placement) }
            return true
        }
        busy = true
        readStates(running) { [self] states in
            // A player Kinara may not script (Automation declined) counts as any other app.
            let snapshot = PlaybackSnapshot(players: states, others: sounding.subtracting(states.keys))
            run(PlaybackRules.plan(snapshot, hold: hold), snapshot: snapshot, placement: placement, nowPlaying: nowPlaying)
        }
        return true
    }

    private func run(_ plan: PlaybackPlan, snapshot: PlaybackSnapshot, placement: OSDPlacement?, nowPlaying: @escaping () -> Void) {
        switch plan {
        case .key:
            // Apps still held silent stay in the hold, so a later press can bring them back.
            hold = hold.map { PlaybackHold(muted: $0.muted) }.flatMap { $0.isEmpty ? nil : $0 }
            busy = false
            guard sendKey() else { return }
            nowPlaying()
            if snapshot.playing.isEmpty && snapshot.others.isEmpty { confirmStart(placement: placement) }
        case let .pause(players, key):
            guard key else {
                finishPause(players: players, key: false, landing: nil, snapshot: snapshot, placement: placement, nowPlaying: nowPlaying)
                return
            }
            // The key goes first, while every app it could reach is still playing,
            // then the players show whether it landed on one of them.
            _ = sendKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [self] in
                readStates(Array(snapshot.players.keys.compactMap(NowPlayingPlayer.init(rawValue:)))) { [self] after in
                    let landing = PlaybackRules.landing(before: snapshot.players, after: after)
                    finishPause(players: players, key: true, landing: landing, snapshot: snapshot, placement: placement, nowPlaying: nowPlaying)
                }
            }
        case let .resume(previous):
            hold = nil
            let resumePlayers = { [self] in
                transport(previous.players, play: true) { [self] in
                    for id in previous.muted { _ = MixerModel.shared.setMuted(false, forApp: id, remember: false) }
                    busy = false
                    let back = previous.players.union(previous.muted).union(previous.keyPaused ? keyApps : [])
                    keyApps = []
                    // One app: the track HUD, as before; several: one line naming them.
                    if back.count <= 1 { nowPlaying(); return }
                    OSDOverlay.shared.show(type: .message("Playing \(Self.names(back)) again", icon: "play.fill"), value: 1, placement: placement)
                }
            }
            // The key first: the app it paused is still the one macOS sends it to.
            if previous.keyPaused, sendKey() {
                // Only the key can bring this back, and the page it paused may have gone to sleep since.
                if previous.players.isEmpty && previous.muted.isEmpty { confirmStart(placement: placement) }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: resumePlayers)
            } else {
                resumePlayers()
            }
        }
    }

    private func finishPause(players: Set<String>, key: Bool, landing: PlaybackRules.Landing?, snapshot: PlaybackSnapshot,
                             placement: OSDPlacement?, nowPlaying: @escaping () -> Void) {
        let result = PlaybackRules.hold(after: (players, key), landing: landing, snapshot: snapshot, previous: hold)
        // Holding an app silent needs mixer access; Kinara never asks for it out of the blue.
        let canMute = MixerModel.shared.permission == .authorized
        let muted = canMute ? result.mute : []
        var newHold = result.hold
        if !canMute { newHold.muted.subtract(result.mute) }
        transport(result.pause, play: false) { [self] in
            for id in muted { _ = MixerModel.shared.setMuted(true, forApp: id, remember: false) }
            hold = newHold.isEmpty ? nil : newHold
            keyApps = newHold.keyPaused ? snapshot.others : []
            busy = false
            let paused = players.union(keyApps)
            let missed = result.mute.subtracting(muted)
            if paused.count <= 1 && muted.isEmpty && missed.isEmpty { nowPlaying(); return }
            var parts: [String] = []
            if !paused.isEmpty { parts.append("Paused \(Self.names(paused))") }
            if !muted.isEmpty { parts.append("\(Self.names(muted)) muted") }
            if !missed.isEmpty { parts.append("\(Self.names(missed)) kept playing") }
            OSDOverlay.shared.show(type: .message(parts.joined(separator: " · "), icon: "pause.fill"), value: 1, placement: placement)
        }
    }

    /// After a press meant to start something: when it stays quiet and Kinara
    /// can tell why, say so instead of nothing happening.
    private func confirmStart(placement: OSDPlacement?) {
        guard MixerModel.isSupported else { return }
        checkStarted(placement: placement, until: ProcessInfo.processInfo.systemUptime + Self.startWindow)
    }

    private func checkStarted(placement: OSDPlacement?, until deadline: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            let sounding = MixerModel.soundingApps()
            guard sounding.isEmpty else {
                KinaraLog.info(.output, "Play/pause started \(sounding.sorted().joined(separator: ", "))")
                return
            }
            guard ProcessInfo.processInfo.systemUptime >= deadline else {
                checkStarted(placement: placement, until: deadline)
                return
            }
            guard let id = PlaybackRules.sleepingPage(audioApps: MixerModel.audioApps(), sounding: sounding) else {
                KinaraLog.info(.output, "Play/pause: nothing started playing")
                return
            }
            sleeper = (id, ProcessInfo.processInfo.systemUptime + Self.wakeWindow)
            let name = MixerModel.shared.displayName(forApp: id)
            KinaraLog.info(.output, "Play/pause: nothing started; \(name) likely put its page to sleep")
            let title = "\(name)'s tab is asleep"
            if !CornerBloom.shared.absorb(title, icon: "moon.zzz.fill", detail: "Do it again to open \(name)", placement: placement) {
                OSDOverlay.shared.show(type: .message("\(title) · do it again to open it", icon: "moon.zzz.fill"), value: 1, placement: placement)
            }
        }
    }

    /// Shown again, the page catches up on the press it slept through.
    private func wake(_ id: String) {
        sleeper = nil
        guard let url = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL else { return }
        KinaraLog.info(.output, "Play/pause: opening \(id) to wake its page")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { KinaraLog.warning(.output, "Play/pause: \(id) didn't open: \(error.localizedDescription)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let played = MixerModel.soundingApps().contains(id)
            KinaraLog.info(.output, played ? "Play/pause: \(id) woke and played" : "Play/pause: \(id) opened but stayed quiet")
        }
    }

    // MARK: Plumbing

    /// NX_KEYTYPE_PLAY, routed by macOS to its now-playing app.
    private func sendKey() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return EdgeActionController.send(.media(16), expectedApplication: front)
    }

    /// Each player's own state, read off main; unreadable players are left out.
    private func readStates(_ players: [NowPlayingPlayer], completion: @escaping ([String: Bool]) -> Void) {
        worker.async { [self] in
            var states: [String: Bool] = [:]
            for player in players {
                switch run(NowPlayingAppleScript.stateSource(for: player)) {
                case "playing": states[player.bundleID] = true
                case "paused": states[player.bundleID] = false
                default: break
                }
            }
            DispatchQueue.main.async { completion(states) }
        }
    }

    private func transport(_ ids: Set<String>, play: Bool, completion: @escaping () -> Void) {
        let players = ids.compactMap(NowPlayingPlayer.init(rawValue:))
        guard !players.isEmpty else { completion(); return }
        worker.async { [self] in
            for player in players { _ = run(NowPlayingAppleScript.transportSource(for: player, play: play)) }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Worker only. The reply as text, or nil when the script fails (for
    /// example, Automation access declined).
    private func run(_ source: String) -> String? {
        let script = scripts[source] ?? NSAppleScript(source: source)
        scripts[source] = script
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil else { return nil }
        return result.stringValue
    }

    /// "Safari", "Music and Safari", "Music, Safari and Spotify".
    private static func names(_ ids: Set<String>) -> String {
        let parts = ids.map { MixerModel.shared.displayName(forApp: $0) }.sorted()
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}

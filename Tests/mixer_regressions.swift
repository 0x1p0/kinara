import AppKit
import CoreAudio

/// The mixer's rules (solo, call ducking, mute, routing, boost, remembered
/// settings) and its model in preview mode. Never touches Core Audio: the tap
/// engine traps if anything tries while under test.
@main private enum MixerTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        guard condition() else { fatalError("FAIL line \(line): \(message)") }
        checks += 1
    }

    static func main() {
        ruleTests()
        statusTests()
        storeTests()
        modelTests()
        pickerTests()
        detectionTests()
        print("\(checks) mixer assertions passed. Rules and preview model only; no tap, aggregate device, routing change, or permission prompt.")
    }

    /// Hearing apps start and stop, and naming them, without trusting a miss forever.
    private static func detectionTests() {
        var cache = ResolutionCache<String>()
        var lookups = 0
        func ask(_ pid: pid_t, at now: TimeInterval, answer: String?) -> String? {
            cache.value(for: pid, now: now) { lookups += 1; return answer }
        }
        expect(ask(7, at: 0, answer: nil) == nil && lookups == 1, "an app not registered yet has no name")
        expect(ask(7, at: 0.5, answer: "com.brave.Browser") == nil && lookups == 1, "a miss isn't looked up again at once")
        expect(ask(7, at: 1.2, answer: "com.brave.Browser") == "com.brave.Browser" && lookups == 2,
               "a miss is retried a moment later, so the app's audio still shows up")
        expect(ask(7, at: 60, answer: nil) == "com.brave.Browser" && lookups == 2, "a found app is kept for the life of its process")
        cache.prune(keeping: [])
        expect(ask(7, at: 61, answer: "com.other") == "com.other" && lookups == 3, "a pid reused after its process ends is looked up afresh")

        let selectors = MixerProcessMonitor.stateSelectors
        expect(selectors.contains(kAudioProcessPropertyIsRunning) && selectors.contains(kAudioProcessPropertyDevices),
               "starts and stops are heard through what Core Audio posts: is running, and devices")
        expect(selectors.contains(kAudioProcessPropertyIsRunningOutput) && selectors.contains(kAudioProcessPropertyIsRunningInput),
               "the output and input properties stay watched in case macOS posts them")
    }

    private static func ruleTests() {
        let plain = MixerState(volume: 0.8)
        func decide(_ state: MixerState, id: String = "music", solo: String? = nil, ducking: Bool = false, level: Float = 0.3) -> MixerDecision {
            MixerRules.decide(state, id: id, soloID: solo, ducking: ducking, duckLevel: level)
        }
        expect(decide(plain).mix == AppMix(gain: 0.8), "an app plays at its own level")
        expect(decide(MixerState(volume: 1)).mix.isNeutral, "an untouched app stays untapped")
        expect(decide(MixerState(volume: 0.8, isMuted: true)).mix.gain == 0, "mute silences")
        expect(decide(MixerState(volume: 1, deviceUID: "airpods")).mix == AppMix(gain: 1, route: "airpods"), "a chosen output is kept, even at full level")

        let soloed = decide(plain, solo: "music")
        expect(soloed.isSoloed && !soloed.isSilencedBySolo && soloed.mix.gain == 0.8, "the soloed app plays as set")
        let others = decide(plain, id: "chat", solo: "music")
        expect(others.isSilencedBySolo && others.mix.gain == 0, "solo silences everyone else")
        expect(!decide(MixerState(volume: 0.8, hasPlayed: false), id: "chat", solo: "music").isSilencedBySolo,
               "apps that haven't played aren't rerouted for solo")

        let ducked = decide(plain, ducking: true)
        expect(ducked.isDucked && abs(ducked.mix.gain - 0.24) < 0.0001, "a call lowers other apps to the duck level")
        expect(!decide(MixerState(volume: 0.8, isUsingMicrophone: true), ducking: true).isDucked, "the app on the call is never lowered")
        expect(!decide(plain, solo: "music", ducking: true).isDucked, "a soloed app isn't lowered")
        expect(decide(plain, ducking: true, level: 5).mix.gain == 0.8 && decide(plain, ducking: true, level: -1).mix.gain == 0,
               "the duck level is clamped to 0…1")
        expect(decide(MixerState(volume: 1.4), ducking: false).mix.gain == 1.4, "boosted levels pass through to the engine")
    }

    private static func statusTests() {
        func status(solo: Bool = false, mic: Bool = false, muted: Bool = false, silenced: Bool = false, ducked: Bool = false, playing: Bool = false) -> String {
            MixerRules.status(isSoloed: solo, isUsingMicrophone: mic, isMuted: muted, isSilencedBySolo: silenced, isDucked: ducked, isPlaying: playing)
        }
        expect(status(playing: true) == "Playing" && status() == "Not playing", "plain apps say whether they're playing")
        expect(status(solo: true, mic: true, muted: true) == "Solo", "solo is the most important status")
        expect(status(mic: true, muted: true) == "On a call", "a call outranks mute")
        expect(status(muted: true, silenced: true, ducked: true) == "Muted", "mute outranks solo and ducking")
        expect(status(silenced: true, ducked: true, playing: true) == "Silenced by solo", "solo silence outranks ducking")
        expect(status(ducked: true, playing: true) == "Lowered for your call", "ducked apps say why")
    }

    private static func storeTests() {
        var values: [String: MixerChannelSettings] = [:]
        MixerRules.store(MixerChannelSettings(volume: 0.5), for: "music", in: &values)
        expect(values["music"]?.volume == 0.5, "changed settings are remembered")
        MixerRules.store(MixerChannelSettings(), for: "music", in: &values)
        expect(values["music"] == nil, "default settings are forgotten, so the app is left alone")
        MixerRules.store(MixerChannelSettings(volume: 1, isMuted: false, deviceUID: "airpods"), for: "music", in: &values)
        expect(values["music"]?.deviceUID == "airpods", "an output choice alone is remembered")
        let data = try? JSONEncoder().encode(values)
        let decoded = data.flatMap { try? JSONDecoder().decode([String: MixerChannelSettings].self, from: $0) }
        expect(decoded == values, "settings survive a round trip")

        let suite = "com.sway.mixer-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "mixerChannels.v1")
        defaults.set(9.0, forKey: "mixerDuckLevel")
        let model = MixerModel(defaults: defaults, preview: false)
        expect(model.duckLevel <= 0.8 && !model.duckDuringCalls && model.showInMenu && !model.allowBoost,
               "corrupt or extreme saved values fall back to safe defaults")
        expect(model.channels.isEmpty, "a model that hasn't started lists nothing and touches no hardware")
    }

    private static func modelTests() {
        let suite = "com.sway.mixer-preview-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MixerModel(defaults: defaults, preview: true)
        guard let music = model.channels.first(where: { $0.id == "com.apple.Music" }),
              let safari = model.channels.first(where: { $0.id == "com.apple.Safari" }),
              let slack = model.channels.first(where: { $0.id == "com.tinyspeck.slackmacgap" }) else {
            expect(false, "the preview lists demo apps")
            return
        }
        expect(model.channels.map(\.name) == model.channels.map(\.name).sorted(), "apps are listed alphabetically")
        expect(slack.status == "Muted" && music.status == "Playing", "rows start with the right status")

        model.toggleSolo(music)
        expect(model.soloChannel === music && music.isSoloed && safari.isSilencedBySolo, "solo marks the soloed app and silences the rest")
        expect(safari.status == "Silenced by solo", "silenced apps say so")
        model.toggleSolo(music)
        expect(model.soloID == nil && !safari.isSilencedBySolo, "tapping solo again ends it")
        model.setSoloed(nil, forApp: "com.apple.Safari")
        expect(model.soloID == "com.apple.Safari", "the edge action solos the app in front")
        model.endSolo()

        model.setVolume(2, for: safari)
        expect(safari.volume == 1, "without boost a fader stops at 100%")
        model.allowBoost = true
        model.setVolume(2, for: safari)
        expect(safari.volume == AppVolumeController.boostLimit, "boost reaches 150% and no further")
        model.allowBoost = false
        expect(safari.volume == 1, "turning boost off brings boosted apps back to 100%")

        model.setVolume(0.6, for: slack)
        expect(!slack.isMuted && slack.volume == 0.6, "raising a muted app's fader unmutes it")
        expect(model.setMuted(nil, forApp: "com.apple.Music") && music.isMuted, "the edge action toggles mute")
        expect(!model.setMuted(false, forApp: "com.apple.Music") && !music.isMuted, "a swipe up unmutes")

        model.setRoute("airpods", for: music)
        expect(music.deviceUID == "airpods" && model.device(uid: music.deviceUID)?.name == "AirPods Pro", "an app can be sent to another output")
        model.resetAllChannels()
        expect(model.channels.allSatisfy { $0.volume == 1 && !$0.isMuted && $0.deviceUID == nil } && model.soloID == nil,
               "reset puts every app back to normal")
        expect(model.volume(forApp: "com.example.unknown") == 1, "unknown apps are at full level")
    }

    static func pickerTests() {
        func app(_ id: String, playing: Bool = false, muted: Bool = false, soloed: Bool = false, silenced: Bool = false, played: Bool = false) -> AudioPickerApp {
            AudioPickerApp(id: id, name: id.capitalized, icon: nil, isPlaying: playing, isMuted: muted,
                           isSoloed: soloed, isSilencedBySolo: silenced, hasPlayed: played || playing)
        }
        let apps = [app("zoom", played: true), app("safari", playing: true), app("notes"), app("music", playing: true, muted: true),
                    app("arc", playing: true), app("slack", silenced: true, played: true)]
        let ordered = AudioPickerRules.ordered(apps)
        expect(ordered.map(\.id) == ["arc", "safari", "music", "slack", "zoom"], "sounding apps first, then muted or silenced, then recent; never silent strangers")
        expect(AudioPickerRules.ordered([app("notes")]).isEmpty, "an app that never made a sound is not offered")
        expect(AudioPickerRules.selection(keeping: "safari", previous: 0, in: Array(ordered.dropFirst())) == 0, "the highlight stays on its app as the list changes")
        expect(AudioPickerRules.selection(keeping: "gone", previous: 4, in: Array(ordered.prefix(2))) == 1, "a vanished app hands the highlight to its neighbour")
        expect(AudioPickerRules.selection(keeping: nil, previous: -1, in: ordered) == -1, "Cancel stays Cancel")
        expect(AudioPickerRules.selection(keeping: "arc", previous: 0, in: []) == -1, "an empty list leaves only Cancel")
        expect(app("a").action(solo: false) == "Mute" && app("a", muted: true).action(solo: false) == "Unmute", "lifting mutes or unmutes")
        expect(app("a").action(solo: true) == "Only this" && app("a", soloed: true).action(solo: true) == "End solo", "sliding right solos, or ends solo")
        expect(app("a", playing: true).status == "Playing" && app("a", muted: true).status == "Muted", "each row says what the app is doing")
    }
}

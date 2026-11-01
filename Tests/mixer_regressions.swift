import AppKit

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
        print("\(checks) mixer assertions passed. Rules and preview model only; no tap, aggregate device, routing change, or permission prompt.")
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
}

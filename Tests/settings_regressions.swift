import Foundation
import Carbon

/// Exercises production settings and their real dependent types without ever
/// constructing an application delegate, monitor, or hardware controller.
@main
enum SettingsRegressionTests {
    private static var checks = 0
    private static var cases = 0

    private enum Failure: Error, CustomStringConvertible {
        case assertion(String, Int)
        case preferencesUnavailable
        var description: String {
            switch self {
            case let .assertion(message, line): return "Line \(line): \(message)"
            case .preferencesUnavailable: return "Could not create isolated test preferences."
            }
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String, line: Int = #line) throws {
        checks += 1
        if !condition() { throw Failure.assertion(message, line) }
    }

    private static func near(_ value: Double, _ expected: Double) -> Bool {
        value.isFinite && abs(value - expected) < 0.000_001
    }

    private static func isolated(_ label: String, seed: [String: Any] = [:],
                                 _ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "com.sway.settings-regression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.preferencesUnavailable }
        // Only this disposable test domain is written or removed. Never use
        // UserDefaults.standard, the app's bundle domain, or registered globals.
        defaults.setPersistentDomain(seed, forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
        cases += 1
        print("PASS \(label)")
    }

    static func main() throws {
        try isolated("fresh installation defaults") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(settings.isEnabled && settings.minimumFingers == 2, "fresh setup enables two-finger gestures")
            try expect(settings.leftZoneAction == .brightness && settings.rightZoneAction == .volume, "familiar default edge actions")
            try expect(near(settings.leftZoneWidth, 0.2) && near(settings.rightZoneWidth, 0.2), "default zones leave free center space")
            try expect(near(settings.brightnessMin, 0.05) && near(settings.brightnessMax, 1), "default brightness protects against a black screen")
            try expect(near(settings.volumeMin, 0) && near(settings.volumeMax, 1), "fresh audio uses its full range")
            try expect(!settings.topEdgeEnabled && settings.cursorFreezeOnOneFinger, "fresh setup adds no top zones and holds the pointer during one-finger gestures")
            try expect(settings.palmRejectionMode == "balanced" && near(settings.typingCooldown, 0.45), "typing protection is enabled by default")
            try expect(settings.toggleHotkey.isEmpty && !settings.launchAtLogin, "no system shortcut or login registration is implied")
            try expect(settings.excludedApps.isEmpty && settings.appearanceMode == "system", "fresh app scope and appearance")
            try expect(settings.osdStyle == "horizontal" && near(settings.osdHorizontalWidth, 240), "fresh indicator uses the readable pill")
            try expect(settings.hapticConfiguration == HapticConfiguration(), "fresh haptics use standard 5% steps and an activation tap")
            try expect(settings.showDockIcon, "open windows are in the Dock and ⌘-Tab by default")
        }

        try isolated("Dock discoverability persists independently") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.showDockIcon = true
            let restored = TrackpadSettings(defaults: defaults)
            try expect(restored.showDockIcon, "Dock preference survives relaunch")
            restored.applyGesturePreset(.precise)
            try expect(restored.showDockIcon, "presets leave app discoverability alone")
            restored.resetGestureSettings()
            try expect(restored.showDockIcon, "gesture reset preserves Dock preference")
            restored.showDockIcon = false
            try expect(!TrackpadSettings(defaults: defaults).showDockIcon, "Dock icon can be disabled and stays disabled")
        }

        try isolated("legacy haptics off stays off", seed: ["hapticFeedback": false]) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(!settings.hapticFeedback && !settings.hapticConfiguration.enabled, "upgrading never re-enables disabled haptics")
        }
        try isolated("unknown haptic preferences recover safely", seed: ["hapticStyle": "strongest", "hapticSpacing": "invalid", "hapticOnStart": "invalid"]) { defaults, _ in
            try expect(TrackpadSettings(defaults: defaults).hapticConfiguration == HapticConfiguration(), "unknown styles, spacing, and start values fall back")
        }
        try isolated("edge light colour starts as the accent and persists", seed: ["edgeLightColor": "rainbow"]) { defaults, suite in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(settings.edgeLightColor == .accent, "an unknown colour falls back to the accent")
            for option in EdgeLightColor.allCases {
                settings.edgeLightColor = option
                defaults.synchronize()
                try expect(TrackpadSettings(defaults: UserDefaults(suiteName: suite)!).edgeLightColor == option, "\(option.rawValue) survives relaunch")
            }
            try expect(TrackpadSettings.exportedKeys.contains("edgeLightColor"), "the colour travels with exported settings")
        }
        for style in HapticStyle.allCases {
            for spacing in HapticSpacing.allCases {
                try isolated("haptic preferences persist: \(style.rawValue), \(spacing.rawValue)") { defaults, suite in
                    let settings = TrackpadSettings(defaults: defaults)
                    settings.hapticStyle = style
                    settings.hapticSpacing = spacing
                    settings.hapticOnStart = false
                    settings.hapticFeedback = false
                    defaults.synchronize()
                    let restored = TrackpadSettings(defaults: UserDefaults(suiteName: suite)!)
                    try expect(restored.hapticConfiguration == HapticConfiguration(enabled: false, style: style, spacing: spacing, onStart: false), "all choices survive relaunch even when disabled")
                    restored.hapticFeedback = true
                    restored.applyGesturePreset(.precise)
                    try expect(restored.hapticConfiguration == HapticConfiguration(style: style, spacing: spacing, onStart: false), "reenabling and gesture presets retain preferred haptics")
                    restored.resetGestureSettings()
                    try expect(TrackpadSettings(defaults: defaults).hapticConfiguration == HapticConfiguration(), "explicit reset restores haptics and persists them")
                }
            }
        }

        try isolated("out-of-range persisted numbers recover safely", seed: [
            "leftZoneWidth": -4.0, "rightZoneWidth": 8.0, "sensitivity": 100.0,
            "brightnessMin": -2.0, "brightnessMax": 4.0,
            "volumeMin": 0.90, "volumeMax": 0.10,
            "activationThreshold": -5.0, "osdHorizontalWidth": 900.0,
            "topEdgeHeight": -1.0, "typingCooldown": 40.0,
            "minimumFingers": 99, "topEdgeEnabled": true
        ]) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(near(settings.leftZoneWidth, 0.01), "negative left width clamps to 1% minimum")
            try expect(near(settings.rightZoneWidth, 0.4), "oversized right width clamps to maximum")
            try expect(near(settings.sensitivity, 3), "sensitivity clamps on load")
            try expect(near(settings.brightnessMin, 0) && near(settings.brightnessMax, 1), "brightness remains within device range")
            try expect(near(settings.volumeMin, 0.90) && near(settings.volumeMax, 0.95), "inverted audio limits retain a usable interval")
            try expect(near(settings.activationThreshold, 0), "activation distance cannot be negative")
            try expect(near(settings.osdHorizontalWidth, 320), "indicator fits its supported width")
            try expect(near(settings.topEdgeHeight, 0.01), "top strip supports a 1% minimum height")
            try expect(near(settings.typingCooldown, 1), "typing cooldown remains bounded")
            try expect(settings.minimumFingers == 2 && !settings.topEdgeEnabled, "invalid finger count cannot enable unsupported two-finger top mode")
        }

        try isolated("malformed persisted values fall back", seed: [
            "sensitivity": "invalid", "leftZoneAction": "unknown", "rightZoneAction": "unknown",
            "osdPosition": "unknown", "palmRejectionMode": "unknown",
            "toggleHotkey": Data([0xff, 0x00]), "brightnessMin": 100.0, "brightnessMax": -100.0
        ]) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(near(settings.sensitivity, 1), "nonnumeric sensitivity uses its default")
            try expect(settings.leftZoneAction == .brightness && settings.rightZoneAction == .volume, "unknown actions remain usable")
            try expect(settings.osdPosition == .right && settings.palmRejectionMode == "balanced", "invalid constrained options use defaults")
            try expect(settings.toggleHotkey.isEmpty, "corrupt shortcut data does not register a shortcut")
            try expect(near(settings.brightnessMin, 0.95) && near(settings.brightnessMax, 1), "reversed extreme brightness limits stay within 0–1")
            for value in [Double.nan, .infinity, -.infinity] {
                try expect(near(TrackpadSettings.clamp(value, to: 0...1, fallback: 0.45), 0.45), "nonfinite scalar uses safe fallback")
            }
            try expect(near(TrackpadSettings.clamp(-1, to: 0...1, fallback: 0.45), 0), "finite low scalar clamps")
            try expect(near(TrackpadSettings.clamp(2, to: 0...1, fallback: 0.45), 1), "finite high scalar clamps")
            try expect(near(TrackpadSettings.clamp(0.37, to: 0...1, fallback: 0.45), 0.37), "in-range precision is preserved")
        }

        for width in [0.01, 0.025] {
            try isolated("\(width * 100)% edge widths survive persistence", seed: [
                "leftZoneWidth": width, "rightZoneWidth": width,
                "topEdgeHeight": width, "minimumFingers": 1, "topEdgeEnabled": true
            ]) { defaults, suite in
                let settings = TrackpadSettings(defaults: defaults)
                try expect(near(settings.leftZoneWidth, width), "narrow left width is not raised to the old 5% floor")
                try expect(near(settings.rightZoneWidth, width), "narrow right width is not raised to the old 5% floor")
                try expect(near(settings.topEdgeHeight, width), "narrow top height loads without rounding")
                let changedWidth = width == 0.01 ? 0.025 : 0.01
                settings.leftZoneWidth = changedWidth
                settings.rightZoneWidth = changedWidth
                settings.topEdgeHeight = changedWidth
                defaults.synchronize()
                guard let reopened = UserDefaults(suiteName: suite) else { throw Failure.preferencesUnavailable }
                let restored = TrackpadSettings(defaults: reopened)
                try expect(near(restored.leftZoneWidth, changedWidth), "edited narrow left width survives a new preferences instance")
                try expect(near(restored.rightZoneWidth, changedWidth), "edited narrow right width survives a new preferences instance")
                try expect(near(restored.topEdgeHeight, changedWidth), "edited narrow top height survives a new preferences instance")
            }
        }

        let shortcut = HotkeyCombo(keyCode: 1, modifiers: UInt32(cmdKey | optionKey))
        let preferenceSeed: [String: Any] = [
            "excludedApps": ["com.example.editor", "com.example.meeting"],
            "appearanceMode": "dark", "toggleHotkey": try JSONEncoder().encode(shortcut),
            "launchAtLogin": true, "isEnabled": false, "osdStyle": "off", "menuBarValueSource": "both"
        ]
        for preset in GesturePreset.allCases {
            try isolated("\(preset.title) preset scope", seed: preferenceSeed) { defaults, _ in
                let settings = TrackpadSettings(defaults: defaults)
                settings.leftZoneAction = .disabled
                settings.rightZoneAction = .brightness
                settings.invertScrollDirection = true
                settings.topEdgeEnabled = true
                settings.cursorFreezeOnOneFinger = false
                settings.brightnessMin = 0.2
                settings.volumeMax = 0.6
                settings.applyGesturePreset(preset)
                try expect(settings.leftZoneAction == .brightness && settings.rightZoneAction == .volume, "preset restores deliberate edge assignments")
                try expect(settings.minimumFingers == (preset == .oneFinger ? 1 : 2), "preset selects its advertised contact count")
                try expect(near(settings.leftZoneWidth, preset == .precise ? 0.12 : 0.2) && near(settings.rightZoneWidth, settings.leftZoneWidth), "preset widths match intended precision")
                try expect(near(settings.sensitivity, preset == .precise ? 0.65 : 1), "precise preset slows level changes")
                try expect(near(settings.activationThreshold, preset == .precise ? 7 : 4), "precise preset requires additional travel")
                try expect(settings.palmRejectionMode == (preset == .precise ? "strict" : "balanced"), "preset applies its intent policy")
                try expect(near(settings.typingCooldown, preset == .precise ? 0.65 : 0.45), "preset applies its typing delay")
                try expect(!settings.topEdgeEnabled && !settings.invertScrollDirection && settings.cursorFreezeOnOneFinger, "preset resets optional gesture modifiers and holds the pointer")
                try expect(near(settings.brightnessMin, 0.2) && near(settings.volumeMax, 0.6), "gesture preset preserves comfort limits")
                try preservedPreferences(settings, shortcut: shortcut)
            }
        }

        try isolated("reset restores gestures and limits only", seed: preferenceSeed) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.applyGesturePreset(.precise)
            settings.brightnessMin = 0.4; settings.brightnessMax = 0.6
            settings.volumeMin = 0.2; settings.volumeMax = 0.3
            settings.topEdgeEnabled = true; settings.topEdgeHeight = 0.28
            settings.topEdgeSwipeDirection = "vertical"
            settings.topLeftAction = .volume; settings.topRightAction = .disabled; settings.topEdgeAction = .brightness
            settings.hapticFeedback = false; settings.muteAtZero = false
            settings.resetGestureSettings()
            try expect(settings.minimumFingers == 2 && !settings.topEdgeEnabled, "reset restores simple two-finger setup")
            try expect(near(settings.sensitivity, 1) && near(settings.activationThreshold, 4), "reset restores everyday responsiveness")
            try expect(settings.palmRejectionMode == "balanced" && near(settings.typingCooldown, 0.45), "reset retains typing and intent protection")
            try expect(near(settings.brightnessMin, 0.05) && near(settings.brightnessMax, 1), "reset restores safe brightness range")
            try expect(near(settings.volumeMin, 0) && near(settings.volumeMax, 1), "reset restores audio range")
            try expect(near(settings.topEdgeHeight, 0.15) && settings.topEdgeSwipeDirection == "horizontal", "reset restores top geometry")
            try expect(settings.topLeftAction == .brightness && settings.topRightAction == .volume && settings.topEdgeAction == .volume, "reset restores all top assignments")
            try expect(settings.hapticFeedback && settings.muteAtZero, "reset restores feedback options")
            try preservedPreferences(settings, shortcut: shortcut)
        }

        try isolated("edits survive a new settings instance", seed: preferenceSeed) { defaults, suite in
            let settings = TrackpadSettings(defaults: defaults)
            settings.applyGesturePreset(.oneFinger)
            settings.leftZoneAction = .volume; settings.rightZoneAction = .disabled
            settings.leftZoneWidth = 0.17; settings.rightZoneWidth = 0.27
            settings.brightnessMin = 0.12; settings.brightnessMax = 0.83
            settings.volumeMin = 0.08; settings.volumeMax = 0.74
            settings.topEdgeEnabled = true; settings.topEdgeHeight = 0.11
            settings.topEdgeSwipeDirection = "vertical"; settings.topEdgeAction = .brightness
            settings.typingCooldown = 0.7; settings.palmRejectionMode = "strict"
            settings.invertScrollDirection = true; settings.cursorFreezeOnOneFinger = false
            settings.hapticFeedback = false; settings.muteAtZero = false
            defaults.synchronize()
            guard let reopened = UserDefaults(suiteName: suite) else { throw Failure.preferencesUnavailable }
            let restored = TrackpadSettings(defaults: reopened)
            try expect(restored.minimumFingers == 1 && restored.topEdgeEnabled, "one-finger top mode survives reload")
            try expect(restored.leftZoneAction == .volume && restored.rightZoneAction == .disabled, "edge actions persist")
            try expect(near(restored.leftZoneWidth, 0.17) && near(restored.rightZoneWidth, 0.27), "zone geometry persists")
            try expect(near(restored.brightnessMin, 0.12) && near(restored.brightnessMax, 0.83), "brightness range persists")
            try expect(near(restored.volumeMin, 0.08) && near(restored.volumeMax, 0.74), "audio range persists")
            try expect(near(restored.topEdgeHeight, 0.11) && restored.topEdgeSwipeDirection == "vertical" && restored.topEdgeAction == .brightness, "top configuration persists")
            try expect(restored.palmRejectionMode == "strict" && near(restored.typingCooldown, 0.7), "intent configuration persists")
            try expect(restored.invertScrollDirection && !restored.cursorFreezeOnOneFinger && !restored.hapticFeedback && !restored.muteAtZero, "gesture modifiers persist")
            try expect(reopened.persistentDomain(forName: suite)?["leftZoneAction"] as? String == "volume", "changes are written to the isolated persistent domain")
            try preservedPreferences(restored, shortcut: shortcut)
            restored.resetGestureSettings()
            let resetReload = TrackpadSettings(defaults: reopened)
            try expect(resetReload.minimumFingers == 2 && !resetReload.topEdgeEnabled && near(resetReload.brightnessMin, 0.05), "reset itself persists across reload")
        }
        for action in ZoneAction.allCases {
            try isolated("action persists: \(action.rawValue)") { defaults, _ in
                let settings = TrackpadSettings(defaults: defaults)
                settings.leftZoneAction = action
                settings.rightZoneAction = action
                settings.topEdgeAction = action
                settings.swipeUpShortcut = HotkeyCombo(keyCode: 24, modifiers: UInt32(cmdKey))
                settings.swipeDownShortcut = HotkeyCombo(keyCode: 27, modifiers: UInt32(cmdKey))
                let reopened = TrackpadSettings(defaults: defaults)
                try expect(reopened.leftZoneAction == action && reopened.rightZoneAction == action && reopened.topEdgeAction == action, "all edges retain the action")
                try expect(reopened.swipeUpShortcut == settings.swipeUpShortcut && reopened.swipeDownShortcut == settings.swipeDownShortcut, "custom pairs persist without global registration")
            }
        }
        try expansionCases()
        print("\(checks) settings assertions passed across \(cases) isolated cases. No monitor, hardware writes, shortcuts, or login registrations ran.")
    }

    private static func expansionCases() throws {
        try isolated("expanded defaults keep upgrades unchanged") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(!settings.bottomEdgeEnabled && settings.bindings.isEmpty && settings.appProfiles.isEmpty, "no new zones, layers, taps or profiles are implied")
            try expect(!settings.dockedProfileEnabled && settings.dockedProfile.bindings.isEmpty, "docked profile starts off and empty")
            try expect(settings.precisionEnabled && settings.accelerationEnabled, "feel improvements start on")
            try expect(!settings.midpointNotch, "the 50% notch is opt-in")
            try expect(settings.volumeFavorite < 0 && settings.brightnessFavorite < 0, "no favorite level is assumed")
            try expect(settings.brightnessFollowsPointer && !settings.extraDimBelowMinimum, "brightness follows the pointer; extra dim is opt-in")
            try expect(settings.volumeFeedbackSound == "system" && settings.nowPlayingHUD && settings.menuBarScroll, "feedback follows macOS and the menu bar scrolls")
            try expect(settings.cornerEffects && settings.edgeLight && settings.seenGestureHints.isEmpty, "corner feedback and the edge light start on, with every first-time hint still to show")
            settings.seenGestureHints.insert("topRightCorner.doubleTap")
            try expect(TrackpadSettings(defaults: defaults).seenGestureHints == ["topRightCorner.doubleTap"], "a hint shown once stays shown")
            try expect(settings.cheatSheetHotkey.isEmpty && settings.urlCommandsEnabled, "no global cheat-sheet hotkey is registered by default")
            try expect(settings.notches(for: .volume).isEmpty, "no notch is felt by default")
            try expect(settings.cornerTapFingers == 0, "corner taps follow the swipe finger count by default")
            settings.cornerTapFingers = 1
            try expect(TrackpadSettings(defaults: defaults).cornerTapFingers == 1, "one-finger corner taps persist")
            defaults.set(7, forKey: "cornerTapFingers")
            try expect(TrackpadSettings(defaults: defaults).cornerTapFingers == 0, "unknown corner finger counts fall back to following swipes")
        }

        try isolated("bindings, profiles and resolution order", seed: ["leftZoneAction": "volume"]) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(settings.baseBinding("left").action == .volume, "base slot reads the original key")
            settings.setBaseBinding(EdgeBinding(.customShortcut, up: HotkeyCombo(keyCode: 1, modifiers: UInt32(cmdKey))), for: "left")
            try expect(settings.leftZoneAction == .customShortcut, "setting a base slot writes the original key")
            settings.setBaseBinding(EdgeBinding(.playPause), for: "left.doubleTap")
            settings.setBaseBinding(EdgeBinding(.brightness), for: "left.option")
            settings.bottomEdgeAction = .seek
            settings.appProfiles["com.example.editor"] = ActionProfile(name: "Editor", bindings: ["left": EdgeBinding(.tabs)])
            settings.dockedProfileEnabled = true
            settings.dockedProfile.bindings["left"] = EdgeBinding(.zoom)
            settings.dockedProfile.bindings["right"] = EdgeBinding(.audioOutput)
            let reopened = TrackpadSettings(defaults: defaults)
            try expect(reopened.leftZoneAction == .customShortcut && reopened.bindings["left"]?.up.keyCode == 1, "per-edge recording persists")
            try expect(reopened.baseBinding("left.doubleTap").action == .playPause && reopened.baseBinding("left.option").action == .brightness, "tap and layer slots persist")
            try expect(reopened.baseBinding("bottom").action == .seek, "bottom slot reads its own key")
            try expect(reopened.binding("left", appBundleID: "com.example.editor", docked: true).action == .tabs, "an app profile wins over docked")
            try expect(reopened.resolvedBinding("left", appBundleID: "com.example.other", docked: true).source == .docked, "docked wins over everyday when connected")
            try expect(reopened.binding("left", appBundleID: nil, docked: false).action == .customShortcut, "undocked without an app profile uses everyday")
            try expect(reopened.binding("right", appBundleID: "com.example.editor", docked: true).action == .audioOutput, "a profile that omits a slot falls through")
            reopened.dockedProfileEnabled = false
            try expect(reopened.binding("right", appBundleID: nil, docked: true).action == .volume, "a disabled docked profile is ignored")
            try expect(reopened.slotIsAssigned("left.doubleTap") && !reopened.slotIsAssigned("right.tapHold"), "assignment checks follow bindings")
            reopened.appProfiles["com.example.editor"]?.bindings["right.tapHold"] = EdgeBinding(.missionControl)
            try expect(reopened.slotIsAssigned("right.tapHold"), "a slot assigned only in an app profile still counts")
            reopened.setBaseBinding(EdgeBinding(.disabled), for: "left.doubleTap")
            try expect(reopened.bindings["left.doubleTap"] == nil, "turning a slot off removes its stored binding")
        }

        try isolated("custom shortcuts fall back to the shared pair") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.swipeUpShortcut = HotkeyCombo(keyCode: 24, modifiers: UInt32(cmdKey))
            settings.swipeDownShortcut = HotkeyCombo(keyCode: 27, modifiers: UInt32(cmdKey))
            let legacy = EdgeBinding(.customShortcut)
            try expect(settings.customShortcut(for: legacy, increasing: true).keyCode == 24, "an edge without its own pair uses the original shared pair")
            let own = EdgeBinding(.customShortcut, up: HotkeyCombo(keyCode: 30, modifiers: UInt32(cmdKey)))
            try expect(settings.customShortcut(for: own, increasing: true).keyCode == 30, "an edge's own recording wins")
            try expect(settings.customShortcut(for: own, increasing: false).isEmpty, "a half-recorded pair never borrows the other half")
        }

        try isolated("app profiles choose their own finger count") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.minimumFingers = 2
            settings.appProfiles["com.example.draw"] = ActionProfile(name: "Draw", fingers: 1)
            settings.appProfiles["com.example.game"] = ActionProfile(name: "Game", fingers: 7)
            try expect(settings.requiredFingers(appBundleID: "com.example.draw") == 1, "a profile can ask for one finger")
            try expect(settings.requiredFingers(appBundleID: "com.example.game") == 2, "an invalid count follows the everyday setting")
            try expect(settings.requiredFingers(appBundleID: nil) == 2 && settings.requiredFingers(appBundleID: "com.example.other") == 2, "other apps use the everyday setting")
            let reloaded = TrackpadSettings(defaults: defaults)
            try expect(reloaded.appProfiles["com.example.draw"]?.fingers == 1, "a profile's finger count persists")
            settings.minimumFingers = 1
            settings.appProfiles["com.example.draw"]?.fingers = 2
            try expect(settings.requiredFingers(appBundleID: "com.example.draw") == 2 && settings.requiredFingers(appBundleID: nil) == 1, "two fingers in one app, one everywhere else")
            let old = try JSONDecoder().decode(ActionProfile.self, from: Data(#"{"name":"Old","bindings":{}}"#.utf8))
            try expect(old.fingers == nil, "profiles saved before finger counts follow the everyday setting")
        }

        try isolated("the recommended setup and its tour") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(settings.offersRecommendedSetup, "a fresh install is offered Kinara's picks")
            settings.applyRecommendedSetup(appAudio: true)
            try expect(settings.minimumFingers == 1 && settings.rightZoneAction == .volume && settings.leftZoneAction == .brightness, "one finger: volume right, brightness left")
            try expect(settings.binding("bottomRightCorner.doubleTap", appBundleID: nil, docked: false).action == .clipboardHistory
                       && settings.binding("bottomLeftCorner.doubleTap", appBundleID: nil, docked: false).action == .audioApps
                       && settings.binding("topRightCorner.doubleTap", appBundleID: nil, docked: false).action == .playPause
                       && settings.binding("topLeftCorner.doubleTap", appBundleID: nil, docked: false).action == .missionControl, "four corners are set")
            try expect(settings.binding("topRightCorner.tapHold", appBundleID: nil, docked: false).action == .cheatSheet
                       && settings.binding("right.doubleTap", appBundleID: nil, docked: false).action == .outputMute, "tap and hold, and an edge double-tap, are set too")
            try expect(!settings.offersRecommendedSetup && !TrackpadSettings(defaults: defaults).offersRecommendedSetup, "it's applied once, never over someone's own setup")
            let steps = settings.tourSteps()
            try expect(steps.map(\.slot) == ["right", "left", "bottomRightCorner.doubleTap", "bottomLeftCorner.doubleTap", "topRightCorner.doubleTap",
                                              "topLeftCorner.doubleTap", "topRightCorner.tapHold", "right.doubleTap"], "the tour shows every gesture the setup has")
            try expect(steps.map(\.place) == ["the right edge", "the left edge", "the bottom-right corner", "the bottom-left corner", "the top-right corner",
                                               "the top-left corner", "the top-right corner", "the right edge"], "each stop names where it is")
            try expect(steps[6].kind == .tapHold("topRightCorner") && steps[7].kind == .doubleTap("right"), "tap and hold, and an edge tap, are their own stops")
            settings.applyRecommendedSetup(appAudio: false)
            try expect(settings.binding("bottomLeftCorner.doubleTap", appBundleID: nil, docked: false).action == .showDesktop, "without the mixer, that corner shows the desktop")
            let other = TrackpadSettings(defaults: UserDefaults(suiteName: "com.sway.tests.tour.\(UUID().uuidString)")!)
            other.setBaseBinding(EdgeBinding(.paste), for: "topRightCorner.doubleTap")
            try expect(!other.offersRecommendedSetup, "someone who already set a tap keeps their setup")
        }

        try isolated("notches and favorites") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.volumeFavorite = 0.3
            try expect(settings.notches(for: .volume) == [0.3] && settings.notches(for: .brightness).isEmpty, "a favorite notches its own level, even with the 50% notch off")
            settings.midpointNotch = true
            try expect(TrackpadSettings(defaults: defaults).midpointNotch, "the 50% notch persists once turned on")
            try expect(settings.notches(for: .volume) == [0.5, 0.3] && settings.notches(for: .brightness) == [0.5], "favorites add a notch to their own level only")
            settings.brightnessFavorite = 0.51
            try expect(settings.notches(for: .brightness) == [0.5], "a favorite on top of the middle notch is not doubled")
            settings.midpointNotch = false
            try expect(settings.notches(for: .volume) == [0.3], "turning the 50% notch off keeps favorites")
        }

        try isolated("corrupt and out-of-range expansion data", seed: [
            "edgeBindings": Data("not json".utf8), "appProfiles": Data("[]".utf8), "tapCornerSize": 9.0,
            "volumeFavorite": Double.nan, "brightnessFavorite": 4.0, "volumeFeedbackSound": "loud",
            "bottomEdgeAction": "teleport", "bottomEdgeEnabled": true, "minimumFingers": 2,
            "dockedProfile": Data(#"{"bindings":{"left":{"action":"warp"}}}"#.utf8),
        ]) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(settings.bindings.isEmpty && settings.appProfiles.isEmpty, "unreadable binding data is ignored")
            try expect(near(settings.tapCornerSize, TrackpadSettings.cornerSizeRange.upperBound), "corner size is clamped")
            try expect(settings.volumeFavorite < 0 && settings.brightnessFavorite < 0, "invalid favorites mean none")
            try expect(settings.volumeFeedbackSound == "system" && settings.bottomEdgeAction == .mediaTracks, "unknown choices fall back")
            try expect(!settings.bottomEdgeEnabled, "bottom edge requires one-finger mode like the top edge")
            try expect(settings.dockedProfile.bindings["left"]?.action == .disabled && settings.dockedProfile.name == "Profile", "unknown actions decode as Off")
        }

        try isolated("per-device volume limits") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.volumeMax = 0.9
            settings.deviceVolumeLimits["airpods-uid"] = DeviceLimit(name: "AirPods", min: 0.1, max: 0.6)
            settings.deviceVolumeLimits["odd"] = DeviceLimit(name: "Odd", min: 0.99, max: .nan)
            let reopened = TrackpadSettings(defaults: defaults)
            try expect(reopened.volumeLimits(forDevice: "airpods-uid") == 0.1...0.6, "a device's own limits apply")
            try expect(near(reopened.volumeLimits(forDevice: "speakers").upperBound, 0.9) && near(reopened.volumeLimits(forDevice: nil).upperBound, 0.9), "other devices use the global limits")
            let odd = reopened.volumeLimits(forDevice: "odd")
            try expect(near(odd.lowerBound, 0.95) && near(odd.upperBound, 1), "invalid stored limits still form a valid range")
        }

        try isolated("reset keeps recordings and profiles") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.minimumFingers = 1
            settings.bottomEdgeEnabled = true
            settings.setBaseBinding(EdgeBinding(.customShortcut, up: HotkeyCombo(keyCode: 5, modifiers: UInt32(cmdKey))), for: "right")
            settings.setBaseBinding(EdgeBinding(.playPause), for: "right.doubleTap")
            settings.appProfiles["com.example.editor"] = ActionProfile(name: "Editor", bindings: ["left": EdgeBinding(.tabs)])
            settings.precisionEnabled = false; settings.midpointNotch = true
            settings.resetGestureSettings()
            try expect(!settings.bottomEdgeEnabled && settings.precisionEnabled && !settings.midpointNotch, "reset restores zones and feel")
            try expect(settings.bindings["right.doubleTap"] == nil && settings.bindings["right"]?.up.keyCode == 5, "reset turns taps off but keeps a recorded shortcut")
            try expect(settings.appProfiles["com.example.editor"] != nil, "app profiles survive a gesture reset")
        }

        try isolated("export and import round trip") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.leftZoneAction = .nightShift
            settings.setBaseBinding(EdgeBinding(.runShortcut, shortcut: "Lights On", downShortcut: "Lights Off"), for: "right")
            settings.appProfiles["com.example.editor"] = ActionProfile(name: "Editor", bindings: ["left": EdgeBinding(.tabs)])
            settings.volumeFavorite = 0.25
            let exported = try settings.exportData()
            try isolated("import target") { target, _ in
                let other = TrackpadSettings(defaults: target)
                try other.importData(exported)
                try expect(other.leftZoneAction == .nightShift && other.baseBinding("right").shortcut == "Lights On", "actions and Shortcut names import")
                try expect(other.appProfiles["com.example.editor"]?.bindings["left"]?.action == .tabs && near(other.volumeFavorite, 0.25), "profiles and favorites import")
                try expect(TrackpadSettings(defaults: target).baseBinding("right").downShortcut == "Lights Off", "imported values persist")
            }
            let tampered = try PropertyListSerialization.data(fromPropertyList: [
                "format": TrackpadSettings.exportFormat, "version": 1, "leftZoneWidth": 7.0,
                "leftZoneAction": "selfDestruct", "launchAtLogin": true, "hasFinishedSwaySetup": true,
            ] as [String: Any], format: .xml, options: 0)
            try settings.importData(tampered)
            try expect(near(settings.leftZoneWidth, TrackpadSettings.sideZoneWidthRange.upperBound) && settings.leftZoneAction == .brightness, "imported values pass normal validation")
            try expect(!settings.launchAtLogin && defaults.object(forKey: "hasFinishedSwaySetup") == nil, "login and setup state are never imported")
            var rejected = 0
            for data in [Data("garbage".utf8),
                         try PropertyListSerialization.data(fromPropertyList: ["format": "other"], format: .xml, options: 0),
                         try PropertyListSerialization.data(fromPropertyList: ["format": TrackpadSettings.exportFormat, "version": 9], format: .xml, options: 0)] {
                do { try settings.importData(data) } catch { rejected += 1 }
            }
            try expect(rejected == 3, "unreadable, foreign and newer files are refused")
        }
    }

    private static func preservedPreferences(_ settings: TrackpadSettings, shortcut: HotkeyCombo) throws {
        try expect(settings.excludedApps == ["com.example.editor", "com.example.meeting"], "excluded applications are preserved")
        try expect(settings.appearanceMode == "dark", "appearance is preserved")
        try expect(settings.toggleHotkey == shortcut, "saved shortcut is preserved without registration")
        try expect(settings.launchAtLogin && !settings.isEnabled, "login preference and pause state are preserved")
        try expect(settings.osdStyle == "off" && settings.menuBarValueSource == "both", "indicator and menu preferences are preserved")
    }
}

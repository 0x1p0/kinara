import Foundation
import Combine
import Carbon
import SwiftUI

// MARK: - Zone Action
enum ZoneAction: String, CaseIterable, Identifiable, Codable {
    case brightness = "brightness"
    case volume     = "volume"
    case microphoneLevel, keyboardBrightness, outputMute, microphoneMute
    case mediaTracks, playPause, tabs, history, zoom, pages, documentEnds
    case workspaces, missionControl, appWindows, showDesktop, switchApps, cycleWindows
    case fullScreen, minimizeWindow, hideApp, spotlight, screenshotTools, emojiPicker
    case customShortcut
    case appVolume, audioOutput, seek, nowPlaying, tileWindow
    case nightShift, trueTone, extraDim, runShortcut, cheatSheet
    case disabled   = "disabled"

    /// Unknown values from a newer version or a hand-edited export become Off.
    init(from decoder: Decoder) throws {
        self = ZoneAction(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .disabled
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .brightness: return "Brightness"
        case .volume:     return "Volume"
        case .microphoneLevel: return "Microphone level"
        case .keyboardBrightness: return "Keyboard backlight"
        case .outputMute: return "Speaker mute"
        case .microphoneMute: return "Microphone mute"
        case .mediaTracks: return "Previous / next track"
        case .playPause: return "Play / pause"
        case .tabs: return "Switch tabs"
        case .history: return "Back / forward"
        case .zoom: return "App zoom"
        case .pages: return "Page up / down"
        case .documentEnds: return "Document start / end"
        case .workspaces: return "Switch desktops"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App Exposé"
        case .showDesktop: return "Show desktop"
        case .switchApps: return "Switch apps"
        case .cycleWindows: return "Cycle app windows"
        case .fullScreen: return "Toggle full screen"
        case .minimizeWindow: return "Minimize window"
        case .hideApp: return "Hide current app"
        case .spotlight: return "Spotlight"
        case .screenshotTools: return "Screenshot tools"
        case .emojiPicker: return "Emoji & symbols"
        case .customShortcut: return "Custom shortcuts"
        case .appVolume: return "App volume"
        case .audioOutput: return "Switch audio output"
        case .seek: return "Seek in track"
        case .nowPlaying: return "Show now playing"
        case .tileWindow: return "Tile window"
        case .nightShift: return "Night Shift warmth"
        case .trueTone: return "True Tone"
        case .extraDim: return "Extra dim"
        case .runShortcut: return "Run a Shortcut"
        case .cheatSheet: return "Show edge map"
        case .disabled:   return "Off"
        }
    }

    var icon: String {
        switch self {
        case .brightness: return "sun.max.fill"
        case .volume:     return "speaker.wave.2.fill"
        case .microphoneLevel: return "mic.fill"
        case .keyboardBrightness: return "light.max"
        case .outputMute: return "speaker.slash.fill"
        case .microphoneMute: return "mic.slash.fill"
        case .mediaTracks: return "forward.end.fill"
        case .playPause: return "playpause.fill"
        case .tabs: return "rectangle.on.rectangle"
        case .history: return "arrow.left.arrow.right"
        case .zoom: return "plus.magnifyingglass"
        case .pages: return "doc.text"
        case .documentEnds: return "arrow.up.to.line"
        case .workspaces: return "rectangle.split.3x1"
        case .missionControl: return "rectangle.3.group"
        case .appWindows: return "macwindow.on.rectangle"
        case .showDesktop: return "menubar.dock.rectangle"
        case .switchApps: return "app.stack"
        case .cycleWindows: return "macwindow"
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .minimizeWindow: return "minus.rectangle"
        case .hideApp: return "eye.slash"
        case .spotlight: return "magnifyingglass"
        case .screenshotTools: return "camera.viewfinder"
        case .emojiPicker: return "face.smiling"
        case .customShortcut: return "keyboard"
        case .appVolume: return "dial.medium"
        case .audioOutput: return "airplayaudio"
        case .seek: return "goforward"
        case .nowPlaying: return "music.note"
        case .tileWindow: return "rectangle.split.2x1"
        case .nightShift: return "flame"
        case .trueTone: return "circle.lefthalf.fill"
        case .extraDim: return "moon.fill"
        case .runShortcut: return "square.stack.3d.up.fill"
        case .cheatSheet: return "map"
        case .disabled:   return "slash.circle"
        }
    }

    var category: String {
        switch self {
        case .brightness, .keyboardBrightness, .nightShift, .trueTone, .extraDim: return "Display & keyboard"
        case .volume, .appVolume, .audioOutput, .microphoneLevel, .outputMute, .microphoneMute: return "Audio & microphone"
        case .mediaTracks, .playPause, .seek, .nowPlaying: return "Media"
        case .tabs, .history, .zoom, .pages, .documentEnds: return "Navigation"
        case .workspaces, .missionControl, .appWindows, .showDesktop, .switchApps, .cycleWindows,
             .fullScreen, .minimizeWindow, .hideApp, .tileWindow: return "Windows & desktops"
        case .spotlight, .screenshotTools, .emojiPicker, .runShortcut, .cheatSheet, .customShortcut: return "Tools & shortcuts"
        case .disabled: return "Other"
        }
    }
    static let categories = ["Display & keyboard", "Audio & microphone", "Media", "Navigation", "Windows & desktops", "Tools & shortcuts", "Other"]
    /// Follows finger travel as a level rather than firing commands.
    var isContinuous: Bool { [.brightness, .volume, .microphoneLevel, .appVolume, .nightShift, .extraDim, .seek].contains(self) }
    var repeatsWhileSwiping: Bool { [.keyboardBrightness, .tabs, .zoom, .pages, .cycleWindows, .audioOutput].contains(self) }
    /// Taps fire once with no direction, so only commands and toggles fit.
    var worksAsTap: Bool { !isContinuous }
    /// A tap flips these instead of sending their "up" command.
    var togglesOnTap: Bool { [.outputMute, .microphoneMute, .trueTone].contains(self) }
    var guidance: String {
        switch self {
        case .brightness: return "Up brightens; down dims the built-in display."
        case .volume: return "Up raises; down lowers the default audio output."
        case .microphoneLevel: return "Up raises; down lowers the default input’s gain. Does not record audio or change a meeting app’s mute button."
        case .keyboardBrightness: return "Up brightens; down dims a supported backlit keyboard using macOS media keys. Ambient light can limit changes."
        case .outputMute: return "Up unmutes; down mutes the default output. Requires a hardware mute control."
        case .microphoneMute: return "Up unmutes; down mutes the default input device, only when hardware mute is available. Other inputs and app mute buttons are separate."
        case .mediaTracks: return "Up sends next track; down sends previous track. One request per swipe to the active media app."
        case .playPause: return "Either direction sends play/pause to the active media app. Once per swipe."
        case .tabs: return "Up selects the next tab; down selects the previous tab. Uses Control-Tab in apps that support it."
        case .history: return "Up goes forward; down goes back. Uses Command-] / Command-[ in supporting apps."
        case .zoom: return "Up zooms in; down zooms out. Uses Command-+ / Command-− in supporting apps; not macOS accessibility zoom."
        case .pages: return "Up sends Page Up; down sends Page Down to the current app."
        case .documentEnds: return "Up goes to the start; down goes to the end. Uses Command-Up / Command-Down."
        case .workspaces: return "Up moves to the next desktop; down to the previous. Requires macOS Control-Arrow shortcuts."
        case .missionControl: return "Either direction opens Mission Control using Control-Up. Once per swipe."
        case .appWindows: return "Either direction shows the current app’s windows using Control-Down."
        case .showDesktop: return "Either direction sends F11 (Show Desktop). Requires this macOS shortcut to be enabled."
        case .switchApps: return "Up switches to the next recent app; down switches in reverse. One switch per swipe."
        case .cycleWindows: return "Up cycles forward through the current app’s windows; down cycles backward. Uses Command-`."
        case .fullScreen: return "Either direction sends Control-Command-F to toggle the current window’s full screen."
        case .minimizeWindow: return "Either direction sends Command-M to minimize the current window. Once per swipe."
        case .hideApp: return "Either direction sends Command-H to hide the current app. Once per swipe."
        case .spotlight: return "Either direction sends Command-Space. Requires the standard Spotlight shortcut."
        case .screenshotTools: return "Either direction opens the macOS screenshot toolbar (Command-Shift-5). You choose what to capture; Sway records nothing."
        case .emojiPicker: return "Either direction opens Emoji & Symbols using Control-Command-Space."
        case .customShortcut: return "Record an up/right and down/left shortcut for this edge. Each runs once per swipe, in the app where the gesture started."
        case .appVolume: return "Up raises; down lowers only the frontmost app’s sound, like a per-app mixer. macOS asks once for System Audio Recording permission; Sway never records or saves audio. macOS 14.2 or later."
        case .audioOutput: return "Up switches to the next audio output; down to the previous one. The indicator names the new device."
        case .seek: return "Up moves forward; down moves back within the current track. Works with Music and Spotify, and other players macOS exposes."
        case .nowPlaying: return "Shows the current track with artwork and progress. Changes nothing."
        case .tileWindow: return "Up fills the screen with the front window; down moves it to this edge’s half (left or right). Uses Accessibility, so it works in most apps."
        case .nightShift: return "Up warms the display; down cools it. Swiping to zero turns Night Shift off. Uses a private macOS interface that can change."
        case .trueTone: return "Up turns True Tone on; down turns it off. A tap toggles it. Only on displays that support True Tone."
        case .extraDim: return "Down dims below the display’s lowest backlight level; up restores it. Quitting Sway always restores normal brightness."
        case .runShortcut: return "Runs the Shortcut you choose for this edge: one for up/right, another for down/left. Opens a world of automations, such as smart lights."
        case .cheatSheet: return "Shows what every edge does in the current app. Changes nothing."
        case .disabled: return "This edge behaves like the rest of your trackpad."
        }
    }
}

// MARK: - OSD Position
enum OSDPosition: String, CaseIterable, Identifiable {
    case left   = "left"
    case center = "center"
    case right  = "right"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left:   return "Left"
        case .center: return "Center"
        case .right:  return "Right"
        }
    }

    var icon: String {
        switch self {
        case .left:   return "align.horizontal.left"
        case .center: return "align.horizontal.center"
        case .right:  return "align.horizontal.right"
        }
    }
}

// MARK: - Hotkey
struct HotkeyCombo: Codable, Equatable {
    var keyCode:   UInt32
    var modifiers: UInt32  // Carbon modifier flags

    static let none = HotkeyCombo(keyCode: 0, modifiers: 0)
    var isEmpty: Bool { keyCode == 0 && modifiers == 0 }

    var displayString: String {
        guard !isEmpty else { return "None" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    private func keyName(for code: UInt32) -> String {
        let map: [UInt32: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X",
            8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R",
            16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6",
            23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0",
            30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 37:"L",
            38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/",
            45:"N", 46:"M", 47:".", 49:"Space", 51:"⌫",
            53:"Esc", 96:"F5", 97:"F6", 98:"F7", 99:"F3",
            100:"F8", 101:"F9", 103:"F11", 109:"F10", 111:"F12",
            122:"F1", 120:"F2", 118:"F4",
        ]
        return map[code] ?? "(\(code))"
    }
}

// MARK: - Bindings

/// Everything one gesture slot needs: its action plus that slot's own
/// shortcut recording or Shortcuts-app name. Missing fields decode as empty.
struct EdgeBinding: Codable, Equatable {
    var action: ZoneAction
    var up: HotkeyCombo = .none
    var down: HotkeyCombo = .none
    var shortcut = ""
    var downShortcut = ""

    init(_ action: ZoneAction, up: HotkeyCombo = .none, down: HotkeyCombo = .none,
         shortcut: String = "", downShortcut: String = "") {
        self.action = action; self.up = up; self.down = down
        self.shortcut = shortcut; self.downShortcut = downShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decodeIfPresent(ZoneAction.self, forKey: .action) ?? .disabled
        up = (try? container.decodeIfPresent(HotkeyCombo.self, forKey: .up)) ?? .none
        down = (try? container.decodeIfPresent(HotkeyCombo.self, forKey: .down)) ?? .none
        shortcut = (try? container.decodeIfPresent(String.self, forKey: .shortcut)) ?? ""
        downShortcut = (try? container.decodeIfPresent(String.self, forKey: .downShortcut)) ?? ""
    }
}

/// Slot names are stable strings so settings never depend on gesture types.
enum EdgeSlot {
    static let swipe = ["left", "right", "topLeft", "topRight", "top", "bottom"]
    static let sides = ["left", "right"]
    static let tapRegions = ["left", "right", "top", "bottom", "topLeftCorner", "topRightCorner", "bottomLeftCorner", "bottomRightCorner"]
    static let tapGestures = ["doubleTap", "tapHold"]
    static func option(_ region: String) -> String { "\(region).option" }
    static func alternate(_ region: String) -> String { "\(region).alternate" }
    static func tap(_ region: String, _ gesture: String) -> String { "\(region).\(gesture)" }
    static var allTaps: [String] { tapRegions.flatMap { region in tapGestures.map { tap(region, $0) } } }
    static var all: [String] { swipe + sides.map(option) + sides.map(alternate) + allTaps }

    static func title(_ slot: String) -> String {
        let names = ["left": "Left edge", "right": "Right edge", "topLeft": "Top left", "topRight": "Top right",
                     "top": "Top edge", "bottom": "Bottom edge", "topLeftCorner": "Top-left corner",
                     "topRightCorner": "Top-right corner", "bottomLeftCorner": "Bottom-left corner",
                     "bottomRightCorner": "Bottom-right corner"]
        let parts = slot.split(separator: ".").map(String.init)
        let base = names[parts.first ?? ""] ?? slot
        guard parts.count == 2 else { return base }
        switch parts[1] {
        case "option": return "\(base) + ⌥"
        case "alternate": return "\(base), other finger count"
        case "doubleTap": return "\(base) double-tap"
        case "tapHold": return "\(base) tap and hold"
        default: return base
        }
    }
}

/// Overrides for one app (or for docked use). Slots it does not mention use
/// the everyday setup, so a profile can change a single edge.
struct ActionProfile: Codable, Equatable {
    var name: String
    var bindings: [String: EdgeBinding] = [:]

    init(name: String, bindings: [String: EdgeBinding] = [:]) { self.name = name; self.bindings = bindings }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Profile"
        bindings = (try? container.decodeIfPresent([String: EdgeBinding].self, forKey: .bindings)) ?? [:]
    }
}

/// Sanitized on creation and decoding: a non-finite value could not even be
/// encoded as JSON, which would silently drop every device's limits.
struct DeviceLimit: Codable, Equatable {
    let name: String
    let min: Double
    let max: Double
    var range: ClosedRange<Double> { min...max }

    init(name: String, min: Double, max: Double) {
        let low = Swift.min(0.95, Swift.max(0, min.isFinite ? min : 0))
        self.name = name
        self.min = low
        self.max = Swift.max(low + 0.05, Swift.min(1, max.isFinite ? max : 1))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: (try? container.decode(String.self, forKey: .name)) ?? "Audio output",
                  min: (try? container.decode(Double.self, forKey: .min)) ?? 0,
                  max: (try? container.decode(Double.self, forKey: .max)) ?? 1)
    }
}

/// Where a binding came from, so the edge map can explain itself.
enum BindingSource: String { case app, docked, everyday }

// MARK: - Settings
class TrackpadSettings: ObservableObject {
    static let shared = TrackpadSettings()
    /// Normalized geometry retains fractional percentages; a 1% strip is valid.
    static let sideZoneWidthRange = 0.01...0.4
    static let topEdgeHeightRange = 0.01...0.3
    private let defaults: UserDefaults
    private var reconcilingLoginStatus = false

    @Published var leftZoneWidth: Double {
        didSet { defaults.set(leftZoneWidth, forKey: "leftZoneWidth") }
    }
    @Published var rightZoneWidth: Double {
        didSet { defaults.set(rightZoneWidth, forKey: "rightZoneWidth") }
    }
    @Published var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: "sensitivity") }
    }
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "isEnabled") }
    }
    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback") }
    }
    @Published var hapticStyle: HapticStyle {
        didSet { defaults.set(hapticStyle.rawValue, forKey: "hapticStyle") }
    }
    @Published var hapticSpacing: HapticSpacing {
        didSet { defaults.set(hapticSpacing.rawValue, forKey: "hapticSpacing") }
    }
    @Published var hapticOnStart: Bool {
        didSet { defaults.set(hapticOnStart, forKey: "hapticOnStart") }
    }
    var hapticConfiguration: HapticConfiguration {
        HapticConfiguration(enabled: hapticFeedback, style: hapticStyle,
                            spacing: hapticSpacing, onStart: hapticOnStart)
    }
    @Published var invertScrollDirection: Bool {
        didSet { defaults.set(invertScrollDirection, forKey: "invertScrollDirection") }
    }
    @Published var leftZoneAction: ZoneAction {
        didSet { defaults.set(leftZoneAction.rawValue, forKey: "leftZoneAction") }
    }
    @Published var rightZoneAction: ZoneAction {
        didSet { defaults.set(rightZoneAction.rawValue, forKey: "rightZoneAction") }
    }
    @Published var swipeUpShortcut: HotkeyCombo {
        didSet { if let data = try? JSONEncoder().encode(swipeUpShortcut) { defaults.set(data, forKey: "swipeUpShortcut") } }
    }
    @Published var swipeDownShortcut: HotkeyCombo {
        didSet { if let data = try? JSONEncoder().encode(swipeDownShortcut) { defaults.set(data, forKey: "swipeDownShortcut") } }
    }
    @Published var brightnessMin: Double {
        didSet { defaults.set(brightnessMin, forKey: "brightnessMin") }
    }
    @Published var brightnessMax: Double {
        didSet { defaults.set(brightnessMax, forKey: "brightnessMax") }
    }
    @Published var volumeMin: Double {
        didSet { defaults.set(volumeMin, forKey: "volumeMin") }
    }
    @Published var volumeMax: Double {
        didSet { defaults.set(volumeMax, forKey: "volumeMax") }
    }
    @Published var activationThreshold: Double {
        didSet { defaults.set(activationThreshold, forKey: "activationThreshold") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !reconcilingLoginStatus else { return }
            if !LoginItemManager.shared.setEnabled(launchAtLogin) {
                reconcilingLoginStatus = true
                launchAtLogin = LoginItemManager.shared.currentStatus()
                reconcilingLoginStatus = false
            }
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }
    @Published var appearanceMode: String {
        didSet { defaults.set(appearanceMode, forKey: "appearanceMode") }
    }
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: "showDockIcon") }
    }

    // ── NEW: Global hotkey ───────────────────────────────────────────
    @Published var toggleHotkey: HotkeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(toggleHotkey) {
                defaults.set(data, forKey: "toggleHotkey")
            }
            HotkeyManager.shared.update(hotkey: toggleHotkey)
        }
    }

    // ── NEW: Excluded app bundle IDs ─────────────────────────────────
    @Published var excludedApps: [String] {
        didSet { defaults.set(excludedApps, forKey: "excludedApps") }
    }

    // ── NEW: OSD position ────────────────────────────────────────────
    @Published var osdPosition: OSDPosition {
        didSet { defaults.set(osdPosition.rawValue, forKey: "osdPosition") }
    }

    // ── NEW: OSD style: "vertical" | "horizontal" | "off" ───────────
    @Published var osdStyle: String {
        didSet { defaults.set(osdStyle, forKey: "osdStyle") }
    }

    // ── Horizontal OSD width (points, 120…320) ───────────────────────
    @Published var osdHorizontalWidth: Double {
        didSet { defaults.set(osdHorizontalWidth, forKey: "osdHorizontalWidth") }
    }

    // ── NEW: Menu bar display mode: "icon" | "volume" | "brightness"
    @Published var menuBarValueSource: String {
        didSet { defaults.set(menuBarValueSource, forKey: "menuBarValueSource") }
    }

    // ── NEW: Mute/unmute at zero ─────────────────────────────────────
    @Published var muteAtZero: Bool {
        didSet { defaults.set(muteAtZero, forKey: "muteAtZero") }
    }

    // Exact number of intentional contacts required to start a gesture.
    @Published var minimumFingers: Int {
        didSet { defaults.set(minimumFingers, forKey: "minimumFingers") }
    }

    // ── Cursor freeze while adjusting (1-finger mode only) ──────────
    @Published var cursorFreezeOnOneFinger: Bool {
        didSet { defaults.set(cursorFreezeOnOneFinger, forKey: "cursorFreezeOnOneFinger") }
    }

    // ── Top edge zone ─────────────────────────────────────────────────
    // horizontal mode: left half → topLeftAction, right half → topRightAction (swipe left/right)
    // vertical   mode: whole strip → topAction (swipe up/down)
    @Published var topEdgeEnabled: Bool {
        didSet { defaults.set(topEdgeEnabled, forKey: "topEdgeEnabled") }
    }
    @Published var topEdgeHeight: Double {
        didSet { defaults.set(topEdgeHeight, forKey: "topEdgeHeight") }
    }
    /// "horizontal" or "vertical"
    @Published var topEdgeSwipeDirection: String {
        didSet { defaults.set(topEdgeSwipeDirection, forKey: "topEdgeSwipeDirection") }
    }
    // horizontal mode actions (left half / right half)
    @Published var topLeftAction: ZoneAction {
        didSet { defaults.set(topLeftAction.rawValue, forKey: "topLeftAction") }
    }
    @Published var topRightAction: ZoneAction {
        didSet { defaults.set(topRightAction.rawValue, forKey: "topRightAction") }
    }
    // vertical mode action (single strip)
    @Published var topEdgeAction: ZoneAction {
        didSet { defaults.set(topEdgeAction.rawValue, forKey: "topEdgeAction") }
    }

    @Published var palmRejectionMode: String {
        didSet { defaults.set(palmRejectionMode, forKey: "palmRejectionMode") }
    }
    @Published var typingCooldown: Double {
        didSet { defaults.set(typingCooldown, forKey: "typingCooldown") }
    }

    // ── Bottom edge (one finger, horizontal swipes) ──────────────────
    @Published var bottomEdgeEnabled: Bool {
        didSet { defaults.set(bottomEdgeEnabled, forKey: "bottomEdgeEnabled") }
    }
    @Published var bottomEdgeHeight: Double {
        didSet { defaults.set(bottomEdgeHeight, forKey: "bottomEdgeHeight") }
    }
    @Published var bottomEdgeAction: ZoneAction {
        didSet { defaults.set(bottomEdgeAction.rawValue, forKey: "bottomEdgeAction") }
    }

    // ── Per-slot bindings: per-edge shortcuts, layers and taps ───────
    @Published var bindings: [String: EdgeBinding] {
        didSet { store(bindings, "edgeBindings") }
    }
    @Published var appProfiles: [String: ActionProfile] {
        didSet { store(appProfiles, "appProfiles") }
    }
    @Published var dockedProfileEnabled: Bool {
        didSet { defaults.set(dockedProfileEnabled, forKey: "dockedProfileEnabled") }
    }
    @Published var dockedProfile: ActionProfile {
        didSet { store(dockedProfile, "dockedProfile") }
    }
    @Published var tapCornerSize: Double {
        didSet { defaults.set(tapCornerSize, forKey: "tapCornerSize") }
    }

    // ── Feel ──────────────────────────────────────────────────────────
    @Published var precisionEnabled: Bool {
        didSet { defaults.set(precisionEnabled, forKey: "precisionEnabled") }
    }
    @Published var accelerationEnabled: Bool {
        didSet { defaults.set(accelerationEnabled, forKey: "accelerationEnabled") }
    }
    @Published var notchesEnabled: Bool {
        didSet { defaults.set(notchesEnabled, forKey: "notchesEnabled") }
    }
    /// A favorite level adds a notch; a negative value means none.
    @Published var volumeFavorite: Double {
        didSet { defaults.set(volumeFavorite, forKey: "volumeFavorite") }
    }
    @Published var brightnessFavorite: Double {
        didSet { defaults.set(brightnessFavorite, forKey: "brightnessFavorite") }
    }

    // ── Context ───────────────────────────────────────────────────────
    /// Keyed by Core Audio device UID, which survives reconnects and restarts.
    @Published var deviceVolumeLimits: [String: DeviceLimit] {
        didSet { store(deviceVolumeLimits, "deviceVolumeLimits") }
    }
    @Published var brightnessFollowsPointer: Bool {
        didSet { defaults.set(brightnessFollowsPointer, forKey: "brightnessFollowsPointer") }
    }
    @Published var extraDimBelowMinimum: Bool {
        didSet { defaults.set(extraDimBelowMinimum, forKey: "extraDimBelowMinimum") }
    }

    // ── Feedback, menu bar and automation ─────────────────────────────
    /// "system" follows macOS's “Play feedback when volume is changed”.
    @Published var volumeFeedbackSound: String {
        didSet { defaults.set(volumeFeedbackSound, forKey: "volumeFeedbackSound") }
    }
    @Published var nowPlayingHUD: Bool {
        didSet { defaults.set(nowPlayingHUD, forKey: "nowPlayingHUD") }
    }
    @Published var menuBarScroll: Bool {
        didSet { defaults.set(menuBarScroll, forKey: "menuBarScroll") }
    }
    @Published var cheatSheetHotkey: HotkeyCombo {
        didSet {
            store(cheatSheetHotkey, "cheatSheetHotkey")
            HotkeyManager.shared.updateCheatSheet(hotkey: cheatSheetHotkey)
        }
    }
    @Published var urlCommandsEnabled: Bool {
        didSet { defaults.set(urlCommandsEnabled, forKey: "urlCommandsEnabled") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        leftZoneWidth  = Self.clamp(defaults.object(forKey: "leftZoneWidth") as? Double ?? 0.2, to: Self.sideZoneWidthRange, fallback: 0.2)
        rightZoneWidth = Self.clamp(defaults.object(forKey: "rightZoneWidth") as? Double ?? 0.2, to: Self.sideZoneWidthRange, fallback: 0.2)
        sensitivity    = Self.clamp(defaults.object(forKey: "sensitivity") as? Double ?? 1, to: 0.3...3, fallback: 1)
        isEnabled      = defaults.object(forKey: "isEnabled")      as? Bool   ?? true
        hapticFeedback = defaults.object(forKey: "hapticFeedback") as? Bool   ?? true
        hapticStyle = HapticStyle(rawValue: defaults.string(forKey: "hapticStyle") ?? "") ?? .standard
        hapticSpacing = HapticSpacing(rawValue: defaults.string(forKey: "hapticSpacing") ?? "") ?? .regular
        hapticOnStart = defaults.object(forKey: "hapticOnStart") as? Bool ?? true
        invertScrollDirection = defaults.object(forKey: "invertScrollDirection") as? Bool ?? false

        let la = defaults.string(forKey: "leftZoneAction")  ?? ZoneAction.brightness.rawValue
        let ra = defaults.string(forKey: "rightZoneAction") ?? ZoneAction.volume.rawValue
        leftZoneAction  = ZoneAction(rawValue: la)  ?? .brightness
        rightZoneAction = ZoneAction(rawValue: ra)  ?? .volume
        swipeUpShortcut = defaults.data(forKey: "swipeUpShortcut").flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) } ?? .none
        swipeDownShortcut = defaults.data(forKey: "swipeDownShortcut").flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) } ?? .none

        brightnessMin = Self.clamp(defaults.object(forKey: "brightnessMin") as? Double ?? 0.05, to: 0...0.95, fallback: 0.05)
        brightnessMax = max(Self.clamp(defaults.object(forKey: "brightnessMin") as? Double ?? 0.05, to: 0...0.95, fallback: 0.05) + 0.05, Self.clamp(defaults.object(forKey: "brightnessMax") as? Double ?? 1, to: 0.05...1, fallback: 1))
        volumeMin     = Self.clamp(defaults.object(forKey: "volumeMin") as? Double ?? 0, to: 0...0.95, fallback: 0)
        volumeMax     = max(Self.clamp(defaults.object(forKey: "volumeMin") as? Double ?? 0, to: 0...0.95, fallback: 0) + 0.05, Self.clamp(defaults.object(forKey: "volumeMax") as? Double ?? 1, to: 0.05...1, fallback: 1))

        activationThreshold = Self.clamp(defaults.object(forKey: "activationThreshold") as? Double ?? 4, to: 0...12, fallback: 4)
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        appearanceMode = defaults.string(forKey: "appearanceMode") ?? "system"
        showDockIcon = defaults.object(forKey: "showDockIcon") as? Bool ?? false

        if let data = defaults.data(forKey: "toggleHotkey"),
           let hk = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            toggleHotkey = hk
        } else {
            toggleHotkey = .none
        }

        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []

        let osdRaw = defaults.string(forKey: "osdPosition") ?? OSDPosition.right.rawValue
        osdPosition = OSDPosition(rawValue: osdRaw) ?? .right

        osdStyle = defaults.string(forKey: "osdStyle") ?? "horizontal"
        osdHorizontalWidth = Self.clamp(defaults.object(forKey: "osdHorizontalWidth") as? Double ?? 240, to: 160...320, fallback: 240)

        menuBarValueSource = defaults.string(forKey: "menuBarValueSource") ?? "icon"
        muteAtZero         = defaults.object(forKey: "muteAtZero") as? Bool ?? true
        minimumFingers = defaults.integer(forKey: "minimumFingers") == 1 ? 1 : 2
        cursorFreezeOnOneFinger = defaults.object(forKey: "cursorFreezeOnOneFinger") as? Bool ?? false

        topEdgeEnabled = defaults.integer(forKey: "minimumFingers") == 1 && (defaults.object(forKey: "topEdgeEnabled") as? Bool ?? false)
        topEdgeHeight  = Self.clamp(defaults.object(forKey: "topEdgeHeight") as? Double ?? 0.15, to: Self.topEdgeHeightRange, fallback: 0.15)

        topEdgeSwipeDirection = defaults.string(forKey: "topEdgeSwipeDirection") ?? "horizontal"
        let tla = defaults.string(forKey: "topLeftAction")  ?? ZoneAction.brightness.rawValue
        let tra = defaults.string(forKey: "topRightAction") ?? ZoneAction.volume.rawValue
        topLeftAction  = ZoneAction(rawValue: tla) ?? .brightness
        topRightAction = ZoneAction(rawValue: tra) ?? .volume
        let tea = defaults.string(forKey: "topEdgeAction") ?? ZoneAction.volume.rawValue
        topEdgeAction  = ZoneAction(rawValue: tea) ?? .volume
        palmRejectionMode = defaults.string(forKey: "palmRejectionMode") == "strict" ? "strict" : "balanced"
        typingCooldown = Self.clamp(defaults.object(forKey: "typingCooldown") as? Double ?? 0.45, to: 0.2...1.0, fallback: 0.45)

        bottomEdgeEnabled = defaults.integer(forKey: "minimumFingers") == 1 && (defaults.object(forKey: "bottomEdgeEnabled") as? Bool ?? false)
        bottomEdgeHeight = Self.clamp(defaults.object(forKey: "bottomEdgeHeight") as? Double ?? 0.15, to: Self.topEdgeHeightRange, fallback: 0.15)
        bottomEdgeAction = ZoneAction(rawValue: defaults.string(forKey: "bottomEdgeAction") ?? "") ?? .mediaTracks
        bindings = Self.load([String: EdgeBinding].self, "edgeBindings", from: defaults) ?? [:]
        appProfiles = Self.load([String: ActionProfile].self, "appProfiles", from: defaults) ?? [:]
        dockedProfileEnabled = defaults.object(forKey: "dockedProfileEnabled") as? Bool ?? false
        dockedProfile = Self.load(ActionProfile.self, "dockedProfile", from: defaults) ?? ActionProfile(name: "Docked")
        tapCornerSize = Self.clamp(defaults.object(forKey: "tapCornerSize") as? Double ?? 0.14, to: Self.cornerSizeRange, fallback: 0.14)
        precisionEnabled = defaults.object(forKey: "precisionEnabled") as? Bool ?? true
        accelerationEnabled = defaults.object(forKey: "accelerationEnabled") as? Bool ?? true
        notchesEnabled = defaults.object(forKey: "notchesEnabled") as? Bool ?? true
        volumeFavorite = Self.favorite(defaults.object(forKey: "volumeFavorite") as? Double)
        brightnessFavorite = Self.favorite(defaults.object(forKey: "brightnessFavorite") as? Double)
        deviceVolumeLimits = Self.load([String: DeviceLimit].self, "deviceVolumeLimits", from: defaults) ?? [:]
        brightnessFollowsPointer = defaults.object(forKey: "brightnessFollowsPointer") as? Bool ?? true
        extraDimBelowMinimum = defaults.object(forKey: "extraDimBelowMinimum") as? Bool ?? false
        let sound = defaults.string(forKey: "volumeFeedbackSound") ?? "system"
        volumeFeedbackSound = ["system", "on", "off"].contains(sound) ? sound : "system"
        nowPlayingHUD = defaults.object(forKey: "nowPlayingHUD") as? Bool ?? true
        menuBarScroll = defaults.object(forKey: "menuBarScroll") as? Bool ?? true
        cheatSheetHotkey = Self.load(HotkeyCombo.self, "cheatSheetHotkey", from: defaults) ?? .none
        urlCommandsEnabled = defaults.object(forKey: "urlCommandsEnabled") as? Bool ?? true
    }

    static let cornerSizeRange = 0.06...0.3
    /// How far a notch pulls: enough to feel, too little to fight.
    static let notchCapture = 0.015

    static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private static func favorite(_ value: Double?) -> Double {
        guard let value, value.isFinite, (0...1).contains(value) else { return -1 }
        return value
    }

    private func store<Value: Encodable>(_ value: Value, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, _ key: String, from defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    // MARK: Binding resolution

    /// The everyday binding. The five original swipe slots keep their actions
    /// in their original keys so older versions and exports stay readable.
    func baseBinding(_ slot: String) -> EdgeBinding {
        var binding = bindings[slot] ?? EdgeBinding(.disabled)
        switch slot {
        case "left": binding.action = leftZoneAction
        case "right": binding.action = rightZoneAction
        case "topLeft": binding.action = topLeftAction
        case "topRight": binding.action = topRightAction
        case "top": binding.action = topEdgeAction
        case "bottom": binding.action = bottomEdgeAction
        default: break
        }
        return binding
    }

    func setBaseBinding(_ binding: EdgeBinding, for slot: String) {
        switch slot {
        case "left": leftZoneAction = binding.action
        case "right": rightZoneAction = binding.action
        case "topLeft": topLeftAction = binding.action
        case "topRight": topRightAction = binding.action
        case "top": topEdgeAction = binding.action
        case "bottom": bottomEdgeAction = binding.action
        default: break
        }
        if binding == EdgeBinding(.disabled) { bindings.removeValue(forKey: slot) }
        else { bindings[slot] = binding }
    }

    /// App profile first, then the docked profile, then the everyday setup.
    func resolvedBinding(_ slot: String, appBundleID: String?, docked: Bool) -> (binding: EdgeBinding, source: BindingSource) {
        if let appBundleID, let binding = appProfiles[appBundleID]?.bindings[slot] { return (binding, .app) }
        if docked, dockedProfileEnabled, let binding = dockedProfile.bindings[slot] { return (binding, .docked) }
        return (baseBinding(slot), .everyday)
    }

    func binding(_ slot: String, appBundleID: String?, docked: Bool) -> EdgeBinding {
        resolvedBinding(slot, appBundleID: appBundleID, docked: docked).binding
    }

    /// Whether any context could make this slot active, so the recognizer can
    /// accept touches that a profile, but not the everyday setup, assigns.
    func slotIsAssigned(_ slot: String) -> Bool {
        baseBinding(slot).action != .disabled
            || (dockedProfileEnabled && (dockedProfile.bindings[slot]?.action ?? .disabled) != .disabled)
            || appProfiles.values.contains { ($0.bindings[slot]?.action ?? .disabled) != .disabled }
    }

    /// A slot's own recording wins; otherwise the original shared pair applies,
    /// so custom shortcuts set up before per-edge recording keep working.
    func customShortcut(for binding: EdgeBinding, increasing: Bool) -> HotkeyCombo {
        let own = increasing ? binding.up : binding.down
        if !binding.up.isEmpty || !binding.down.isEmpty { return own }
        return increasing ? swipeUpShortcut : swipeDownShortcut
    }

    func notches(for action: ZoneAction) -> [Double] {
        guard notchesEnabled else { return [] }
        var points = [0.5]
        let favorite = action == .volume ? volumeFavorite : action == .brightness ? brightnessFavorite : -1
        if favorite >= 0 && abs(favorite - 0.5) > Self.notchCapture * 2 { points.append(favorite) }
        return points
    }

    func volumeLimits(forDevice uid: String?) -> ClosedRange<Double> {
        if let uid, let limit = deviceVolumeLimits[uid] { return limit.range }
        return min(volumeMin, volumeMax)...max(volumeMin, volumeMax)
    }

    // MARK: Export and import

    /// Preferences only. Setup progress, login registration and update
    /// history stay on this Mac.
    static let exportedKeys = [
        "leftZoneWidth", "rightZoneWidth", "sensitivity", "hapticFeedback", "hapticStyle", "hapticSpacing",
        "hapticOnStart", "invertScrollDirection", "leftZoneAction", "rightZoneAction", "swipeUpShortcut",
        "swipeDownShortcut", "brightnessMin", "brightnessMax", "volumeMin", "volumeMax", "activationThreshold",
        "appearanceMode", "showDockIcon", "toggleHotkey", "excludedApps", "osdPosition", "osdStyle",
        "osdHorizontalWidth", "menuBarValueSource", "muteAtZero", "minimumFingers", "cursorFreezeOnOneFinger",
        "topEdgeEnabled", "topEdgeHeight", "topEdgeSwipeDirection", "topLeftAction", "topRightAction",
        "topEdgeAction", "palmRejectionMode", "typingCooldown", "bottomEdgeEnabled", "bottomEdgeHeight",
        "bottomEdgeAction", "edgeBindings", "appProfiles", "dockedProfileEnabled", "dockedProfile", "tapCornerSize",
        "precisionEnabled", "accelerationEnabled", "notchesEnabled", "volumeFavorite", "brightnessFavorite",
        "deviceVolumeLimits", "brightnessFollowsPointer", "extraDimBelowMinimum", "volumeFeedbackSound",
        "nowPlayingHUD", "menuBarScroll", "cheatSheetHotkey", "urlCommandsEnabled",
    ]
    static let exportFormat = "com.sway.settings"

    func exportData() throws -> Data {
        var payload: [String: Any] = ["format": Self.exportFormat, "version": 1]
        for key in Self.exportedKeys { if let value = defaults.object(forKey: key) { payload[key] = value } }
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    enum ImportError: Error, CustomStringConvertible {
        case unreadable, notSway, newerVersion
        var description: String {
            switch self {
            case .unreadable: return "This file could not be read as Sway settings."
            case .notSway: return "This file is not a Sway settings export."
            case .newerVersion: return "These settings come from a newer version of Sway. Update Sway, then try again."
            }
        }
    }

    /// Only known keys are read, then every value passes through the same
    /// validation as a normal launch, so a hand-edited file cannot inject
    /// out-of-range zones or unknown actions.
    func importData(_ data: Data) throws {
        guard let payload = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.unreadable
        }
        guard payload["format"] as? String == Self.exportFormat else { throw ImportError.notSway }
        guard (payload["version"] as? Int ?? 0) <= 1 else { throw ImportError.newerVersion }
        let suite = "com.sway.import.\(UUID().uuidString)"
        guard let staging = UserDefaults(suiteName: suite) else { throw ImportError.unreadable }
        defer { staging.removePersistentDomain(forName: suite) }
        for key in Self.exportedKeys { if let value = payload[key] { staging.set(value, forKey: key) } }
        adopt(TrackpadSettings(defaults: staging))
    }

    private func adopt(_ other: TrackpadSettings) {
        leftZoneWidth = other.leftZoneWidth; rightZoneWidth = other.rightZoneWidth
        sensitivity = other.sensitivity
        hapticFeedback = other.hapticFeedback; hapticStyle = other.hapticStyle
        hapticSpacing = other.hapticSpacing; hapticOnStart = other.hapticOnStart
        invertScrollDirection = other.invertScrollDirection
        leftZoneAction = other.leftZoneAction; rightZoneAction = other.rightZoneAction
        swipeUpShortcut = other.swipeUpShortcut; swipeDownShortcut = other.swipeDownShortcut
        brightnessMin = other.brightnessMin; brightnessMax = other.brightnessMax
        volumeMin = other.volumeMin; volumeMax = other.volumeMax
        activationThreshold = other.activationThreshold
        appearanceMode = other.appearanceMode; showDockIcon = other.showDockIcon
        toggleHotkey = other.toggleHotkey; excludedApps = other.excludedApps
        osdPosition = other.osdPosition; osdStyle = other.osdStyle; osdHorizontalWidth = other.osdHorizontalWidth
        menuBarValueSource = other.menuBarValueSource; muteAtZero = other.muteAtZero
        minimumFingers = other.minimumFingers; cursorFreezeOnOneFinger = other.cursorFreezeOnOneFinger
        topEdgeEnabled = other.topEdgeEnabled; topEdgeHeight = other.topEdgeHeight
        topEdgeSwipeDirection = other.topEdgeSwipeDirection
        topLeftAction = other.topLeftAction; topRightAction = other.topRightAction; topEdgeAction = other.topEdgeAction
        palmRejectionMode = other.palmRejectionMode; typingCooldown = other.typingCooldown
        bottomEdgeEnabled = other.bottomEdgeEnabled; bottomEdgeHeight = other.bottomEdgeHeight
        bottomEdgeAction = other.bottomEdgeAction
        bindings = other.bindings; appProfiles = other.appProfiles
        dockedProfileEnabled = other.dockedProfileEnabled; dockedProfile = other.dockedProfile
        tapCornerSize = other.tapCornerSize
        precisionEnabled = other.precisionEnabled; accelerationEnabled = other.accelerationEnabled
        notchesEnabled = other.notchesEnabled
        volumeFavorite = other.volumeFavorite; brightnessFavorite = other.brightnessFavorite
        deviceVolumeLimits = other.deviceVolumeLimits
        brightnessFollowsPointer = other.brightnessFollowsPointer; extraDimBelowMinimum = other.extraDimBelowMinimum
        volumeFeedbackSound = other.volumeFeedbackSound; nowPlayingHUD = other.nowPlayingHUD
        menuBarScroll = other.menuBarScroll; cheatSheetHotkey = other.cheatSheetHotkey
        urlCommandsEnabled = other.urlCommandsEnabled
    }

    func applyGesturePreset(_ preset: GesturePreset) {
        leftZoneAction = .brightness
        rightZoneAction = .volume
        leftZoneWidth = preset == .precise ? 0.12 : 0.20
        rightZoneWidth = preset == .precise ? 0.12 : 0.20
        minimumFingers = preset == .oneFinger ? 1 : 2
        sensitivity = preset == .precise ? 0.65 : 1.0
        activationThreshold = preset == .precise ? 7 : 4
        palmRejectionMode = preset == .precise ? "strict" : "balanced"
        typingCooldown = preset == .precise ? 0.65 : 0.45
        topEdgeEnabled = false
        bottomEdgeEnabled = false
        invertScrollDirection = false
        cursorFreezeOnOneFinger = false
    }

    func resetGestureSettings() {
        applyGesturePreset(.everyday)
        brightnessMin = 0.05
        brightnessMax = 1
        volumeMin = 0
        volumeMax = 1
        topEdgeHeight = 0.15
        topEdgeSwipeDirection = "horizontal"
        topLeftAction = .brightness
        topRightAction = .volume
        topEdgeAction = .volume
        hapticFeedback = true
        hapticStyle = .standard
        hapticSpacing = .regular
        hapticOnStart = true
        muteAtZero = true
        bottomEdgeHeight = 0.15
        bottomEdgeAction = .mediaTracks
        // Layers and taps return to Off; recorded per-edge shortcuts are kept,
        // like the shared pair, so a reset never discards typed-in work.
        bindings = bindings.filter { EdgeSlot.swipe.contains($0.key) }
        tapCornerSize = 0.14
        precisionEnabled = true
        accelerationEnabled = true
        notchesEnabled = true
    }
}

enum GesturePreset: String, CaseIterable, Identifiable {
    case everyday, precise, oneFinger
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everyday: return "Everyday"
        case .precise: return "Precise"
        case .oneFinger: return "One finger"
        }
    }
    var detail: String {
        switch self {
        case .everyday: return "Two fingers · balanced"
        case .precise: return "Narrow zones · slower"
        case .oneFinger: return "One finger · edge only"
        }
    }
    var icon: String {
        switch self {
        case .everyday: return "hand.draw"
        case .precise: return "scope"
        case .oneFinger: return "hand.point.up"
        }
    }
}

// MARK: - Appearance helper (moved from ContentView extension)
extension TrackpadSettings {
    var resolvedColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default: return nil
        }
    }
}

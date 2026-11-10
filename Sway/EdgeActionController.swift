import AppKit
import Carbon
import Combine
import ObjectiveC

/// Distance-based commands never queue bursts or repeat a one-shot action.
/// A reversal discards residual travel, and stale frames are rejected by the
/// monitor before reaching this gate. No timer runs while idle.
struct GestureActionStepper {
    /// A level macOS lets apps move only a notch at a time (the keyboard
    /// backlight): notches come as fast as the finger travels, as any level
    /// would. Commands such as tabs and zoom keep a deliberate pace instead.
    var levelLike = false
    private var travel = 0.0
    private var direction = 0
    private var lastFire = -Double.infinity
    private var didFire = false

    // Spelled out: with private state, older Swift (Xcode 26, as on CI) makes
    // the generated initializer private to this file.
    init(levelLike: Bool = false) { self.levelLike = levelLike }

    mutating func consume(delta: Double, sensitivity: Double, inverted: Bool,
                          repeats: Bool, at time: Double) -> Bool? {
        guard delta.isFinite, sensitivity.isFinite, time.isFinite,
              abs(delta) <= 0.25, !didFire || repeats else { return nil }
        let movement = delta * min(3, max(0.3, sensitivity)) * (inverted ? -1 : 1)
        guard movement != 0 else { return nil }
        let sign = movement > 0 ? 1 : -1
        if sign != direction { travel = 0; direction = sign }
        let step = levelLike ? 0.035 : 0.07
        travel = min(step, travel + abs(movement))
        let threshold = didFire ? step : 0.025
        guard travel >= threshold else { return nil }
        if levelLike {
            // Every notch the finger covers counts; nothing is dropped.
            travel -= threshold
        } else {
            // Drop motion during the refractory period instead of replaying it.
            travel = 0
            guard time - lastFire >= 0.22 else { return nil }
        }
        lastFire = time
        didFire = true
        return sign > 0
    }
}

enum EdgeCommand: Equatable {
    case key(UInt16, UInt64, global: Bool)
    case media(Int)

    static func resolve(_ action: ZoneAction, increasing: Bool, custom: HotkeyCombo = .none) -> EdgeCommand? {
        let command = CGEventFlags.maskCommand.rawValue
        let control = CGEventFlags.maskControl.rawValue
        let shift = CGEventFlags.maskShift.rawValue
        switch action {
        case .keyboardBrightness: return .media(increasing ? 21 : 22)
        case .mediaTracks: return .media(increasing ? 17 : 18)
        case .playPause: return .media(16)
        case .tabs: return .key(48, control | (increasing ? 0 : shift), global: false)
        case .history: return .key(increasing ? 30 : 33, command, global: false)
        case .zoom: return .key(increasing ? 24 : 27, command, global: false)
        case .pages: return .key(increasing ? 116 : 121, 0, global: false)
        case .documentEnds: return .key(increasing ? 126 : 125, command, global: false)
        case .workspaces: return .key(increasing ? 124 : 123, control, global: true)
        case .missionControl: return .key(126, control, global: true)
        case .appWindows: return .key(125, control, global: true)
        case .showDesktop: return .key(103, 0, global: true)
        case .switchApps: return .key(48, command | (increasing ? 0 : shift), global: true)
        case .cycleWindows: return .key(50, command | (increasing ? 0 : shift), global: false)
        case .fullScreen: return .key(3, command | control, global: false)
        case .minimizeWindow: return .key(46, command, global: false)
        case .hideApp: return .key(4, command, global: false)
        case .spotlight: return .key(49, command, global: true)
        case .screenshotTools: return .key(23, command | shift, global: true)
        case .emojiPicker: return .key(49, command | control, global: false)
        case .copy: return .key(8, command, global: false)
        case .cut: return .key(7, command, global: false)
        case .paste: return .key(9, command, global: false)
        case .pastePlain: return .key(9, command | shift | CGEventFlags.maskAlternate.rawValue, global: false)
        case .undoRedo: return .key(6, command | (increasing ? shift : 0), global: false)
        case .selectAll: return .key(0, command, global: false)
        case .find: return .key(3, command, global: false)
        case .newCloseTab: return .key(increasing ? 17 : 13, command, global: false)
        case .reopenTab: return .key(17, command | shift, global: false)
        case .lockScreen: return .key(12, command | control, global: true)
        case .customShortcut:
            guard !custom.isEmpty, custom.keyCode <= 127,
                  custom.modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
            var flags: UInt64 = 0
            if custom.modifiers & UInt32(cmdKey) != 0 { flags |= command }
            if custom.modifiers & UInt32(controlKey) != 0 { flags |= control }
            if custom.modifiers & UInt32(optionKey) != 0 { flags |= CGEventFlags.maskAlternate.rawValue }
            if custom.modifiers & UInt32(shiftKey) != 0 { flags |= shift }
            return .key(UInt16(custom.keyCode), flags, global: true)
        case .brightness, .volume, .microphoneLevel, .outputMute, .microphoneMute, .disabled: return nil
        // Performed directly (Accessibility, Core Audio, Shortcuts, HUDs), not as keys.
        case .appVolume, .muteApp, .soloApp, .audioApps, .audioOutput, .seek, .nowPlaying, .tileWindow, .nightShift, .trueTone,
             .extraDim, .runShortcut, .cheatSheet, .ambientLight, .pastePrevious, .clipboardHistory, .sleepDisplay: return nil
        }
    }
}

enum EdgeActionController {
    // Own generated keys must not look like typing to palm protection.
    static let eventMarker: Int64 = 0x5357415945444745

    static func canDispatch(hasAccess: Bool, testing: Bool, expectedApplication: pid_t, currentApplication: pid_t?) -> Bool {
        hasAccess && !testing && expectedApplication > 0 && currentApplication == expectedApplication
    }

    /// Construct first, then post as a complete sequence. Explicit modifier
    /// release dismisses system switchers such as Command-Tab. Physical keys
    /// the user is actually holding are preserved, never synthetically lifted.
    /// Real arrow keys carry the number-pad and function flags, and F-keys and
    /// Home/End/Page keys the function flag. macOS's system shortcuts (Mission
    /// Control, App Exposé, switching desktops, Show Desktop) only match keys
    /// that carry them, so synthetic keys must too.
    static func hardwareFlags(for code: UInt16) -> UInt64 {
        if (123...126).contains(code) { return CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue }
        let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 115, 119, 116, 121]
        return functionKeys.contains(code) ? CGEventFlags.maskSecondaryFn.rawValue : 0
    }

    static func keyboardEvents(code: UInt16, flags: UInt64, physicalFlags: CGEventFlags) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
        down.flags = CGEventFlags(rawValue: flags | hardwareFlags(for: code))
        up.flags = CGEventFlags(rawValue: flags | hardwareFlags(for: code))
        var events = [down, up]
        let modifiers: [(CGEventFlags, UInt16)] = [(.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59), (.maskCommand, 55)]
        for (mask, key) in modifiers where flags & mask.rawValue != 0 && !physicalFlags.contains(mask) {
            guard let release = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
            release.type = .flagsChanged
            release.flags = physicalFlags
            events.append(release)
        }
        for event in events { event.setIntegerValueField(.eventSourceUserData, value: eventMarker) }
        return events
    }

    static func send(_ command: EdgeCommand, expectedApplication: pid_t) -> Bool {
        guard canDispatch(hasAccess: AXIsProcessTrusted(), testing: GestureTelemetry.shared.isTesting,
            expectedApplication: expectedApplication,
            currentApplication: NSWorkspace.shared.frontmostApplication?.processIdentifier) else { return false }
        switch command {
        case let .key(code, flags, global):
            guard let events = keyboardEvents(code: code, flags: flags, physicalFlags: CGEventSource.flagsState(.hidSystemState)) else { return false }
            for event in events {
                // System shortcuts are matched where hardware keys arrive.
                if global { event.post(tap: .cghidEventTap) }
                else { event.postToPid(expectedApplication) }
            }
        case let .media(code):
            // IOKit's NX_KEYTYPE values, paired down/up with no held modifiers.
            // macOS owns routing and native feedback; no success level is invented.
            var events: [CGEvent] = []
            for state in [0xA, 0xB] {
                guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0,
                    windowNumber: 0, context: nil, subtype: 8,
                    data1: (code << 16) | (state << 8), data2: -1)?.cgEvent else { return false }
                event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
                events.append(event)
            }
            // Create the whole pair before posting; never leave a key held if
            // event creation fails partway through.
            for event in events { event.post(tap: .cghidEventTap) }
        }
        return true
    }
}

/// Read-only capability discovery off main. Keyboard brightness itself is sent
/// through native media keys, not an unverified private brightness setter.
final class KeyboardBacklightCapability: ObservableObject {
    static let shared = KeyboardBacklightCapability()
    @Published private(set) var isAvailable = false
    @Published private(set) var checked = false
    private let worker = DispatchQueue(label: "com.sway.keyboard-capability", qos: .utility)
    private var checking = false
    private init() { refresh() }

    func refresh() {
        guard !checking else { return }
        checking = true
        worker.async { [weak self] in
            let available = Self.discover()
            DispatchQueue.main.async {
                self?.isAvailable = available
                self?.checked = true
                self?.checking = false
                NotificationCenter.default.post(name: .swayKeyboardCapabilityChanged, object: nil)
            }
        }
    }

    private static func discover() -> Bool {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"),
              bundle.load(), let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return false }
        let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let method = class_getInstanceMethod(type, selector), method_getNumberOfArguments(method) == 2 else { return false }
        // Fail closed if the private API changes its return type.
        let resultType = method_copyReturnType(method)
        defer { free(resultType) }
        guard resultType.pointee == 64 else { return false } // Objective-C object (@)
        let client = type.init()
        guard let keyboards = client.perform(selector)?.takeRetainedValue() as? [NSNumber] else { return false }
        return !keyboards.isEmpty
    }
}

extension Notification.Name {
    static let swayKeyboardCapabilityChanged = Notification.Name("swayKeyboardCapabilityChanged")
}

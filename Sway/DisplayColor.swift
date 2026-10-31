import AppKit
import CoreGraphics
import ObjectiveC

/// Private CoreBrightness classes, resolved at runtime and verified by method
/// signature before any call, so a changed interface fails closed instead of
/// crashing. These are the same clients Control Center's toggles use.
private enum CoreBrightness {
    static let loaded: Bool = {
        Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() == true
    }()

    static func client(_ name: String) -> NSObject? {
        guard loaded, let type = NSClassFromString(name) as? NSObject.Type else { return nil }
        return type.init()
    }

    /// The implementation, only when its Objective-C type encoding matches.
    /// `prefix` allows a trailing struct description that varies by release.
    static func implementation(_ object: NSObject, _ name: String, encoding: String, prefix: Bool = false) -> IMP? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: object), selector),
              let types = method_getTypeEncoding(method) else { return nil }
        // Strip frame offsets ("c24@0:8f16c20" -> "c@:fc"). BOOL is "c" on
        // Intel and "B" on Apple silicon; both are one byte.
        let signature = String(cString: types).filter { !$0.isNumber }.replacingOccurrences(of: "B", with: "c")
        guard prefix ? signature.hasPrefix(encoding) : signature == encoding else { return nil }
        return method_getImplementation(method)
    }
}

/// Night Shift strength as a level: 0 is off, 1 is warmest.
final class NightShiftController {
    static let shared = NightShiftController()
    private typealias SetStrength = @convention(c) (NSObject, Selector, Float, ObjCBool) -> ObjCBool
    private typealias GetStrength = @convention(c) (NSObject, Selector, UnsafeMutablePointer<Float>) -> ObjCBool
    private typealias SetEnabled = @convention(c) (NSObject, Selector, ObjCBool) -> ObjCBool
    private typealias GetStatus = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> ObjCBool
    private let queue = DispatchQueue(label: "com.sway.night-shift", qos: .userInteractive)
    private var client: NSObject?
    private var setStrength: SetStrength?
    private var getStrength: GetStrength?
    private var setEnabled: SetEnabled?
    private var getStatus: GetStatus?
    private let worker = LatestValueWorker(label: "com.sway.night-shift-writes")

    private init() {
        queue.sync {
            guard let client = CoreBrightness.client("CBBlueLightClient") else { return }
            self.client = client
            setStrength = CoreBrightness.implementation(client, "setStrength:commit:", encoding: "c@:fc")
                .map { unsafeBitCast($0, to: SetStrength.self) }
            getStrength = CoreBrightness.implementation(client, "getStrength:", encoding: "c@:^f")
                .map { unsafeBitCast($0, to: GetStrength.self) }
            setEnabled = CoreBrightness.implementation(client, "setEnabled:", encoding: "c@:c")
                .map { unsafeBitCast($0, to: SetEnabled.self) }
            getStatus = CoreBrightness.implementation(client, "getBlueLightStatus:", encoding: "c@:^", prefix: true)
                .map { unsafeBitCast($0, to: GetStatus.self) }
        }
    }

    var isAvailable: Bool { queue.sync { client != nil && setStrength != nil && getStrength != nil && setEnabled != nil } }

    /// Effective warmth: zero whenever Night Shift is off.
    func level() -> Float? {
        queue.sync {
            guard let client, let getStrength else { return nil }
            var strength: Float = 0
            guard getStrength(client, NSSelectorFromString("getStrength:"), &strength).boolValue,
                  strength.isFinite else { return nil }
            if let enabled = enabledLocked(), !enabled { return 0 }
            return min(1, max(0, strength))
        }
    }

    private func enabledLocked() -> Bool? {
        guard let client, let getStatus else { return nil }
        // Generous zeroed buffer: the status struct has grown across releases.
        var buffer = [UInt8](repeating: 0, count: 128)
        let ok = buffer.withUnsafeMutableBytes { getStatus(client, NSSelectorFromString("getBlueLightStatus:"), $0.baseAddress!).boolValue }
        return ok ? buffer[1] != 0 : nil // { BOOL active; BOOL enabled; ... }
    }

    /// Latest-wins. Completion on main with the level macOS reports afterwards.
    func request(_ value: Float, completion: @escaping (Float?) -> Void) {
        let target = min(1, max(0, value.isFinite ? value : 0))
        worker.submit(completion: completion) { [weak self] in
            guard let self else { return nil }
            let accepted = self.queue.sync { () -> Bool in
                guard let client = self.client, let setStrength = self.setStrength, let setEnabled = self.setEnabled else { return false }
                // Zero means off, not "on at zero strength".
                guard setEnabled(client, NSSelectorFromString("setEnabled:"), ObjCBool(target >= 0.01)).boolValue else { return false }
                return target < 0.01 || setStrength(client, NSSelectorFromString("setStrength:commit:"), target, true).boolValue
            }
            return accepted ? self.level() : nil
        }
    }
}

/// True Tone on supported displays.
final class TrueToneController {
    static let shared = TrueToneController()
    private typealias GetBool = @convention(c) (NSObject, Selector) -> ObjCBool
    private typealias SetBool = @convention(c) (NSObject, Selector, ObjCBool) -> ObjCBool
    private let queue = DispatchQueue(label: "com.sway.true-tone", qos: .userInitiated)
    private var client: NSObject?
    private var supported: GetBool?
    private var available: GetBool?
    private var enabled: GetBool?
    private var setEnabled: SetBool?

    private init() {
        queue.sync {
            guard let client = CoreBrightness.client("CBTrueToneClient") else { return }
            self.client = client
            supported = CoreBrightness.implementation(client, "supported", encoding: "c@:").map { unsafeBitCast($0, to: GetBool.self) }
            available = CoreBrightness.implementation(client, "available", encoding: "c@:").map { unsafeBitCast($0, to: GetBool.self) }
            enabled = CoreBrightness.implementation(client, "enabled", encoding: "c@:").map { unsafeBitCast($0, to: GetBool.self) }
            setEnabled = CoreBrightness.implementation(client, "setEnabled:", encoding: "c@:c").map { unsafeBitCast($0, to: SetBool.self) }
        }
    }

    var isAvailable: Bool {
        queue.sync {
            guard let client, let supported, let available, enabled != nil, setEnabled != nil else { return false }
            return supported(client, NSSelectorFromString("supported")).boolValue
                && available(client, NSSelectorFromString("available")).boolValue
        }
    }

    var isEnabled: Bool? {
        queue.sync {
            guard let client, let enabled else { return nil }
            return enabled(client, NSSelectorFromString("enabled")).boolValue
        }
    }

    /// Completion on main with the state read back afterwards.
    func setEnabled(_ on: Bool, completion: @escaping (Bool?) -> Void) {
        queue.async { [weak self] in
            guard let self, let client = self.client, let setEnabled = self.setEnabled, let enabled = self.enabled else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let accepted = setEnabled(client, NSSelectorFromString("setEnabled:"), ObjCBool(on)).boolValue
            let state = accepted ? enabled(client, NSSelectorFromString("enabled")).boolValue : nil
            DispatchQueue.main.async { completion(state) }
        }
    }
}

/// Dims below the backlight's minimum by scaling the display's gamma table.
/// The original (calibrated) table is captured first and restored exactly.
/// macOS restores gamma when the process exits, so a crash cannot leave a
/// display dark; quitting restores it explicitly as well.
final class GammaDimmer {
    static let shared = GammaDimmer()
    /// Never darker than this fraction of normal output: always readable.
    static let darkestScale: Float = 0.2
    private let queue = DispatchQueue(label: "com.sway.gamma", qos: .userInteractive)
    private var originals: [CGDirectDisplayID: (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])] = [:]
    private var levels: [CGDirectDisplayID: Float] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            // macOS resets tables on reconfiguration; forget stale captures.
            self?.queue.async { self?.originals.removeAll(); self?.levels.removeAll() }
        }
    }

    /// Pure: output scale for a dim level (0 = normal, 1 = darkest).
    static func scale(for level: Float) -> Float {
        let clamped = min(1, max(0, level.isFinite ? level : 0))
        return 1 - clamped * (1 - darkestScale)
    }

    func level(for display: CGDirectDisplayID) -> Float { queue.sync { levels[display] ?? 0 } }

    @discardableResult
    func setLevel(_ level: Float, for display: CGDirectDisplayID) -> Bool {
        queue.sync {
            let clamped = min(1, max(0, level.isFinite ? level : 0))
            if clamped < 0.001 {
                guard let original = originals.removeValue(forKey: display) else { levels[display] = 0; return true }
                levels[display] = 0
                return CGSetDisplayTransferByTable(display, UInt32(original.red.count), original.red, original.green, original.blue) == .success
            }
            if originals[display] == nil {
                let capacity = CGDisplayGammaTableCapacity(display)
                guard capacity > 0 else { return false }
                var red = [CGGammaValue](repeating: 0, count: Int(capacity))
                var green = red, blue = red
                var count: UInt32 = 0
                guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 0 else { return false }
                originals[display] = (Array(red.prefix(Int(count))), Array(green.prefix(Int(count))), Array(blue.prefix(Int(count))))
            }
            guard let original = originals[display] else { return false }
            let factor = Self.scale(for: clamped)
            let result = CGSetDisplayTransferByTable(display, UInt32(original.red.count),
                                                     original.red.map { $0 * factor }, original.green.map { $0 * factor },
                                                     original.blue.map { $0 * factor })
            if result == .success { levels[display] = clamped }
            return result == .success
        }
    }

    func restoreAll() {
        queue.sync {
            guard !originals.isEmpty || levels.values.contains(where: { $0 > 0 }) else { return }
            originals.removeAll()
            levels.removeAll()
            CGDisplayRestoreColorSyncSettings()
        }
    }
}

/// One background write at a time; newer values replace queued ones instead
/// of building a backlog. Completions run on main, exactly once each.
final class LatestValueWorker {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: (work: () -> Float?, completion: (Float?) -> Void)?
    private var running = false

    init(label: String) { queue = DispatchQueue(label: label, qos: .userInteractive) }

    func submit(completion: @escaping (Float?) -> Void, work: @escaping () -> Float?) {
        lock.lock()
        let replaced = pending?.completion
        pending = (work, completion)
        let start = !running
        running = true
        lock.unlock()
        if let replaced { DispatchQueue.main.async { replaced(nil) } }
        if start { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        lock.lock()
        guard let next = pending else { running = false; lock.unlock(); return }
        pending = nil
        lock.unlock()
        let result = next.work()
        DispatchQueue.main.async { next.completion(result) }
        queue.async { [weak self] in self?.drain() }
    }
}

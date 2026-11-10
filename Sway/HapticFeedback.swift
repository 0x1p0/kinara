import AppKit

/// Soft, Standard and Crisp are public macOS patterns. Strongest drives the
/// trackpad's actuator directly for a firmer click than any public pattern,
/// and falls back to Crisp wherever that private actuator is unavailable.
enum HapticStyle: String, CaseIterable, Identifiable {
    case soft, standard, crisp, strong
    var id: String { rawValue }
    var label: String {
        switch self {
        case .soft: return "Soft"
        case .standard: return "Standard"
        case .crisp: return "Crisp"
        case .strong: return "Strongest"
        }
    }
    var pattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .soft: return .alignment
        case .standard: return .generic
        case .crisp, .strong: return .levelChange
        }
    }
}

/// Fine taps every 1%: one tap for every number the indicator shows.
enum HapticSpacing: String, CaseIterable, Identifiable {
    case fine, regular, sparse
    var id: String { rawValue }
    var amount: Double {
        switch self {
        case .fine: return 0.01
        case .regular: return 0.05
        case .sparse: return 0.10
        }
    }
    var label: String {
        switch self {
        case .fine: return "1%"
        case .regular: return "5%"
        case .sparse: return "10%"
        }
    }
}

struct HapticConfiguration: Equatable {
    var enabled = true
    var style: HapticStyle = .standard
    var spacing: HapticSpacing = .regular
    var onStart = true
}

/// A notched dial, not a metronome. Detents sit at fixed places: the shown
/// number reaching a multiple of the spacing, each notch, and both limits. A
/// tap means the level crossed or landed on one, so a level always taps in
/// the same place, at any speed, on any device. Feed it the level the finger
/// asked for, on the frame it asked: readback arrives late, paced and
/// quantized by the device, so it never drives feedback. A detent that just
/// tapped has hysteresis, like a real one: it never taps twice the same way,
/// and back the other way only `rearm` past it, so a finger resting on it
/// can't chatter. No timers, work items, or pulse queue.
struct GestureHapticFeedback {
    /// Quick enough that a brisk slide still ratchets through every 5% detent.
    static let minimumInterval = 0.05
    /// Within this of a notch or limit the level is on it: arriving taps, leaving doesn't.
    static let tolerance = 0.000_5
    /// Levels show as whole percents, so a shown number changes half a percent
    /// before the level reaches it: 25 appears at 24.5% on the way up and at
    /// 25.49% on the way down. Steps tap there, on the frame the number changes.
    static let half = 0.005
    private var configuration = HapticConfiguration()
    private var previous: Double?
    /// The detent that tapped last and which way, until the level is `rearm` from it.
    private var quiet: (detent: Double, rising: Bool, stop: Bool)?
    private var lastPulseTime: Double?

    /// The hysteresis: how far past a detent that just tapped the level must go to tap it again.
    var rearm: Double { min(0.01, configuration.spacing.amount * 0.3) }

    mutating func begin(value: Double, configuration: HapticConfiguration, at time: Double) -> HapticStyle? {
        end()
        self.configuration = configuration
        guard configuration.enabled, value.isFinite, time.isFinite else { return nil }
        previous = value
        return configuration.onStart ? pulse(configuration.style, at: time) : nil
    }

    /// A notch or a limit is at least crisp, so it reads as a stop, not a step.
    var notchStyle: HapticStyle { configuration.style == .strong ? .strong : .crisp }

    mutating func update(value: Double, bounds: ClosedRange<Double>, at time: Double,
                         notches: [Double] = []) -> HapticStyle? {
        guard configuration.enabled, let previous,
              value.isFinite, time.isFinite,
              bounds.lowerBound.isFinite, bounds.upperBound.isFinite else { return nil }
        let value = min(bounds.upperBound, max(bounds.lowerBound, value))
        self.previous = value
        guard abs(value - previous) > 0.000_001 else { return nil }
        let rising = value > previous
        let rearm = self.rearm
        // Passed on the way: beyond where the level was, up to and including where it is.
        func passed(_ detent: Double, stop: Bool) -> Bool {
            var detent = detent
            if let quiet, abs(quiet.detent - detent) <= Self.tolerance {
                // Never twice the same way; a stop taps only on arrival; a step back only past the hysteresis.
                guard quiet.rising != rising, !quiet.stop else { return false }
                detent += rising ? rearm : -rearm
            }
            let tolerance = stop ? Self.tolerance : 0
            return rising ? previous < detent - tolerance && detent - tolerance <= value
                          : previous > detent + tolerance && detent + tolerance >= value
        }
        // Stops: notches and limits, exact levels the value comes to rest on.
        let anchors = notches.filter { $0.isFinite && bounds.contains($0) } + [bounds.lowerBound, bounds.upperBound]
        let stops = anchors.filter { passed($0, stop: true) }
        // Steps: the shown number reaching a multiple of the spacing. A stop's own
        // number belongs to the stop, so the two never tap twice.
        let step = configuration.spacing.amount
        let reach = Self.half + rearm
        let low = (min(previous, value) - reach) / step, high = (max(previous, value) + reach) / step
        let steps = stride(from: low.rounded(.down), through: high.rounded(.up), by: 1)
            .map { $0 * step }
            .filter { level in bounds.contains(level) && !anchors.contains { abs($0 - level) <= Self.half + Self.tolerance } }
            .map { rising ? $0 - Self.half : $0 + Self.half }
            .filter { passed($0, stop: false) }
        let detents = stops.map { ($0, true) } + steps.map { ($0, false) }
        guard let last = rising ? detents.max(by: { $0.0 < $1.0 }) : detents.min(by: { $0.0 < $1.0 }) else {
            if let quiet, abs(value - quiet.detent) >= rearm { self.quiet = nil }
            return nil
        }
        guard let style = pulse(stops.isEmpty ? configuration.style : notchStyle, at: time) else { return nil }
        quiet = (last.0, rising, last.1)
        return style
    }

    /// A one-off tap inside the gesture, such as precision engaging. It keeps
    /// the gesture's cadence, so the next detent is never silently dropped.
    mutating func cue(_ style: HapticStyle, at time: Double) -> HapticStyle? {
        guard configuration.enabled, previous != nil, time.isFinite else { return nil }
        return pulse(style, at: time)
    }

    mutating func end() {
        previous = nil
        quiet = nil
        // Preserve the rate limit across rapid lift/restart cycles.
    }

    private mutating func pulse(_ style: HapticStyle, at time: Double) -> HapticStyle? {
        guard lastPulseTime.map({ time - $0 >= Self.minimumInterval }) ?? true else { return nil }
        lastPulseTime = time
        return style
    }
}

/// Both gesture feedback and the explicit preview use the same immediate path.
/// The performer is fetched per tap: macOS can change the active input device.
final class HapticOutput {
    static let shared = HapticOutput()
    /// Installed by the app at launch: fires the actuator's strongest waveform
    /// and reports whether it did. Unset (tests, unsupported Macs) means Crisp.
    static var strongActuator: (() -> Bool)?
    private let now: () -> Double
    private let perform: (NSHapticFeedbackManager.FeedbackPattern, NSHapticFeedbackManager.PerformanceTime) -> Void
    private let strong: (() -> Bool)?
    private var lastPulseTime: Double?

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         perform: @escaping (NSHapticFeedbackManager.FeedbackPattern, NSHapticFeedbackManager.PerformanceTime) -> Void = {
             NSHapticFeedbackManager.defaultPerformer.perform($0, performanceTime: $1)
         },
         strong: (() -> Bool)? = nil) {
        self.now = now
        self.perform = perform
        self.strong = strong
    }

    func play(_ style: HapticStyle) {
        let time = now()
        guard time.isFinite,
              lastPulseTime.map({ time - $0 >= GestureHapticFeedback.minimumInterval }) ?? true else { return }
        lastPulseTime = time
        if style == .strong, (strong ?? Self.strongActuator)?() == true { return }
        perform(style.pattern, .now)
    }
}

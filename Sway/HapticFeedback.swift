import AppKit

/// Public macOS patterns, not an undocumented actuator-strength control.
enum HapticStyle: String, CaseIterable, Identifiable {
    case soft, standard, crisp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .soft: return "Soft"
        case .standard: return "Standard"
        case .crisp: return "Crisp"
        }
    }
    var pattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .soft: return .alignment
        case .standard: return .generic
        case .crisp: return .levelChange
        }
    }
}

enum HapticSpacing: String, CaseIterable, Identifiable {
    case fine, regular, sparse
    var id: String { rawValue }
    var amount: Double {
        switch self {
        case .fine: return 0.02
        case .regular: return 0.05
        case .sparse: return 0.10
        }
    }
    var label: String {
        switch self {
        case .fine: return "2%"
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

/// Value-driven, with no timers, work items, or accumulated pulse queue.
/// A step is distance from the last tap, so boundary jitter cannot chatter.
struct GestureHapticFeedback {
    static let minimumInterval = 0.08
    private var configuration = HapticConfiguration()
    private var anchor: Double?
    private var previous: Double?
    private var lastPulseTime: Double?

    mutating func begin(value: Double, configuration: HapticConfiguration, at time: Double) -> HapticStyle? {
        end()
        self.configuration = configuration
        guard configuration.enabled, value.isFinite, time.isFinite else { return nil }
        anchor = min(1, max(0, value))
        previous = anchor
        return configuration.onStart ? pulse(at: time) : nil
    }

    /// A notch always uses the crisp pattern so it reads as a detent, not a step.
    static let notchStyle: HapticStyle = .crisp

    mutating func update(value: Double, bounds: ClosedRange<Double>, at time: Double,
                         notches: [Double] = []) -> HapticStyle? {
        guard configuration.enabled, let anchor, let previous,
              value.isFinite, time.isFinite,
              bounds.lowerBound.isFinite, bounds.upperBound.isFinite else { return nil }
        let value = min(1, max(0, value))
        self.previous = value
        // Only fresh, changed readbacks can request feedback. No delayed replay
        // when a stationary value arrives after a rate-limited step.
        guard abs(value - previous) > 0.000_001 else { return nil }
        // Drivers quantize, so "on the notch" allows half a percent of readback error.
        if notches.contains(where: { abs($0 - value) < 0.005 && abs($0 - previous) >= 0.005 }) {
            guard pulse(at: time) != nil else { return nil }
            self.anchor = value
            return Self.notchStyle
        }
        let reachedLimit = (value <= bounds.lowerBound + 0.000_001 && previous > bounds.lowerBound + 0.000_001)
            || (value >= bounds.upperBound - 0.000_001 && previous < bounds.upperBound - 0.000_001)
        guard abs(value - anchor) + 0.000_001 >= configuration.spacing.amount || reachedLimit,
              let style = pulse(at: time) else { return nil }
        self.anchor = value
        return style
    }

    mutating func end() {
        anchor = nil
        previous = nil
        // Preserve the rate limit across rapid lift/restart cycles.
    }

    private mutating func pulse(at time: Double) -> HapticStyle? {
        guard lastPulseTime.map({ time - $0 >= Self.minimumInterval }) ?? true else { return nil }
        lastPulseTime = time
        return configuration.style
    }
}

/// Both gesture feedback and the explicit preview use the same immediate path.
/// The performer is fetched per tap: macOS can change the active input device.
final class HapticOutput {
    static let shared = HapticOutput()
    private let now: () -> Double
    private let perform: (NSHapticFeedbackManager.FeedbackPattern, NSHapticFeedbackManager.PerformanceTime) -> Void
    private var lastPulseTime: Double?

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         perform: @escaping (NSHapticFeedbackManager.FeedbackPattern, NSHapticFeedbackManager.PerformanceTime) -> Void = {
             NSHapticFeedbackManager.defaultPerformer.perform($0, performanceTime: $1)
         }) {
        self.now = now
        self.perform = perform
    }

    func play(_ style: HapticStyle) {
        let time = now()
        guard time.isFinite,
              lastPulseTime.map({ time - $0 >= GestureHapticFeedback.minimumInterval }) ?? true else { return }
        lastPulseTime = time
        perform(style.pattern, .now)
    }
}

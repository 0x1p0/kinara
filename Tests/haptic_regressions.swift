import AppKit

@main
enum HapticRegressionTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let limits = 0.0...1.0
        var haptics = GestureHapticFeedback()
        expect(haptics.update(value: 0.6, bounds: limits, at: 1) == nil, "no feedback before an accepted gesture")
        expect(haptics.begin(value: 0.5, configuration: .init(), at: 1) == .standard, "default start tap")
        expect(haptics.update(value: 0.55, bounds: limits, at: 1.01) == nil, "start and first step cannot pile up")
        expect(haptics.update(value: 0.55, bounds: limits, at: 1.2) == nil, "no deferred tap for an unchanged value")
        expect(haptics.update(value: 0.56, bounds: limits, at: 1.21) == .standard, "fresh movement can cross a suppressed step")
        expect(haptics.update(value: 0.559, bounds: limits, at: 1.4) == nil, "small reversal cannot chatter")
        expect(haptics.update(value: 0.51, bounds: limits, at: 1.6) == .standard, "reverse movement gets its own step")
        haptics.end()
        expect(haptics.update(value: 1, bounds: limits, at: 2) == nil, "late readback after lift or cancellation is silent")
        expect(haptics.begin(value: 0.5, configuration: .init(enabled: false), at: 3) == nil, "off suppresses gesture start")
        expect(haptics.update(value: 0.7, bounds: limits, at: 4) == nil, "off suppresses steps")

        for style in HapticStyle.allCases {
            for spacing in HapticSpacing.allCases {
                var sequence = GestureHapticFeedback()
                let configuration = HapticConfiguration(style: style, spacing: spacing, onStart: false)
                expect(sequence.begin(value: 0.5, configuration: configuration, at: 0) == nil, "start tap can be disabled independently")
                expect(sequence.update(value: 0.5 + spacing.amount / 2, bounds: limits, at: 0.1) == nil, "spacing waits for enough movement")
                expect(sequence.update(value: 0.5 + spacing.amount, bounds: limits, at: 0.2) == style, "each style and spacing reaches the selected performer")
                expect(sequence.update(value: 0.5, bounds: limits, at: 0.4) == style, "selected spacing works in reverse")
            }
        }

        var boundary = GestureHapticFeedback()
        _ = boundary.begin(value: 0.4999, configuration: .init(onStart: false), at: 0)
        for index in 1...20 {
            let value = index.isMultiple(of: 2) ? 0.4999 : 0.5001
            expect(boundary.update(value: value, bounds: limits, at: Double(index)) == nil, "jitter across a percentage boundary stays quiet")
        }
        expect(boundary.update(value: 0.51, bounds: 0.49...0.51, at: 21) == .standard, "short movement into a custom maximum gets feedback")
        expect(boundary.update(value: 0.51, bounds: 0.49...0.51, at: 22) == nil, "holding a limit does not repeat taps")
        expect(boundary.update(value: 0.49, bounds: 0.49...0.51, at: 23) == .standard, "custom minimum also gets feedback")

        var invalid = GestureHapticFeedback()
        expect(invalid.begin(value: .nan, configuration: .init(), at: 0) == nil, "nonfinite baseline is ignored")
        expect(invalid.update(value: 0.8, bounds: limits, at: 1) == nil, "invalid start never arms the sequence")
        expect(invalid.begin(value: 0.5, configuration: .init(), at: .infinity) == nil, "nonfinite start time is ignored")
        _ = invalid.begin(value: 0.5, configuration: .init(onStart: false), at: 0)
        expect(invalid.update(value: .nan, bounds: limits, at: 1) == nil, "nonfinite measurement is ignored")
        expect(invalid.update(value: 0.7, bounds: limits, at: .nan) == nil, "nonfinite update time is ignored")
        expect(invalid.update(value: 0.7, bounds: limits, at: 1) == .standard, "invalid inputs do not poison the next valid step")

        var fast = GestureHapticFeedback()
        var pulseTimes: [Double] = []
        for index in 0..<1_000 {
            let time = Double(index) / 1_000
            fast.end()
            if fast.begin(value: 0.5, configuration: .init(), at: time) != nil { pulseTimes.append(time) }
        }
        expect(pulseTimes.count <= 13, "rapid restart cannot bypass the global cadence")
        expect(zip(pulseTimes.dropFirst(), pulseTimes).allSatisfy { $0 - $1 >= 0.08 }, "all pulse intervals stay bounded")
        expect(fast.begin(value: 0.5, configuration: .init(), at: -1) == nil, "backwards clock cannot defeat the limiter")

        var now = 0.0
        var calls: [(NSHapticFeedbackManager.FeedbackPattern, NSHapticFeedbackManager.PerformanceTime)] = []
        let output = HapticOutput(now: { now }, perform: { calls.append(($0, $1)) })
        output.play(.soft)
        expect(calls.count == 1 && calls[0].0 == .alignment && calls[0].1 == .now, "soft preview is immediate, without a drawing pass")
        output.play(.crisp)
        expect(calls.count == 1, "rapid previews cannot build a pulse queue")
        now = 0.1
        output.play(.standard)
        expect(calls.count == 2 && calls[1].0 == .generic && calls[1].1 == .now, "standard pattern uses immediate timing")
        now = 0.2
        output.play(.crisp)
        expect(calls.count == 3 && calls[2].0 == .levelChange && calls[2].1 == .now, "crisp pattern uses immediate timing")
        now = .nan
        output.play(.standard)
        expect(calls.count == 3, "invalid performer clock is silent")

        var notched = GestureHapticFeedback()
        _ = notched.begin(value: 0.47, configuration: HapticConfiguration(enabled: true, style: .soft, spacing: .sparse, onStart: false), at: 10)
        expect(notched.update(value: 0.49, bounds: 0...1, at: 10.1, notches: [0.5]) == nil, "approaching a notch stays quiet below the step size")
        expect(notched.update(value: 0.5, bounds: 0...1, at: 10.2, notches: [0.5]) == .crisp, "landing on a notch taps crisply, whatever the step style")
        expect(notched.update(value: 0.502, bounds: 0...1, at: 10.3, notches: [0.5]) == nil, "jitter on a notch does not chatter")
        expect(notched.update(value: 0.5, bounds: 0...1, at: 10.4, notches: [0.5]) == nil, "re-reading the notch value is not a new notch")
        expect(notched.update(value: 0.53, bounds: 0...1, at: 10.5, notches: [0.5]) == nil, "leaving a notch restarts step spacing from it")
        expect(notched.update(value: 0.505, bounds: 0...1, at: 10.6, notches: [0.5]) == nil, "re-entering within readback error of the last notch value stays quiet")
        _ = notched.update(value: 0.6, bounds: 0...1, at: 10.7, notches: [0.5])
        expect(notched.update(value: 0.5, bounds: 0...1, at: 10.75, notches: [0.5]) == nil, "notches obey the shared tap cadence")
        expect(notched.update(value: 0.4, bounds: 0...1, at: 11, notches: []) == .soft, "without notches ordinary steps continue")
        var strongClock = 0.0
        var strongCalls: [NSHapticFeedbackManager.FeedbackPattern] = []
        var actuations = 0
        var actuatorWorks = true
        let strongOutput = HapticOutput(now: { strongClock }, perform: { pattern, _ in strongCalls.append(pattern) },
                                        strong: { actuations += 1; return actuatorWorks })
        strongOutput.play(.strong)
        expect(actuations == 1 && strongCalls.isEmpty, "Strongest uses the actuator instead of a public pattern")
        strongClock = 0.05
        strongOutput.play(.strong)
        expect(actuations == 1, "Strongest obeys the shared tap cadence")
        strongClock = 0.2
        actuatorWorks = false
        strongOutput.play(.strong)
        expect(actuations == 2 && strongCalls == [.levelChange], "an unavailable actuator falls back to Crisp")
        strongClock = 0.4
        strongOutput.play(.standard)
        expect(actuations == 2 && strongCalls.last == .generic, "other styles never touch the actuator")
        let noActuator = HapticOutput(now: { 1 }, perform: { pattern, _ in strongCalls.append(pattern) })
        noActuator.play(.strong)
        expect(strongCalls.last == .levelChange, "without an installed actuator Strongest is Crisp")
        var strongNotch = GestureHapticFeedback()
        _ = strongNotch.begin(value: 0.45, configuration: HapticConfiguration(enabled: true, style: .strong, spacing: .sparse, onStart: false), at: 20)
        expect(strongNotch.update(value: 0.5, bounds: 0...1, at: 20.2, notches: [0.5]) == .strong, "with Strongest, notches are strongest too")
        expect(HapticStyle.strong.label == "Strongest" && HapticStyle.allCases.last == .strong, "Strongest is offered last, after Crisp")
        print("\(checks) haptic assertions passed. Fake clock and performer only; no physical haptics ran.")
    }
}

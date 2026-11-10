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
        expect(haptics.update(value: 0.55, bounds: limits, at: 1.01) == nil, "start and first detent cannot pile up")
        expect(haptics.update(value: 0.55, bounds: limits, at: 1.2) == nil, "no deferred tap for an unchanged value")
        expect(haptics.update(value: 0.56, bounds: limits, at: 1.21) == nil, "a detent lost to the cadence is never replayed")
        expect(haptics.update(value: 0.6, bounds: limits, at: 1.3) == .standard, "the next detent taps")
        expect(haptics.update(value: 0.597, bounds: limits, at: 1.4) == nil, "small reversal cannot chatter")
        expect(haptics.update(value: 0.55, bounds: limits, at: 1.6) == .standard, "reverse movement taps at the detent below")
        haptics.end()
        expect(haptics.update(value: 1, bounds: limits, at: 2) == nil, "late readback after lift or cancellation is silent")
        expect(haptics.begin(value: 0.5, configuration: .init(enabled: false), at: 3) == nil, "off suppresses gesture start")
        expect(haptics.update(value: 0.7, bounds: limits, at: 4) == nil, "off suppresses steps")

        expect(HapticSpacing.fine.amount == 0.01 && HapticSpacing.fine.label == "1%", "the finest spacing taps every 1%")
        for style in HapticStyle.allCases {
            for spacing in HapticSpacing.allCases {
                var sequence = GestureHapticFeedback()
                let configuration = HapticConfiguration(style: style, spacing: spacing, onStart: false)
                expect(sequence.begin(value: 0.5, configuration: configuration, at: 0) == nil, "start tap can be disabled independently")
                expect(sequence.update(value: 0.5 + spacing.amount / 2 - 0.001, bounds: limits, at: 0.1) == nil, "spacing waits for the next detent")
                expect(sequence.update(value: 0.5 + spacing.amount, bounds: limits, at: 0.2) == style, "each style and spacing reaches the selected performer")
                expect(sequence.update(value: 0.5, bounds: limits, at: 0.4) == style, "selected spacing works in reverse")
            }
        }

        // The contract: a tap on exactly the frames where the number on screen
        // (whole percents) reaches a multiple of the spacing, up and down.
        for spacing in [HapticSpacing.fine, .regular, .sparse] {
            let percent = Int((spacing.amount * 100).rounded())
            let path = (0...860).map { 0.200_03 + Double($0) * 0.000_7 }
            let values = path + path.reversed().dropFirst()
            var feedback = GestureHapticFeedback()
            _ = feedback.begin(value: values[0], configuration: .init(spacing: spacing, onStart: false), at: 0)
            var shown = Int((values[0] * 100).rounded())
            var agrees = true, count = 0
            for (index, value) in values.enumerated().dropFirst() {
                let number = Int((value * 100).rounded())
                let arrives = number != shown && number % percent == 0
                shown = number
                let tapped = feedback.update(value: value, bounds: limits, at: Double(index) * 0.1) != nil
                if tapped { count += 1 }
                agrees = agrees && tapped == arrives
            }
            expect(agrees && count > 0, "\(spacing.label) taps on the frame the shown number reaches each multiple, and only then")
        }

        func taps(from start: Double, through values: [Double], spacing: HapticSpacing = .regular,
                  bounds: ClosedRange<Double> = 0...1, notches: [Double] = [], frame: Double = 0.1) -> [Double] {
            var feedback = GestureHapticFeedback()
            _ = feedback.begin(value: start, configuration: .init(spacing: spacing, onStart: false), at: 0)
            var landed: [Double] = []
            for (index, value) in values.enumerated()
            where feedback.update(value: value, bounds: bounds, at: Double(index + 1) * frame, notches: notches) != nil {
                landed.append(value)
            }
            return landed
        }
        expect(taps(from: 0.43, through: [0.44, 0.45, 0.47, 0.49, 0.5, 0.53]) == [0.45, 0.5],
               "taps land at fixed multiples, not a step from where the slide began")
        expect(taps(from: 0, through: stride(from: 0.003, through: 1, by: 0.003).map { $0 } + [1]).count == 20
               && taps(from: 0, through: stride(from: 0.03, through: 1, by: 0.03).map { $0 } + [1]).count == 20,
               "small and large frame-to-frame jumps tap the same 20 detents, the last at the limit")
        let flick = taps(from: 0.2, through: stride(from: 0.22, through: 0.7, by: 0.02).map { $0 }, frame: 0.01)
        expect(flick.count <= 6 && !flick.isEmpty, "a fast flick ratchets within the cadence instead of buzzing")
        expect(taps(from: 0.03, through: [0.0, -0.02, -0.05, -0.1], bounds: -0.5...1, notches: [0]) == [0.0, -0.05, -0.1],
               "where the hardware ends and extra dim begins is a stop, and detents continue below it")

        var boundary = GestureHapticFeedback()
        _ = boundary.begin(value: 0.2449, configuration: .init(onStart: false), at: 0)
        expect(boundary.update(value: 0.2451, bounds: limits, at: 1) == .standard, "the number reaching 25 taps once")
        for index in 2...21 {
            let value = index.isMultiple(of: 2) ? 0.2449 : 0.2451
            expect(boundary.update(value: value, bounds: limits, at: Double(index)) == nil, "jitter on a detent stays quiet")
        }
        expect(boundary.update(value: 0.262, bounds: limits, at: 22) == nil, "moving away from a detent re-arms it silently")
        expect(boundary.update(value: 0.24, bounds: limits, at: 23) == .standard, "coming back down to 25 taps again")
        var limited = GestureHapticFeedback()
        _ = limited.begin(value: 0.5, configuration: .init(onStart: false), at: 0)
        expect(limited.update(value: 0.51, bounds: 0.49...0.51, at: 1) == .crisp, "short movement into a custom maximum stops firmly")
        expect(limited.update(value: 0.51, bounds: 0.49...0.51, at: 2) == nil, "holding a limit does not repeat taps")
        expect(limited.update(value: 0.49, bounds: 0.49...0.51, at: 3) == .crisp, "custom minimum also stops firmly, once")
        var resting = GestureHapticFeedback()
        _ = resting.begin(value: 0.5, configuration: .init(onStart: false), at: 0)
        expect(resting.update(value: 0.5003, bounds: limits, at: 1) == nil && resting.update(value: 0.4997, bounds: limits, at: 2) == nil,
               "a slide that starts on a detent leaves it without a tap")
        var fine = GestureHapticFeedback()
        _ = fine.begin(value: 0.5, configuration: .init(style: .strong, spacing: .fine, onStart: false), at: 0)
        expect(fine.update(value: 0.506, bounds: limits, at: 1) == .strong, "Strongest at 1% taps as the number turns 51")
        expect(fine.update(value: 0.5045, bounds: limits, at: 2) == nil, "a hair back is not a new number")
        expect(fine.update(value: 0.5, bounds: limits, at: 3) == .strong, "back to 50 taps again")
        var trembling = GestureHapticFeedback()
        _ = trembling.begin(value: 0.300_3, configuration: .init(style: .strong, spacing: .fine, onStart: false), at: 0)
        var seed: UInt64 = 42, trembles = 0
        for index in 1...2_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let tremor = (Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.002
            let value = 0.300_3 + Double(index) * 0.000_05 + tremor
            if trembling.update(value: value, bounds: limits, at: Double(index) * 0.1) != nil { trembles += 1 }
        }
        expect(trembles == 10, "a slow slide with finger tremor taps once per number, 31 to 40, never chattering")

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
        expect(pulseTimes.count <= 21, "rapid restart cannot bypass the global cadence")
        expect(zip(pulseTimes.dropFirst(), pulseTimes).allSatisfy { $0 - $1 >= GestureHapticFeedback.minimumInterval },
               "all pulse intervals stay bounded")
        expect(fast.begin(value: 0.5, configuration: .init(), at: -1) == nil, "backwards clock cannot defeat the limiter")

        var cued = GestureHapticFeedback()
        expect(cued.cue(.soft, at: 0) == nil, "no cue outside a slide")
        _ = cued.begin(value: 0.52, configuration: .init(onStart: false), at: 0)
        expect(cued.cue(.soft, at: 1) == .soft, "precision engaging can cue")
        expect(cued.update(value: 0.55, bounds: limits, at: 1.02) == nil, "a cue keeps the cadence, so taps never overlap")
        expect(cued.cue(.soft, at: 1.03) == nil, "cues obey the cadence too")
        cued.end()
        expect(cued.cue(.soft, at: 2) == nil, "no cue after the slide ends")

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
        expect(notched.update(value: 0.49, bounds: 0...1, at: 10.1, notches: [0.52]) == nil, "approaching a notch stays quiet")
        expect(notched.update(value: 0.52, bounds: 0...1, at: 10.2, notches: [0.52]) == .crisp, "landing on a notch taps crisply, whatever the step style")
        expect(notched.update(value: 0.522, bounds: 0...1, at: 10.3, notches: [0.52]) == nil, "jitter on a notch does not chatter")
        expect(notched.update(value: 0.52, bounds: 0...1, at: 10.4, notches: [0.52]) == nil, "re-reading the notch value is not a new notch")
        expect(notched.update(value: 0.6, bounds: 0...1, at: 10.5, notches: [0.52]) == .soft, "past a notch the grid carries on")
        expect(notched.update(value: 0.5, bounds: 0...1, at: 10.52, notches: [0.52]) == nil, "notches obey the shared tap cadence")
        expect(notched.update(value: 0.4, bounds: 0...1, at: 11, notches: []) == .soft, "without notches ordinary steps continue")
        var midpoint = GestureHapticFeedback()
        _ = midpoint.begin(value: 0.46, configuration: .init(onStart: false), at: 0)
        expect(midpoint.update(value: 0.5, bounds: 0...1, at: 1, notches: [0.5]) == .crisp, "a notch on a grid line still taps as a notch")
        var strongClock = 0.0
        var strongCalls: [NSHapticFeedbackManager.FeedbackPattern] = []
        var actuations = 0
        var actuatorWorks = true
        let strongOutput = HapticOutput(now: { strongClock }, perform: { pattern, _ in strongCalls.append(pattern) },
                                        strong: { actuations += 1; return actuatorWorks })
        strongOutput.play(.strong)
        expect(actuations == 1 && strongCalls.isEmpty, "Strongest uses the actuator instead of a public pattern")
        strongClock = 0.03
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

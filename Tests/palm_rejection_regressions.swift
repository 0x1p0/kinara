import Foundation

// Synthetic touch sequences built from contact shapes measured on a MacBook
// Air trackpad. Palms must never trigger anything, typing or not; deliberate
// fingertip swipes and taps must keep working, even beside a resting palm.
@main
enum PalmRejectionRegressionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(label)") }
    }

    // Measured footprints, in millimetres (length × width).
    static let fingertip = (8.65, 7.67)
    static let fastFingertip = (13.8, 7.65)   // a quick swipe smears a fingertip
    static let firmFingertip = (11.53, 8.45)
    static let palmLanding = (15.4, 10.6)     // first frame of a palm
    static let palm = (26.4, 15.5)
    static let brushStart = (12.9, 10.0)      // a palm grazing a corner
    static let sideOfHand = (22.0, 8.6)
    static let flatThumb = (17.5, 11.5)

    static func contact(_ id: Int32, _ x: Double, _ y: Double, _ shape: (Double, Double)) -> GestureContact {
        GestureContact(id: id, x: x, y: y, major: shape.0, minor: shape.1)
    }

    /// Mirrors TrackpadMonitor.handleFrame: palms come out first; a finger
    /// that turns out to be a palm cancels both recognizers instead of
    /// reading as a lift; repeated empty frames under a resting palm are skipped.
    struct Pipeline {
        var configuration = GestureConfiguration()
        var tapConfiguration = TapConfiguration()
        var palms = PalmFilter()
        var swipe = EdgeGestureRecognizer()
        var taps = EdgeTapRecognizer()
        var lastCount = 0
        var accepted = 0
        var movement = 0.0
        var tapEvents: [TapEvent] = []
        var ignoredPalms = 0

        @discardableResult
        mutating func frame(_ touches: [GestureContact], at time: Double) -> GestureDecision {
            let result = palms.filter(touches)
            ignoredPalms += result.newPalms
            if result.withdrewFinger {
                taps.cancel()
                _ = swipe.cancel(reason: "Palm detected. Nothing was triggered.")
            }
            let contacts = result.fingers
            if contacts.isEmpty && lastCount == 0 && !result.withdrewFinger { return swipe.decision }
            lastCount = contacts.count
            if let event = taps.process(contacts: contacts, timestamp: time, configuration: tapConfiguration) {
                tapEvents.append(event)
            }
            let decision = swipe.process(contacts: contacts, timestamp: time, configuration: configuration)
            if decision.justAccepted { accepted += 1 }
            if decision.phase == .accepted && !decision.ended { movement += abs(decision.delta) }
            return decision
        }

        var triggeredNothing: Bool { accepted == 0 && movement == 0 && tapEvents.isEmpty }
    }

    /// A touch sequence sampled at 8 ms, the trackpad's own report rate.
    static func run(_ pipeline: inout Pipeline, from start: Double, frames: Int,
                    _ touches: (Int) -> [GestureContact]) -> Double {
        for index in 0..<frames { pipeline.frame(touches(index), at: start + Double(index) * 0.008) }
        return start + Double(frames) * 0.008
    }

    static func lift(_ pipeline: inout Pipeline, at time: Double) { pipeline.frame([], at: time) }

    static func main() {
        filterRules()
        swipes()
        taps()
        print("PASS: \(checks) palm rejection regression checks")
    }

    // MARK: - The footprint rule itself

    static func filterRules() {
        let fingertips: [(Double, Double)] = [fingertip, fastFingertip, firmFingertip, (10.53, 7.99), (12.26, 8.03),
                                              (8.81, 8.12), (10.88, 7.31), (7.51, 5.86)]
        for shape in fingertips {
            expect(!PalmFilter.isPalm(contact(1, 0.5, 0.5, shape)), "measured fingertip \(shape) is a finger")
        }
        let palms: [(Double, Double)] = [palmLanding, palm, brushStart, sideOfHand, flatThumb, (27.95, 15.99), (24.99, 16.57),
                                         (14.09, 11.38), (15.41, 10.32), (13.07, 11.44), (12.9, 10.7)]
        for shape in palms {
            expect(PalmFilter.isPalm(contact(1, 0.5, 0.5, shape)), "measured palm \(shape) is a palm")
        }
        expect(PalmFilter.isPalm(contact(1, 0.5, 0.5, (10.6, 15.4))), "axis order does not matter")
        expect(!PalmFilter.isPalm(contact(1, 0.5, 0.5, (0, 0))), "a device without shapes falls back to the motion checks")
        expect(!PalmFilter.isPalm(GestureContact(id: -1, x: .nan, y: .nan)), "the invalid-frame marker is never hidden")

        var filter = PalmFilter()
        var result = filter.filter([contact(1, 0.1, 0.5, palmLanding), contact(2, 0.9, 0.5, fingertip)])
        expect(result.fingers.map(\.id) == [2] && result.newPalms == 1 && !result.withdrewFinger,
               "a palm is removed from its first frame; the fingertip beside it stays")
        result = filter.filter([contact(1, 0.1, 0.5, (11, 9)), contact(2, 0.9, 0.5, fingertip)])
        expect(result.fingers.map(\.id) == [2] && result.newPalms == 0,
               "a palm stays a palm while it lifts edge-first and looks smaller")
        result = filter.filter([contact(2, 0.9, 0.5, fingertip)])
        result = filter.filter([contact(1, 0.1, 0.5, fingertip), contact(2, 0.9, 0.5, fingertip)])
        expect(result.fingers.count == 2, "a reused identifier after that palm lifted is a new finger")
        _ = filter.filter([])
        result = filter.filter([contact(3, 0.95, 0.05, (9.5, 8.6))])
        expect(result.fingers.count == 1 && !result.withdrewFinger, "a grazing contact counts as a finger at first")
        result = filter.filter([contact(3, 0.95, 0.05, (14.6, 11.4))])
        expect(result.fingers.isEmpty && result.withdrewFinger, "once it spreads into a palm, it is withdrawn")
        result = filter.filter([contact(3, 0.95, 0.05, (16, 12))])
        expect(result.fingers.isEmpty && !result.withdrewFinger && result.newPalms == 0, "withdrawal is reported once")
        // Speed smears a fingertip along its path; only width counts then.
        _ = filter.filter([])
        var y = 0.2
        for _ in 0..<4 { y += 0.006; expect(filter.filter([contact(4, 0.9, y, fingertip)]).fingers.count == 1, "a swipe begins") }
        for length in [14.0, 18.0, 22.0] {
            y += 0.03
            result = filter.filter([contact(4, 0.9, y, (length, 7.7))])
            expect(result.fingers.count == 1 && !result.withdrewFinger, "a fast flick smeared to \(length) mm stays a finger")
        }
        result = filter.filter([contact(4, 0.9, y + 0.03, (19, 10.4))])
        expect(result.withdrewFinger, "width still marks a palm at any speed")
        _ = filter.filter([])
        _ = filter.filter([contact(5, 0.03, 0.5, fingertip)])
        result = filter.filter([contact(5, 0.03, 0.502, sideOfHand)])
        expect(result.withdrewFinger, "a long contact that is nearly still is the side of a hand")
        let marker = GestureContact(id: -1, x: .nan, y: .nan)
        expect(filter.filter([marker]).fingers.count == 1, "invalid data still reaches the recognizers and fails closed")
    }

    // MARK: - Swipes

    static func swipes() {
        var one = GestureConfiguration()
        one.requiredFingers = 1
        one.topEnabled = true
        one.bottomEnabled = true
        let two = GestureConfiguration()

        // A palm landing on the right edge and creeping straight up as it
        // settles looks exactly like a slow swipe. Its footprint gives it away.
        var pipeline = Pipeline(configuration: one)
        var t = run(&pipeline, from: 1, frames: 60) { i in [contact(1, 0.96, 0.3 + Double(i) * 0.004, i < 2 ? palmLanding : palm)] }
        lift(&pipeline, at: t)
        expect(pipeline.triggeredNothing && pipeline.ignoredPalms == 1, "a palm creeping along the right edge never adjusts anything")

        // Two blobs of one palm on the left edge, moving together, in two-finger mode.
        pipeline = Pipeline(configuration: two)
        t = run(&pipeline, from: 2, frames: 60) { i in
            [contact(1, 0.04, 0.4 + Double(i) * 0.005, palm), contact(2, 0.1, 0.45 + Double(i) * 0.005, palmLanding)]
        }
        lift(&pipeline, at: t)
        expect(pipeline.triggeredNothing, "a palm split into two contacts never passes as a two-finger swipe")

        // The side of a hand lying along the left edge and sliding.
        pipeline = Pipeline(configuration: one)
        t = run(&pipeline, from: 3, frames: 60) { i in [contact(1, 0.03, 0.5 - Double(i) * 0.004, sideOfHand)] }
        lift(&pipeline, at: t)
        expect(pipeline.triggeredNothing, "the side of a hand on an edge is ignored")

        // A thumb lying flat on the bottom edge, drifting sideways while pointing.
        pipeline = Pipeline(configuration: one)
        t = run(&pipeline, from: 4, frames: 60) { i in [contact(1, 0.3 + Double(i) * 0.004, 0.06, flatThumb)] }
        lift(&pipeline, at: t)
        expect(pipeline.triggeredNothing, "a resting thumb on the bottom edge is ignored")

        // A palm that touches down edge-first, fingertip-sized, then spreads
        // while it moves: it is withdrawn before it can be accepted.
        pipeline = Pipeline(configuration: one)
        t = run(&pipeline, from: 5, frames: 40) { i in
            [contact(1, 0.95, 0.4 + Double(i) * 0.004, i < 3 ? (9.4, 8.2) : i < 5 ? brushStart : palm)]
        }
        lift(&pipeline, at: t)
        expect(pipeline.triggeredNothing, "a palm that lands edge-first is withdrawn before it activates")

        // A real swipe whose contact then flattens into a palm stops at once.
        pipeline = Pipeline(configuration: one)
        t = run(&pipeline, from: 6, frames: 20) { i in [contact(1, 0.95, 0.4 + Double(i) * 0.004, fingertip)] }
        expect(pipeline.accepted == 1, "a fingertip swipe on the right edge activates")
        let before = pipeline.movement
        let grown = pipeline.frame([contact(1, 0.95, 0.49, palm)], at: t)
        t = run(&pipeline, from: t + 0.008, frames: 20) { i in [contact(1, 0.95, 0.5 + Double(i) * 0.004, palm)] }
        expect(grown.phase == .rejected && pipeline.movement == before, "a contact that becomes a palm stops adjusting")
        lift(&pipeline, at: t)

        // Moving a whole palm around the trackpad, across edges and corners,
        // with no typing at all, triggers nothing.
        pipeline = Pipeline(configuration: one)
        var corners = TapConfiguration()
        corners.requiredFingers = 1
        corners.topEnabled = true
        corners.bottomEnabled = true
        corners.slots = ["bottomRightCorner.doubleTap", "topLeftCorner.tapHold", "left.doubleTap", "right.tapHold"]
        pipeline.tapConfiguration = corners
        t = run(&pipeline, from: 7, frames: 250) { i in
            let a = Double(i) / 250 * 2 * Double.pi
            return [contact(1, 0.5 + 0.47 * cos(a), 0.5 + 0.47 * sin(a), i == 0 ? palmLanding : palm)]
        }
        lift(&pipeline, at: t)
        for start in stride(from: t + 0.1, to: t + 1.5, by: 0.2) {
            let end = run(&pipeline, from: start, frames: 4) { _ in [contact(1, 0.97, 0.03, palm)] }
            lift(&pipeline, at: end)
        }
        expect(pipeline.triggeredNothing, "a whole palm moved over every edge and corner triggers nothing, typing or not")

        // Typing changes nothing about palms: same result right after a key.
        pipeline = Pipeline(configuration: one)
        _ = pipeline.swipe.keyDown(at: 8)
        t = run(&pipeline, from: 8.05, frames: 120) { i in [contact(1, 0.96, 0.2 + Double(i) * 0.005, palm)] }
        lift(&pipeline, at: t)
        expect(pipeline.triggeredNothing, "a palm during typing is ignored the same way")

        // Deliberate swipes keep working with their real, measured shapes.
        pipeline = Pipeline(configuration: two)
        t = run(&pipeline, from: 10, frames: 20) { i in
            let y = 0.3 + Double(i) * 0.012
            return [contact(1, 0.06, y, i > 6 ? fastFingertip : fingertip), contact(2, 0.13, y, i > 6 ? firmFingertip : fingertip)]
        }
        expect(pipeline.accepted == 1 && pipeline.movement > 0, "a fast two-finger fingertip swipe still activates and adjusts")
        lift(&pipeline, at: t)

        pipeline = Pipeline(configuration: one)
        t = run(&pipeline, from: 11, frames: 20) { i in [contact(1, 0.3 + Double(i) * 0.004, 0.06, fingertip)] }
        expect(pipeline.accepted == 1 && pipeline.swipe.decision.region == .bottom, "a fingertip swipe on the bottom edge still activates")
        lift(&pipeline, at: t)

        pipeline = Pipeline(configuration: one)
        t = run(&pipeline, from: 12, frames: 20) { i in [contact(1, 0.95, 0.4 + Double(i) * 0.004, (0, 0))] }
        expect(pipeline.accepted == 1, "trackpads that report no shape keep the motion-only behaviour")
        lift(&pipeline, at: t)

        // Like macOS: a palm already resting does not block a real swipe elsewhere.
        pipeline = Pipeline(configuration: two)
        t = run(&pipeline, from: 13, frames: 30) { _ in [contact(1, 0.08, 0.6, palm)] }
        t = run(&pipeline, from: t, frames: 20) { i in
            let y = 0.3 + Double(i) * 0.006
            return [contact(1, 0.08, 0.6, palm), contact(2, 0.88, y, fingertip), contact(3, 0.94, y, fingertip)]
        }
        expect(pipeline.accepted == 1 && pipeline.swipe.decision.region == .right,
               "a two-finger swipe on the right edge works while a palm rests on the left")
        let resting = pipeline.movement
        t = run(&pipeline, from: t, frames: 10) { i in
            let y = 0.42 + Double(i) * 0.006
            return [contact(1, 0.08, 0.6, palm), contact(2, 0.88, y, fingertip), contact(3, 0.94, y, fingertip), contact(4, 0.5, 0.1, palmLanding)]
        }
        expect(pipeline.movement > resting && pipeline.swipe.decision.phase == .accepted,
               "a palm landing mid-swipe does not interrupt the swipe")
        lift(&pipeline, at: t)

        // The existing intent checks still apply to fingertips.
        pipeline = Pipeline(configuration: one)
        t = run(&pipeline, from: 14, frames: 20) { i in [contact(1, 0.5 - Double(i) * 0.02, 0.4, fingertip)] }
        expect(pipeline.accepted == 0, "a fingertip that starts in the middle and drifts to an edge still never activates")
        lift(&pipeline, at: t)
    }

    // MARK: - Taps

    static func taps() {
        var corners = TapConfiguration()
        corners.requiredFingers = 2
        corners.cornerFingers = 1
        corners.slots = ["bottomRightCorner.doubleTap", "bottomRightCorner.tapHold", "topLeftCorner.doubleTap"]

        func tap(_ pipeline: inout Pipeline, at start: Double, _ shapes: [(Double, Double)], x: Double = 0.97, y: Double = 0.04) -> Double {
            let end = run(&pipeline, from: start, frames: shapes.count) { i in [contact(1, x, y, shapes[i])] }
            lift(&pipeline, at: end)
            return end
        }

        // A palm grazing the bottom-right corner twice while typing pauses.
        var pipeline = Pipeline(tapConfiguration: corners)
        var t = tap(&pipeline, at: 1, [brushStart, (14.6, 11.4), (14.7, 11.1)])
        _ = tap(&pipeline, at: t + 0.15, [brushStart, (14.6, 11.4)])
        expect(pipeline.tapEvents.isEmpty, "two palm brushes in a corner are not a double-tap")

        // A brush that starts fingertip-sized, then spreads before it lifts.
        pipeline = Pipeline(tapConfiguration: corners)
        t = tap(&pipeline, at: 2, [(9.6, 8.7), (9.8, 9.2), (14.6, 11.4)])
        _ = tap(&pipeline, at: t + 0.15, [(9.6, 8.7), (13.2, 10.4)])
        expect(pipeline.tapEvents.isEmpty && pipeline.taps.claimsClicksUntil < 2,
               "a palm withdrawn mid-touch is never read as a tap's lift")

        // A palm brush, then the palm settling in the same corner: not a hold.
        pipeline = Pipeline(tapConfiguration: corners)
        t = tap(&pipeline, at: 3, [brushStart, (13.5, 10.8)])
        t = run(&pipeline, from: t + 0.12, frames: 90) { i in [contact(1, 0.97, 0.04, i < 2 ? palmLanding : palm)] }
        lift(&pipeline, at: t)
        expect(pipeline.tapEvents.isEmpty, "a palm brushing then resting in a corner is not tap-and-hold")

        // Fingertip taps keep working.
        pipeline = Pipeline(tapConfiguration: corners)
        t = tap(&pipeline, at: 4, Array(repeating: fingertip, count: 10))
        _ = tap(&pipeline, at: t + 0.15, Array(repeating: fingertip, count: 10))
        expect(pipeline.tapEvents == [TapEvent(region: .bottomRightCorner, gesture: .doubleTap)], "a fingertip double-tap in a corner fires")

        pipeline = Pipeline(tapConfiguration: corners)
        t = tap(&pipeline, at: 5, Array(repeating: fingertip, count: 10))
        t = run(&pipeline, from: t + 0.15, frames: 70) { _ in [contact(1, 0.97, 0.04, fingertip)] }
        lift(&pipeline, at: t)
        expect(pipeline.tapEvents == [TapEvent(region: .bottomRightCorner, gesture: .tapHold)], "a fingertip tap-and-hold fires once")

        // A hold that flattens into a palm before it completes never fires.
        pipeline = Pipeline(tapConfiguration: corners)
        t = tap(&pipeline, at: 6, Array(repeating: fingertip, count: 10))
        t = run(&pipeline, from: t + 0.15, frames: 70) { i in [contact(1, 0.97, 0.04, i < 20 ? fingertip : palm)] }
        lift(&pipeline, at: t)
        expect(pipeline.tapEvents.isEmpty, "a hold that turns into a resting palm does not fire")

        // Like macOS: a resting palm elsewhere does not get in the way of a tap.
        pipeline = Pipeline(tapConfiguration: corners)
        t = run(&pipeline, from: 7, frames: 10) { _ in [contact(1, 0.1, 0.1, palm)] }
        for start in [t, t + 0.18] {
            let end = run(&pipeline, from: start, frames: 10) { _ in [contact(1, 0.1, 0.1, palm), contact(2, 0.04, 0.96, fingertip)] }
            pipeline.frame([contact(1, 0.1, 0.1, palm)], at: end)
            t = end
        }
        lift(&pipeline, at: t + 0.01)
        expect(pipeline.tapEvents == [TapEvent(region: .topLeftCorner, gesture: .doubleTap)],
               "a fingertip double-tap works while a palm rests on the trackpad")
    }
}

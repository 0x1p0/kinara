import Foundation

// Observable evidence, not a "palm probability": identity, touchdown position,
// exact count, elapsed time, axis displacement, path efficiency and typing.
enum GestureRegion: String, CaseIterable {
    case none, left, right, topLeft, topRight, top, bottom
    var isTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var isSide: Bool { self == .left || self == .right }
}

struct GestureContact {
    let id: Int32
    let x: Double
    let y: Double
}

struct GestureInputFrame {
    let contacts: [GestureContact]
    let timestamp: Double
    let generation: UInt64
}

/// One scheduled main-queue delivery instead of a closure for every native
/// sample. Preserve ALL samples (including transient extra fingers and lifts).
/// If the UI stalls long enough to overflow, fail closed until a real full lift;
/// dropping intermediate positions must never make unsafe motion look valid.
final class GestureFrameInbox {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [GestureInputFrame] = []
    private var deliveryScheduled = false
    private var waitingForLift = false
    private var generation: UInt64?

    init(capacity: Int = 64) { self.capacity = max(2, capacity) }

    @discardableResult
    func enqueue(_ frame: GestureInputFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if generation != frame.generation {
            frames.removeAll(keepingCapacity: true)
            waitingForLift = false
            generation = frame.generation
        }
        if waitingForLift {
            guard frame.contacts.isEmpty else { return false }
            waitingForLift = false
            frames.append(frame)
        } else if frames.count >= capacity {
            frames.removeAll(keepingCapacity: true)
            frames.append(GestureInputFrame(contacts: [GestureContact(id: -1, x: .nan, y: .nan)],
                                            timestamp: frame.timestamp, generation: frame.generation))
            waitingForLift = !frame.contacts.isEmpty
            if frame.contacts.isEmpty { frames.append(frame) }
        } else {
            frames.append(frame)
        }
        guard !deliveryScheduled else { return false }
        deliveryScheduled = true
        return true
    }

    func takeBatch() -> [GestureInputFrame] {
        lock.lock()
        defer { lock.unlock() }
        let result = frames
        frames = []
        deliveryScheduled = false
        return result
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll(keepingCapacity: true)
        deliveryScheduled = false
        waitingForLift = false
        generation = nil
    }
}

struct GestureConfiguration: Equatable {
    var requiredFingers = 2
    var leftWidth = 0.2
    var rightWidth = 0.2
    var topHeight = 0.15
    var topEnabled = false
    var topHorizontal = true
    var bottomHeight = 0.15
    var bottomEnabled = false
    var enabledRegions: Set<GestureRegion> = [.left, .right, .topLeft, .topRight, .top, .bottom]
    var strict = false
    var activationThreshold = 4.0
    var typingCooldown = 0.45
    /// Accept the other finger count (1 or 2) as a second layer, only in
    /// regions that actually have an action for it.
    var fingerLayers = false
    var alternateRegions: Set<GestureRegion> = []

    var maximumFingers: Int { fingerLayers ? 2 : requiredFingers }
    func isHorizontal(_ region: GestureRegion) -> Bool { region == .bottom || (region.isTop && topHorizontal) }
    var minimumLifetime: Double { strict ? 0.095 : 0.065 }
    var minimumSamples: Int { strict ? 6 : 4 }
    var minimumDisplacement: Double {
        max(strict ? 0.014 : 0.008, activationThreshold / 500 * (strict ? 1.3 : 1))
    }
    var requiredStraightness: Double { strict ? 0.85 : 0.72 }
    var restingDeadline: Double { strict ? 0.3 : 0.4 }

    func region(x: Double, y: Double) -> GestureRegion {
        let candidate: GestureRegion
        if topEnabled && y >= 1 - topHeight {
            candidate = topHorizontal ? (x < 0.5 ? .topLeft : .topRight) : .top
        } else if bottomEnabled && y <= bottomHeight {
            candidate = .bottom
        } else if x <= leftWidth {
            candidate = .left
        } else if x >= 1 - rightWidth {
            candidate = .right
        } else {
            candidate = .none
        }
        return enabledRegions.contains(candidate) ? candidate : .none
    }
}

struct GestureDecision {
    enum Phase: String { case ready = "Ready", gathering = "Gathering", accepted = "Accepted", rejected = "Rejected" }
    var phase: Phase = .ready
    var reason = "Start at an enabled edge, then swipe."
    var region: GestureRegion = .none
    var x = 0.5
    var y = 0.5
    var count = 0
    var displacement = 0.0
    var straightness = 0.0
    var elapsed = 0.0
    var samples = 0
    var delta = 0.0
    var justAccepted = false
    var justRejected = false
    var ended = false
    /// Assembled contact count, which selects the finger layer.
    var fingers = 0
    /// Travel from the edge toward the trackpad centre since activation.
    var inward = 0.0
    /// Smoothed travel along the swipe axis, in trackpad heights per second.
    var speed = 0.0
}

/// Deterministic and independent of AppKit, timers, controllers and wall-clock time.
/// A rejected contact stays rejected until EVERY finger lifts.
struct EdgeGestureRecognizer {
    private(set) var decision = GestureDecision()
    private var configuration = GestureConfiguration()
    private var startedAt: Double?
    private var assembledAt: Double?
    private var previousTime: Double?
    private var lastKeyTime = -Double.infinity
    private var firstPositions: [Int32: GestureContact] = [:]
    private var previousPositions: [Int32: GestureContact] = [:]
    private var pathLengths: [Int32: Double] = [:]
    private var assembledIDs: Set<Int32>?
    private var assembledCentroid: (x: Double, y: Double)?
    private var smoothedSpeed = 0.0

    var isCapturing: Bool { startedAt != nil && !decision.ended && (decision.phase == .gathering || decision.phase == .accepted) }

    mutating func reset() { self = EdgeGestureRecognizer() }

    mutating func cancel(reason: String) -> GestureDecision {
        decision.delta = 0
        decision.justAccepted = false
        decision.justRejected = false
        if startedAt != nil && !decision.ended { reject(reason) }
        return decision
    }

    mutating func keyDown(at timestamp: Double) -> GestureDecision {
        lastKeyTime = timestamp
        return cancel(reason: "Typing detected. Lift your fingers, then try again.")
    }

    mutating func process(contacts: [GestureContact], timestamp: Double,
                          configuration newConfiguration: GestureConfiguration) -> GestureDecision {
        decision.delta = 0
        decision.justAccepted = false
        decision.justRejected = false
        decision.count = contacts.count
        guard !contacts.isEmpty else {
            let keyTime = lastKeyTime
            let previous = decision
            self = EdgeGestureRecognizer()
            lastKeyTime = keyTime
            // Preserve the last verdict after lift so the Test tab can explain it.
            decision = previous
            decision.count = 0
            decision.delta = 0
            decision.justAccepted = false
            decision.justRejected = false
            if previous.phase == .gathering {
                decision.phase = .rejected
                decision.reason = "Lifted before there was enough movement evidence."
                decision.justRejected = true
            }
            return decision
        }
        // Ordinary pointer use and a rejected palm can generate hundreds of
        // samples. Once blocked, only a physical full lift can change the
        // verdict; do not rebuild sets/dictionaries for those samples.
        if startedAt != nil && (decision.phase == .rejected || decision.ended) { return decision }
        let ids = Set(contacts.map(\.id))
        guard timestamp.isFinite,
              contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              ids.count == contacts.count else {
            if startedAt == nil { startedAt = timestamp.isFinite ? timestamp : 0 }
            reject("Invalid touch data. Lift your fingers to reset.")
            return decision
        }
        let count = Double(contacts.count)
        decision.x = contacts.reduce(0) { $0 + $1.x } / count
        decision.y = contacts.reduce(0) { $0 + $1.y } / count
        if startedAt == nil {
            configuration = newConfiguration
            startedAt = timestamp
            previousTime = timestamp
            decision = GestureDecision(phase: .gathering, reason: "Checking touch direction and movement…",
                                       x: decision.x, y: decision.y, count: contacts.count)
            decision.region = configuration.region(x: contacts[0].x, y: contacts[0].y)
            firstPositions = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
            previousPositions = firstPositions
            pathLengths = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, 0) })
            if decision.region == .none {
                reject("Touch started outside an enabled edge. Lift, then start at an edge.")
            }
        }
        decision.elapsed = max(0, timestamp - (startedAt ?? timestamp))
        guard decision.phase != .rejected && !decision.ended else { return decision }
        guard configuration == newConfiguration else {
            reject("Gesture settings changed. Lift your fingers to use the new setup.")
            return decision
        }
        guard timestamp - lastKeyTime >= configuration.typingCooldown else {
            reject("Typing cooldown is active. Lift your fingers, then try again.")
            return decision
        }
        guard contacts.count <= configuration.maximumFingers else {
            reject("Extra contact detected. Lift all fingers to reset.")
            return decision
        }
        if let assembledIDs, assembledIDs != ids {
            if decision.phase == .accepted && ids.isStrictSubset(of: assembledIDs) {
                // A normal two-finger release is often staggered by a scan. End
                // control immediately without labelling a successful swipe a palm.
                decision.ended = true
                decision.reason = "Gesture complete. Lift the remaining finger to reset."
                return decision
            }
            reject("Finger count or identity changed. Lift all fingers to reset.")
            return decision
        }
        // Allow a second finger to land within 100 ms, preserving the first
        // finger's true touchdown region and identity throughout assembly.
        if assembledIDs == nil {
            guard Set(firstPositions.keys).isSubset(of: ids) else {
                reject("A contact was replaced before the gesture began.")
                return decision
            }
            for contact in contacts where firstPositions[contact.id] == nil {
                firstPositions[contact.id] = contact
                previousPositions[contact.id] = contact
                pathLengths[contact.id] = 0
            }
            guard firstPositions.values.allSatisfy({ configuration.region(x: $0.x, y: $0.y) == decision.region }) else {
                reject("Both fingers must start in the same edge zone.")
                return decision
            }
            if contacts.count < configuration.maximumFingers {
                // With finger layers, a lone finger becomes the one-finger
                // layer only after the window for a second finger has passed.
                let loneLayer = configuration.fingerLayers && contacts.count == 1 && decision.elapsed > 0.1
                if !loneLayer {
                    if decision.elapsed > 0.1 {
                        reject("This setup needs \(configuration.requiredFingers) fingers. Lift and try again.")
                    } else {
                        decision.reason = "Waiting for \(configuration.requiredFingers) fingers together…"
                    }
                    previousTime = timestamp
                    return decision
                }
            } else if decision.elapsed > 0.1 {
                reject("Place both fingers together, then swipe.")
                return decision
            }
            if contacts.count != configuration.requiredFingers && !configuration.alternateRegions.contains(decision.region) {
                reject("This edge has no \(contacts.count)-finger action. Lift and try again.")
                return decision
            }
            assembledIDs = ids
            assembledAt = timestamp
            assembledCentroid = (decision.x, decision.y)
            decision.fingers = contacts.count
            previousPositions = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        }
        let interval = timestamp - (previousTime ?? timestamp)
        if interval < 0 || interval > 0.18 {
            reject("Touch tracking was interrupted. Lift your fingers to reset.")
            return decision
        }
        if interval == 0 && decision.samples > 0 { return decision }
        previousTime = timestamp
        decision.samples += 1
        let horizontal = configuration.isHorizontal(decision.region)
        var netAxis = 0.0, netPerpendicular = 0.0, delta = 0.0, path = 0.0
        var perFingerDisplacements: [Double] = []
        for contact in contacts {
            guard let start = firstPositions[contact.id], let previous = previousPositions[contact.id] else { continue }
            let dx = contact.x - previous.x, dy = contact.y - previous.y
            let step = hypot(dx, dy)
            if step > 0.18 {
                reject("Contact position jumped. Lift your fingers to reset.")
                return decision
            }
            pathLengths[contact.id, default: 0] += step
            path += pathLengths[contact.id, default: 0]
            let axis = horizontal ? contact.x - start.x : contact.y - start.y
            netAxis += axis
            netPerpendicular += horizontal ? contact.y - start.y : contact.x - start.x
            delta += horizontal ? dx : dy
            perFingerDisplacements.append(axis)
            previousPositions[contact.id] = contact
        }
        netAxis /= count
        netPerpendicular /= count
        path /= count
        decision.displacement = abs(netAxis)
        decision.straightness = path > 0.00001 ? min(1, abs(netAxis) / path) : 0
        if decision.phase == .accepted {
            decision.delta = delta / count
            if interval > 0 {
                let instant = abs(decision.delta) / interval
                smoothedSpeed = smoothedSpeed == 0 ? instant : smoothedSpeed * 0.65 + instant * 0.35
            }
            decision.speed = smoothedSpeed
            decision.inward = inwardTravel()
            return decision
        }
        let enoughTime = timestamp - (assembledAt ?? timestamp) >= configuration.minimumLifetime
        let enoughSamples = decision.samples >= configuration.minimumSamples
        guard enoughTime && enoughSamples else { return decision }
        if abs(netPerpendicular) > max(configuration.minimumDisplacement, abs(netAxis) * 1.2) {
            reject(horizontal ? "Swipe left or right along this \(decision.region == .bottom ? "bottom" : "top") zone." : "Swipe up or down along this side zone.")
        } else if path > configuration.minimumDisplacement * 2.5 && decision.straightness < 0.45 {
            reject("Movement was mostly jitter or backtracking. Try a steady swipe.")
        } else if decision.displacement >= configuration.minimumDisplacement &&
                    decision.straightness >= configuration.requiredStraightness &&
                    perFingerDisplacements.allSatisfy({ abs($0) >= configuration.minimumDisplacement * 0.65 && $0 * netAxis > 0 }) {
            decision.phase = .accepted
            decision.reason = "Stable contacts, clear direction and enough movement confirmed."
            decision.justAccepted = true
            // Consume activation movement to avoid a jump on confirmation.
            decision.delta = 0
        } else if decision.elapsed > configuration.restingDeadline {
            reject("Contact stayed still or unclear too long. Lift, then swipe deliberately.")
        }
        return decision
    }
    private mutating func reject(_ reason: String) {
        decision.justRejected = decision.phase != .rejected
        decision.phase = .rejected
        decision.reason = reason
        decision.delta = 0
    }

    /// Perpendicular travel toward the centre. A top strip swiped vertically
    /// has no perpendicular "inward" direction, so it never enters fine mode.
    private func inwardTravel() -> Double {
        guard let start = assembledCentroid else { return 0 }
        let travel: Double
        switch decision.region {
        case .left: travel = decision.x - start.x
        case .right: travel = start.x - decision.x
        case .bottom: travel = decision.y - start.y
        case .topLeft, .topRight: travel = start.y - decision.y
        case .top, .none: travel = 0
        }
        return travel.isFinite ? max(0, travel) : 0
    }
}

/// Precision and speed shaping for continuous levels. Pure: no clocks or AppKit.
/// Sliding inward from the edge trades range for control, like scrubbing a
/// video; a quick flick covers more range than a slow, deliberate movement.
struct GestureFeel: Equatable {
    var precision = true
    var acceleration = true
    static let precisionDeadZone = 0.03
    static let precisionTravel = 0.18
    static let finestScale = 0.2
    private static let curve: [(speed: Double, scale: Double)] = [(0.15, 0.55), (0.5, 1), (1.5, 1.8), (2.5, 2.2)]

    func precisionScale(inward: Double) -> Double {
        guard precision, inward.isFinite else { return 1 }
        let progress = min(1, max(0, (inward - Self.precisionDeadZone) / Self.precisionTravel))
        return 1 - progress * (1 - Self.finestScale)
    }

    func accelerationScale(speed: Double) -> Double {
        guard acceleration, speed.isFinite, speed >= 0 else { return 1 }
        let points = Self.curve
        if speed <= points[0].speed { return points[0].scale }
        for (low, high) in zip(points, points.dropFirst()) where speed <= high.speed {
            return low.scale + (speed - low.speed) / (high.speed - low.speed) * (high.scale - low.scale)
        }
        return points[points.count - 1].scale
    }

    /// Fine control wins: a fast inward slide must never undo precision.
    func scale(speed: Double, inward: Double) -> Double {
        let fine = precisionScale(inward: inward)
        let speedScale = accelerationScale(speed: speed)
        return fine < 1 ? fine * min(1, speedScale) : speedScale
    }

    func isFine(inward: Double) -> Bool { precisionScale(inward: inward) < 0.999 }
}

/// Clamp each relative sample, so overshooting a bound never delays reversal.
/// Notches are magnetic: within `capture` of one, the level rests on it until
/// continuous travel carries it back out, which is what makes it feel like a
/// physical detent instead of a number that happens to pass 50%.
struct RelativeGestureValue {
    private(set) var value: Double
    private var raw: Double?

    init(value: Double) { self.value = value }

    mutating func apply(delta: Double, sensitivity: Double, inverted: Bool, bounds: ClosedRange<Double>,
                        scale: Double = 1, notches: [Double] = [], capture: Double = 0) -> Double {
        guard delta.isFinite, sensitivity.isFinite, scale.isFinite else { return value }
        let next = min(bounds.upperBound, max(bounds.lowerBound,
                   (raw ?? value) + delta * max(0.1, sensitivity) * 0.9 * max(0, scale) * (inverted ? -1 : 1)))
        raw = next
        let nearest = notches.filter { $0.isFinite && bounds.contains($0) }
            .min { abs($0 - next) < abs($1 - next) }
        if let nearest, capture > 0, abs(nearest - next) <= capture { value = nearest }
        else { value = next }
        return value
    }
}

// MARK: - Taps

/// Tap regions. Corners exist only for taps and win over the strips they
/// overlap, but only when a corner actually has an action.
enum TapRegion: String, CaseIterable {
    case left, right, top, bottom, topLeftCorner, topRightCorner, bottomLeftCorner, bottomRightCorner
    var isCorner: Bool { ![.left, .right, .top, .bottom].contains(self) }
}

enum TapGesture: String, CaseIterable { case doubleTap, tapHold }

struct TapEvent: Equatable {
    let region: TapRegion
    let gesture: TapGesture
    var slot: String { "\(region.rawValue).\(gesture.rawValue)" }
}

struct TapConfiguration: Equatable {
    var requiredFingers = 2
    var leftWidth = 0.2
    var rightWidth = 0.2
    var topEnabled = false
    var topHeight = 0.15
    var bottomEnabled = false
    var bottomHeight = 0.15
    var cornerSize = 0.14
    var typingCooldown = 0.45
    /// "region.gesture" slots that have an action; nothing else is recognized.
    var slots: Set<String> = []

    static let maximumTapDuration = 0.25
    static let maximumTravel = 0.025
    static let maximumGap = 0.35
    static let holdDuration = 0.45

    func region(x: Double, y: Double) -> TapRegion? {
        let corners = slots.contains { TapRegion(rawValue: String($0.split(separator: ".")[0]))?.isCorner == true }
        if corners {
            let left = x <= cornerSize, right = x >= 1 - cornerSize
            let top = y >= 1 - cornerSize, bottom = y <= cornerSize
            if top && left { return .topLeftCorner }
            if top && right { return .topRightCorner }
            if bottom && left { return .bottomLeftCorner }
            if bottom && right { return .bottomRightCorner }
        }
        if topEnabled && y >= 1 - topHeight { return .top }
        if bottomEnabled && y <= bottomHeight { return .bottom }
        if x <= leftWidth { return .left }
        if x >= 1 - rightWidth { return .right }
        return nil
    }

    func hasSlot(_ region: TapRegion) -> Bool {
        TapGesture.allCases.contains { slots.contains("\(region.rawValue).\($0.rawValue)") }
    }
}

/// Double-tap and tap-and-hold. Both begin with a short, still tap, which a
/// resting palm does not produce, so a hand lying on an edge never triggers
/// them. Deterministic and independent of AppKit and wall-clock time.
struct EdgeTapRecognizer {
    private var started: Double?
    private var region: TapRegion?
    private var starts: [Int32: GestureContact] = [:]
    private var maxCount = 0
    private var travel = 0.0
    private var invalid = false
    private var isSecond = false
    private var holdFired = false
    private var lastTap: (region: TapRegion, end: Double)?
    private var lastKeyTime = -Double.infinity
    /// Tap-to-click clicks that follow a recognized edge tap until this time
    /// belong to Sway and are withheld from the app under the pointer.
    private(set) var claimsClicksUntil = -Double.infinity
    var isTouching: Bool { started != nil }

    mutating func keyDown(at timestamp: Double) {
        lastKeyTime = timestamp
        invalid = started != nil
        lastTap = nil
    }

    /// A physical click is not a tap and ends any pending double-tap.
    mutating func click() {
        if started != nil { invalid = true }
        lastTap = nil
    }

    mutating func process(contacts: [GestureContact], timestamp: Double,
                          configuration: TapConfiguration) -> TapEvent? {
        guard timestamp.isFinite, !configuration.slots.isEmpty else { reset(keepingTap: false); return nil }
        guard !contacts.isEmpty else { return lift(at: timestamp, configuration: configuration) }
        if started == nil {
            started = timestamp
            let first = contacts[0]
            region = configuration.region(x: first.x, y: first.y)
            invalid = region.map { !configuration.hasSlot($0) } ?? true
                || timestamp - lastKeyTime < configuration.typingCooldown
            isSecond = lastTap.map { $0.region == region && timestamp - $0.end <= TapConfiguration.maximumGap } ?? false
            if !isSecond { lastTap = nil }
        }
        guard let start = started, !invalid else { return nil }
        for contact in contacts {
            guard contact.x.isFinite, contact.y.isFinite else { invalid = true; return nil }
            if let origin = starts[contact.id] {
                travel = max(travel, hypot(contact.x - origin.x, contact.y - origin.y))
            } else {
                // Late or out-of-region contacts are a hand settling, not a tap.
                guard timestamp - start <= 0.1, configuration.region(x: contact.x, y: contact.y) == region else {
                    invalid = true; return nil
                }
                starts[contact.id] = contact
            }
        }
        maxCount = max(maxCount, contacts.count)
        if maxCount > configuration.requiredFingers || travel > TapConfiguration.maximumTravel { invalid = true; return nil }
        if isSecond, !holdFired, let region, contacts.count == configuration.requiredFingers,
           timestamp - start >= TapConfiguration.holdDuration,
           configuration.slots.contains("\(region.rawValue).\(TapGesture.tapHold.rawValue)") {
            holdFired = true
            lastTap = nil
            return TapEvent(region: region, gesture: .tapHold)
        }
        return nil
    }

    private mutating func lift(at timestamp: Double, configuration: TapConfiguration) -> TapEvent? {
        guard let start = started else { return nil }
        defer { reset(keepingTap: true) }
        guard !invalid, !holdFired, let region, maxCount == configuration.requiredFingers,
              timestamp - start <= TapConfiguration.maximumTapDuration else {
            lastTap = nil
            return nil
        }
        claimsClicksUntil = timestamp + 0.4
        if isSecond, configuration.slots.contains("\(region.rawValue).\(TapGesture.doubleTap.rawValue)") {
            lastTap = nil
            return TapEvent(region: region, gesture: .doubleTap)
        }
        lastTap = (region, timestamp)
        return nil
    }

    private mutating func reset(keepingTap: Bool) {
        started = nil
        region = nil
        starts.removeAll(keepingCapacity: true)
        maxCount = 0
        travel = 0
        invalid = false
        isSecond = false
        holdFired = false
        if !keepingTap { lastTap = nil }
    }
}

/// Ownership belongs to an entire precise-scroll sequence, including inertia.
/// Mouse wheels and a new unrelated gesture never inherit old ownership.
struct GestureScrollCapture {
    enum Phase { case none, mayBegin, began, changed, stationary, ended, cancelled }
    private enum Owner { case system, sway }
    private var directOwner: Owner?
    private var momentumOwner: Owner?
    private var pendingMomentumOwner: Owner?
    private var momentumStartDeadline = 0.0
    private var touchesHaveEnded = false

    var blocksEdgeGesture: Bool { directOwner == .system && !touchesHaveEnded }

    mutating func touchesEnded() {
        // Native lift may precede the scroll-ended event. Keep the latter's
        // owner, but do not let it reject the next physical touch sequence.
        touchesHaveEnded = true
    }

    // The event tap calls this before draining queued touch frames at a new
    // scroll boundary, so an old system scroll cannot reject a fresh edge touch.
    mutating func prepare(phase: Phase, momentum: Phase) {
        if momentum == .none && (phase == .mayBegin || phase == .began) {
            self = GestureScrollCapture()
        }
    }

    mutating func consume(precise: Bool, phase: Phase, momentum: Phase = .none,
                          eligible: Bool, at time: Double) -> Bool {
        guard precise, time.isFinite else { return false }
        prepare(phase: phase, momentum: momentum)
        if momentum != .none {
            // Some sources combine direct end with momentum begin in one event.
            if phase == .ended { _ = endDirect(at: time, cancelled: false) }
            // A delayed tail from an older gesture cannot change the owner of
            // a newer, still-touching scroll. Never acquire inertia from current
            // touch eligibility: it must belong to a sequence we already saw.
            guard directOwner == nil else { return false }
            if momentum == .began || momentumOwner == nil {
                momentumOwner = time <= momentumStartDeadline ? (pendingMomentumOwner ?? .system) : .system
                pendingMomentumOwner = nil
            }
            let consume = momentumOwner == .sway
            if momentum == .ended || momentum == .cancelled {
                momentumOwner = nil
                pendingMomentumOwner = nil
                momentumStartDeadline = 0
            }
            // The deadline limits only the handoff, NOT the inertia's duration.
            // Once owned, a long deceleration remains owned through its end.
            return consume
        }
        switch phase {
        case .none:
            // Precise does not necessarily mean trackpad: phase-less wheels
            // and synthetic scrolling must not inherit trackpad ownership.
            return false
        case .mayBegin:
            // This is a preflight, not the actual scroll start.
            // Let apps see it (including their normal stop-inertia behavior).
            return false
        case .began:
            directOwner = eligible ? .sway : .system
            return directOwner == .sway
        case .changed, .stationary:
            // Missing/late begin: favor uninterrupted scrolling. In particular,
            // NEVER steal a system scroll once its first movement was delivered.
            if directOwner == nil {
                directOwner = .system
                touchesHaveEnded = false
                momentumOwner = nil
                pendingMomentumOwner = nil
            }
            return directOwner == .sway
        case .ended:
            return endDirect(at: time, cancelled: false)
        case .cancelled:
            return endDirect(at: time, cancelled: true)
        }
    }

    private mutating func endDirect(at time: Double, cancelled: Bool) -> Bool {
        let consume = directOwner == .sway
        if cancelled {
            pendingMomentumOwner = nil
            momentumStartDeadline = 0
            momentumOwner = nil
        } else if let directOwner {
            pendingMomentumOwner = directOwner
            momentumStartDeadline = time + 1
            momentumOwner = nil
        }
        directOwner = nil
        return consume
    }
}

#if !SWAY_GESTURE_TESTS
import AppKit
import Combine

final class GestureTelemetry: ObservableObject {
    static let shared = GestureTelemetry()
    struct Snapshot {
        var decision = GestureDecision()
        var acceptedCount = 0
        var rejectedCount = 0
        var lastTap: String?
    }
    // A single coherent publication per rendered sample. Publishing each field
    // separately invalidated every observing view up to 13 times per sample.
    @Published private(set) var snapshot = Snapshot()
    var phase: String { snapshot.decision.phase.rawValue }
    var reason: String { snapshot.decision.reason }
    var fingerCount: Int { snapshot.decision.count }
    var x: Double { snapshot.decision.x }
    var y: Double { snapshot.decision.y }
    var displacement: Double { snapshot.decision.displacement }
    var straightness: Double { snapshot.decision.straightness }
    var elapsedMilliseconds: Int { Int(snapshot.decision.elapsed * 1000) }
    var sampleCount: Int { snapshot.decision.samples }
    var activeZone: String { snapshot.decision.region.rawValue }
    var acceptedCount: Int { snapshot.acceptedCount }
    var rejectedCount: Int { snapshot.rejectedCount }
    @Published var isTesting = false {
        didSet {
            if isTesting != oldValue {
                lastPublish = -Double.infinity
                TrackpadMonitor.shared.cancelCurrentGesture()
            }
        }
    }
    /// Settings is showing a live map: positions publish, counters do not.
    @Published var isLiveViewing = false {
        didSet { if isLiveViewing != oldValue { lastPublish = -Double.infinity } }
    }
    private var lastPublish = -Double.infinity

    func resetCounters() {
        snapshot = Snapshot()
        lastPublish = -Double.infinity
    }

    func monitorStopped() {
        guard isTesting else { return }
        var next = snapshot
        next.decision = GestureDecision(reason: "Enable Sway to detect gestures.")
        snapshot = next
    }

    /// Taps never change anything during a test; this only explains them.
    func publishTap(_ event: TapEvent, title: String) {
        guard isTesting else { return }
        var next = snapshot
        next.lastTap = "\(title) recognized. Nothing was sent during the test."
        next.decision.reason = next.lastTap ?? next.decision.reason
        snapshot = next
    }

    func publish(_ decision: GestureDecision, at time: Double, force: Bool = false) {
        // No SwiftUI work, trail updates or counter churn during normal use.
        guard isTesting || isLiveViewing else { return }
        guard force || decision.justAccepted || decision.justRejected || decision.count == 0 ||
                time - lastPublish >= 1.0 / 30 else { return }
        lastPublish = time
        var next = snapshot
        next.decision = decision
        if isTesting && decision.justAccepted { next.acceptedCount += 1 }
        if isTesting && decision.justRejected { next.rejectedCount += 1 }
        snapshot = next
    }
}
#endif

import Foundation
import CoreGraphics

private final class FakeBrightnessHardware: BrightnessHardware {
    private let lock = NSLock()
    private var displays: [CGDirectDisplayID] = [1, 2]
    private var builtIn: CGDirectDisplayID = 1
    private var value: Float? = 0.5
    private var writes: [(CGDirectDisplayID, Float)] = []
    private var reads = 0
    private var enumerations = 0
    private var writeWorks = true
    private var writeGate: DispatchSemaphore?
    private var writeEntered: DispatchSemaphore?
    private var readGate: DispatchSemaphore?
    private var readEntered: DispatchSemaphore?
    private var changed: (() -> Void)?
    var canWrite: Bool { true }

    func activeDisplays() -> [CGDirectDisplayID] {
        lock.lock(); defer { lock.unlock() }; enumerations += 1; return displays
    }
    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return builtIn == display
    }
    func isActive(_ display: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return displays.contains(display)
    }
    func read(_ display: CGDirectDisplayID) -> Float? {
        lock.lock()
        let gate = readGate, entered = readEntered
        readGate = nil; readEntered = nil
        lock.unlock()
        entered?.signal()
        if let gate { _ = gate.wait(timeout: .now() + 2) }
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return displays.contains(display) ? value : nil
    }
    func write(_ newValue: Float, to display: CGDirectDisplayID) -> Bool {
        lock.lock()
        let gate = writeGate, entered = writeEntered
        writeGate = nil; writeEntered = nil
        lock.unlock()
        entered?.signal()
        if let gate { _ = gate.wait(timeout: .now() + 2) }
        lock.lock(); defer { lock.unlock() }
        guard writeWorks, displays.contains(display) else { return false }
        writes.append((display, newValue)); value = newValue
        return true
    }
    func observeChanges(_ callback: @escaping () -> Void) {
        lock.lock(); changed = callback; lock.unlock()
    }
    func externalValue(_ value: Float?) { lock.lock(); self.value = value; lock.unlock() }
    func setWriteWorks(_ works: Bool) { lock.lock(); writeWorks = works; lock.unlock() }
    func route(_ display: CGDirectDisplayID, notify: Bool = true) {
        lock.lock(); displays = [display, 2]; builtIn = display; let callback = changed; lock.unlock()
        if notify { callback?() }
    }
    func blockNextWrite() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        lock.lock(); writeEntered = entered; writeGate = release; lock.unlock()
        return (entered, release)
    }
    func blockNextRead() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        lock.lock(); readEntered = entered; readGate = release; lock.unlock()
        return (entered, release)
    }
    var counts: (reads: Int, enumerations: Int, writes: Int) {
        lock.lock(); defer { lock.unlock() }; return (reads, enumerations, writes.count)
    }
    var writtenDisplays: [CGDirectDisplayID] { lock.lock(); defer { lock.unlock() }; return writes.map(\.0) }
}

/// External displays that can be controlled, plus a movable pointer.
private final class PointerBrightnessHardware: BrightnessHardware {
    private let lock = NSLock()
    var displays: [CGDirectDisplayID] = [1, 5, 6]
    var builtInDisplay: CGDirectDisplayID? = 1
    var controllable: Set<CGDirectDisplayID> = [1, 5]
    var pointer: CGDirectDisplayID?
    var values: [CGDirectDisplayID: Float] = [1: 0.4, 5: 0.8, 6: 0.3]
    var writes: [CGDirectDisplayID] = []
    var canWrite: Bool { true }
    func activeDisplays() -> [CGDirectDisplayID] { lock.lock(); defer { lock.unlock() }; return displays }
    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool { lock.lock(); defer { lock.unlock() }; return display == builtInDisplay }
    func isActive(_ display: CGDirectDisplayID) -> Bool { lock.lock(); defer { lock.unlock() }; return displays.contains(display) }
    func isControllable(_ display: CGDirectDisplayID) -> Bool { lock.lock(); defer { lock.unlock() }; return controllable.contains(display) }
    func displayUnderPointer() -> CGDirectDisplayID? { lock.lock(); defer { lock.unlock() }; return pointer }
    func read(_ display: CGDirectDisplayID) -> Float? { lock.lock(); defer { lock.unlock() }; return controllable.contains(display) ? values[display] : nil }
    func write(_ value: Float, to display: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard controllable.contains(display) else { return false }
        values[display] = value; writes.append(display); return true
    }
    func observeChanges(_ callback: @escaping () -> Void) {}
    func update(_ change: (PointerBrightnessHardware) -> Void) { lock.lock(); change(self); lock.unlock() }
}

@main
enum BrightnessRegressionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        expect(condition(), "asynchronous operation completes without timeout")
    }
    static func value(_ result: BrightnessRequestResult?) -> Float? {
        guard case let .applied(value, _) = result else { return nil }; return value
    }
    static func cancelled(_ result: BrightnessRequestResult?) -> Bool {
        guard case .cancelled = result else { return false }; return true
    }
    static func failed(_ result: BrightnessRequestResult?) -> Bool {
        guard case .failed = result else { return false }; return true
    }
    static func main() {
        let hardware = FakeBrightnessHardware()
        let controller = BrightnessController(backend: hardware)
        var baseline: BrightnessRequestResult?
        controller.refresh { baseline = $0 }
        wait { baseline != nil }
        expect(value(baseline) == 0.5 && controller.isAvailable, "startup reads built-in brightness")
        expect(controller.hasExternalDisplayConnected && controller.isBuiltInDisplayActive,
               "external primary display does not displace built-in control")
        let beforeGetters = hardware.counts
        for _ in 0..<1000 {
            _ = controller.getBrightness(); _ = controller.isAvailable
            _ = controller.targetIdentifier; _ = controller.deviceName
        }
        expect(hardware.counts.reads == beforeGetters.reads && hardware.counts.enumerations == beforeGetters.enumerations,
               "cached UI and gesture getters never perform hardware IO")

        hardware.externalValue(0.8)
        expect(controller.getBrightness() == 0.5, "external change demonstrates old cache before refresh")
        baseline = nil
        var completionOnMain = false
        controller.refresh { baseline = $0; completionOnMain = Thread.isMainThread }
        wait { baseline != nil }
        expect(value(baseline) == 0.8 && completionOnMain, "fresh baseline barrier returns external value on main")
        expect(hardware.counts.writes == 0, "baseline refresh never adjusts brightness")

        let read = hardware.blockNextRead()
        baseline = nil
        controller.refresh { baseline = $0 }
        expect(read.entered.wait(timeout: .now() + 1) == .success, "fresh read entered background worker")
        expect(baseline == nil, "slow baseline does not fabricate a cached success")
        hardware.externalValue(0.7)
        read.release.signal()
        wait { baseline != nil }
        expect(value(baseline) == 0.7, "fresh baseline reflects completed read, not pre-request cache")

        let block = hardware.blockNextWrite()
        var results: [Int: BrightnessRequestResult] = [:]
        var callbackCounts: [Int: Int] = [:]
        let beforeBurst = hardware.counts.writes
        controller.requestBrightness(0.3) { results[0] = $0; callbackCounts[0, default: 0] += 1 }
        expect(block.entered.wait(timeout: .now() + 1) == .success, "hardware write is off main")
        for index in 1...20 {
            controller.requestBrightness(0.4 + Float(index) * 0.02) {
                results[index] = $0; callbackCounts[index, default: 0] += 1
            }
        }
        expect(results[0] == nil, "main thread remains available while driver write is blocked")
        block.release.signal()
        wait { results.count == 21 }
        expect(value(results[0]) == 0.3, "in-flight applied sample remains visible despite newer pending values")
        expect(value(results[20]).map { abs($0 - 0.8) < 0.0001 } == true, "latest queued brightness settles")
        expect((1..<20).allSatisfy { cancelled(results[$0]) }, "superseded pending values are cancelled")
        expect(callbackCounts.values.allSatisfy { $0 == 1 }, "every request completes exactly once")
        expect(hardware.counts.writes - beforeBurst == 2, "burst has one in-flight and one latest queued write")

        let cancelledWrite = hardware.blockNextWrite()
        var firstCancelled: BrightnessRequestResult?, pendingCancelled: BrightnessRequestResult?
        controller.requestBrightness(0.25) { firstCancelled = $0 }
        expect(cancelledWrite.entered.wait(timeout: .now() + 1) == .success, "cancellation test enters in-flight write")
        let beforeCancel = hardware.counts.writes
        controller.requestBrightness(0.6) { pendingCancelled = $0 }
        controller.cancelPendingRequests()
        cancelledWrite.release.signal()
        wait { firstCancelled != nil && pendingCancelled != nil }
        expect(cancelled(firstCancelled) && cancelled(pendingCancelled), "explicit cancellation invalidates queued and in-flight success")
        expect(hardware.counts.writes == beforeCancel + 1, "explicit cancellation never executes pending write")
        expect(controller.getBrightness() == 0.25, "unretractable in-flight write still reconciles real measured cache")

        let scope = UUID()
        let scopedWrite = hardware.blockNextWrite()
        var gestureResult: BrightnessRequestResult?, manualResult: BrightnessRequestResult?
        controller.requestBrightness(0.35, cancellationScope: scope) { gestureResult = $0 }
        expect(scopedWrite.entered.wait(timeout: .now() + 1) == .success, "scoped gesture write enters worker")
        controller.requestBrightness(0.55) { manualResult = $0 }
        controller.cancelPendingRequests(in: scope)
        scopedWrite.release.signal()
        wait { gestureResult != nil && manualResult != nil }
        expect(cancelled(gestureResult), "gesture-scoped cancellation invalidates in-flight gesture feedback")
        expect(value(manualResult) == 0.55, "gesture cancellation preserves a newer queued manual slider request")

        let manualWrite = hardware.blockNextWrite()
        gestureResult = nil; manualResult = nil
        controller.requestBrightness(0.45) { manualResult = $0 }
        expect(manualWrite.entered.wait(timeout: .now() + 1) == .success, "manual write enters worker")
        let beforeScopedCancel = hardware.counts.writes
        controller.requestBrightness(0.9, cancellationScope: scope) { gestureResult = $0 }
        controller.cancelPendingRequests(in: scope)
        manualWrite.release.signal()
        wait { gestureResult != nil && manualResult != nil }
        expect(cancelled(gestureResult) && value(manualResult) == 0.45,
               "cancelling a queued gesture preserves executing manual control")
        expect(hardware.counts.writes == beforeScopedCancel + 1, "cancelled queued gesture never reaches driver")
        gestureResult = nil
        controller.requestBrightness(0.65, cancellationScope: scope) { gestureResult = $0 }
        wait { gestureResult != nil }
        expect(value(gestureResult) == 0.65, "finished cancellation scopes release their bounded bookkeeping")

        let oldTarget = controller.targetIdentifier
        hardware.route(3, notify: false)
        var staleRoute: BrightnessRequestResult?
        let beforeRoute = hardware.counts.writes
        controller.requestBrightness(0.9, expectedTargetIdentifier: oldTarget) { staleRoute = $0 }
        wait { staleRoute != nil }
        expect(cancelled(staleRoute), "disconnected route rejects even before notification is delivered")
        expect(hardware.counts.writes == beforeRoute, "stale request never writes to replacement display")
        expect(controller.targetIdentifier != oldTarget, "route refresh changes opaque target identity")
        var mismatch: BrightnessRequestResult?
        controller.requestBrightness(0.9, expectedTargetIdentifier: oldTarget) { mismatch = $0 }
        wait { mismatch != nil }
        expect(cancelled(mismatch), "explicit old target stays invalid after refresh")

        var invalid: BrightnessRequestResult?
        controller.requestBrightness(.nan) { invalid = $0 }
        wait { invalid != nil }
        expect(failed(invalid) && hardware.counts.writes == beforeRoute, "invalid level never reaches hardware")
        hardware.setWriteWorks(false)
        var failedWrite: BrightnessRequestResult?
        controller.requestBrightness(0.9) { failedWrite = $0 }
        wait { failedWrite != nil }
        expect(failed(failedWrite), "driver write failure is not reported as applied")
        hardware.externalValue(.nan)
        baseline = nil
        controller.refresh { baseline = $0 }
        wait { baseline != nil }
        expect(failed(baseline) && !controller.isAvailable, "invalid hardware read cannot become relative baseline")
        expect(!hardware.writtenDisplays.contains(3), "all writes remained on the original fake display")
        pointerChecks()
        print("PASS: \(checks) brightness controller regression checks (fake hardware only)")
    }

    static func pointerChecks() {
        let hardware = PointerBrightnessHardware()
        let controller = BrightnessController(backend: hardware)
        var result: BrightnessRequestResult?
        controller.refresh { result = $0 }
        wait { result != nil }
        expect(value(result) == 0.4 && controller.activeDisplay == 1, "without pointer following the built-in display stays the target")
        hardware.update { $0.pointer = 5 }
        controller.followsPointer = true
        result = nil
        controller.refresh { result = $0 }
        wait { result != nil }
        expect(value(result) == 0.8 && controller.activeDisplay == 5, "the controllable display under the pointer becomes the target")
        expect(controller.deviceName == "External display" && !controller.isBuiltInDisplayActive, "an external target is named as external")
        var write: BrightnessRequestResult?
        controller.requestBrightness(0.6) { write = $0 }
        wait { write != nil }
        expect(value(write) == 0.6 && hardware.writes == [5], "writes go to the pointer's display only")
        hardware.update { $0.pointer = 6 }
        result = nil
        controller.refresh { result = $0 }
        wait { result != nil }
        expect(value(result) == 0.4 && controller.activeDisplay == 1, "an uncontrollable pointer display falls back to built-in")
        hardware.update { $0.displays = [5, 6]; $0.builtInDisplay = nil; $0.pointer = nil }
        controller.followsPointer = false
        result = nil
        controller.refresh { result = $0 }
        wait { result != nil }
        expect(value(result) == 0.6 && controller.activeDisplay == 5, "with the lid closed a controllable external display is used")
        hardware.update { $0.controllable = [] }
        result = nil
        controller.refresh { result = $0 }
        wait { result != nil }
        expect(failed(result) && !controller.isAvailable, "no controllable display means unavailable, not a guess")
    }
}

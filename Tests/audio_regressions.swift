import Foundation
import CoreAudio

private final class FakeAudioBackend: AudioOutputBackend {
    let lock = NSLock()
    var token: AudioOutputToken? = AudioOutputToken(device: 7, source: 1)
    var volumes: [UInt32: Float] = [0: 0.4]
    var mutes: [UInt32: Bool] = [0: false]
    var volumeElements: [UInt32] = [0]
    var muteElements: [UInt32] = [0]
    var volumeWritable = true
    var muteWritable = true
    var failVolumeWrite = false
    var failMuteWrite = false
    var ignoreMuteWrite = false
    var failReadback = false
    var quantize = false
    var reads = 0
    var discoveries = 0
    var volumeWrites: [(AudioDeviceID, Float)] = []
    var muteWrites: [Bool] = []
    var operations: [String] = []
    var mutedDuringVolumeWrites: [Bool] = []
    var allIOOffMain = true
    var stopped = false
    var blockNextWrite: (entered: DispatchSemaphore, release: DispatchSemaphore)?
    private var queue: DispatchQueue?
    private var handler: ((AudioBackendEvent) -> Void)?

    func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
    private func noteIO() { reads += 1; allIOOffMain = allIOOffMain && !Thread.isMainThread }
    func start(on queue: DispatchQueue, handler: @escaping (AudioBackendEvent) -> Void) {
        locked { self.queue = queue; self.handler = handler; noteIO() }
    }
    func stop() { locked { stopped = true; handler = nil } }
    func currentOutput() -> AudioOutputToken? { locked { noteIO(); return token } }
    func configuration(for token: AudioOutputToken) -> AudioOutputConfiguration {
        locked {
            noteIO(); discoveries += 1
            return AudioOutputConfiguration(token: token, name: "Test output", volumeElements: volumeElements,
                volumeWritable: volumeWritable, muteElements: muteElements, muteWritable: muteWritable)
        }
    }
    func observe(_ configuration: AudioOutputConfiguration?) { locked { noteIO() } }
    func volume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        locked { noteIO(); return failReadback ? nil : volumes[element] }
    }
    func mute(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        locked { noteIO(); return mutes[element] }
    }
    func setVolume(_ value: Float, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        let blocker = locked { () -> (DispatchSemaphore, DispatchSemaphore)? in
            noteIO()
            let result = blockNextWrite
            blockNextWrite = nil
            return result
        }
        blocker?.0.signal()
        if let blocker { _ = blocker.1.wait(timeout: .now() + 3) }
        return locked {
            volumeWrites.append((device, value))
            operations.append("volume")
            mutedDuringVolumeWrites.append(!mutes.isEmpty && mutes.values.allSatisfy { $0 })
            guard !failVolumeWrite else { return false }
            volumes[element] = quantize ? (value * 10).rounded() / 10 : value
            return true
        }
    }
    func setMute(_ value: Bool, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        locked {
            noteIO(); muteWrites.append(value)
            operations.append(value ? "mute" : "unmute")
            guard !failMuteWrite else { return false }
            if !ignoreMuteWrite { mutes[element] = value }
            return true
        }
    }
    func emit(_ event: AudioBackendEvent) {
        let state = locked { (queue, handler) }
        state.0?.async { state.1?(event) }
    }
    func blockOneWrite() -> (DispatchSemaphore, DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        locked { blockNextWrite = (entered, release) }
        return (entered, release)
    }
}

@main private enum AudioRegressionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    static func waitFor(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
        expect(condition(), message)
    }
    static func ready(_ backend: FakeAudioBackend = FakeAudioBackend()) -> (VolumeController, FakeAudioBackend) {
        let controller = VolumeController(backend: backend)
        controller.flushWorkerForTesting()
        return (controller, backend)
    }
    static func request(_ controller: VolumeController, _ value: Float, muteAtZero: Bool = true,
                        target: String? = nil, restoringMute: Bool? = nil) -> VolumeRequestResult {
        var result: VolumeRequestResult?
        controller.requestVolume(value, muteAtZero: muteAtZero, restoringMute: restoringMute, expectedTargetIdentifier: target) {
            expect(Thread.isMainThread, "volume completion on main")
            result = $0
        }
        waitFor("volume completion arrives") { result != nil }
        return result!
    }
    static func applied(_ result: VolumeRequestResult, _ value: Float) -> Bool {
        if case let .applied(measured, _, _) = result { return abs(measured - value) < 0.0001 }
        return false
    }
    static func cancelled(_ result: VolumeRequestResult) -> Bool {
        if case .cancelled = result { return true }; return false
    }
    static func failed(_ result: VolumeRequestResult) -> Bool {
        if case .failed = result { return true }; return false
    }

    static func main() {
        testCacheAndExternalChanges()
        testMeasuredWritesAndMute()
        testAtomicMuteRestore()
        testLatestPendingAndCancellation()
        testScopedCancellation()
        testRoutesAndAvailability()
        testPacedLevels()
        print("\(checks) audio regression checks passed (fake backend; no system audio writes).")
    }

    /// A slide sends a level every trackpad frame (about 120 a second). Each one
    /// ripples through Control Center and the audio daemon, so writes are paced
    /// to 30 a second, and the newest value always lands.
    static func testPacedLevels() {
        let (controller, backend) = ready()
        let before = backend.locked { backend.volumeWrites.count }
        var last: VolumeRequestResult?
        let start = Date()
        for step in 1...60 {
            controller.requestVolume(0.2 + Float(step) * 0.01) { last = $0 }
            RunLoop.current.run(until: start.addingTimeInterval(Double(step) / 120))
        }
        waitFor("the last level lands") { last != nil && backend.locked { backend.volumes[0] ?? 0 } > 0.79 }
        let written = backend.locked { backend.volumeWrites.count } - before
        expect(written <= 22, "half a second of a slide writes about 15 times, not 60 (wrote \(written))")
        expect(abs((backend.locked { backend.volumes[0] ?? 0 }) - 0.8) < 0.001, "the final level is exactly the last one asked for")
        var muted: VolumeRequestResult?
        let mutedAt = Date()
        controller.requestMuted(true) { muted = $0 }
        waitFor("mute completes") { muted != nil }
        expect(Date().timeIntervalSince(mutedAt) < 0.03, "mute never waits behind level pacing")
    }

    static func testCacheAndExternalChanges() {
        let (controller, backend) = ready()
        expect(controller.isAvailable, "cached output availability")
        expect(controller.targetIdentifier == "audio:7:1", "physical output source participates in identity")
        expect(controller.deviceName == "Test output", "cached name")
        expect(controller.supportsMute && !controller.isMuted, "cached mute capabilities")
        expect(controller.getVolume() == 0.4, "initial measured scalar")
        let before = backend.locked { backend.reads }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100_000 {
            _ = controller.getVolume(); _ = controller.isAvailable; _ = controller.targetIdentifier
            _ = controller.supportsMute; _ = controller.isMuted; _ = controller.deviceName
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        expect(backend.locked { backend.reads } == before, "600000 snapshot reads perform zero HAL calls")
        print(String(format: "600000 cached reads: %.2f ms; HAL calls: 0", elapsed * 1000))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        expect(backend.locked { backend.reads } == before, "idle has no polling IO")
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: .swayAudioStateChanged, object: controller, queue: nil) { _ in
            expect(Thread.isMainThread, "state notification on main")
            notifications += 1
        }
        backend.locked { backend.volumes[0] = 0.8; backend.mutes[0] = true }
        backend.emit(.state)
        waitFor("external volume keys update cache") { controller.getVolume() == 0.8 }
        expect(controller.isMuted, "external mute reflected")
        waitFor("external state notification") { notifications > 0 }
        expect(backend.locked { backend.discoveries } == 1, "volume event never rediscovers channel topology")
        let previousNotifications = notifications
        backend.emit(.state)
        controller.flushWorkerForTesting(); controller.flushWorkerForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        expect(notifications == previousNotifications, "unchanged state produces no redraw notification")
        expect(backend.locked { backend.allIOOffMain }, "all HAL IO remains off main")
        NotificationCenter.default.removeObserver(observer)
        var disposable: VolumeController? = VolumeController(backend: backend)
        disposable?.flushWorkerForTesting()
        disposable = nil
        expect(backend.locked { backend.stopped }, "lifecycle removes property listeners")
    }

    static func testMeasuredWritesAndMute() {
        let (controller, backend) = ready()
        expect(applied(request(controller, 0.6), 0.6), "scalar write measured")
        expect(backend.locked { backend.muteWrites.isEmpty }, "raising unmuted volume avoids redundant mute writes")
        let writes = backend.locked { backend.volumeWrites.count }
        expect(applied(request(controller, 0.6), 0.6), "same value still reports measured success")
        expect(backend.locked { backend.volumeWrites.count } == writes, "same value skips hardware write")
        expect(applied(request(controller, 2), 1), "upper bound clamps")
        expect(applied(request(controller, -1), 0), "lower bound clamps")
        expect(controller.isMuted, "zero mutes when enabled")
        expect(applied(request(controller, 0.3), 0.3), "raising muted volume succeeds")
        expect(!controller.isMuted, "raising scalar unmutes")
        expect(applied(request(controller, 0, muteAtZero: false), 0), "zero scalar without hardware mute")
        expect(!controller.isMuted, "mute-at-zero preference honored")
        expect(failed(request(controller, .nan)), "NaN rejected")
        expect(failed(request(controller, .infinity)), "infinity rejected")
        backend.locked { backend.quantize = true }
        expect(applied(request(controller, 0.543), 0.5), "report quantized readback, not requested value")
        backend.locked { backend.failVolumeWrite = true }
        expect(failed(request(controller, 0.9)), "driver write failure reported")
        expect(controller.getVolume() == 0.5, "failed write never fabricates a cache value")
        backend.locked { backend.failVolumeWrite = false; backend.failReadback = true }
        expect(failed(request(controller, 0.7)), "missing readback is not success")
        expect(!controller.isAvailable, "unreadable output disables scalar control")
        backend.locked { backend.failReadback = false }
        controller.refresh(); controller.flushWorkerForTesting()
        expect(controller.isAvailable, "explicit reconnect restores capability")
        expect(controller.setMuted(true), "legacy mute preserves support")
        expect(controller.getVolume() == 0.7 && controller.isMuted, "mute preserves scalar")
        var muteResult: VolumeRequestResult?
        controller.requestMuted(false) { muteResult = $0 }
        waitFor("async mute completion") { muteResult != nil }
        expect(applied(muteResult!, 0.7) && !controller.isMuted, "async unmute preserves scalar")
        backend.locked { backend.ignoreMuteWrite = true }
        controller.requestMuted(true) { muteResult = $0 }
        controller.flushWorkerForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        expect(failed(muteResult!), "mute success requires measured mute readback")
        expect(backend.locked { backend.allIOOffMain }, "legacy sync API still performs IO on worker")
    }

    static func testLatestPendingAndCancellation() {
        let (controller, backend) = ready()
        let (entered, release) = backend.blockOneWrite()
        var results: [Int: VolumeRequestResult] = [:]
        controller.requestVolume(0.5) { results[0] = $0 }
        expect(entered.wait(timeout: .now() + 1) == .success, "slow fake driver entered")
        for index in 1...400 {
            controller.requestVolume(Float(index) / 500) { results[index] = $0 }
        }
        for _ in 0..<400 { controller.refresh() }
        expect(controller.getVolume() == 0.4, "slow write never blocks cheap measured getter")
        release.signal()
        waitFor("every coalesced request completes exactly once") { results.count == 401 }
        expect(applied(results[0]!, 0.5), "in-flight progress is retained during continuous input")
        expect(applied(results[400]!, 0.8), "newest pending value reaches hardware")
        expect((1..<400).allSatisfy { cancelled(results[$0]!) }, "all intermediate queued values cancelled")
        expect(backend.locked { backend.volumeWrites.count } == 2, "401 requests coalesce to two writes")
        expect(backend.locked { backend.discoveries } == 2, "400 explicit refreshes coalesce into one route discovery")
        let blocked = backend.blockOneWrite()
        var cancelledResults: [VolumeRequestResult] = []
        controller.requestVolume(0.3) { cancelledResults.append($0) }
        expect(blocked.0.wait(timeout: .now() + 1) == .success, "cancellation test driver entered")
        controller.requestVolume(0.2) { cancelledResults.append($0) }
        controller.cancelPendingRequests()
        blocked.1.signal()
        waitFor("cancel completions") { cancelledResults.count == 2 }
        expect(cancelledResults.allSatisfy(cancelled), "explicit cancellation invalidates in-flight and pending results")
        expect(backend.locked { backend.volumeWrites.count } == 3, "cancelled pending write never executes")
        expect(applied(request(controller, 0.6), 0.6), "controller accepts input after cancellation")
    }

    static func testAtomicMuteRestore() {
        let (controller, backend) = ready()
        expect(applied(request(controller, 0.8, restoringMute: true), 0.8), "atomic muted restore succeeds")
        expect(controller.isMuted, "restored level remains muted")
        expect(backend.locked { backend.operations } == ["mute", "volume"], "mute precedes scalar with no transient unmute")
        expect(backend.locked { backend.mutedDuringVolumeWrites } == [true], "saved level written only after verified silence")
        backend.locked { backend.operations = []; backend.mutedDuringVolumeWrites = [] }
        expect(applied(request(controller, 0.5, restoringMute: true), 0.5), "already-muted restore succeeds")
        expect(backend.locked { backend.operations } == ["volume"], "already-muted restore avoids redundant mute writes")
        expect(backend.locked { backend.mutedDuringVolumeWrites } == [true], "already-muted scalar stays silent")
        backend.locked { backend.operations = [] }
        expect(applied(request(controller, 0.2, restoringMute: false), 0.2), "unmuted restore succeeds")
        expect(backend.locked { backend.operations } == ["volume", "unmute"], "restored scalar is set before unmuting")
        expect(!controller.isMuted, "explicit unmuted state restored")
        expect(applied(request(controller, 0, restoringMute: false), 0), "zero restore honors explicit unmuted state")
        expect(!controller.isMuted, "explicit unmuted zero overrides automatic mute policy")
        backend.locked { backend.failMuteWrite = true; backend.operations = [] }
        expect(failed(request(controller, 0.9, restoringMute: true)), "failed safety mute rejects restore")
        expect(backend.locked { backend.operations } == ["mute"], "failed mute never writes saved scalar")
        backend.locked { backend.failMuteWrite = false; backend.ignoreMuteWrite = true; backend.operations = [] }
        expect(failed(request(controller, 0.9, restoringMute: true)), "accepted-but-unapplied mute rejects restore")
        expect(backend.locked { backend.operations } == ["mute"], "readback required before scalar restore")
        backend.locked { backend.muteElements = []; backend.mutes = [:]; backend.muteWritable = false }
        controller.refresh(); controller.flushWorkerForTesting()
        expect(applied(request(controller, 0.6, restoringMute: false), 0.6), "unmuted restore works on scalar-only output")
        expect(failed(request(controller, 0.9, restoringMute: true)), "cannot claim muted restore without a mute control")
    }

    static func testScopedCancellation() {
        let (controller, backend) = ready()
        let gestureScope = UUID()
        let blocked = backend.blockOneWrite()
        var gestureResult: VolumeRequestResult?
        var manualResult: VolumeRequestResult?
        controller.requestVolume(0.5, cancellationScope: gestureScope) { gestureResult = $0 }
        expect(blocked.0.wait(timeout: .now() + 1) == .success, "scoped in-flight driver entered")
        controller.requestVolume(0.8) { manualResult = $0 }
        controller.cancelPendingRequests(in: gestureScope)
        blocked.1.signal()
        waitFor("scoped gesture and manual completions") { gestureResult != nil && manualResult != nil }
        expect(cancelled(gestureResult!), "scoped cancellation suppresses old in-flight gesture feedback")
        expect(applied(manualResult!, 0.8), "scoped cancellation preserves later manual slider input")
        expect(controller.getVolume() == 0.8, "manual value reaches hardware after cancelled gesture")
        expect(controller.activeScopeCountForTesting == 0, "completed gesture scope bookkeeping released")

        let pendingScope = UUID()
        let blockedManual = backend.blockOneWrite()
        gestureResult = nil; manualResult = nil
        controller.requestVolume(0.4) { manualResult = $0 }
        expect(blockedManual.0.wait(timeout: .now() + 1) == .success, "unscoped in-flight driver entered")
        controller.requestVolume(0.9, cancellationScope: pendingScope) { gestureResult = $0 }
        controller.cancelPendingRequests(in: pendingScope)
        blockedManual.1.signal()
        waitFor("pending-only cancellation completions") { gestureResult != nil && manualResult != nil }
        expect(applied(manualResult!, 0.4), "pending scope cancellation preserves current unscoped write")
        expect(cancelled(gestureResult!), "pending gesture cancelled before hardware write")
        expect(controller.getVolume() == 0.4, "cancelled pending scope never changes level")
        expect(controller.activeScopeCountForTesting == 0, "cancelled pending scope bookkeeping released")

        let completedScope = UUID()
        var delayedResult: VolumeRequestResult?
        controller.requestVolume(0.7, cancellationScope: completedScope) { delayedResult = $0 }
        controller.flushWorkerForTesting()
        controller.cancelPendingRequests(in: completedScope)
        waitFor("queued main completion cancellation") { delayedResult != nil }
        expect(cancelled(delayedResult!), "scoped cancellation also invalidates an already-queued main callback")
        expect(controller.activeScopeCountForTesting == 0, "late cancellation has no retained scope state")
        for _ in 0..<1000 { controller.cancelPendingRequests(in: UUID()) }
        expect(controller.activeScopeCountForTesting == 0, "unknown scopes do not accumulate memory")
    }

    static func testRoutesAndAvailability() {
        let (controller, backend) = ready()
        expect(cancelled(request(controller, 0.8, target: "audio:other")), "wrong expected target cancelled")
        expect(backend.locked { backend.volumeWrites.isEmpty }, "wrong target never written")
        let oldTarget = controller.targetIdentifier
        backend.locked { backend.token = AudioOutputToken(device: 7, source: 2) }
        expect(cancelled(request(controller, 0.8, target: oldTarget)), "headphone source change without notification cancelled")
        expect(controller.targetIdentifier == "audio:7:2", "route token refreshes on safety check")
        expect(backend.locked { backend.volumeWrites.isEmpty }, "same-device source change cannot inherit queued volume")
        let blocked = backend.blockOneWrite()
        var routeResults: [VolumeRequestResult] = []
        controller.requestVolume(0.5) { routeResults.append($0) }
        expect(blocked.0.wait(timeout: .now() + 1) == .success, "route-switch driver entered")
        controller.requestVolume(0.9) { routeResults.append($0) }
        backend.locked { backend.token = AudioOutputToken(device: 9, source: nil) }
        backend.emit(.route)
        blocked.1.signal()
        waitFor("route-switch completions") { routeResults.count == 2 }
        expect(routeResults.allSatisfy(cancelled), "route switch discards queued and obsolete in-flight feedback")
        expect(backend.locked { backend.volumeWrites.count == 1 && backend.volumeWrites[0].0 == 7 },
               "queued volume is never applied to a replacement output")
        backend.locked { backend.token = nil }
        backend.emit(.route)
        waitFor("disconnect event") { controller.targetIdentifier == nil }
        expect(!controller.isAvailable && !controller.supportsMute, "disconnected output unavailable")
        backend.locked {
            backend.token = AudioOutputToken(device: 8, source: nil)
            backend.volumeElements = [1, 2]; backend.volumes = [1: 0.2, 2: 0.6]
            backend.volumeWritable = false
        }
        backend.emit(.route)
        waitFor("new output route event") { controller.targetIdentifier == "audio:8" }
        expect(abs(controller.getVolume() - 0.4) < 0.0001, "stereo scalar is average")
        expect(!controller.isAvailable, "partially writable stereo output remains unavailable")
        expect(failed(request(controller, 0.8)), "fixed volume write rejected")
        backend.locked { backend.volumeWritable = true }
        controller.refresh(); controller.flushWorkerForTesting()
        expect(applied(request(controller, 0.7), 0.7), "writable stereo changes both channels")
        expect(backend.locked { backend.volumes[1] == 0.7 && backend.volumes[2] == 0.7 }, "stereo channels consistent")
        backend.locked { backend.muteElements = []; backend.mutes = [:]; backend.muteWritable = false }
        controller.refresh(); controller.flushWorkerForTesting()
        expect(applied(request(controller, 0), 0), "outputs without mute use zero scalar")
        expect(!controller.supportsMute, "no mute falsely advertised")
        let muteOnlyBackend = FakeAudioBackend()
        muteOnlyBackend.volumeElements = []; muteOnlyBackend.volumes = [:]; muteOnlyBackend.volumeWritable = false
        let (muteOnly, _) = ready(muteOnlyBackend)
        expect(!muteOnly.isAvailable && muteOnly.supportsMute, "mute-only device capability preserved")
        expect(muteOnly.setMuted(true) && muteOnly.isMuted, "mute-only fixed output can still be muted")
    }
}

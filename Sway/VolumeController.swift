import Foundation
import CoreAudio

extension Notification.Name {
    /// Measured state changed on main. External changes never request an OSD.
    static let swayAudioStateChanged = Notification.Name("swayAudioStateChanged")
    static let swayInputStateChanged = Notification.Name("swayInputStateChanged")
}

enum VolumeRequestResult {
    case applied(value: Float, muted: Bool, targetIdentifier: String)
    case failed
    /// Superseded, cancelled, or route changed; not a driver failure. An already
    /// executing driver call cannot be withdrawn.
    case cancelled
}

struct AudioOutputToken: Equatable {
    let device: AudioDeviceID
    let source: UInt32?
    var identifier: String { "audio:\(device)" + (source.map { ":\($0)" } ?? "") }
}

struct AudioOutputConfiguration {
    let token: AudioOutputToken
    let name: String
    let volumeElements: [AudioObjectPropertyElement]
    let volumeWritable: Bool
    let muteElements: [AudioObjectPropertyElement]
    let muteWritable: Bool
    /// Stable across reconnects and restarts, unlike the AudioDeviceID.
    var uid: String? = nil
}

enum AudioBackendEvent { case route, state }

/// Injectable HAL boundary: tests simulate slow drivers without audio writes.
protocol AudioOutputBackend: AnyObject {
    func start(on queue: DispatchQueue, handler: @escaping (AudioBackendEvent) -> Void)
    func stop()
    func currentOutput() -> AudioOutputToken?
    func configuration(for token: AudioOutputToken) -> AudioOutputConfiguration
    func observe(_ configuration: AudioOutputConfiguration?)
    func volume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float?
    func mute(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool?
    func setVolume(_ value: Float, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool
    func setMute(_ value: Bool, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool
}

private struct AudioOutputSnapshot: Equatable {
    var targetIdentifier: String?
    var uid: String?
    var name = "No audio output"
    var volume: Float?
    var isAvailable = false
    var isMuted = false
    var supportsMute = false
}

/// Serial-worker HAL IO, lock-protected cheap reads, and property listeners.
/// No polling, no discovery or driver calls from public snapshot getters.
final class VolumeController {
    static let shared = VolumeController(backend: CoreAudioOutputBackend())
    // Gain/mute only: no input stream is opened and no audio is captured.
    static let microphone = VolumeController(backend: CoreAudioOutputBackend(input: true),
                                             notification: .swayInputStateChanged, preservesMuteOnGain: true)
    private let notification: Notification.Name
    private let preservesMuteOnGain: Bool
    private let backend: AudioOutputBackend
    private let worker = DispatchQueue(label: "com.sway.audio-output", qos: .userInteractive)
    private let stateLock = NSLock()
    private var snapshot = AudioOutputSnapshot()
    // Worker-only state.
    private var route: AudioOutputConfiguration?
    private var measuredVolumes: [AudioObjectPropertyElement: Float] = [:]
    private var measuredMutes: [AudioObjectPropertyElement: Bool] = [:]
    private var refreshScheduled = false
    private var routeRefreshScheduled = false

    private enum Change { case volume(Float, Bool, Bool?), mute(Bool) }
    private struct Request {
        let epoch: UInt64
        let scope: UUID?
        let target: String?
        let change: Change
        let completion: (VolumeRequestResult) -> Void
    }
    private final class SynchronousResult {
        var value: VolumeRequestResult = .failed
        let completed = DispatchSemaphore(value: 0)
    }
    private let requestLock = NSLock()
    private var cancellationEpoch: UInt64 = 0
    private var pending: Request?
    private var drainScheduled = false
    private var scopeRequestCounts: [UUID: Int] = [:]
    private var cancelledScopes = Set<UUID>()

    /// Startup discovery is off main; listeners deliver the first snapshot.
    init(backend: AudioOutputBackend, notification: Notification.Name = .swayAudioStateChanged,
         preservesMuteOnGain: Bool = false) {
        self.backend = backend
        self.notification = notification
        self.preservesMuteOnGain = preservesMuteOnGain
        worker.async { [weak self] in
            guard let self else { return }
            self.backend.start(on: self.worker) { [weak self] event in
                guard let self else { return }
                switch event {
                case .route: self.reloadRoute()
                case .state: self.scheduleStateRefresh()
                }
            }
            self.reloadRoute()
        }
    }

    deinit { backend.stop() }

    private func readSnapshot() -> AudioOutputSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshot
    }
    var targetIdentifier: String? { readSnapshot().targetIdentifier }
    var isAvailable: Bool { readSnapshot().isAvailable }
    var deviceName: String { readSnapshot().name }
    var deviceUID: String? { readSnapshot().uid }
    var isMuted: Bool { readSnapshot().isMuted }
    var supportsMute: Bool { readSnapshot().supportsMute }
    func getVolume() -> Float { readSnapshot().volume ?? 0 }
    func refresh() {
        stateLock.lock()
        guard !routeRefreshScheduled else { stateLock.unlock(); return }
        routeRefreshScheduled = true
        stateLock.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            self.reloadRoute()
            self.stateLock.lock()
            self.routeRefreshScheduled = false
            self.stateLock.unlock()
        }
    }

    /// Nonblocking, latest-pending-value-wins, completion exactly once on main.
    /// An executing write completes with measured readback while newer values
    /// coalesce behind it, so continuous movement still gets measured feedback.
    /// restoringMute overrides the ordinary mute-at-zero policy for undo. A
    /// restored muted level is muted and verified before changing its scalar.
    func requestVolume(_ value: Float, muteAtZero: Bool = true,
                       restoringMute: Bool? = nil,
                       expectedTargetIdentifier: String? = nil,
                       cancellationScope: UUID? = nil,
                       completion: @escaping (VolumeRequestResult) -> Void) {
        guard value.isFinite else { DispatchQueue.main.async { completion(.failed) }; return }
        enqueue(.volume(min(1, max(0, value)), muteAtZero, restoringMute),
                target: expectedTargetIdentifier ?? targetIdentifier, scope: cancellationScope, completion: completion)
    }

    func requestMuted(_ muted: Bool, expectedTargetIdentifier: String? = nil, cancellationScope: UUID? = nil,
                      completion: @escaping (VolumeRequestResult) -> Void) {
        enqueue(.mute(muted), target: expectedTargetIdentifier ?? targetIdentifier, scope: cancellationScope, completion: completion)
    }

    func cancelPendingRequests() {
        requestLock.lock()
        cancellationEpoch &+= 1
        let discarded = pending
        pending = nil
        requestLock.unlock()
        if let discarded { finish(discarded, with: .cancelled) }
    }

    /// Cancel a completed-contact gesture's trailing write without touching a
    /// later manual slider request. Use a fresh UUID for each gesture session.
    func cancelPendingRequests(in scope: UUID) {
        requestLock.lock()
        if scopeRequestCounts[scope] != nil { cancelledScopes.insert(scope) }
        let discarded = pending?.scope == scope ? pending : nil
        if discarded != nil { pending = nil }
        requestLock.unlock()
        if let discarded { finish(discarded, with: .cancelled) }
    }

    private func enqueue(_ change: Change, target: String?, scope: UUID?, completion: @escaping (VolumeRequestResult) -> Void) {
        requestLock.lock()
        let discarded = pending
        pending = Request(epoch: cancellationEpoch, scope: scope, target: target, change: change, completion: completion)
        if let scope { scopeRequestCounts[scope, default: 0] += 1 }
        let needsDrain = !drainScheduled
        drainScheduled = true
        requestLock.unlock()
        if let discarded { finish(discarded, with: .cancelled) }
        if needsDrain { worker.async { [weak self] in self?.drainNext() } }
    }

    private func isCurrent(_ request: Request) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return cancellationEpoch == request.epoch
            && request.scope.map { !cancelledScopes.contains($0) } != false
    }

    private func drainNext() {
        requestLock.lock()
        let request = pending
        pending = nil
        if request == nil { drainScheduled = false }
        requestLock.unlock()
        guard let request else { return }
        let result = apply(request.change, expectedTarget: request.target,
            isCurrent: { [weak self] in self?.isCurrent(request) == true })
        finish(request, with: result)
        // Yield to queued HAL notifications between writes during long gestures.
        worker.async { [weak self] in self?.drainNext() }
    }

    private func finish(_ request: Request, with result: VolumeRequestResult) {
        DispatchQueue.main.async { [weak self] in
            let current = self?.isCurrent(request) == true
            request.completion(current ? result : .cancelled)
            guard let self, let scope = request.scope else { return }
            self.requestLock.lock()
            let remaining = (self.scopeRequestCounts[scope] ?? 1) - 1
            if remaining == 0 {
                self.scopeRequestCounts.removeValue(forKey: scope)
                self.cancelledScopes.remove(scope)
            } else { self.scopeRequestCounts[scope] = remaining }
            self.requestLock.unlock()
        }
    }

    /// Legacy compatibility. UI/gesture code should use the asynchronous API.
    @discardableResult
    func setVolumeDirectly(_ value: Float, muteAtZero: Bool = true) -> Bool {
        guard value.isFinite else { return false }
        let target = targetIdentifier
        cancelPendingRequests()
        let result = applySynchronously(.volume(min(1, max(0, value)), muteAtZero, nil), target: target)
        if case .applied = result { return true }
        return false
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        let target = targetIdentifier
        cancelPendingRequests()
        let result = applySynchronously(.mute(muted), target: target)
        if case .applied = result { return true }
        return false
    }

    private func applySynchronously(_ change: Change, target: String?) -> VolumeRequestResult {
        let result = SynchronousResult()
        // DispatchQueue.sync may execute on its caller's thread. Use an async
        // bridge here so even this compatibility API keeps driver IO off main.
        worker.async {
            result.value = self.apply(change, expectedTarget: target, isCurrent: { true })
            result.completed.signal()
        }
        result.completed.wait()
        return result.value
    }

    private func apply(_ change: Change, expectedTarget: String?, isCurrent: () -> Bool) -> VolumeRequestResult {
        guard isCurrent() else { return .cancelled }
        // Route notification may be behind this block. Check the cheap token,
        // never rediscover channel topology or settable flags per touch frame.
        let liveToken = backend.currentOutput()
        if liveToken != route?.token { reloadRoute(token: liveToken) }
        guard let route, expectedTarget == route.token.identifier, isCurrent() else { return .cancelled }
        var succeeded = true
        var expectedMute: Bool?
        switch change {
        case let .volume(value, muteAtZero, restoringMute):
            guard route.volumeWritable, !route.volumeElements.isEmpty else { return .failed }
            if restoringMute == true {
                // Undo must never briefly unmute a saved muted level. Some
                // drivers accept a mute write without applying it, so verify
                // the silence before touching the scalar as well as afterward.
                guard writeMute(true, route: route, required: true, isCurrent: isCurrent),
                      verifyMute(true, route: route) else {
                    refreshState()
                    return isCurrent() ? .failed : .cancelled
                }
            }
            for element in route.volumeElements {
                guard isCurrent() else { refreshState(); return .cancelled }
                if measuredVolumes[element].map({ abs($0 - value) < 0.0001 }) == true { continue }
                if !backend.setVolume(value, device: route.token.device, element: element) { succeeded = false }
            }
            if let restoringMute {
                expectedMute = restoringMute
                succeeded = writeMute(restoringMute, route: route, required: restoringMute, isCurrent: isCurrent) && succeeded
            } else if !preservesMuteOnGain && (value > 0 || muteAtZero) {
                if !route.muteElements.isEmpty { expectedMute = value == 0 }
                succeeded = writeMute(value == 0, route: route, required: false, isCurrent: isCurrent) && succeeded
            }
        case let .mute(muted):
            guard route.muteWritable, !route.muteElements.isEmpty else { return .failed }
            expectedMute = muted
            succeeded = writeMute(muted, route: route, required: true, isCurrent: isCurrent)
        }
        // Drivers may quantize. Read once per transaction, not per getter.
        refreshState()
        let measured = readSnapshot()
        guard isCurrent() else { return .cancelled }
        guard backend.currentOutput() == route.token else { reloadRoute(); return .cancelled }
        guard succeeded, measured.targetIdentifier == route.token.identifier else { return .failed }
        if let expectedMute,
           measuredMutes.count != route.muteElements.count || !measuredMutes.values.allSatisfy({ $0 == expectedMute }) {
            return .failed
        }
        // A fixed-volume output can still have an independent mute control.
        if case .volume = change, measured.volume == nil { return .failed }
        let value = measured.volume ?? 0
        return .applied(value: value, muted: measured.isMuted, targetIdentifier: route.token.identifier)
    }

    private func writeMute(_ muted: Bool, route: AudioOutputConfiguration, required: Bool,
                           isCurrent: () -> Bool) -> Bool {
        // Scalar-only outputs need no hardware mute; zero is already silent.
        guard !route.muteElements.isEmpty else { return !required }
        var succeeded = true
        for element in route.muteElements {
            guard isCurrent() else { return false }
            if measuredMutes[element] == muted { continue }
            guard route.muteWritable else { succeeded = false; continue }
            if !backend.setMute(muted, device: route.token.device, element: element) { succeeded = false }
        }
        return succeeded
    }

    private func verifyMute(_ expected: Bool, route: AudioOutputConfiguration) -> Bool {
        guard !route.muteElements.isEmpty else { return false }
        var verified = true
        for element in route.muteElements {
            let measured = backend.mute(device: route.token.device, element: element)
            measuredMutes[element] = measured
            if measured != expected { verified = false }
        }
        return verified
    }

    private func reloadRoute() { reloadRoute(token: backend.currentOutput()) }
    private func reloadRoute(token: AudioOutputToken?) {
        if route?.token != token { cancelPendingRequests() }
        route = token.map { backend.configuration(for: $0) }
        backend.observe(route)
        refreshState()
    }

    private func scheduleStateRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        worker.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshState()
        }
    }

    private func refreshState() {
        measuredVolumes.removeAll(keepingCapacity: true)
        measuredMutes.removeAll(keepingCapacity: true)
        var next = AudioOutputSnapshot()
        if let route {
            next.targetIdentifier = route.token.identifier
            next.uid = route.uid
            next.name = route.name
            for element in route.volumeElements {
                if let value = backend.volume(device: route.token.device, element: element),
                   value.isFinite, (0...1).contains(value) { measuredVolumes[element] = value }
            }
            for element in route.muteElements {
                if let muted = backend.mute(device: route.token.device, element: element) { measuredMutes[element] = muted }
            }
            if !route.volumeElements.isEmpty, measuredVolumes.count == route.volumeElements.count {
                next.volume = measuredVolumes.values.reduce(0, +) / Float(measuredVolumes.count)
                next.isAvailable = route.volumeWritable
            }
            let readableMute = !route.muteElements.isEmpty && measuredMutes.count == route.muteElements.count
            next.isMuted = readableMute && measuredMutes.values.allSatisfy { $0 }
            next.supportsMute = readableMute && route.muteWritable
        }
        stateLock.lock()
        let changed = snapshot != next
        snapshot = next
        stateLock.unlock()
        if changed {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: self.notification, object: self)
            }
        }
    }

    #if SWAY_AUDIO_TESTS
    func flushWorkerForTesting() { worker.sync {} }
    var activeScopeCountForTesting: Int {
        requestLock.lock(); defer { requestLock.unlock() }
        return scopeRequestCounts.count
    }
    #endif
}

private final class CoreAudioOutputBackend: AudioOutputBackend {
    private let input: Bool
    init(input: Bool = false) { self.input = input }
    private var defaultSelector: AudioObjectPropertySelector {
        input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var queue: DispatchQueue?
    private var handler: ((AudioBackendEvent) -> Void)?
    private var systemListener: Listener?
    private var deviceListener: Listener?

    func start(on queue: DispatchQueue, handler: @escaping (AudioBackendEvent) -> Void) {
        self.queue = queue
        self.handler = handler
        systemListener = addListener(object: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObjectPropertyAddress(mSelector: defaultSelector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)) { [weak self] _, _ in
                    self?.handler?(.route)
                }
    }

    func stop() {
        removeListener(&deviceListener)
        removeListener(&systemListener)
        handler = nil
    }

    func currentOutput() -> AudioOutputToken? {
        var device = AudioDeviceID(kAudioDeviceUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: defaultSelector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &device) == noErr, device != kAudioDeviceUnknown else { return nil }
        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = property(kAudioDevicePropertyDataSource, element: kAudioObjectPropertyElementMain)
        let hasSource = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr
        return AudioOutputToken(device: device, source: hasSource ? source : nil)
    }

    func configuration(for token: AudioOutputToken) -> AudioOutputConfiguration {
        let device = token.device
        let stereo = stereoChannels(device: device)
        let volumes: [AudioObjectPropertyElement] = volume(device: device, element: kAudioObjectPropertyElementMain) != nil
            ? [kAudioObjectPropertyElementMain] : stereo.filter { volume(device: device, element: $0) != nil }
        var mainMute = property(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        let mutes: [AudioObjectPropertyElement] = AudioObjectHasProperty(device, &mainMute)
            ? [kAudioObjectPropertyElementMain] : stereo.filter {
                var address = property(kAudioDevicePropertyMute, element: $0)
                return AudioObjectHasProperty(device, &address)
            }
        return AudioOutputConfiguration(token: token, name: deviceName(device), volumeElements: volumes,
            volumeWritable: !volumes.isEmpty && volumes.allSatisfy {
                isSettable(device: device, selector: kAudioDevicePropertyVolumeScalar, element: $0)
            }, muteElements: mutes, muteWritable: !mutes.isEmpty && mutes.allSatisfy {
                isSettable(device: device, selector: kAudioDevicePropertyMute, element: $0)
            }, uid: deviceUID(device))
    }

    func observe(_ configuration: AudioOutputConfiguration?) {
        removeListener(&deviceListener)
        guard let configuration else { return }
        // Wildcards also discover topology changes; unrelated activity ignored.
        let address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertySelectorWildcard,
            mScope: kAudioObjectPropertyScopeWildcard, mElement: kAudioObjectPropertyElementWildcard)
        deviceListener = addListener(object: configuration.token.device, address: address) { [weak self] count, addresses in
            var stateChanged = false
            for index in 0..<Int(count) {
                switch addresses[index].mSelector {
                case kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute, kAudioDevicePropertyVolumeDecibels:
                    stateChanged = true
                case kAudioObjectPropertyName, kAudioDevicePropertyDeviceIsAlive,
                     kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyControlList,
                     kAudioDevicePropertyDataSource, kAudioDevicePropertyStreamConfiguration:
                    self?.handler?(.route)
                    return
                default: break
                }
            }
            if stateChanged { self?.handler?(.state) }
        }
    }

    private func addListener(object: AudioObjectID, address: AudioObjectPropertyAddress,
                             block: @escaping AudioObjectPropertyListenerBlock) -> Listener? {
        guard let queue else { return nil }
        var address = address
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    private func removeListener(_ listener: inout Listener?) {
        guard var registered = listener else { return }
        AudioObjectRemovePropertyListenerBlock(registered.object, &registered.address, queue, registered.block)
        listener = nil
    }

    private func property(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func deviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "Audio output" }
        return name.takeRetainedValue() as String
    }

    private func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private func isSettable(device: AudioDeviceID, selector: AudioObjectPropertySelector,
                            element: AudioObjectPropertyElement) -> Bool {
        var address = property(selector, element: element)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func stereoChannels(device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = property(kAudioDevicePropertyPreferredChannelsForStereo, element: kAudioObjectPropertyElementMain)
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels) != noErr { return [1, 2] }
        return Array(Set(channels.filter { $0 != kAudioObjectPropertyElementMain })).sorted()
    }

    func volume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var address = property(kAudioDevicePropertyVolumeScalar, element: element)
        var size = UInt32(MemoryLayout<Float>.size)
        var value: Float = 0
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    func mute(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        var address = property(kAudioDevicePropertyMute, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    func setVolume(_ value: Float, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var value = value
        var address = property(kAudioDevicePropertyVolumeScalar, element: element)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr
    }

    func setMute(_ value: Bool, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var scalar: UInt32 = value ? 1 : 0
        var address = property(kAudioDevicePropertyMute, element: element)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &scalar) == noErr
    }
}

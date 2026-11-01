import AppKit
import CoreAudio

enum AppVolumeResult: Equatable { case applied(Float), failed(String), cancelled }

/// How one app should sound: its gain (above 1 boosts, through a soft limiter)
/// and where it plays (`nil` follows the default output).
struct AppMix: Equatable {
    var gain: Float
    var route: String? = nil
    /// Neutral apps are never tapped: they play on their normal path.
    var isNeutral: Bool { gain == 1 && route == nil }
}

/// Per-app output gain and routing through Core Audio process taps (macOS 14.2+).
///
/// A private tap mutes the app's processes on their normal path only while Sway
/// reads the tap, and a private aggregate device plays the same audio, scaled,
/// to the default output. Sway never records, stores, or transmits audio: each
/// sample lives for one real-time IO cycle. Private taps and aggregates belong
/// to this process, so if Sway quits or crashes macOS destroys them and every
/// app's audio returns to its normal path on its own.
///
/// Serial-worker HAL IO, latest-pending-value-wins per app, completion exactly
/// once on main, lock-protected cheap reads. System listeners exist only while
/// a tap does; there are no timers and no polling. The mixer drives several
/// apps at once (solo, call ducking), so each app keeps its own pending request.
final class AppVolumeController {
    static let shared = AppVolumeController()

    /// True on macOS 14.2+ where process taps exist.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private let worker = DispatchQueue(label: "com.sway.app-volume", qos: .userInteractive)
    private let events = DispatchQueue(label: "com.sway.app-volume.events", qos: .userInteractive)
    private let stateLock = NSLock()
    private var gains: [String: Float] = [:]
    private var routes: [String: String] = [:]

    /// Gain changes glide at most this much per sample (a full fade takes about
    /// a quarter of a second), so mute, solo and call ducking never click.
    static let maximumGainStepPerSample: Float = 1 / 12_000
    /// The highest gain the mixer may ask for when boost is on.
    static let boostLimit: Float = 1.5

    private struct Request {
        let epoch: UInt64
        let mix: AppMix
        let bundleID: String
        let completion: (AppVolumeResult) -> Void
    }
    private let requestLock = NSLock()
    private var cancellationEpoch: UInt64 = 0
    private var pending: [String: Request] = [:]
    private var pendingOrder: [String] = []
    private var drainScheduled = false
    private var resetRequested = false

    private struct AudioClient { let bundleID: String?; let pid: pid_t; let responsiblePID: pid_t? }
    private struct Listener { var address: AudioObjectPropertyAddress; let block: AudioObjectPropertyListenerBlock }
    private enum Outcome { case built(Tap), failed(String) }
    // Worker-only state.
    private var taps: [String: Tap] = [:]
    private var clients: [AudioObjectID: AudioClient] = [:]
    private var listeners: [Listener] = []
    private var processRefreshScheduled = false

    private init() {}

    /// Cheap, lock-protected snapshot. 1.0 when the app is not tapped.
    func gain(for bundleID: String) -> Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return gains[bundleID] ?? 1
    }

    /// The output an app was moved to, or nil when it follows the default.
    func route(for bundleID: String) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return routes[bundleID]
    }

    /// Latest-wins per app, nonblocking. Completion exactly once on main. gain
    /// is clamped to 0...1; NaN fails. Reaching 1.0 (with no route) removes the
    /// tap and aggregate so the app's audio returns to its normal path. A
    /// failure is never cached: each request rediscovers the app's processes.
    func requestGain(_ gain: Float, for bundleID: String, completion: @escaping (AppVolumeResult) -> Void) {
        requestMix(AppMix(gain: gain, route: route(for: bundleID)), for: bundleID, completion: completion)
    }

    /// Like `requestGain`, also choosing where the app plays. `maximumGain`
    /// above 1 allows boost (the mixer passes `boostLimit` when it's on).
    func requestMix(_ mix: AppMix, for bundleID: String, maximumGain: Float = 1, completion: @escaping (AppVolumeResult) -> Void) {
        guard Self.isSupported, let gain = Self.clampedGain(mix.gain, maximum: maximumGain),
              !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else {
            let message = !Self.isSupported ? "Per-app volume needs macOS 14.2 or later."
                : mix.gain.isNaN ? "That volume level isn't valid." : "Sway can't change this app's volume."
            DispatchQueue.main.async { completion(.failed(message)) }
            return
        }
        requestLock.lock()
        let discarded = pending[bundleID]
        pending[bundleID] = Request(epoch: cancellationEpoch, mix: AppMix(gain: gain, route: mix.route), bundleID: bundleID, completion: completion)
        if discarded == nil { pendingOrder.append(bundleID) }
        let needsDrain = !drainScheduled
        drainScheduled = true
        requestLock.unlock()
        if let discarded { finish(discarded, with: .cancelled) }
        if needsDrain { worker.async { [weak self] in self?.drainNext() } }
    }

    /// Tear down every tap/aggregate and forget gains (quit, feature off).
    /// Requests made after this call run after the teardown.
    func resetAll() {
        requestLock.lock()
        cancellationEpoch &+= 1
        let discarded = pendingOrder.compactMap { pending[$0] }
        pending.removeAll()
        pendingOrder.removeAll()
        resetRequested = true
        let needsDrain = !drainScheduled
        drainScheduled = true
        requestLock.unlock()
        discarded.forEach { finish($0, with: .cancelled) }
        if needsDrain { worker.async { [weak self] in self?.drainNext() } }
    }

    // MARK: Pure rules (covered by Tests/app_volume_regressions.swift)

    /// nil for NaN; infinities clamp like any other out-of-range value.
    static func clampedGain(_ value: Float, maximum: Float = 1) -> Float? {
        value.isNaN ? nil : min(max(1, min(maximum, boostLimit)), max(0, value))
    }

    /// `com.google.Chrome` owns itself and `com.google.Chrome.helper…`, never
    /// `com.google.ChromeCanary`. Bundle IDs compare case-insensitively.
    static func processBundleID(_ processBundleID: String, belongsTo appBundleID: String) -> Bool {
        let process = processBundleID.lowercased(), app = appBundleID.lowercased()
        guard !app.isEmpty, !process.isEmpty else { return false }
        return process == app || (process.count > app.count + 1 && process.hasPrefix(app + "."))
    }

    /// Bundle-ID ownership, plus processes macOS attributes to the app (Safari
    /// and other WebKit apps play media from a `com.apple.WebKit.GPU` XPC
    /// service whose responsible process is the app). Sway itself never matches,
    /// which would feed the aggregate's output back into its own tap.
    static func process(bundleID: String?, pid: pid_t, responsiblePID: pid_t?, belongsTo appBundleID: String,
                        appPIDs: Set<pid_t>, ownPID: pid_t) -> Bool {
        guard pid != ownPID else { return false }
        if let bundleID, processBundleID(bundleID, belongsTo: appBundleID) { return true }
        if pid > 0, appPIDs.contains(pid) { return true }
        return responsiblePID.map { $0 != ownPID && appPIDs.contains($0) } ?? false
    }

    // MARK: Queue

    private func isCurrent(_ request: Request) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return cancellationEpoch == request.epoch
    }

    private func drainNext() {
        requestLock.lock()
        let reset = resetRequested
        resetRequested = false
        let request = pendingOrder.isEmpty ? nil : pending.removeValue(forKey: pendingOrder.removeFirst())
        if request == nil { drainScheduled = false }
        requestLock.unlock()
        // Anything still pending was requested after the reset, so it runs after it.
        if reset, #available(macOS 14.2, *) { tearDownAll() }
        guard let request else { return }
        finish(request, with: apply(request))
        // Yield to queued HAL notifications between writes during long gestures.
        worker.async { [weak self] in self?.drainNext() }
    }

    private func finish(_ request: Request, with result: AppVolumeResult) {
        DispatchQueue.main.async { [weak self] in
            request.completion(self?.isCurrent(request) == true ? result : .cancelled)
        }
    }

    private func apply(_ request: Request) -> AppVolumeResult {
        guard isCurrent(request) else { return .cancelled }
        guard #available(macOS 14.2, *) else { return .failed("Per-app volume needs macOS 14.2 or later.") }
        return apply(request.mix, to: request.bundleID, isCurrent: { [weak self] in self?.isCurrent(request) == true })
    }

    @available(macOS 14.2, *)
    private func apply(_ mix: AppMix, to bundleID: String, isCurrent: () -> Bool) -> AppVolumeResult {
        let gain = mix.gain
        if let tap = taps[bundleID] {
            guard !mix.isNeutral else { remove(bundleID); return .applied(1) }
            if !tap.permissionConfirmed {
                switch AppVolumePermission.status() {
                case .granted: tap.permissionConfirmed = true
                case .undetermined: break
                case .denied:
                    // A denied tap delivers silence while still muting the app.
                    let name = Self.displayName(for: bundleID)
                    tearDownAll()
                    return .failed(Self.permissionMessage(name))
                }
            }
            if tap.route != mix.route {
                // Moving between outputs rebuilds only the aggregate; the tap stays.
                tap.route = mix.route
                guard let output = AppVolumeHAL.output(for: mix.route) else { remove(bundleID); return .failed("No audio output is available.") }
                if tap.outputUID != output.uid {
                    detach(tap)
                    if let message = attach(tap, to: output, name: Self.displayName(for: bundleID)) { remove(bundleID); return .failed(message) }
                }
            }
            tap.target.pointee = gain
            publish()
            return .applied(gain)
        }
        // Nothing to undo: an untapped app already plays at its normal level.
        guard !mix.isNeutral else { return .applied(1) }
        #if SWAY_APP_VOLUME_TESTS
        precondition(!Self.forbidsCoreAudioForTesting, "Regression tests must never reach Core Audio taps.")
        #endif
        let name = Self.displayName(for: bundleID)
        guard let output = AppVolumeHAL.output(for: mix.route) else { return .failed("No audio output is available.") }
        guard let objects = AppVolumeHAL.objectIDs(AudioObjectID(kAudioObjectSystemObject),
                                                   kAudioHardwarePropertyProcessObjectList) else {
            return .failed("Couldn't read which apps are playing audio.")
        }
        let processes = audioProcesses(for: bundleID, among: objects)
        guard !processes.isEmpty else { return .failed("\(name) isn't playing audio right now.") }
        // A mixdown tap would move audio the app sends to another device (a
        // call on a headset, say) onto the default output. Refuse instead,
        // unless the user chose where this app plays.
        guard mix.route != nil || !processes.contains(where: { AppVolumeHAL.outputDevices(of: $0).contains { $0 != output.device } }) else {
            return .failed("\(name) is playing to a different output. Per-app volume follows the default output.")
        }
        let permission = AppVolumePermission.status()
        guard permission != .denied else { return .failed(Self.permissionMessage(name)) }
        guard isCurrent() else { return .cancelled }
        switch makeTap(processes: processes, gain: gain, output: output, name: name, route: mix.route) {
        case let .failed(message): return .failed(message)
        case let .built(tap):
            tap.permissionConfirmed = permission == .granted
            taps[bundleID] = tap
            // Without the default-output listener a device switch could strand
            // the app's audio on the old output. Fail closed.
            guard observeSystem() else { remove(bundleID); return .failed(Self.failureMessage(name, kAudioHardwareUnspecifiedError)) }
            publish()
            return .applied(gain)
        }
    }

    // MARK: Taps

    private static func displayName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? "This app"
    }

    private static func permissionMessage(_ name: String) -> String {
        "Allow Sway in System Settings → Privacy & Security → Screen & System Audio Recording to change \(name)'s volume."
    }

    private static func failureMessage(_ name: String, _ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        let code = bytes.allSatisfy { (0x20...0x7E).contains($0) } ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(status)"
        return "Couldn't change \(name)'s volume (Core Audio error \(code))."
    }

    private func audioProcesses(for bundleID: String, among objects: [AudioObjectID]) -> [AudioObjectID] {
        let live = Set(objects)
        clients = clients.filter { live.contains($0.key) }
        let appPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        let ownPID = getpid()
        return objects.filter { object in
            let client = self.client(object)
            return Self.process(bundleID: client.bundleID, pid: client.pid, responsiblePID: client.responsiblePID,
                                belongsTo: bundleID, appPIDs: appPIDs, ownPID: ownPID)
        }
    }

    /// Process object IDs are never reused while listed, so identity is cached.
    private func client(_ object: AudioObjectID) -> AudioClient {
        if let cached = clients[object] { return cached }
        var pid: pid_t = -1
        if !AppVolumeHAL.read(object, AppVolumeHAL.address(kAudioProcessPropertyPID), into: &pid) { pid = -1 }
        let client = AudioClient(bundleID: AppVolumeHAL.string(object, kAudioProcessPropertyBundleID), pid: pid,
                                 responsiblePID: AppVolumeResponsibility.responsiblePID(for: pid))
        clients[object] = client
        return client
    }

    @available(macOS 14.2, *)
    private static func tapDescription(of processes: [AudioObjectID], uuid: UUID) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = uuid
        description.name = "Sway app volume"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        return description
    }

    @available(macOS 14.2, *)
    private func makeTap(processes: [AudioObjectID], gain: Float, output: AppVolumeHAL.Output, name: String, route: String?) -> Outcome {
        // Sway never records or stores audio. Tap samples are scaled and handed
        // straight back to the output device inside one IO cycle, then dropped.
        // macOS still asks for "System Audio Recording" (Info.plist key
        // NSAudioCaptureUsageDescription) because the same API can capture; the
        // prompt appears the first time the aggregate starts.
        let uuid = UUID()
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(Self.tapDescription(of: processes, uuid: uuid), &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            return .failed(status == kAudioDevicePermissionsError ? Self.permissionMessage(name) : Self.failureMessage(name, status))
        }
        let tap = Tap(tapID: tapID, uuid: uuid, processes: processes, gain: gain)
        tap.route = route
        var format = AudioStreamBasicDescription()
        guard AppVolumeHAL.read(tapID, AppVolumeHAL.address(kAudioTapPropertyFormat), into: &format),
              AppVolumeHAL.isFloat32PCM(format) else {
            destroy(tap)
            return .failed("\(name)'s audio format isn't supported.")
        }
        if let message = attach(tap, to: output, name: name) { destroy(tap); return .failed(message) }
        return .built(tap)
    }

    /// Builds and starts the aggregate for an existing tap. nil on success.
    private func attach(_ tap: Tap, to output: AppVolumeHAL.Output, name: String) -> String? {
        // Following the default output, the app plays to this same device, so
        // tap and output share a clock: drift compensation would only add
        // periodic sample slips (Bluetooth). A routed app crosses clocks.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sway App Volume",
            kAudioAggregateDeviceUIDKey: "com.sway.app-volume.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: tap.route != nil]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else { return Self.failureMessage(name, status) }
        tap.aggregate = aggregate
        tap.outputUID = output.uid
        let deviceInputs = AppVolumeHAL.streams(of: output.device, scope: kAudioObjectPropertyScopeInput).count
        guard let layout = waitForLayout(of: aggregate, deviceInputs: deviceInputs) else {
            detach(tap)
            return Self.failureMessage(name, kAudioHardwareNotRunningError)
        }
        // Real-time IO block: no locks, allocation, logging, or Objective-C.
        // It captures only raw pointers and integers owned by `tap`.
        let target = tap.target, rendered = tap.rendered, staging = tap.staging.unsafeMutablePointer
        let firstTapBuffer = layout.firstTapBuffer, capacity = Tap.stagingCapacity
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, tap.ioQueue) { _, input, _, output, _ in
            let start = rendered.pointee
            let end = AppVolumeMixer.glide(from: start, toward: target.pointee, frames: AppVolumeMixer.frames(in: output),
                                           maximumStep: AppVolumeController.maximumGainStepPerSample)
            let source = AppVolumeMixer.tapBuffers(in: input, from: firstTapBuffer, staging: staging, capacity: capacity)
            AppVolumeMixer.render(input: source, output: output, from: min(start, 1), to: min(end, 1))
            AppVolumeMixer.boost(output, from: max(start, 1), to: max(end, 1))
            rendered.pointee = end
        }
        guard status == noErr, let procID else { detach(tap); return Self.failureMessage(name, status) }
        tap.procID = procID
        Self.disableHardwareInputs(of: aggregate, procID: procID, layout: layout)
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { detach(tap); return Self.failureMessage(name, status) }
        return nil
    }

    private struct Layout { let firstTapBuffer: Int; let inputStreams: Int }

    /// Tap streams follow the sub-device's own input streams. Requires every
    /// IO buffer to be Float32 PCM, which is what AppVolumeMixer renders.
    private static func layout(of aggregate: AudioObjectID, deviceInputs: Int) -> Layout? {
        guard AppVolumeHAL.isAlive(aggregate) else { return nil }
        let inputs = AppVolumeHAL.streams(of: aggregate, scope: kAudioObjectPropertyScopeInput)
        let outputs = AppVolumeHAL.streams(of: aggregate, scope: kAudioObjectPropertyScopeOutput)
        guard (1...Tap.stagingCapacity).contains(inputs.count - deviceInputs), !outputs.isEmpty,
              (inputs[deviceInputs...] + outputs).allSatisfy({ AppVolumeHAL.virtualFormatIsFloat32($0) }) else { return nil }
        return Layout(firstTapBuffer: deviceInputs, inputStreams: inputs.count)
    }

    /// A new aggregate can publish its streams just after creation. Wait for
    /// its own change notifications, bounded at one second; never poll.
    private func waitForLayout(of aggregate: AudioObjectID, deviceInputs: Int) -> Layout? {
        if let layout = Self.layout(of: aggregate, deviceInputs: deviceInputs) { return layout }
        let changed = DispatchSemaphore(value: 0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertySelectorWildcard,
            mScope: kAudioObjectPropertyScopeWildcard, mElement: kAudioObjectPropertyElementWildcard)
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed.signal() }
        guard AudioObjectAddPropertyListenerBlock(aggregate, &address, events, block) == noErr else { return nil }
        defer { AudioObjectRemovePropertyListenerBlock(aggregate, &address, events, block) }
        let deadline = DispatchTime.now() + .seconds(1)
        repeat {
            if let layout = Self.layout(of: aggregate, deviceInputs: deviceInputs) { return layout }
        } while changed.wait(timeout: deadline) == .success
        return nil
    }

    /// Duplex outputs (USB headsets, interfaces) bring their microphone into
    /// the aggregate. Marking those streams unused keeps the HAL from opening
    /// the microphone at all. Best effort: the IO block never reads them.
    private static func disableHardwareInputs(of aggregate: AudioObjectID, procID: AudioDeviceIOProcID, layout: Layout) {
        guard layout.firstTapBuffer > 0,
              let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams),
              let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let size = flagsOffset + layout.inputStreams * MemoryLayout<UInt32>.stride
        let usage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { usage.deallocate() }
        usage.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        usage.storeBytes(of: UInt32(layout.inputStreams), toByteOffset: countOffset, as: UInt32.self)
        for stream in 0..<layout.inputStreams {
            usage.storeBytes(of: UInt32(stream < layout.firstTapBuffer ? 0 : 1),
                             toByteOffset: flagsOffset + stream * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        var address = AppVolumeHAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        _ = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), usage)
    }

    /// Stop device, then destroy IOProc, then the aggregate. The tap survives.
    private func detach(_ tap: Tap) {
        guard tap.aggregate != kAudioObjectUnknown else { return }
        if let procID = tap.procID {
            _ = AudioDeviceStop(tap.aggregate, procID)
            // If the IOProc can't be destroyed its block may still run, so its
            // buffers are deliberately leaked instead of freed under it.
            if AudioDeviceDestroyIOProcID(tap.aggregate, procID) != noErr { tap.buffersPinned = true }
            tap.procID = nil
        }
        _ = AudioHardwareDestroyAggregateDevice(tap.aggregate)
        tap.aggregate = AudioObjectID(kAudioObjectUnknown)
    }

    /// Full teardown: aggregate first, then the tap, then the gain memory.
    @available(macOS 14.2, *)
    private func destroy(_ tap: Tap) {
        detach(tap)
        _ = AudioHardwareDestroyProcessTap(tap.tapID)
        tap.releaseBuffers()
    }

    @available(macOS 14.2, *)
    private func remove(_ bundleID: String) {
        if let tap = taps.removeValue(forKey: bundleID) { destroy(tap) }
        publish()
        stopObservingIfIdle()
    }

    @available(macOS 14.2, *)
    private func tearDownAll() {
        let removed = taps
        taps.removeAll()
        for tap in removed.values { destroy(tap) }
        publish()
        stopObservingIfIdle()
    }

    private func publish() {
        var next: [String: Float] = [:], nextRoutes: [String: String] = [:]
        for (bundleID, tap) in taps {
            next[bundleID] = tap.target.pointee
            nextRoutes[bundleID] = tap.route
        }
        stateLock.lock()
        gains = next
        routes = nextRoutes
        stateLock.unlock()
    }

    // MARK: System changes

    /// Returns false when the default-output listener could not be added.
    private func observeSystem() -> Bool {
        guard listeners.isEmpty else { return true }
        let selectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList,
                         kAudioHardwarePropertyServiceRestarted, kAudioHardwarePropertyDevices]
        for selector in selectors {
            var address = AppVolumeHAL.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.systemChanged(selector) }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, worker, block) == noErr {
                listeners.append(Listener(address: address, block: block))
            } else if selector == kAudioHardwarePropertyDefaultOutputDevice {
                return false
            }
        }
        return true
    }

    private func stopObservingIfIdle() {
        guard taps.isEmpty else { return }
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listener.address, worker, listener.block)
        }
        listeners.removeAll()
        clients.removeAll()
    }

    /// Delivered on the worker, serialized with requests.
    private func systemChanged(_ selector: AudioObjectPropertySelector) {
        guard #available(macOS 14.2, *), !taps.isEmpty else { return }
        switch selector {
        case kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices: outputsChanged()
        case kAudioHardwarePropertyServiceRestarted:
            // Every HAL object we held is gone; destroy calls fail harmlessly.
            clients.removeAll()
            tearDownAll()
        default:
            guard !processRefreshScheduled else { return }
            processRefreshScheduled = true
            worker.async { [weak self] in
                guard let self else { return }
                self.processRefreshScheduled = false
                self.refreshTappedProcesses()
            }
        }
    }

    /// Rebuild aggregates whose output moved: the default changed, or a routed
    /// app's device came or went (it falls back to the default meanwhile). If
    /// that fails, destroy the tap so the app is never left muted on a route
    /// Sway cannot play.
    @available(macOS 14.2, *)
    private func outputsChanged() {
        guard AppVolumeHAL.defaultOutput() != nil else { tearDownAll(); return }
        for (bundleID, tap) in taps {
            guard let output = AppVolumeHAL.output(for: tap.route) else { remove(bundleID); continue }
            guard tap.outputUID != output.uid else { continue }
            detach(tap)
            if attach(tap, to: output, name: Self.displayName(for: bundleID)) != nil { remove(bundleID) }
        }
        publish()
    }

    /// Browsers start audio helpers on demand. Keep each tap's process set
    /// current so audio from a new helper is never left at full level, and
    /// drop the tap once the app has no audio processes left (it quit).
    @available(macOS 14.2, *)
    private func refreshTappedProcesses() {
        guard !taps.isEmpty, let objects = AppVolumeHAL.objectIDs(AudioObjectID(kAudioObjectSystemObject),
                                                                   kAudioHardwarePropertyProcessObjectList) else { return }
        for (bundleID, tap) in taps {
            let processes = audioProcesses(for: bundleID, among: objects)
            guard Set(processes) != Set(tap.processes) else { continue }
            guard !processes.isEmpty else { remove(bundleID); continue }
            if retarget(tap, to: processes) { continue }
            // The in-place update failed: rebuild with the same gain, or let go.
            let gain = tap.target.pointee, confirmed = tap.permissionConfirmed, route = tap.route
            remove(bundleID)
            guard let output = AppVolumeHAL.output(for: route) else { continue }
            if case let .built(fresh) = makeTap(processes: processes, gain: gain, output: output,
                                                name: Self.displayName(for: bundleID), route: route) {
                fresh.permissionConfirmed = confirmed
                taps[bundleID] = fresh
                if !observeSystem() { remove(bundleID) }
            }
        }
        publish()
    }

    @available(macOS 14.2, *)
    private func retarget(_ tap: Tap, to processes: [AudioObjectID]) -> Bool {
        var description = Self.tapDescription(of: processes, uuid: tap.uuid)
        var address = AppVolumeHAL.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectSetPropertyData(tap.tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr { tap.processes = processes }
        return status == noErr
    }

    #if SWAY_APP_VOLUME_TESTS
    static var forbidsCoreAudioForTesting = true
    func flushWorkerForTesting() { worker.sync {} }
    #endif

    /// One app's tap chain. Worker-owned, except the three buffers the IO block
    /// captures, which outlive the IOProc and are freed only after it is gone.
    private final class Tap {
        static let stagingCapacity = 2
        let tapID: AudioObjectID
        let uuid: UUID
        var processes: [AudioObjectID]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var outputUID = ""
        /// The device the user chose for this app; nil follows the default.
        var route: String?
        var permissionConfirmed = false
        var buffersPinned = false
        private var released = false
        let ioQueue = DispatchQueue(label: "com.sway.app-volume.io", qos: .userInteractive)
        /// Written only by the worker, read by the IO thread. Aligned 32-bit
        /// loads and stores are single instructions on arm64 and x86_64.
        let target: UnsafeMutablePointer<Float>
        /// IO thread only: the gain the previous cycle ended on, for gliding.
        let rendered: UnsafeMutablePointer<Float>
        /// IO thread only: the tap's buffers split from device input buffers.
        let staging: UnsafeMutableAudioBufferListPointer

        init(tapID: AudioObjectID, uuid: UUID, processes: [AudioObjectID], gain: Float) {
            self.tapID = tapID
            self.uuid = uuid
            self.processes = processes
            target = .allocate(capacity: 1)
            target.initialize(to: gain)
            // The app was at full level; the first cycle ramps down from there.
            rendered = .allocate(capacity: 1)
            rendered.initialize(to: 1)
            staging = AudioBufferList.allocate(maximumBuffers: Self.stagingCapacity)
        }

        func releaseBuffers() {
            guard !released, !buffersPinned else { return }
            released = true
            target.deallocate()
            rendered.deallocate()
            free(staging.unsafeMutablePointer)
        }
    }
}

/// Pure, allocation-free rendering helper so tests can cover channel/format
/// edge cases without Core Audio devices. Safe on the real-time IO thread: no
/// locks, allocation, Objective-C, or generic dispatch.
enum AppVolumeMixer {
    private struct Channel { let samples: UnsafeMutablePointer<Float>; let stride: Int; let frames: Int }

    static func clamp(_ gain: Float) -> Float { gain.isNaN ? 0 : min(1, max(0, gain)) }

    /// Where a cycle of `frames` samples ends when gliding from `start`
    /// toward `target` by at most `maximumStep` per sample. NaN never escapes.
    static func glide(from start: Float, toward target: Float, frames: Int, maximumStep: Float) -> Float {
        let safeStart = start.isNaN ? 0 : start, safeTarget = target.isNaN ? 0 : target
        let reach = maximumStep * Float(max(frames, 1))
        return safeTarget > safeStart ? min(safeTarget, safeStart + reach) : max(safeTarget, safeStart - reach)
    }

    /// Frames in the first audible output buffer (0 when there is none).
    static func frames(in output: UnsafeMutablePointer<AudioBufferList>) -> Int {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for index in 0..<outputs.count {
            let buffer = outputs[index]
            let channels = Int(buffer.mNumberChannels)
            if channels > 0, buffer.mData != nil { return Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels) }
        }
        return 0
    }

    /// Boost above full level, ramped like `render`, through a soft limiter
    /// so loud passages round off instead of crackling. A no-op at or below 1.
    static func boost(_ output: UnsafeMutablePointer<AudioBufferList>, from startGain: Float, to endGain: Float) {
        guard startGain > 1 || endGain > 1, !startGain.isNaN, !endGain.isNaN else { return }
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for index in 0..<outputs.count {
            let buffer = outputs[index]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let step = (endGain - startGain) / Float(frames)
            var frame = 0
            while frame < frames {
                let gain = frame == frames - 1 ? endGain : startGain + step * Float(frame + 1)
                var channel = 0
                while channel < channels {
                    let sample = frame * channels + channel
                    samples[sample] = softLimit(samples[sample] * gain)
                    channel += 1
                }
                frame += 1
            }
        }
    }

    /// Linear below 0.85, then a tanh knee that never exceeds 1.
    static func softLimit(_ x: Float) -> Float {
        let threshold: Float = 0.85, magnitude = abs(x)
        guard magnitude > threshold else { return x }
        let knee = 1 - threshold
        let shaped = threshold + knee * tanh((magnitude - threshold) / knee)
        return x < 0 ? -shaped : shaped
    }

    /// Copies tap input to device output with gain. Handles interleaved and
    /// non-interleaved Float32, differing channel counts (mono→stereo
    /// duplicate, stereo→mono average, extra output channels silenced),
    /// differing frame counts (copy the minimum, zero the rest), and empty/nil
    /// buffers (silence). NaN gain renders silence; others clamp to 0...1.
    static func render(input: UnsafePointer<AudioBufferList>?, output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        render(input: input, output: output, from: gain, to: gain)
    }

    /// Same as `render(input:output:gain:)`, ramping linearly across the cycle
    /// so gesture-rate gain steps don't click. The last frame reaches `endGain`.
    static func render(input: UnsafePointer<AudioBufferList>?, output: UnsafeMutablePointer<AudioBufferList>,
                       from startGain: Float, to endGain: Float) {
        let start = clamp(startGain), end = clamp(endGain)
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var inputs: UnsafeMutableAudioBufferListPointer?
        var inputChannels = 0
        if let input {
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            inputs = list
            inputChannels = channelCount(list)
        }
        let outputChannels = channelCount(outputs)
        var firstChannel = 0
        for index in 0..<outputs.count {
            let buffer = outputs[index]
            let channels = Int(buffer.mNumberChannels)
            defer { firstChannel += channels }
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            guard channels > 0, let inputs else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                let destination = Channel(samples: samples + channel, stride: channels, frames: frames)
                let target = firstChannel + channel
                if outputChannels == 1, inputChannels >= 2 {
                    guard let left = locate(0, in: inputs) else { continue }
                    if let right = locate(1, in: inputs) { average(left, right, into: destination, start, end) }
                    else { copy(left, into: destination, start, end) }
                } else if let source = sourceChannel(for: target, inputChannels: inputChannels),
                          let located = locate(source, in: inputs) {
                    copy(located, into: destination, start, end)
                }
            }
        }
    }

    /// Selects the tap's buffers from an aggregate's input list, where the
    /// sub-device's own input streams come first. nil when there are none.
    static func tapBuffers(in input: UnsafePointer<AudioBufferList>, from first: Int,
                           staging: UnsafeMutablePointer<AudioBufferList>, capacity: Int) -> UnsafePointer<AudioBufferList>? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let available = source.count - first
        guard first >= 0, available > 0, capacity > 0 else { return nil }
        if first == 0, available <= capacity { return input }
        let destination = UnsafeMutableAudioBufferListPointer(staging)
        destination.count = min(available, capacity)
        for index in 0..<destination.count { destination[index] = source[first + index] }
        return UnsafePointer(staging)
    }

    private static func sourceChannel(for target: Int, inputChannels: Int) -> Int? {
        if inputChannels == 1 { return target < 2 ? 0 : nil }
        return target < inputChannels ? target : nil
    }

    private static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var count = 0
        for index in 0..<list.count { count += Int(list[index].mNumberChannels) }
        return count
    }

    private static func locate(_ channel: Int, in list: UnsafeMutableAudioBufferListPointer) -> Channel? {
        var first = 0
        for index in 0..<list.count {
            let buffer = list[index]
            let channels = Int(buffer.mNumberChannels)
            if channel < first + channels {
                guard let data = buffer.mData else { return nil }
                return Channel(samples: data.assumingMemoryBound(to: Float.self) + (channel - first), stride: channels,
                               frames: Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            }
            first += channels
        }
        return nil
    }

    private static func copy(_ source: Channel, into destination: Channel, _ start: Float, _ end: Float) {
        let frames = min(source.frames, destination.frames)
        guard frames > 0 else { return }
        let step = (end - start) / Float(frames)
        var frame = 0
        while frame < frames {
            let gain = frame == frames - 1 ? end : start + step * Float(frame + 1)
            destination.samples[frame * destination.stride] = source.samples[frame * source.stride] * gain
            frame += 1
        }
    }

    private static func average(_ left: Channel, _ right: Channel, into destination: Channel, _ start: Float, _ end: Float) {
        let frames = min(left.frames, right.frames, destination.frames)
        guard frames > 0 else { return }
        let step = (end - start) / Float(frames)
        var frame = 0
        while frame < frames {
            let gain = (frame == frames - 1 ? end : start + step * Float(frame + 1)) * 0.5
            destination.samples[frame * destination.stride] =
                (left.samples[frame * left.stride] + right.samples[frame * right.stride]) * gain
            frame += 1
        }
    }
}

/// Small HAL property readers used only on the worker queue.
private enum AppVolumeHAL {
    struct Output { let device: AudioDeviceID; let uid: String }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Plain-data values only (IDs, PIDs, flags, stream descriptions).
    static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, into value: inout T) -> Bool {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr && Int(size) == MemoryLayout<T>.size
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func defaultOutput() -> Output? {
        var device = AudioDeviceID(kAudioDeviceUnknown)
        guard read(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), into: &device),
              device != kAudioDeviceUnknown, let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
        return Output(device: device, uid: uid)
    }

    /// The chosen device when it is present, otherwise the default output.
    static func output(for route: String?) -> Output? {
        if let route, let device = device(uid: route), isAlive(device), !streams(of: device, scope: kAudioObjectPropertyScopeOutput).isEmpty {
            return Output(device: device, uid: route)
        }
        return defaultOutput()
    }

    static func device(uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uidRef = uid as CFString
        var device = AudioDeviceID(kAudioDeviceUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uidRef) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        return status == noErr && device != kAudioDeviceUnknown ? device : nil
    }

    static func streams(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        objectIDs(device, kAudioDevicePropertyStreams, scope: scope) ?? []
    }

    static func outputDevices(of process: AudioObjectID) -> [AudioObjectID] {
        objectIDs(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) ?? []
    }

    static func isAlive(_ device: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        return read(device, address(kAudioDevicePropertyDeviceIsAlive), into: &alive) && alive != 0
    }

    static func virtualFormatIsFloat32(_ stream: AudioStreamID) -> Bool {
        var format = AudioStreamBasicDescription()
        return read(stream, address(kAudioStreamPropertyVirtualFormat), into: &format) && isFloat32PCM(format)
    }

    static func isFloat32PCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
    }
}

/// macOS has no public preflight for System Audio Recording, and a denied tap
/// returns noErr, delivers silence, and can leave the app muted. Like the other
/// private frameworks Sway loads, this is optional: if the symbol is missing the
/// answer is `.undetermined` and the documented path (prompt on first start)
/// still applies.
private enum AppVolumePermission {
    enum Status { case granted, denied, undetermined }
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private static let preflight: Preflight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    static func status() -> Status {
        switch preflight?("kTCCServiceAudioCapture" as CFString, nil) {
        case 0?: return .granted
        case 1?: return .denied
        default: return .undetermined
        }
    }
}

/// Maps XPC helpers (e.g. Safari's WebKit GPU process) to the app macOS holds
/// responsible for them. Optional private symbol: nil when unavailable, in
/// which case only bundle-ID ownership applies.
private enum AppVolumeResponsibility {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t
    private static let lookup: Lookup? = {
        // RTLD_DEFAULT is ((void *)-2) on Darwin.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard pid > 0, let lookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }
}

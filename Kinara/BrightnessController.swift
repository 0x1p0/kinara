import Foundation
import CoreGraphics

enum BrightnessRequestResult {
    case applied(value: Float, targetIdentifier: String)
    case failed
    case cancelled
}

/// The test implementation is entirely in memory: no display services or real
/// devices are opened while exercising queueing, cancellation and stale routes.
protocol BrightnessHardware: AnyObject {
    var canWrite: Bool { get }
    func activeDisplays() -> [CGDirectDisplayID]
    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool
    func isActive(_ display: CGDirectDisplayID) -> Bool
    func read(_ display: CGDirectDisplayID) -> Float?
    func write(_ value: Float, to display: CGDirectDisplayID) -> Bool
    func observeChanges(_ callback: @escaping () -> Void)
    /// Whether brightness can be read and written for this display.
    func isControllable(_ display: CGDirectDisplayID) -> Bool
    func displayUnderPointer() -> CGDirectDisplayID?
    func name(_ display: CGDirectDisplayID) -> String
}

/// Defaults keep in-memory test hardware built-in only, exactly as before.
extension BrightnessHardware {
    func isControllable(_ display: CGDirectDisplayID) -> Bool { isBuiltIn(display) }
    func displayUnderPointer() -> CGDirectDisplayID? { nil }
    func name(_ display: CGDirectDisplayID) -> String { isBuiltIn(display) ? "Built-in display" : "External display" }
}

/// Cached route and serial hardware work. UI/touch callbacks never wait on IO.
final class BrightnessController {
    static let shared = BrightnessController(backend: SystemBrightnessHardware())
    private let backend: BrightnessHardware
    private let queue = DispatchQueue(label: "Kinara.Display", qos: .userInteractive)
    static let minimumWriteInterval: TimeInterval = 1.0 / 60
    private let lock = NSLock()

    private struct State: Equatable {
        var display: CGDirectDisplayID?
        var generation: UInt64 = 0
        var value: Float = 0
        var available = false
        var externalConnected = false
        var name = "No active built-in display"
        var identifier: String? { display.map { "display:\($0):\(generation)" } }
    }
    private struct Request {
        let value: Float
        let target: String
        let epoch: UInt64
        let scope: UUID?
        let scopeEpoch: UInt64
        let completion: (BrightnessRequestResult) -> Void
    }
    private var state = State()
    private var pending: Request?
    private var workerScheduled = false
    private var refreshScheduled = false
    private var cancellationEpoch: UInt64 = 0
    private var scopeEpochs: [UUID: UInt64] = [:]
    private var scopeUseCounts: [UUID: Int] = [:]
    private var pointerPolicy = false

    init(backend: BrightnessHardware) {
        self.backend = backend
        backend.observeChanges { [weak self] in self?.refresh() }
        refresh()
    }

    private var snapshot: State { lock.lock(); defer { lock.unlock() }; return state }
    var isBuiltInDisplayActive: Bool { snapshot.display.map { backend.isBuiltIn($0) } ?? false }
    var targetIdentifier: String? { snapshot.identifier }
    var hasExternalDisplayConnected: Bool { snapshot.externalConnected }
    var isAvailable: Bool { snapshot.available }
    var deviceName: String { snapshot.name }
    /// The display that brightness currently targets, for extra dimming.
    var activeDisplay: CGDirectDisplayID? { snapshot.display }
    func getBrightness() -> Float { snapshot.value }

    /// Target the display under the pointer when it can be controlled.
    /// Applied on the next refresh, which every gesture performs first.
    var followsPointer: Bool {
        get { lock.lock(); defer { lock.unlock() }; return pointerPolicy }
        set { lock.lock(); pointerPolicy = newValue; lock.unlock(); refresh() }
    }

    /// A completion-bearing refresh is a fresh read barrier, used while gesture
    /// intent is being confirmed. It never returns a reused pre-gesture cache.
    /// Ordinary visibility/wake refreshes coalesce and never poll while hidden.
    func refresh(completion: ((BrightnessRequestResult) -> Void)? = nil) {
        if let completion {
            queue.async { [weak self] in
                guard let self else { DispatchQueue.main.async { completion(.cancelled) }; return }
                self.refreshRoute()
                let current = self.snapshot
                let result: BrightnessRequestResult
                if current.available, let target = current.identifier {
                    result = .applied(value: current.value, targetIdentifier: target)
                } else { result = .failed }
                DispatchQueue.main.async { completion(result) }
            }
            return
        }
        lock.lock()
        guard !refreshScheduled else { lock.unlock(); return }
        refreshScheduled = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshRoute()
            self.lock.lock(); self.refreshScheduled = false; self.lock.unlock()
        }
    }

    func requestBrightness(_ value: Float, expectedTargetIdentifier: String? = nil,
                           cancellationScope: UUID? = nil,
                           completion: @escaping (BrightnessRequestResult) -> Void) {
        lock.lock()
        guard value.isFinite, state.available, let target = state.identifier else {
            lock.unlock(); DispatchQueue.main.async { completion(.failed) }; return
        }
        guard expectedTargetIdentifier == nil || expectedTargetIdentifier == target else {
            lock.unlock(); DispatchQueue.main.async { completion(.cancelled) }; return
        }
        let replaced = pending
        let scopeEpoch = cancellationScope.flatMap { scopeEpochs[$0] } ?? 0
        if let scope = cancellationScope {
            scopeEpochs[scope] = scopeEpoch
            scopeUseCounts[scope, default: 0] += 1
        }
        pending = Request(value: min(1, max(0, value)), target: target,
                          epoch: cancellationEpoch, scope: cancellationScope, scopeEpoch: scopeEpoch,
                          completion: completion)
        let schedule = !workerScheduled
        workerScheduled = true
        lock.unlock()
        if let replaced { finish(replaced, result: .cancelled) }
        if schedule { queue.async { [weak self] in self?.processNext() } }
    }

    func cancelPendingRequests() {
        lock.lock()
        cancellationEpoch &+= 1
        let cancelled = pending
        pending = nil
        lock.unlock()
        if let cancelled { finish(cancelled, result: .cancelled) }
    }

    /// Gesture ownership outlives physical lift until its last request settles.
    /// Cancelling that gesture must not cancel a newer manual slider request.
    func cancelPendingRequests(in scope: UUID) {
        lock.lock()
        if scopeUseCounts[scope] != nil { scopeEpochs[scope, default: 0] &+= 1 }
        let cancelled = pending?.scope == scope ? pending : nil
        if cancelled != nil { pending = nil }
        lock.unlock()
        if let cancelled { finish(cancelled, result: .cancelled) }
    }

    private func isCurrent(_ epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return cancellationEpoch == epoch
    }

    private func isCurrent(_ request: Request) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancellationEpoch == request.epoch &&
            (request.scope.map { scopeEpochs[$0] == request.scopeEpoch } ?? true)
    }

    private func finish(_ request: Request, result: BrightnessRequestResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { request.completion(.cancelled); return }
            let current = self.isCurrent(request) && self.targetIdentifier == request.target
            request.completion(current ? result : .cancelled)
            if let scope = request.scope {
                self.lock.lock()
                if let count = self.scopeUseCounts[scope], count > 1 { self.scopeUseCounts[scope] = count - 1 }
                else { self.scopeUseCounts[scope] = nil; self.scopeEpochs[scope] = nil }
                self.lock.unlock()
            }
        }
    }

    private func processNext() {
        lock.lock()
        let request = pending
        pending = nil
        lock.unlock()
        if let request {
            let result = write(request.value, target: request.target, isCurrent: { self.isCurrent(request) })
            finish(request, result: result)
        }
        lock.lock()
        let again = pending != nil
        workerScheduled = again
        lock.unlock()
        // Pace writes during long gestures so a slide never floods the system with
        // display changes (newest value wins, the last one always lands).
        if again { queue.asyncAfter(deadline: .now() + Self.minimumWriteInterval) { [weak self] in self?.processNext() } }
    }

    private func write(_ value: Float, target: String, isCurrent: () -> Bool) -> BrightnessRequestResult {
        guard isCurrent() else { return .cancelled }
        var current = snapshot
        guard current.identifier == target, let display = current.display,
              backend.isActive(display), backend.isControllable(display) else {
            refreshRoute()
            return .cancelled
        }
        guard backend.canWrite, isCurrent() else { return .cancelled }
        if abs(current.value - value) > 0.0005, !backend.write(value, to: display) {
            refreshRoute()
            return .failed
        }
        // An executing hardware call cannot be retracted. Reconcile readback,
        // but suppress success if the gesture was cancelled while IO finished.
        guard let measured = validBrightness(for: display) else { refreshRoute(); return .failed }
        guard backend.isActive(display), backend.isControllable(display), snapshot.identifier == target else {
            refreshRoute()
            return .cancelled
        }
        current.value = measured
        publish(current)
        guard isCurrent() else { return .cancelled }
        return .applied(value: measured, targetIdentifier: target)
    }

    /// Compatibility entry point. UI and gesture paths use requestBrightness.
    @discardableResult
    func setBrightness(_ value: Float) -> Bool {
        guard value.isFinite, let target = targetIdentifier else { return false }
        cancelPendingRequests()
        lock.lock(); let epoch = cancellationEpoch; lock.unlock()
        return queue.sync {
            if case .applied = write(min(1, max(0, value)), target: target, isCurrent: { self.isCurrent(epoch) }) { return true }
            return false
        }
    }

    /// The pointer's display when allowed and controllable, else the built-in
    /// display, else (lid closed) the first controllable external display.
    private func chooseDisplay(among displays: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        if followsPointer, let pointer = backend.displayUnderPointer(), displays.contains(pointer),
           backend.isControllable(pointer) { return pointer }
        if let builtIn = displays.first(where: { backend.isBuiltIn($0) }) { return builtIn }
        return displays.first { backend.isControllable($0) }
    }

    private func refreshRoute() {
        let displays = backend.activeDisplays()
        var next = snapshot
        let display = chooseDisplay(among: displays)
        if next.display != display { next.generation &+= 1 }
        next.display = display
        next.name = display.map { backend.name($0) } ?? "No active built-in display"
        next.externalConnected = displays.contains { !backend.isBuiltIn($0) }
        let value = display.flatMap { validBrightness(for: $0) }
        next.available = value != nil && backend.canWrite
        next.value = value ?? 0
        publish(next)
    }

    private func publish(_ next: State) {
        lock.lock()
        let changed = state != next
        state = next
        lock.unlock()
        if changed {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .kinaraDisplayStateChanged, object: nil) }
        }
    }

    private func validBrightness(for display: CGDirectDisplayID) -> Float? {
        guard let value = backend.read(display), value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
}

private final class SystemBrightnessHardware: BrightnessHardware {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let readBrightness: GetBrightness?
    private let writeBrightness: SetBrightness?
    private var changed: (() -> Void)?
    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard !flags.contains(.beginConfigurationFlag), let context else { return }
        ExternalDisplayDDC.shared.invalidate()
        Unmanaged<SystemBrightnessHardware>.fromOpaque(context).takeUnretainedValue().changed?()
    }

    init() {
        // Explicit-display ABI used by MonitorControl's Support/Bridging-Header.h.
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW | RTLD_LOCAL)
        library = handle
        readBrightness = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightness.self) }
        writeBrightness = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightness.self) }
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Per-display capability is decided by isControllable: DDC monitors can
    /// be written even if DisplayServices is missing.
    var canWrite: Bool { true }
    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(display) != 0 }

    /// Apple displays answer DisplayServices; other monitors may speak DDC/CI.
    private func usesDisplayServices(_ display: CGDirectDisplayID) -> Bool {
        guard let readBrightness else { return false }
        var value: Float = 0
        return readBrightness(display, &value) == 0 && value.isFinite
    }
    func isControllable(_ display: CGDirectDisplayID) -> Bool {
        if isBuiltIn(display) { return writeBrightness != nil && usesDisplayServices(display) }
        return (writeBrightness != nil && usesDisplayServices(display)) || ExternalDisplayDDC.shared.supports(display)
    }
    func displayUnderPointer() -> CGDirectDisplayID? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var display = CGDirectDisplayID(0)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }
    // NSScreen names are main-thread data; the UI resolves friendly names.
    func name(_ display: CGDirectDisplayID) -> String { isBuiltIn(display) ? "Built-in display" : "External display" }
    func isActive(_ display: CGDirectDisplayID) -> Bool { CGDisplayIsActive(display) != 0 }
    func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
    func read(_ display: CGDirectDisplayID) -> Float? {
        if let readBrightness {
            var value: Float = 0
            if readBrightness(display, &value) == 0 { return value }
        }
        return isBuiltIn(display) ? nil : ExternalDisplayDDC.shared.readBrightness(display)
    }
    func write(_ value: Float, to display: CGDirectDisplayID) -> Bool {
        if let writeBrightness, isBuiltIn(display) || usesDisplayServices(display) {
            return writeBrightness(display, value) == 0
        }
        return !isBuiltIn(display) && ExternalDisplayDDC.shared.writeBrightness(value, to: display)
    }
    func observeChanges(_ callback: @escaping () -> Void) {
        changed = callback
        CGDisplayRegisterReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
    }
}

extension Notification.Name {
    static let kinaraDisplayStateChanged = Notification.Name("kinaraDisplayStateChanged")
}

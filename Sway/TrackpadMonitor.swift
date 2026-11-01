import Foundation
import AppKit
import Combine

private let trackpadFrames = GestureFrameInbox()

final class TrackpadMonitor: ObservableObject {
    static let shared = TrackpadMonitor()
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Paused"

    private let settings = TrackpadSettings.shared
    private var recognizer = EdgeGestureRecognizer()
    private var taps = EdgeTapRecognizer()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Exists only while a one-finger gesture holds the pointer, so ordinary
    /// mouse movement never wakes Sway.
    private var freezeTap: CFMachPort?
    private var freezeSource: CFRunLoopSource?
    /// The clipboard picker holds the pointer while one finger scrolls it.
    private var pointerHeldForPicker = false
    private var generation: UInt64 = 0
    private var outputRevision: UInt64 = 0
    private var activeValue: RelativeGestureValue?
    private var activeAction: ZoneAction = .disabled
    private var activeBinding = EdgeBinding(.disabled)
    private var activeTarget: String?
    private var activeApplication: pid_t?
    private var activeAppBundleID: String?
    private var commandStepper = GestureActionStepper()
    private var haptics = GestureHapticFeedback()
    private var lastFrameTime = 0.0
    private var lastContactCount = 0
    private var cursorFreezeActive = false
    private var frozenCursorPosition = CGPoint.zero
    private var scrollCapture = GestureScrollCapture()
    private var inputWatchdog: Timer?
    private var cachedConfiguration = GestureConfiguration()
    private var cachedTapConfiguration = TapConfiguration()
    private var configurationIsDirty = true
    private var settingsObserver: AnyCancellable?
    private var brightnessPreparationGeneration: UInt64 = 0
    private var brightnessPreparationStarted = false
    private var brightnessBaseline: (value: Float, target: String)?
    private var seekPreparationStarted = false
    private var seekBaseline: NowPlayingInfo?
    /// One binding per touch sequence, resolved from the region, finger
    /// count, ⌥, frontmost app and docking state at the moment it began.
    private var gestureBinding: (region: GestureRegion, fingers: Int, binding: EdgeBinding, available: Bool)?
    private var fineEngaged = false
    private var levelChanged = false
    private var claimedButtons = Set<Int64>()
    private struct PendingOutput {
        let action: ZoneAction
        var count: Int
    }
    private var outputScope: UUID?
    private var pendingOutputs: [UUID: PendingOutput] = [:]
    /// Extra dim below the brightness minimum spans this much virtual travel.
    private static let extraDimSpan = 0.5

    private init() {
        // objectWillChange arrives before the setter completes: mark dirty now,
        // then rebuild once on the next frame, after all preset fields settle.
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            self?.configurationIsDirty = true
        }
    }

    func start() {
        guard settings.isEnabled else { statusMessage = "Paused"; return }
        guard !isRunning else { return }
        let actions = assignedActions
        ClipboardHistory.shared.isEnabled = actions.contains { $0.usesClipboardHistory }
        if actions.contains(.keyboardBrightness) { KeyboardBacklightCapability.shared.refresh() }
        if actions.contains(.microphoneLevel) || actions.contains(.microphoneMute) { VolumeController.microphone.refresh() }
        guard AXIsProcessTrusted() else {
            statusMessage = "Accessibility permission needed"
            return
        }
        guard installEventTap() else {
            statusMessage = "Input monitoring could not start. Check Accessibility, then retry."
            return
        }
        generation &+= 1
        recognizer.reset()
        taps = EdgeTapRecognizer()
        trackpadFrames.clear()
        MTBridge_SetFrameCallback { count, contacts, _, token in
            // The native array lives only until callback return. Copy every
            // contact here, and timestamp receipt before the main-queue hop.
            let copied: [GestureContact]
            if let contacts, count > 0 {
                copied = UnsafeBufferPointer(start: contacts, count: Int(count)).map {
                    GestureContact(id: $0.identifier, x: Double($0.x), y: Double($0.y))
                }
            } else { copied = [] }
            let receivedAt = ProcessInfo.processInfo.systemUptime
            if trackpadFrames.enqueue(GestureInputFrame(contacts: copied, timestamp: receivedAt, generation: token)) {
                DispatchQueue.main.async { TrackpadMonitor.shared.drainFrames() }
            }
        }
        let deviceCount = MTBridge_Start(generation)
        guard deviceCount > 0 else {
            removeEventTap()
            MTBridge_Stop()
            statusMessage = "No compatible trackpad found. Connect it, then retry."
            return
        }
        isRunning = true
        statusMessage = "Ready for edge gestures"
    }

    func restart() { stop(); start() }

    func stop() {
        isRunning = false
        generation &+= 1
        MTBridge_Stop()
        trackpadFrames.clear()
        removeEventTap()
        finishAdjustment()
        recognizer.reset()
        taps = EdgeTapRecognizer()
        gestureBinding = nil
        claimedButtons.removeAll()
        scrollCapture = GestureScrollCapture()
        statusMessage = settings.isEnabled ? "Stopped" : "Paused"
        GestureTelemetry.shared.monitorStopped()
    }

    func cancelCurrentGesture() {
        cancelCurrentGesture(reason: "Gesture cancelled. Lift your fingers to start again.")
    }

    private func cancelCurrentGesture(reason: String) {
        let decision = recognizer.cancel(reason: reason)
        GestureTelemetry.shared.publish(decision, at: ProcessInfo.processInfo.systemUptime, force: true)
        finishAdjustment()
    }

    // MARK: Configuration

    /// Every action any slot, layer or profile can produce.
    private var assignedActions: Set<ZoneAction> {
        var actions = Set(EdgeSlot.all.map { settings.baseBinding($0).action })
        for profile in settings.appProfiles.values { actions.formUnion(profile.bindings.values.map(\.action)) }
        if settings.dockedProfileEnabled { actions.formUnion(settings.dockedProfile.bindings.values.map(\.action)) }
        return actions
    }

    private var configuration: GestureConfiguration {
        if configurationIsDirty { rebuildConfigurations() }
        return cachedConfiguration
    }

    private var tapConfiguration: TapConfiguration {
        if configurationIsDirty { rebuildConfigurations() }
        return cachedTapConfiguration
    }

    private func rebuildConfigurations() {
        var result = GestureConfiguration()
        result.requiredFingers = settings.minimumFingers == 1 ? 1 : 2
        result.leftWidth = settings.leftZoneWidth
        result.rightWidth = settings.rightZoneWidth
        result.topHeight = settings.topEdgeHeight
        result.topEnabled = settings.topEdgeEnabled
        result.topHorizontal = settings.topEdgeSwipeDirection == "horizontal"
        result.bottomEnabled = settings.bottomEdgeEnabled
        result.bottomHeight = settings.bottomEdgeHeight
        result.strict = settings.palmRejectionMode == "strict"
        result.activationThreshold = settings.activationThreshold
        result.typingCooldown = settings.typingCooldown
        result.alternateRegions = Set([GestureRegion.left, .right].filter { settings.slotIsAssigned(EdgeSlot.alternate($0.rawValue)) })
        result.fingerLayers = !result.alternateRegions.isEmpty
        result.enabledRegions = Set(GestureRegion.allCases.filter { region in
            guard region != .none else { return false }
            let slot = region.rawValue
            return settings.slotIsAssigned(slot) || (region.isSide &&
                (settings.slotIsAssigned(EdgeSlot.option(slot)) || settings.slotIsAssigned(EdgeSlot.alternate(slot))))
        })
        cachedConfiguration = result

        var taps = TapConfiguration()
        taps.requiredFingers = result.requiredFingers
        taps.leftWidth = result.leftWidth
        taps.rightWidth = result.rightWidth
        taps.topEnabled = result.topEnabled
        taps.topHeight = result.topHeight
        taps.bottomEnabled = result.bottomEnabled
        taps.bottomHeight = result.bottomHeight
        taps.cornerSize = settings.tapCornerSize
        taps.cornerFingers = settings.cornerTapFingers == 1 ? 1 : nil
        taps.typingCooldown = result.typingCooldown
        taps.slots = Set(EdgeSlot.allTaps.filter { settings.slotIsAssigned($0) })
        cachedTapConfiguration = taps
        configurationIsDirty = false
        // History exists only while something can use it.
        ClipboardHistory.shared.isEnabled = assignedActions.contains { $0.usesClipboardHistory }
    }

    private var feel: GestureFeel { GestureFeel(precision: settings.precisionEnabled, acceleration: settings.accelerationEnabled) }
    private var currentAppBundleID: String? { ExcludedAppsManager.shared.currentAppBundleID }
    private var isDocked: Bool { BrightnessController.shared.hasExternalDisplayConnected }

    // MARK: Binding resolution

    private func slot(for region: GestureRegion, fingers: Int) -> String? {
        guard region != .none else { return nil }
        let base = region.rawValue
        guard region.isSide else { return base }
        if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate),
           settings.slotIsAssigned(EdgeSlot.option(base)) { return EdgeSlot.option(base) }
        return fingers != configuration.requiredFingers ? EdgeSlot.alternate(base) : base
    }

    private func binding(for decision: GestureDecision) -> (binding: EdgeBinding, available: Bool) {
        let fingers = decision.fingers > 0 ? decision.fingers : configuration.requiredFingers
        if let cached = gestureBinding, cached.region == decision.region, cached.fingers == fingers {
            return (cached.binding, cached.available)
        }
        let binding = slot(for: decision.region, fingers: fingers)
            .map { settings.binding($0, appBundleID: currentAppBundleID, docked: isDocked) } ?? EdgeBinding(.disabled)
        let available = isAvailable(binding)
        gestureBinding = (decision.region, fingers, binding, available)
        return (binding, available)
    }

    // MARK: Frames

    private func drainFrames() {
        for frame in trackpadFrames.takeBatch() {
            handleFrame(frame.contacts, at: frame.timestamp, generation: frame.generation)
        }
    }

    private func updateWatchdog() {
        guard isRunning && recognizer.isCapturing else {
            inputWatchdog?.invalidate()
            inputWatchdog = nil
            return
        }
        guard inputWatchdog == nil else { return }
        scheduleWatchdog(after: 0.25)
    }

    private func scheduleWatchdog(after delay: Double) {
        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.inputWatchdog = nil
            guard self.isRunning && self.recognizer.isCapturing else { return }
            let remaining = 0.25 - (ProcessInfo.processInfo.systemUptime - self.lastFrameTime)
            if remaining <= 0 {
                self.cancelCurrentGesture(reason: "Touch tracking stopped. Lift your fingers to reset.")
            } else {
                self.scheduleWatchdog(after: remaining)
            }
        }
        inputWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleFrame(_ contacts: [GestureContact], at timestamp: Double, generation token: UInt64) {
        guard isRunning, generation == token else { return }
        guard settings.isEnabled else { stop(); return }
        defer {
            updateWatchdog()
            if contacts.isEmpty { gestureBinding = nil }
        }
        lastFrameTime = timestamp
        lastContactCount = contacts.count
        if contacts.isEmpty { scrollCapture.touchesEnded() }
        let picker = ClipboardPicker.shared
        if picker.isOpen && picker.mode == .touch {
            // While the picker waits, the trackpad only scrolls it.
            picker.handle(contacts: contacts, at: timestamp)
            if !contacts.isEmpty { taps.cancel() }
            return
        }
        // A stalled main thread must never replay queued gestures onto hardware.
        if ProcessInfo.processInfo.systemUptime - timestamp > 0.12 {
            taps.cancel()
            if !contacts.isEmpty {
                _ = recognizer.process(contacts: contacts, timestamp: timestamp, configuration: configuration)
                cancelCurrentGesture(reason: "Input arrived too late. Lift your fingers and try again.")
            } else {
                _ = recognizer.process(contacts: [], timestamp: timestamp, configuration: configuration)
                finishAdjustment()
            }
            return
        }
        handleTaps(contacts, at: timestamp)
        var decision = recognizer.process(contacts: contacts, timestamp: timestamp, configuration: configuration)
        if configuration.maximumFingers == 2, scrollCapture.blocksEdgeGesture, recognizer.isCapturing, decision.count == 2 {
            decision = recognizer.cancel(reason: "Normal scrolling started first. Lift your fingers before using an edge control.")
        }
        if ExcludedAppsManager.shared.activeAppIsExcluded && !contacts.isEmpty {
            decision = recognizer.cancel(reason: "Sway is paused in this app.")
        }
        let telemetry = GestureTelemetry.shared
        if !telemetry.isTesting, recognizer.isCapturing {
            let resolved = binding(for: decision)
            if resolved.binding.action == .brightness { prepareBrightnessBaseline(for: decision.region) }
            if resolved.binding.action == .seek { prepareSeekBaseline() }
            // Unsupported hardware never consumes scrolling, freezes the cursor or
            // pretends to adjust a level. Test mode can still explain the gesture.
            // Brightness and seeking own their verdict through a fresh read.
            if resolved.binding.action == .disabled {
                decision = recognizer.cancel(reason: "This edge has no action here.")
            } else if ![.brightness, .seek].contains(resolved.binding.action), !resolved.available {
                decision = recognizer.cancel(reason: "This control is unavailable on the current device.")
            }
        }
        telemetry.publish(decision, at: timestamp)
        if contacts.isEmpty || decision.phase == .rejected || decision.ended {
            // The last legitimate request should settle after a normal lift.
            // Cancellation and rejected evidence discard queued hardware work.
            // A staggered two-finger release ends the gesture before the full lift.
            if decision.phase != .rejected, levelChanged, activeAction == .volume { VolumeFeedbackSound.play(setting: settings.volumeFeedbackSound) }
            finishAdjustment(cancelPending: decision.phase == .rejected)
            return
        }
        guard decision.phase == .accepted else { return }
        if decision.justAccepted {
            if !telemetry.isTesting { beginAdjustment(for: decision) }
            return
        }
        guard !telemetry.isTesting, activeValue != nil, decision.delta != 0 else { return }
        apply(decision)
    }

    // MARK: Taps

    private func handleTaps(_ contacts: [GestureContact], at timestamp: Double) {
        guard !ExcludedAppsManager.shared.activeAppIsExcluded else {
            _ = taps.process(contacts: contacts, timestamp: timestamp, configuration: TapConfiguration())
            return
        }
        guard let event = taps.process(contacts: contacts, timestamp: timestamp, configuration: tapConfiguration) else { return }
        let telemetry = GestureTelemetry.shared
        guard !telemetry.isTesting else { telemetry.publishTap(event, title: EdgeSlot.title(event.slot)); return }
        let binding = settings.binding(event.slot, appBundleID: currentAppBundleID, docked: isDocked)
        guard binding.action.worksAsTap, binding.action != .disabled, isAvailable(binding),
              let application = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        if perform(binding, increasing: true, tap: true, region: nil, application: application),
           settings.hapticFeedback { HapticOutput.shared.play(settings.hapticStyle) }
    }

    // MARK: Gesture lifecycle

    private func prepareBrightnessBaseline(for region: GestureRegion) {
        guard !brightnessPreparationStarted else { return }
        brightnessPreparationStarted = true
        brightnessPreparationGeneration &+= 1
        let preparation = brightnessPreparationGeneration
        BrightnessController.shared.refresh { [weak self] result in
            guard let self, self.brightnessPreparationGeneration == preparation,
                  self.isRunning, self.recognizer.isCapturing, !GestureTelemetry.shared.isTesting else { return }
            guard self.binding(for: self.recognizer.decision).binding.action == .brightness else {
                self.cancelCurrentGesture(reason: "Gesture settings changed. Lift your fingers to use the new setup.")
                return
            }
            switch result {
            case let .applied(value, target):
                guard target == BrightnessController.shared.targetIdentifier else {
                    self.cancelCurrentGesture(reason: "The display changed. Lift your fingers to reset.")
                    return
                }
                self.brightnessBaseline = (value, target)
                if self.recognizer.decision.phase == .accepted { self.beginAdjustment(for: self.recognizer.decision) }
            case .failed, .cancelled:
                self.cancelCurrentGesture(reason: "Brightness control is unavailable on the current display.")
            }
        }
    }

    /// Seeking needs the track's duration before the first movement counts.
    private func prepareSeekBaseline() {
        guard !seekPreparationStarted else { return }
        seekPreparationStarted = true
        let preparation = brightnessPreparationGeneration
        NowPlayingController.shared.fetch { [weak self] info in
            guard let self, self.brightnessPreparationGeneration == preparation,
                  self.isRunning, self.recognizer.isCapturing, !GestureTelemetry.shared.isTesting else { return }
            guard let info, let duration = info.duration, duration > 0 else {
                self.cancelCurrentGesture(reason: "Nothing seekable is playing right now.")
                return
            }
            self.seekBaseline = info
            if self.settings.nowPlayingHUD { NowPlayingHUD.shared.show(info) }
            if self.recognizer.decision.phase == .accepted { self.beginAdjustment(for: self.recognizer.decision) }
        }
    }

    private func beginAdjustment(for decision: GestureDecision) {
        guard activeValue == nil else { return }
        let binding = binding(for: decision).binding
        let action = binding.action
        let value: Double
        let target: String?
        switch action {
        case .brightness:
            // If a driver is slow, skip pre-baseline deltas. Never jump from an
            // old cached brightness or replay movement accumulated during IO.
            guard let baseline = brightnessBaseline else { return }
            guard baseline.target == BrightnessController.shared.targetIdentifier else {
                cancelCurrentGesture(reason: "The display changed. Lift your fingers to reset.")
                return
            }
            target = baseline.target
            // Below the hardware minimum, existing extra dim continues smoothly.
            let dim = settings.extraDimBelowMinimum ? BrightnessController.shared.activeDisplay.map { Double(GammaDimmer.shared.level(for: $0)) } ?? 0 : 0
            value = dim > 0 ? limits(for: .brightness).lowerBound - dim * Self.extraDimSpan : Double(baseline.value)
        case .seek:
            guard let info = seekBaseline, let duration = info.duration, duration > 0 else { return }
            value = min(1, max(0, (info.position(at: ProcessInfo.processInfo.systemUptime) ?? 0) / duration))
            target = targetIdentifier(action)
        default:
            guard isAvailable(binding), let current = currentValue(action) else { return }
            value = current
            target = targetIdentifier(action)
        }
        outputRevision &+= 1
        activeAction = action
        activeBinding = binding
        activeApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
        activeAppBundleID = currentAppBundleID
        commandStepper = GestureActionStepper()
        outputScope = UUID()
        activeTarget = target
        activeValue = RelativeGestureValue(value: value)
        fineEngaged = false
        levelChanged = false
        let now = ProcessInfo.processInfo.systemUptime
        if let style = haptics.begin(value: min(1, max(0, value)), configuration: settings.hapticConfiguration, at: now),
           !GestureTelemetry.shared.isTesting, now - lastFrameTime <= 0.12 {
            HapticOutput.shared.play(style)
        }
        NotificationCenter.default.post(name: .swayGestureBegan, object: nil,
                                        userInfo: ["action": activeAction.rawValue])
        if decision.fingers == 1 && settings.cursorFreezeOnOneFinger,
           let event = CGEvent(source: nil) {
            // CGEvent.location and CGWarpMouseCursorPosition share global display
            // coordinates, including negative origins on secondary displays.
            frozenCursorPosition = event.location
            cursorFreezeActive = true
            installFreezeTap()
            NSCursor.hide()
        }
    }

    private func finishAdjustment(cancelPending: Bool = true) {
        let picker = ClipboardPicker.shared
        if activeAction == .clipboardHistory, picker.isOpen, picker.mode == .swipe {
            // A completed swipe pastes what's highlighted; anything else pastes nothing.
            cancelPending ? picker.cancel() : picker.commit()
        }
        brightnessPreparationGeneration &+= 1
        brightnessPreparationStarted = false
        brightnessBaseline = nil
        seekPreparationStarted = false
        seekBaseline = nil
        if cancelPending && (activeAction != .disabled || !pendingOutputs.isEmpty) {
            outputRevision &+= 1
            for (scope, output) in pendingOutputs {
                if output.action == .volume || output.action == .outputMute { VolumeController.shared.cancelPendingRequests(in: scope) }
                else if output.action == .microphoneLevel || output.action == .microphoneMute { VolumeController.microphone.cancelPendingRequests(in: scope) }
                else if output.action == .brightness { BrightnessController.shared.cancelPendingRequests(in: scope) }
            }
            pendingOutputs.removeAll(keepingCapacity: true)
        }
        inputWatchdog?.invalidate()
        inputWatchdog = nil
        activeValue = nil
        activeAction = .disabled
        activeBinding = EdgeBinding(.disabled)
        outputScope = nil
        activeTarget = nil
        activeApplication = nil
        activeAppBundleID = nil
        commandStepper = GestureActionStepper()
        haptics.end()
        fineEngaged = false
        levelChanged = false
        if cursorFreezeActive {
            cursorFreezeActive = false
            if !pointerHeldForPicker { removeFreezeTap() }
            NSCursor.unhide()
        }
    }

    /// Keeps the pointer still (without hiding it) while the clipboard picker
    /// is driven by one finger, so choosing an item never moves the pointer.
    func holdPointer(_ hold: Bool) {
        if hold, !pointerHeldForPicker, let event = CGEvent(source: nil) {
            pointerHeldForPicker = true
            if !cursorFreezeActive { frozenCursorPosition = event.location }
            installFreezeTap()
        } else if !hold, pointerHeldForPicker {
            pointerHeldForPicker = false
            if !cursorFreezeActive { removeFreezeTap() }
        }
    }

    // MARK: Levels

    private func limits(for action: ZoneAction) -> ClosedRange<Double> {
        switch action {
        case .volume: return settings.volumeLimits(forDevice: VolumeController.shared.deviceUID)
        case .brightness: return min(settings.brightnessMin, settings.brightnessMax)...max(settings.brightnessMin, settings.brightnessMax)
        default: return 0...1
        }
    }

    private func apply(_ decision: GestureDecision) {
        let region = decision.region
        guard var value = activeValue, let scope = outputScope,
              activeAction == binding(for: decision).binding.action else {
            cancelCurrentGesture()
            return
        }
        guard activeTarget != nil, activeTarget == targetIdentifier(activeAction) else {
            cancelCurrentGesture(reason: activeAction.isContinuous ? "The output device changed. Lift your fingers to reset."
                                                                  : "The active app changed. Lift your fingers before sending another action.")
            return
        }
        if !activeAction.isContinuous {
            applyCommand(delta: decision.delta, region: region, scope: scope)
            return
        }
        var bounds = limits(for: activeAction)
        let dimming = activeAction == .brightness && settings.extraDimBelowMinimum
        if dimming { bounds = (bounds.lowerBound - Self.extraDimSpan)...bounds.upperBound }
        let notches = [.volume, .brightness, .microphoneLevel, .appVolume].contains(activeAction) ? settings.notches(for: activeAction) : []
        // Seeking should feel direct; precision still applies, acceleration does not.
        let shaping = activeAction == .seek ? feel.precisionScale(inward: decision.inward) : feel.scale(speed: decision.speed, inward: decision.inward)
        let fine = feel.isFine(inward: decision.inward)
        if fine && !fineEngaged && settings.hapticFeedback { HapticOutput.shared.play(.soft) }
        fineEngaged = fine
        let previous = value.value
        let requested = value.apply(delta: decision.delta, sensitivity: settings.sensitivity,
                                    inverted: settings.invertScrollDirection, bounds: bounds,
                                    scale: shaping, notches: notches, capture: TrackpadSettings.notchCapture)
        guard abs(requested - previous) > 0.00001 else { return }
        // Accumulate from the requested continuous value, not delayed/quantized
        // device readback. The controllers coalesce writes off the main thread.
        activeValue = value
        levelChanged = true
        let placement = OSDPlacement(edge: region == .left ? "left" : region == .right ? "right" : region == .bottom ? "bottom" : "top",
                                     x: decision.x, y: decision.y)
        requestLevel(requested, region: region, scope: scope, placement: placement, fine: fine)
    }

    // Keep the epoch stable through this gesture. Already-applied samples
    // can render while a newer desired value is pending; filtering by every
    // request would freeze feedback whenever the driver runs below 120 Hz.
    private func requestLevel(_ requested: Double, region: GestureRegion, scope: UUID, placement: OSDPlacement, fine: Bool) {
        let revision = outputRevision
        let target = activeTarget
        let action = activeAction
        switch action {
        case .volume, .microphoneLevel:
            trackOutput(action, in: scope)
            let audio = action == .volume ? VolumeController.shared : VolumeController.microphone
            audio.requestVolume(Float(requested), muteAtZero: action == .volume && settings.muteAtZero,
                                expectedTargetIdentifier: target, cancellationScope: scope) { [weak self] result in
                guard let self else { return }
                defer { self.outputFinished(in: scope) }
                guard self.outputRevision == revision else { return }
                switch result {
                case let .applied(measured, _, appliedTarget):
                    guard appliedTarget == target, appliedTarget == self.targetIdentifier(action) else { return }
                    self.publishAdjustment(measured, action: action, region: region, placement: placement, fine: fine)
                case .failed:
                    self.cancelCurrentGesture(reason: "The device did not accept this adjustment.")
                case .cancelled: break
                }
            }
        case .brightness:
            let lower = limits(for: .brightness).lowerBound
            let dim = requested < lower ? (lower - requested) / Self.extraDimSpan : 0
            if settings.extraDimBelowMinimum, let display = BrightnessController.shared.activeDisplay {
                GammaDimmer.shared.setLevel(Float(dim), for: display)
                if dim > 0 {
                    OSDOverlay.shared.show(type: .extraDim, value: Float(1 - dim), placement: placement, fine: fine)
                    if let style = haptics.update(value: 1 - dim, bounds: 0...1, at: ProcessInfo.processInfo.systemUptime) {
                        HapticOutput.shared.play(style)
                    }
                }
            }
            let hardware = max(lower, requested)
            guard dim == 0 || abs(Double(BrightnessController.shared.getBrightness()) - hardware) > 0.0005 else { return }
            trackOutput(action, in: scope)
            BrightnessController.shared.requestBrightness(Float(hardware), expectedTargetIdentifier: target,
                                                           cancellationScope: scope) { [weak self] result in
                guard let self else { return }
                defer { self.outputFinished(in: scope) }
                guard self.outputRevision == revision else { return }
                switch result {
                case let .applied(measured, appliedTarget):
                    guard appliedTarget == target, appliedTarget == self.targetIdentifier(.brightness), dim == 0 else { return }
                    self.publishAdjustment(measured, action: .brightness, region: region, placement: placement, fine: fine)
                case .failed:
                    self.cancelCurrentGesture(reason: "The device did not accept this adjustment.")
                case .cancelled: break
                }
            }
        case .appVolume:
            guard let bundle = activeAppBundleID else { return }
            // Through the mixer, so the level is remembered and plays nicely with solo and ducking.
            MixerModel.shared.adjustVolume(Float(requested), forApp: bundle) { [weak self] result in
                guard let self, self.outputRevision == revision else { return }
                switch result {
                case let .applied(gain): self.publishAdjustment(gain, action: .appVolume, region: region, placement: placement, fine: fine)
                case let .failed(reason): self.cancelCurrentGesture(reason: reason)
                case .cancelled: break
                }
            }
        case .nightShift:
            NightShiftController.shared.request(Float(requested)) { [weak self] level in
                guard let self, self.outputRevision == revision, let level else { return }
                self.publishAdjustment(level, action: .nightShift, region: region, placement: placement, fine: fine)
            }
        case .extraDim:
            guard let display = dimTargetDisplay(), GammaDimmer.shared.setLevel(Float(1 - requested), for: display) else {
                cancelCurrentGesture(reason: "This display does not allow extra dimming.")
                return
            }
            publishAdjustment(Float(requested), action: .extraDim, region: region, placement: placement, fine: fine)
        case .seek:
            guard let info = seekBaseline, let duration = info.duration else { return }
            let seconds = requested * duration
            if settings.nowPlayingHUD { NowPlayingHUD.shared.show(info, scrubPosition: seconds) }
            NowPlayingController.shared.requestSeek(to: seconds) { [weak self] success in
                guard let self, self.outputRevision == revision, !success else { return }
                self.cancelCurrentGesture(reason: "The player did not accept the new position.")
            }
            if let style = haptics.update(value: requested, bounds: 0...1, at: ProcessInfo.processInfo.systemUptime) {
                HapticOutput.shared.play(style)
            }
        default: break
        }
    }

    private func trackOutput(_ action: ZoneAction, in scope: UUID) {
        if pendingOutputs[scope] == nil { pendingOutputs[scope] = PendingOutput(action: action, count: 0) }
        pendingOutputs[scope]?.count += 1
    }

    private func dimTargetDisplay() -> CGDirectDisplayID? {
        guard let location = CGEvent(source: nil)?.location else { return CGMainDisplayID() }
        var display = CGDirectDisplayID(0)
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(location, 1, &display, &count) == .success && count > 0 ? display : CGMainDisplayID()
    }

    // MARK: Commands

    private func applyCommand(delta: Double, region: GestureRegion, scope: UUID) {
        guard let application = activeApplication,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application else {
            cancelCurrentGesture(reason: "The active app changed. Lift your fingers before sending another action.")
            return
        }
        if activeAction == .clipboardHistory {
            let picker = ClipboardPicker.shared
            if picker.isOpen { picker.scroll(by: delta * (settings.invertScrollDirection ? -1 : 1)) }
            else { picker.open(mode: .swipe, application: application) }
            return
        }
        guard let increasing = commandStepper.consume(delta: delta, sensitivity: settings.sensitivity,
            inverted: settings.invertScrollDirection, repeats: activeAction.repeatsWhileSwiping,
            at: ProcessInfo.processInfo.systemUptime) else { return }
        let action = activeAction
        if action == .outputMute || action == .microphoneMute {
            let controller = action == .outputMute ? VolumeController.shared : VolumeController.microphone
            let revision = outputRevision
            let target = activeTarget
            pendingOutputs[scope] = PendingOutput(action: action, count: 1)
            controller.requestMuted(!increasing, expectedTargetIdentifier: target, cancellationScope: scope) { [weak self] result in
                guard let self else { return }
                defer { self.outputFinished(in: scope) }
                guard self.outputRevision == revision else { return }
                switch result {
                case let .applied(value, muted, identifier):
                    guard target == identifier, identifier == controller.targetIdentifier else { return }
                    if action == .outputMute { self.publishAdjustment(muted ? 0 : value, action: .volume, region: region, placement: nil, fine: false) }
                    else {
                        NotificationCenter.default.post(name: .microphoneMuteChanged, object: muted)
                    }
                case .failed: self.cancelCurrentGesture(reason: "The device did not confirm the mute change. Check its controls.")
                case .cancelled: break
                }
            }
            return
        }
        guard perform(activeBinding, increasing: increasing, tap: false, region: region, application: application) else {
            cancelCurrentGesture(reason: "This action is not configured or could not be sent. Check its settings.")
            return
        }
        if settings.hapticFeedback { HapticOutput.shared.play(settings.hapticStyle) }
    }

    /// One-shot actions shared by swipes and taps. Returns false only when
    /// nothing could be started; asynchronous results report themselves.
    @discardableResult
    private func perform(_ binding: EdgeBinding, increasing: Bool, tap: Bool, region: GestureRegion?, application: pid_t) -> Bool {
        switch binding.action {
        case .outputMute, .microphoneMute:
            // Only taps reach here: a tap flips the measured state.
            let controller = binding.action == .outputMute ? VolumeController.shared : VolumeController.microphone
            let isOutput = binding.action == .outputMute
            controller.requestMuted(!controller.isMuted) { result in
                guard case let .applied(value, muted, _) = result else { return }
                if isOutput { NotificationCenter.default.post(name: .volumeChanged, object: muted ? Float(0) : value) }
                else { NotificationCenter.default.post(name: .microphoneMuteChanged, object: muted) }
            }
            return true
        case .trueTone:
            let on = tap ? !(TrueToneController.shared.isEnabled ?? false) : increasing
            TrueToneController.shared.setEnabled(on) { state in
                guard let state else { return }
                OSDOverlay.shared.show(type: .message(state ? "True Tone on" : "True Tone off", icon: "circle.lefthalf.fill"), value: 1)
            }
            return true
        case .muteApp, .soloApp:
            guard let bundle = NSRunningApplication(processIdentifier: application)?.bundleIdentifier, AppVolumeController.isSupported else { return false }
            let mixer = MixerModel.shared, name = mixer.displayName(forApp: bundle)
            if binding.action == .muteApp {
                let muted = mixer.setMuted(tap ? nil : !increasing, forApp: bundle)
                OSDOverlay.shared.show(type: .message(muted ? "\(name) muted" : "\(name) unmuted", icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"), value: 1)
            } else {
                let soloed = mixer.setSoloed(tap ? nil : increasing, forApp: bundle)
                OSDOverlay.shared.show(type: .message(soloed ? "Only \(name) is playing" : "Solo off", icon: "headphones"), value: 1)
            }
            return true
        case .audioOutput:
            AudioOutputSwitcher.cycle(forward: increasing) { device in
                OSDOverlay.shared.show(type: .message(device?.name ?? "No other audio output", icon: "airplayaudio"), value: 1)
            }
            return true
        case .tileWindow:
            return WindowTiler.tile(tilePlacement(region: region, increasing: increasing, tap: tap), pid: application)
        case .runShortcut:
            let name = increasing || tap ? binding.shortcut : (binding.downShortcut.isEmpty ? binding.shortcut : binding.downShortcut)
            return ShortcutsRunner.run(name)
        case .nowPlaying:
            showNowPlaying(after: 0)
            return true
        case .cheatSheet:
            EdgeMapHUD.shared.toggle()
            return true
        case .pastePrevious:
            return ClipboardHistory.shared.pastePrevious(into: application)
        case .clipboardHistory:
            // A tap opens the picker; the next one-finger slide chooses.
            ClipboardPicker.shared.open(mode: .touch, application: application)
            return true
        case .sleepDisplay:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            return (try? process.run()) != nil
        default:
            let custom = settings.customShortcut(for: binding, increasing: increasing)
            guard let command = EdgeCommand.resolve(binding.action, increasing: increasing, custom: custom),
                  EdgeActionController.send(command, expectedApplication: application) else { return false }
            // Players need a moment to change tracks before they report them.
            if binding.action == .mediaTracks || binding.action == .playPause { showNowPlaying(after: 0.45) }
            if binding.action == .copy || binding.action == .cut { ClipboardHistory.shared.noteCopy() }
            return true
        }
    }

    private func tilePlacement(region: GestureRegion?, increasing: Bool, tap: Bool) -> TilePlacement {
        guard !tap, let region else { return .fill }
        if configuration.isHorizontal(region) { return increasing ? .rightHalf : .leftHalf }
        if increasing { return .fill }
        return region == .right ? .rightHalf : .leftHalf
    }

    private func showNowPlaying(after delay: Double) {
        guard settings.nowPlayingHUD else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NowPlayingController.shared.fetch { info in
                if let info { NowPlayingHUD.shared.show(info) }
            }
        }
    }

    private func outputFinished(in scope: UUID) {
        guard let pending = pendingOutputs[scope] else { return }
        if pending.count <= 1 { pendingOutputs[scope] = nil }
        else { pendingOutputs[scope]?.count -= 1 }
    }

    private func publishAdjustment(_ measured: Float, action: ZoneAction, region: GestureRegion,
                                   placement: OSDPlacement?, fine: Bool) {
        var info: [String: Any] = ["zone": region == .left || region == .topLeft ? "left" : "right",
                                   "gestureRegion": region.rawValue, "fine": fine]
        if let placement { info["placement"] = placement }
        switch action {
        case .volume, .brightness, .microphoneLevel:
            let name: Notification.Name
            if action == .volume { name = region.isTop ? .topEdgeVolumeChanged : .volumeChanged }
            else if action == .microphoneLevel { name = .microphoneLevelChanged }
            else { name = region.isTop ? .topEdgeBrightnessChanged : .brightnessChanged }
            NotificationCenter.default.post(name: name, object: measured, userInfo: info)
        case .appVolume: OSDOverlay.shared.show(type: .appVolume, value: measured, placement: placement, fine: fine)
        case .nightShift: OSDOverlay.shared.show(type: .nightShift, value: measured, placement: placement, fine: fine)
        case .extraDim: OSDOverlay.shared.show(type: .extraDim, value: measured, placement: placement, fine: fine)
        default: break
        }
        if activeValue != nil { haptic(at: measured) }
    }

    // MARK: Capabilities

    private func isAvailable(_ binding: EdgeBinding) -> Bool {
        switch binding.action {
        case .volume: return VolumeController.shared.isAvailable
        case .brightness: return BrightnessController.shared.isAvailable
        case .microphoneLevel: return VolumeController.microphone.isAvailable
        case .outputMute: return VolumeController.shared.supportsMute
        case .microphoneMute: return VolumeController.microphone.supportsMute
        case .keyboardBrightness: return KeyboardBacklightCapability.shared.isAvailable
        case .customShortcut:
            return !settings.customShortcut(for: binding, increasing: true).isEmpty
                || !settings.customShortcut(for: binding, increasing: false).isEmpty
        case .appVolume, .muteApp, .soloApp: return AppVolumeController.isSupported && currentAppBundleID != nil
        case .nightShift: return NightShiftController.shared.isAvailable
        case .trueTone: return TrueToneController.shared.isAvailable
        case .runShortcut:
            return ShortcutsRunner.isAvailable && !(binding.shortcut.isEmpty && binding.downShortcut.isEmpty)
        case .extraDim, .seek, .nowPlaying, .cheatSheet, .audioOutput: return true
        case .disabled: return false
        default: return NSWorkspace.shared.frontmostApplication != nil
        }
    }

    private func currentValue(_ action: ZoneAction) -> Double? {
        switch action {
        case .volume: return Double(VolumeController.shared.getVolume())
        case .microphoneLevel: return Double(VolumeController.microphone.getVolume())
        case .appVolume: return currentAppBundleID.map { Double(min(1, MixerModel.shared.volume(forApp: $0))) }
        case .nightShift: return NightShiftController.shared.level().map(Double.init)
        case .extraDim: return dimTargetDisplay().map { 1 - Double(GammaDimmer.shared.level(for: $0)) }
        default: return 0.5
        }
    }

    private func targetIdentifier(_ action: ZoneAction) -> String? {
        switch action {
        case .volume, .outputMute: return VolumeController.shared.targetIdentifier
        case .brightness: return BrightnessController.shared.targetIdentifier
        case .microphoneLevel, .microphoneMute: return VolumeController.microphone.targetIdentifier
        case .appVolume: return currentAppBundleID.map { "appvolume:\($0)" }
        case .nightShift: return "nightshift"
        case .extraDim: return dimTargetDisplay().map { "gamma:\($0)" }
        case .seek: return "seek"
        case .disabled: return nil
        default: return NSWorkspace.shared.frontmostApplication.map { "app:\($0.processIdentifier)" }
        }
    }

    private func haptic(at value: Float) {
        guard settings.hapticFeedback else { haptics.end(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !GestureTelemetry.shared.isTesting, recognizer.decision.phase == .accepted,
              now - lastFrameTime <= 0.12 else { return }
        let bounds = limits(for: activeAction)
        let notches = [.volume, .brightness, .microphoneLevel, .appVolume].contains(activeAction) ? settings.notches(for: activeAction) : []
        if let style = haptics.update(value: Double(value), bounds: bounds, at: now, notches: notches) {
            HapticOutput.shared.play(style)
        }
    }

    // MARK: Event tap

    private func installEventTap() -> Bool {
        guard eventTap == nil else { return true }
        // No pointer-movement events here: those would wake Sway on every
        // mouse move. The freeze tap below takes them only while needed.
        let types: [CGEventType] = [.scrollWheel, .keyDown,
                                   .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                   .leftMouseUp, .rightMouseUp, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, _ in
            TrackpadMonitor.shared.handleEvent(type: type, event: event)
        }, userInfo: nil) else { return false }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeEventTap() {
        removeFreezeTap()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func installFreezeTap() {
        guard freezeTap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, _ in
            TrackpadMonitor.shared.handleFreezeEvent(type: type, event: event)
        }, userInfo: nil) else { return }
        freezeTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        freezeSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeFreezeTap() {
        if let freezeTap {
            CGEvent.tapEnable(tap: freezeTap, enable: false)
            CFMachPortInvalidate(freezeTap)
        }
        if let freezeSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), freezeSource, .commonModes) }
        freezeTap = nil
        freezeSource = nil
    }

    private func handleFreezeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let freezeTap { CGEvent.tapEnable(tap: freezeTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard cursorFreezeActive || pointerHeldForPicker else { return Unmanaged.passUnretained(event) }
        CGWarpMouseCursorPosition(frozenCursorPosition)
        return nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard isRunning else { return pass }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelCurrentGesture(reason: "Input monitoring was interrupted. Lift your fingers to reset.")
            scrollCapture = GestureScrollCapture()
            claimedButtons.removeAll()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return pass
        }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .keyDown {
            if event.getIntegerValueField(.eventSourceUserData) == EdgeActionController.eventMarker { return pass }
            // While the clipboard picker is up, its keys (esc, return, arrows,
            // 1–9) choose; the app in front keeps focus and receives nothing.
            if ClipboardPicker.shared.isOpen,
               ClipboardPicker.shared.handleKey(code: event.getIntegerValueField(.keyboardEventKeycode),
                                                characters: NSEvent(cgEvent: event)?.charactersIgnoringModifiers) {
                return nil
            }
            // ⌘C / ⌘X: let clipboard history read the result once, shortly after.
            if event.flags.contains(.maskCommand), [7, 8].contains(event.getIntegerValueField(.keyboardEventKeycode)) {
                ClipboardHistory.shared.noteCopy()
            }
            let decision = recognizer.keyDown(at: now)
            taps.keyDown(at: now)
            GestureTelemetry.shared.publish(decision, at: now, force: true)
            finishAdjustment()
            return pass
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
            if claimedButtons.remove(button) != nil { return nil }
            // A click may have chosen Copy from a menu: read the clipboard once, shortly after.
            ClipboardHistory.shared.noteCopy(after: 0.3)
            return pass
        }
        let picker = ClipboardPicker.shared
        if (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown),
           picker.isOpen || now <= picker.claimsClicksUntil {
            // Clicks belong to the picker while it is up: a press chooses, and
            // the tap-to-click after a choosing lift never reaches the app.
            if picker.isOpen && picker.mode == .touch && lastContactCount > 0 { picker.commit() }
            claimedButtons.insert(button)
            return nil
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // Tap-to-click arrives after the lift of a tap Sway recognized at an
            // edge with a tap action; that click belongs to Sway, not the app
            // under the pointer. A press with fingers down is a real click.
            drainFrames()
            if lastContactCount == 0, now <= taps.claimsClicksUntil, !GestureTelemetry.shared.isTesting {
                claimedButtons.insert(button)
                return nil
            }
            taps.click()
            cancelCurrentGesture(reason: "Click detected. Lift your fingers before swiping.")
            return pass
        }
        guard type == .scrollWheel else { return pass }
        guard let scrolling = NSEvent(cgEvent: event), scrolling.hasPreciseScrollingDeltas else { return pass }
        // The open picker owns the trackpad; pages behind it don't scroll.
        if picker.isOpen && picker.mode == .touch { return nil }
        let phase = scrollPhase(scrolling.phase)
        let momentum = scrollPhase(scrolling.momentumPhase)
        scrollCapture.prepare(phase: phase, momentum: momentum)
        // Native touch callbacks and the event tap arrive via separate queues.
        // Apply all already-received touches/lifts before deciding who owns the
        // beginning of this scroll; do not use the preceding gesture's contacts.
        if momentum == .none && (phase == .mayBegin || phase == .began) {
            drainFrames()
        }
        let observedAt = ProcessInfo.processInfo.systemUptime
        let eligible = settings.isEnabled && configuration.maximumFingers == 2 && recognizer.isCapturing &&
            recognizer.decision.count == 2 && observedAt - lastFrameTime < 0.12 &&
            !ExcludedAppsManager.shared.activeAppIsExcluded
        let consume = scrollCapture.consume(precise: true, phase: phase, momentum: momentum,
                                            eligible: eligible, at: observedAt)
        if scrollCapture.blocksEdgeGesture && configuration.maximumFingers == 2 && recognizer.isCapturing && recognizer.decision.count == 2 {
            cancelCurrentGesture(reason: "Normal scrolling started first. Lift your fingers before using an edge control.")
        }
        return consume ? nil : pass
    }

    private func scrollPhase(_ phase: NSEvent.Phase) -> GestureScrollCapture.Phase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.mayBegin) { return .mayBegin }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.stationary) { return .stationary }
        return .none
    }
}

/// The click macOS plays for volume keys, after a volume gesture ends.
enum VolumeFeedbackSound {
    private static let sound: NSSound? = {
        let native = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        return FileManager.default.fileExists(atPath: native) ? NSSound(contentsOfFile: native, byReference: true) : NSSound(named: "Pop")
    }()

    /// "system" follows “Play feedback when volume is changed” in Sound settings.
    static func shouldPlay(setting: String, systemPreference: Bool) -> Bool {
        setting == "on" || (setting == "system" && systemPreference)
    }

    static func play(setting: String) {
        let system = UserDefaults(suiteName: UserDefaults.globalDomain)?.integer(forKey: "com.apple.sound.beep.feedback") == 1
        guard shouldPlay(setting: setting, systemPreference: system) else { return }
        sound?.stop()
        sound?.play()
    }
}

extension Notification.Name {
    static let swayGestureBegan = Notification.Name("swayGestureBegan")
    static let volumeChanged = Notification.Name("volumeChanged")
    static let brightnessChanged = Notification.Name("brightnessChanged")
    static let microphoneLevelChanged = Notification.Name("microphoneLevelChanged")
    static let microphoneMuteChanged = Notification.Name("microphoneMuteChanged")
    static let topEdgeVolumeChanged = Notification.Name("topEdgeVolumeChanged")
    static let topEdgeBrightnessChanged = Notification.Name("topEdgeBrightnessChanged")
}

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
    private var palmFilter = PalmFilter()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Exists only while a one-finger gesture holds the pointer, so ordinary
    /// mouse movement never wakes Sway.
    private var freezeTap: CFMachPort?
    private var warpScheduled = false
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
    /// Where the pointer was when a finger landed on an edge, before the slide could move it.
    private var captureCursor: CGPoint?
    private var wasCapturing = false
    private var frozenCursorPosition = CGPoint.zero
    private var scrollCapture = GestureScrollCapture()
    private var inputWatchdog: Timer?
    private var cachedConfiguration = GestureConfiguration()
    private var cachedTapConfiguration = TapConfiguration()
    private var configurationIsDirty = true
    private var settingsObserver: AnyCancellable?
    private var appObserver: AnyCancellable?
    /// Accessibility can be taken away while Kinara runs. These notice it within
    /// about a second and take every tap down before input can back up behind it.
    private var accessObserver: NSObjectProtocol?
    private var accessTimer: Timer?
    private var tapRecovery = TapRecovery()
    private var tapRestart: DispatchWorkItem?
    private var brightnessPreparationGeneration: UInt64 = 0
    private var brightnessPreparationStarted = false
    private var brightnessBaseline: (value: Float, target: String)?
    private var seekPreparationStarted = false
    private var seekBaseline: NowPlayingInfo?
    /// One binding per touch sequence, resolved from the region, finger
    /// count, ⌥, frontmost app and docking state at the moment it began.
    private var gestureBinding: (region: GestureRegion, fingers: Int, binding: EdgeBinding, available: Bool)?
    /// Where the finger was for the action being performed, so a message from
    /// it can appear there in the Follow finger style.
    private var messagePlacement: OSDPlacement?
    /// A finger resting on a tap spot, to preview what its taps do.
    private var rest = TapRestDetector()
    /// The last tap action, so repeating it soon after can undo it.
    private var lastTapAction: (slot: String, action: ZoneAction, time: Double)?
    /// A tap on a level or a stepper arms it on the side edge it belongs to:
    /// the next slide there adjusts it, and then the edge is itself again.
    /// The rest of the trackpad stays as it is.
    private var armedSlide: (binding: EdgeBinding, sides: Set<GestureRegion>, sliding: Bool)?
    private var armTimeout: DispatchWorkItem?
    /// How long an armed tap waits for its slide.
    static let armWindow = 4.0
    /// After an armed slide lifts, another this soon keeps adjusting, as
    /// repeated swipes on an edge would.
    static let armGrace = 1.0
    static let undoWindow = 2.0
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
        // An app profile can choose its own finger count.
        appObserver = ExcludedAppsManager.shared.$currentAppBundleID.removeDuplicates().sink { [weak self] _ in
            self?.configurationIsDirty = true
        }
        // The watchdog switched the taps off while the main thread was stuck: start clean.
        MainThreadWatchdog.shared.onRecovered = { [weak self] in
            guard let self, self.isRunning else { return }
            self.restart(reason: "main thread recovered")
        }
        // macOS posts this whenever the Accessibility list changes, granted or taken
        // away; the answer can lag the notice, so ask again a moment later too.
        accessObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            KinaraLog.info(.access, "macOS says the Accessibility list changed")
            // macOS can take several seconds to apply a change, so keep asking a little longer.
            for delay in [0.0, 0.3, 1.0, 2.5, 5, 10] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.checkAccess() }
            }
        }
    }

    /// Without Accessibility, nothing of Kinara's may stay in the input path,
    /// and gestures stop: no taps, no touch reading, the pointer restored.
    /// Whether macOS still lets Kinara filter input, asked fresh. On macOS 27,
    /// AXIsProcessTrusted() kept answering yes for minutes after Kinara was
    /// removed from the Accessibility list (Kinara.log, 2 Nov 2026), so this
    /// also creates a tap like Kinara's own and throws it away: macOS refuses
    /// that the moment access is gone. Never call it inside a tap callback.
    static func accessIsLive() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        guard let probe = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                            eventsOfInterest: mask, callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                            userInfo: nil) else { return false }
        CGEvent.tapEnable(tap: probe, enable: false)
        CFMachPortInvalidate(probe)
        return true
    }

    private var lastTrusted: Bool?
    private func checkAccess() {
        let trusted = Self.accessIsLive()
        if trusted != lastTrusted {
            KinaraLog.info(.access, "Accessibility \(trusted ? "granted" : "not granted") (running: \(isRunning), taps: \(eventTap != nil ? 1 : 0) + \(freezeTap != nil ? 1 : 0))")
            lastTrusted = trusted
        }
        if !trusted && (isRunning || eventTap != nil || freezeTap != nil) { stopForMissingAccess() }
        // Drives the menu and Settings, and restarts gestures once access is back.
        ControlCenterModel.shared.refreshAccess()
    }

    private func stopForMissingAccess() {
        // A picker holding the pointer lets go too.
        TrackpadPickers.open?.cancel()
        stop(reason: "Accessibility was taken away")
        statusMessage = "Accessibility permission needed"
    }

    /// A tap was switched off by macOS. It stays off while Kinara checks, on the
    /// next turn and outside the callback, whether access is really still there;
    /// it comes back only if so, and only now and then. Otherwise Kinara steps
    /// out of the input path and tries again later.
    private func recoverTap(_ tap: CFMachPort?, _ type: CGEventType) {
        let name = tap == freezeTap ? "Pointer" : "Input"
        let kind = type == .tapDisabledByTimeout ? "timed out" : "was disabled by user input"
        DispatchQueue.main.async { [weak self] in
            guard let self, let tap, tap == self.eventTap || tap == self.freezeTap else { return }
            let trusted = Self.accessIsLive()
            if self.tapRecovery.mayResume(trusted: trusted, at: ProcessInfo.processInfo.systemUptime) {
                KinaraLog.warning(.taps, "\(name) tap \(kind); access confirmed, switched back on")
                CGEvent.tapEnable(tap: tap, enable: true)
                return
            }
            KinaraLog.fault(.taps, "\(name) tap \(kind); NOT switched back on (access \(trusted ? "still granted, but it keeps timing out" : "is gone"))")
            if !trusted { self.checkAccess(); return }
            // Trusted but timing out again and again: stand down, then come back.
            self.stop(reason: "input tap kept timing out")
            self.statusMessage = "Input monitoring paused for a moment"
            self.tapRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.settings.isEnabled, AXIsProcessTrusted(), !self.isRunning else { return }
                self.start()
            }
            self.tapRestart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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
            KinaraLog.warning(.monitor, "Not starting: Accessibility not granted")
            return
        }
        guard installEventTap() else {
            statusMessage = "Input monitoring could not start. Check Accessibility, then retry."
            KinaraLog.fault(.monitor, "Not starting: the input tap could not be created")
            return
        }
        generation &+= 1
        recognizer.reset()
        taps = EdgeTapRecognizer()
        palmFilter = PalmFilter()
        trackpadFrames.clear()
        MTBridge_SetFrameCallback { count, contacts, _, token in
            // The native array lives only until callback return. Copy every
            // contact here, and timestamp receipt before the main-queue hop.
            let copied: [GestureContact]
            if let contacts, count > 0 {
                copied = UnsafeBufferPointer(start: contacts, count: Int(count)).map {
                    GestureContact(id: $0.identifier, x: Double($0.x), y: Double($0.y),
                                   major: Double($0.majorAxis), minor: Double($0.minorAxis))
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
            KinaraLog.warning(.monitor, "Not starting: no compatible trackpad")
            return
        }
        isRunning = true
        statusMessage = "Ready for edge gestures"
        KinaraLog.info(.monitor, "Running: \(deviceCount) trackpad(s), \(settings.minimumFingers) finger(s), cursor hold \(settings.cursorFreezeOnOneFinger ? "on" : "off"), haptics \(settings.hapticFeedback ? settings.hapticStyle.rawValue : "off")")
        tapRecovery = TapRecovery()
        // The safety net under the notification: a fresh check every two seconds, only while running.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !Self.accessIsLive() else { return }
            self.checkAccess()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        accessTimer?.invalidate()
        accessTimer = timer
    }

    func restart(reason: String = "restart") { stop(reason: reason); start() }

    func stop(reason: String = "requested") {
        if isRunning || eventTap != nil || freezeTap != nil { KinaraLog.info(.monitor, "Stopping: \(reason)") }
        isRunning = false
        disarm()
        accessTimer?.invalidate()
        accessTimer = nil
        generation &+= 1
        MTBridge_Stop()
        trackpadFrames.clear()
        removeEventTap()
        finishAdjustment()
        recognizer.reset()
        taps = EdgeTapRecognizer()
        palmFilter = PalmFilter()
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
        captureCursor = nil
        wasCapturing = false
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
        return armedSlide == nil ? cachedConfiguration : armedConfiguration
    }

    /// While a tap's slide is armed, its side edge takes one finger or two,
    /// even if that edge has nothing of its own. Nothing else changes.
    private var armedConfiguration: GestureConfiguration {
        var armed = cachedConfiguration
        guard let sides = armedSlide?.sides else { return armed }
        armed.enabledRegions.formUnion(sides)
        armed.alternateRegions.formUnion(sides)
        armed.fingerLayers = true
        return armed
    }

    /// The side edge an armed tap borrows: its own side, or both for a tap on
    /// the top or bottom edge.
    static func armedSides(for region: TapRegion) -> Set<GestureRegion> {
        switch region {
        case .topLeftCorner, .bottomLeftCorner, .left: return [.left]
        case .topRightCorner, .bottomRightCorner, .right: return [.right]
        case .top, .bottom: return [.left, .right]
        }
    }

    private var tapConfiguration: TapConfiguration {
        if configurationIsDirty { rebuildConfigurations() }
        return cachedTapConfiguration
    }

    private func rebuildConfigurations() {
        var result = GestureConfiguration()
        result.requiredFingers = settings.requiredFingers(appBundleID: currentAppBundleID)
        result.leftWidth = settings.leftZoneWidth
        result.rightWidth = settings.rightZoneWidth
        result.topHeight = settings.topEdgeHeight
        // The top and bottom edges are one-finger gestures.
        result.topEnabled = settings.topEdgeEnabled && result.requiredFingers == 1
        result.topHorizontal = settings.topEdgeSwipeDirection == "horizontal"
        result.bottomEnabled = settings.bottomEdgeEnabled && result.requiredFingers == 1
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
        cachedConfiguration.tapGuard = taps
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
        if let armed = armedSlide, armed.sides.contains(decision.region) { return (armed.binding, isAvailable(armed.binding)) }
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

    private func handleFrame(_ touches: [GestureContact], at timestamp: Double, generation token: UInt64) {
        guard isRunning, generation == token else { return }
        guard settings.isEnabled else { stop(); return }
        // Palms are not fingers: nothing below ever sees them, as in macOS.
        let palms = palmFilter.filter(touches)
        let contacts = palms.fingers
        if palms.newPalms > 0 { GestureTelemetry.shared.publishPalm(size: palms.palmSize, at: timestamp) }
        if palms.withdrewFinger {
            // A touch that grew into a palm stops whatever it began, and its
            // disappearance from the fingers is never read as a tap's lift.
            taps.cancel()
            cancelCurrentGesture(reason: "Palm detected. Nothing was triggered.")
        }
        // A palm resting alone repeats empty frames; there is nothing to do.
        if contacts.isEmpty && lastContactCount == 0 && !palms.withdrewFinger { return }
        defer {
            updateWatchdog()
            if contacts.isEmpty { gestureBinding = nil }
        }
        lastFrameTime = timestamp
        lastContactCount = contacts.count
        if contacts.isEmpty { scrollCapture.touchesEnded() }
        if let picker = TrackpadPickers.open, picker.isTouchMode {
            // While a picker waits, the trackpad only scrolls it.
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
            decision = recognizer.cancel(reason: "Kinara is paused in this app.")
        }
        // Remember where the pointer was the moment a single finger lands on an edge. macOS
        // moves the pointer while the slide is still being confirmed; acceptance puts it back.
        let capturing = recognizer.isCapturing
        if capturing && !wasCapturing { captureCursor = contacts.count == 1 ? CGEvent(source: nil)?.location : nil }
        if !capturing { captureCursor = nil }
        wasCapturing = capturing
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
            EdgeGlow.shared.end()
            // The last legitimate request should settle after a normal lift.
            // Cancellation and rejected evidence discard queued hardware work.
            // A staggered two-finger release ends the gesture before the full lift.
            if decision.phase != .rejected, levelChanged, activeAction == .volume { VolumeFeedbackSound.play(setting: settings.volumeFeedbackSound) }
            finishAdjustment(cancelPending: decision.phase == .rejected)
            // An armed tap's slide lifted: another one soon keeps adjusting;
            // a pause hands every edge back.
            if armedSlide?.sliding == true { waitForSlide(Self.armGrace) }
            return
        }
        guard decision.phase == .accepted else { return }
        if !telemetry.isTesting {
            let edge = decision.region == .left ? "left" : decision.region == .right ? "right" : decision.region == .bottom ? "bottom" : "top"
            EdgeGlow.shared.update(edge: edge, along: decision.region.isSide ? decision.y : decision.x,
                                   tint: self.binding(for: decision).binding.action.lightTint)
        }
        if decision.justAccepted {
            if armedSlide != nil {
                armedSlide?.sliding = true
                armTimeout?.cancel()
            }
            if !telemetry.isTesting {
                beginAdjustment(for: decision)
                KinaraLog.info(.gesture, "Slide on \(decision.region.rawValue) with \(decision.fingers) finger(s): \(activeAction.rawValue)")
                NotificationCenter.default.post(name: .kinaraGestureUsed, object: decision.region.rawValue)
            }
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
        let pendingBefore = taps.pendingTap?.end
        let event = taps.process(contacts: contacts, timestamp: timestamp, configuration: tapConfiguration)
        let telemetry = GestureTelemetry.shared
        if !telemetry.isTesting { tapFeedback(contacts, at: timestamp, pendingBefore: pendingBefore, fired: event != nil) }
        guard let event else { return }
        guard !telemetry.isTesting else { telemetry.publishTap(event, title: EdgeSlot.title(event.slot)); return }
        // Another tap takes over from one that was waiting for its slide.
        disarm()
        let binding = settings.binding(event.slot, appBundleID: currentAppBundleID, docked: isDocked)
        guard binding.action != .disabled, isAvailable(binding),
              NSWorkspace.shared.frontmostApplication?.processIdentifier != nil else { return }
        if binding.action.slidesAfterTap {
            arm(binding, region: event.region, slot: event.slot)
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let placement = Self.placement(for: event.region)
        messagePlacement = placement
        defer { messagePlacement = nil }
        // After a page that slept through play, the next press opens its app instead.
        let waking = binding.action == .playPause ? PlaybackHoldController.shared.appToWake.map { MixerModel.shared.displayName(forApp: $0) } : nil
        // The same spot again soon after puts things back.
        let undoing = waking == nil && (lastTapAction.map { $0.slot == event.slot && $0.action == binding.action && timestamp - $0.time <= Self.undoWindow } ?? false)
        if undoing, binding.action.undoesWithCommandZ {
            lastTapAction = nil
            CornerBloom.shared.fire(event.region, title: "Undone", icon: "arrow.uturn.backward", detail: nil)
            if EdgeActionController.send(.key(6, CGEventFlags.maskCommand.rawValue, global: false), expectedApplication: application) { tick(.single) }
            return
        }
        // The light runs out from the spot, and the bloom names it (first, so a
        // message the action reports lands in its pill).
        CornerLight.shared.flash(event.region, strength: 1, spread: 1)
        if let waking {
            CornerBloom.shared.fire(event.region, title: "Opening \(waking)", icon: "arrow.up.forward.app", detail: nil)
        } else {
            CornerBloom.shared.fire(event.region, title: binding.action.opensPanel ? nil : bloomTitle(binding, undoing: undoing),
                                    icon: undoing ? "arrow.uturn.backward" : binding.action.icon,
                                    detail: bloomDetail(event, action: binding.action, undoing: undoing))
        }
        guard perform(binding, increasing: true, tap: true, region: nil, application: application) else {
            _ = CornerBloom.shared.absorb("Not available here", icon: "exclamationmark.circle", placement: placement)
            return
        }
        tick(.double)
        KinaraLog.info(.gesture, "Tap \(event.slot): \(binding.action.rawValue)\(undoing ? " (undo)" : "")")
        lastTapAction = undoing ? nil : (event.slot, binding.action, timestamp)
        NotificationCenter.default.post(name: .kinaraGestureUsed, object: event.slot)
    }

    /// A level or a stepper needs a direction and an amount, which a tap
    /// can't give: the tap names it, and the next slide on its edge sets it.
    private func arm(_ binding: EdgeBinding, region: TapRegion, slot: String) {
        let sides = Self.armedSides(for: region)
        armedSlide = (binding, sides, false)
        lastTapAction = nil
        gestureBinding = nil
        let edge = sides == [.left] ? "the left edge" : sides == [.right] ? "the right edge" : "a side edge"
        CornerLight.shared.flash(region, strength: 1, spread: 1)
        CornerBloom.shared.fire(region, title: binding.action.label, icon: binding.action.icon, detail: "Slide \(edge) to adjust")
        tick(.double)
        KinaraLog.info(.gesture, "Tap \(slot): \(binding.action.rawValue), waiting for a slide")
        NotificationCenter.default.post(name: .kinaraGestureUsed, object: slot)
        waitForSlide(Self.armWindow)
    }

    /// Stays armed this long for a (further) slide; then every edge is itself again.
    private func waitForSlide(_ seconds: Double) {
        armedSlide?.sliding = false
        armTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.armedSlide?.sliding == false else { return }
            self.disarm()
        }
        armTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func disarm() {
        guard armedSlide != nil else { return }
        armedSlide = nil
        armTimeout?.cancel()
        armTimeout = nil
        gestureBinding = nil
    }

    private func bloomTitle(_ binding: EdgeBinding, undoing: Bool) -> String {
        if undoing && binding.action.undoesByRepeating { return "Undone" }
        if binding.action == .runShortcut, !binding.shortcut.isEmpty { return binding.shortcut }
        return binding.action.label
    }

    /// The first time a spot fires, where to change it; after that, how to undo it.
    private func bloomDetail(_ event: TapEvent, action: ZoneAction, undoing: Bool) -> String? {
        if !settings.seenGestureHints.contains(event.slot) {
            settings.seenGestureHints.insert(event.slot)
            return "\(EdgeSlot.title(event.slot)) · change it in Settings"
        }
        guard !undoing, action.undoesByRepeating || action.undoesWithCommandZ else { return nil }
        return event.gesture == .doubleTap ? "Double-tap again to undo" : "Tap and hold again to undo"
    }

    /// A drop in the screen corner for a first tap, and a preview for a resting finger.
    /// Corners only: tap-to-click along a whole edge is too common to decorate.
    private func tapFeedback(_ contacts: [GestureContact], at timestamp: Double, pendingBefore: Double?, fired: Bool) {
        if let pending = taps.pendingTap, pending.end != pendingBefore, pending.region.isCorner {
            CornerBloom.shared.arm(pending.region)
            // Heard you: a faint flicker in that corner, waiting for the second tap.
            CornerLight.shared.flash(pending.region, strength: 0.5, spread: 0.4)
        }
        let change = fired ? rest.interrupt() : rest.process(contacts: contacts, timestamp: timestamp, configuration: tapConfiguration)
        switch change {
        case let .show(region)? where region.isCorner:
            showRestPreview(region)
            CornerLight.shared.hold(region)
        case .hide?:
            CornerBloom.shared.endPreview()
            CornerLight.shared.release()
        default: break
        }
    }

    private func showRestPreview(_ region: TapRegion) {
        let double = settings.binding("\(region.rawValue).doubleTap", appBundleID: currentAppBundleID, docked: isDocked)
        let hold = settings.binding("\(region.rawValue).tapHold", appBundleID: currentAppBundleID, docked: isDocked)
        let hasDouble = double.action != .disabled, hasHold = hold.action != .disabled
        guard hasDouble || hasHold else { return }
        let main = hasDouble ? double : hold
        let detail = hasDouble ? (hasHold ? "Double-tap · tap and hold: \(hold.action.label)" : "Double-tap") : "Tap and hold"
        CornerBloom.shared.preview(region, title: main.action.label, icon: main.action.icon, detail: detail)
    }

    /// Haptics with a grammar: a double tick for a tap action, a single one for undo.
    private enum Tick { case single, double }
    private func tick(_ kind: Tick) {
        guard settings.hapticFeedback else { return }
        let style = settings.hapticStyle
        HapticOutput.shared.play(style)
        if kind == .double {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { HapticOutput.shared.play(style) }
        }
    }

    /// The screen spot that matches a tapped trackpad edge or corner.
    static func placement(for region: TapRegion) -> OSDPlacement {
        switch region {
        case .left: return OSDPlacement(edge: "left", x: 0, y: 0.5)
        case .right: return OSDPlacement(edge: "right", x: 1, y: 0.5)
        case .top: return OSDPlacement(edge: "top", x: 0.5, y: 1)
        case .bottom: return OSDPlacement(edge: "bottom", x: 0.5, y: 0)
        case .topLeftCorner: return OSDPlacement(edge: "left", x: 0, y: 1)
        case .topRightCorner: return OSDPlacement(edge: "right", x: 1, y: 1)
        case .bottomLeftCorner: return OSDPlacement(edge: "left", x: 0, y: 0)
        case .bottomRightCorner: return OSDPlacement(edge: "right", x: 1, y: 0)
        }
    }

    private func announce(_ text: String, icon: String, at placement: OSDPlacement?) {
        OSDOverlay.shared.show(type: .message(text, icon: icon), value: 1, placement: placement)
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
        commandStepper = GestureActionStepper(levelLike: action.stepsLikeALevel)
        outputScope = UUID()
        activeTarget = target
        activeValue = RelativeGestureValue(value: value)
        fineEngaged = false
        levelChanged = false
        let now = ProcessInfo.processInfo.systemUptime
        if let style = haptics.begin(value: value, configuration: settings.hapticConfiguration, at: now),
           !GestureTelemetry.shared.isTesting, now - lastFrameTime <= 0.12 {
            HapticOutput.shared.play(style)
        }
        NotificationCenter.default.post(name: .swayGestureBegan, object: nil,
                                        userInfo: ["action": activeAction.rawValue])
        if decision.fingers == 1 && settings.cursorFreezeOnOneFinger,
           let event = CGEvent(source: nil) {
            // CGEvent.location and CGWarpMouseCursorPosition share global display
            // coordinates, including negative origins on secondary displays. The pointer
            // goes back to where the finger landed, undoing the drift before acceptance.
            frozenCursorPosition = captureCursor ?? event.location
            CGWarpMouseCursorPosition(frozenCursorPosition)
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
        let audio = AudioAppPicker.shared
        if activeAction == .audioApps, audio.isOpen, audio.mode == .swipe {
            cancelPending ? audio.cancel() : audio.commit()
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
        let entersFine = fine && !fineEngaged
        fineEngaged = fine
        let previous = value.value
        let requested = value.apply(delta: decision.delta, sensitivity: settings.sensitivity,
                                    inverted: settings.invertScrollDirection, bounds: bounds,
                                    scale: shaping, notches: notches, capture: TrackpadSettings.notchCapture)
        guard abs(requested - previous) > 0.00001 else {
            if entersFine { cue(.soft) }
            return
        }
        // Accumulate from the requested continuous value, not delayed/quantized
        // device readback. The controllers coalesce writes off the main thread.
        activeValue = value
        levelChanged = true
        // Extra dim begins where the hardware ends, and that edge is a detent too.
        let detents = dimming ? notches + [limits(for: .brightness).lowerBound] : notches
        if !haptic(at: requested, bounds: bounds, notches: detents), entersFine { cue(.soft) }
        let placement = OSDPlacement(edge: region == .left ? "left" : region == .right ? "right" : region == .bottom ? "bottom" : "top",
                                     x: decision.x, y: decision.y)
        requestLevel(requested, region: region, scope: scope, placement: placement)
    }

    // Keep the epoch stable through this gesture. Already-applied samples
    // can render while a newer desired value is pending; filtering by every
    // request would freeze feedback whenever the driver runs below 120 Hz.
    private func requestLevel(_ requested: Double, region: GestureRegion, scope: UUID, placement: OSDPlacement) {
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
                    self.publishAdjustment(measured, action: action, region: region, placement: placement)
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
                if dim > 0 { OSDOverlay.shared.show(type: .extraDim, value: Float(1 - dim), placement: placement) }
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
                    self.publishAdjustment(measured, action: .brightness, region: region, placement: placement)
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
                case let .applied(gain): self.publishAdjustment(gain, action: .appVolume, region: region, placement: placement)
                case let .failed(reason): self.cancelCurrentGesture(reason: reason)
                case .cancelled: break
                }
            }
        case .nightShift:
            NightShiftController.shared.request(Float(requested)) { [weak self] level in
                guard let self, self.outputRevision == revision, let level else { return }
                self.publishAdjustment(level, action: .nightShift, region: region, placement: placement)
            }
        case .extraDim:
            guard let display = dimTargetDisplay(), GammaDimmer.shared.setLevel(Float(1 - requested), for: display) else {
                cancelCurrentGesture(reason: "This display does not allow extra dimming.")
                return
            }
            publishAdjustment(Float(requested), action: .extraDim, region: region, placement: placement)
        case .seek:
            guard let info = seekBaseline, let duration = info.duration else { return }
            let seconds = requested * duration
            if settings.nowPlayingHUD { NowPlayingHUD.shared.show(info, scrubPosition: seconds) }
            NowPlayingController.shared.requestSeek(to: seconds) { [weak self] success in
                guard let self, self.outputRevision == revision, !success else { return }
                self.cancelCurrentGesture(reason: "The player did not accept the new position.")
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
        if activeAction == .audioApps {
            let picker = AudioAppPicker.shared
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
                    if action == .outputMute { self.publishAdjustment(muted ? 0 : value, action: .volume, region: region, placement: nil) }
                    else {
                        NotificationCenter.default.post(name: .microphoneMuteChanged, object: muted)
                    }
                case .failed: self.cancelCurrentGesture(reason: "The device did not confirm the mute change. Check its controls.")
                case .cancelled: break
                }
            }
            return
        }
        messagePlacement = OSDPlacement(edge: region == .left ? "left" : region == .right ? "right" : region == .bottom ? "bottom" : "top",
                                        x: recognizer.decision.x, y: recognizer.decision.y)
        defer { messagePlacement = nil }
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
            let placement = messagePlacement
            TrueToneController.shared.setEnabled(on) { [weak self] state in
                guard let state else { return }
                self?.announce(state ? "True Tone on" : "True Tone off", icon: "circle.lefthalf.fill", at: placement)
            }
            return true
        case .muteApp, .soloApp:
            guard let bundle = NSRunningApplication(processIdentifier: application)?.bundleIdentifier, AppVolumeController.isSupported else { return false }
            let mixer = MixerModel.shared, name = mixer.displayName(forApp: bundle)
            if binding.action == .muteApp {
                let muted = mixer.setMuted(tap ? nil : !increasing, forApp: bundle)
                announce(muted ? "\(name) muted" : "\(name) unmuted", icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", at: messagePlacement)
            } else {
                let soloed = mixer.setSoloed(tap ? nil : increasing, forApp: bundle)
                announce(soloed ? "Only \(name) is playing" : "Solo off", icon: "headphones", at: messagePlacement)
            }
            return true
        case .audioOutput:
            let placement = messagePlacement
            AudioOutputSwitcher.cycle(forward: increasing) { [weak self] device in
                self?.announce(device?.name ?? "No other audio output", icon: "airplayaudio", at: placement)
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
        case .ambientLight:
            // A tap toggles; a swipe up starts it, down stops it.
            if tap { AmbientLight.shared.toggle() } else if increasing { AmbientLight.shared.start() } else { AmbientLight.shared.stop() }
            let on = AmbientLight.shared.isRunning
            announce(on ? "Ambient light on" : "Ambient light off", icon: "light.ribbon", at: messagePlacement)
            return true
        case .missionControl:
            // macOS's own Mission Control app: it works whatever the keyboard shortcut is set to.
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { KinaraLog.warning(.output, "Mission Control didn't open: \(error.localizedDescription)") }
            }
            return true
        case .playPause:
            // Predictable with several apps playing: one press quiets them all, the next brings them back.
            let placement = messagePlacement
            return PlaybackHoldController.shared.toggle(placement: placement) { [weak self] in self?.showNowPlaying(after: 0.45, placement: placement) }
        case .pastePrevious:
            return ClipboardHistory.shared.pastePrevious(into: application)
        case .clipboardHistory:
            // A tap opens the picker; the next one-finger slide chooses.
            ClipboardPicker.shared.open(mode: .touch, application: application)
            return true
        case .audioApps:
            // Like the clipboard: a tap opens it, the next slide chooses an app.
            AudioAppPicker.shared.open(mode: .touch, application: application)
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
            if binding.action == .mediaTracks { showNowPlaying(after: 0.45, placement: messagePlacement) }
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

    /// The track card; after a corner tap, the track goes into that tap's pill instead.
    private func showNowPlaying(after delay: Double, placement: OSDPlacement? = nil) {
        guard settings.nowPlayingHUD || CornerBloom.shared.isShowingTap else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [settings] in
            NowPlayingController.shared.fetch { info in
                guard let info else { return }
                let state = info.isPlaying ? "Playing" : "Paused"
                let title = info.title.isEmpty ? state : info.title
                let detail = info.title.isEmpty ? (info.artist.isEmpty ? nil : info.artist) : [state, info.artist].filter { !$0.isEmpty }.joined(separator: " · ")
                if CornerBloom.shared.absorb(title, icon: info.isPlaying ? "play.fill" : "pause.fill", detail: detail, placement: placement) { return }
                if settings.nowPlayingHUD { NowPlayingHUD.shared.show(info) }
            }
        }
    }

    private func outputFinished(in scope: UUID) {
        guard let pending = pendingOutputs[scope] else { return }
        if pending.count <= 1 { pendingOutputs[scope] = nil }
        else { pendingOutputs[scope]?.count -= 1 }
    }

    /// Measured readback drives the indicator only; haptics already followed the finger.
    private func publishAdjustment(_ measured: Float, action: ZoneAction, region: GestureRegion,
                                   placement: OSDPlacement?) {
        var info: [String: Any] = ["zone": region == .left || region == .topLeft ? "left" : "right",
                                   "gestureRegion": region.rawValue]
        if let placement { info["placement"] = placement }
        switch action {
        case .volume, .brightness, .microphoneLevel:
            let name: Notification.Name
            if action == .volume { name = region.isTop ? .topEdgeVolumeChanged : .volumeChanged }
            else if action == .microphoneLevel { name = .microphoneLevelChanged }
            else { name = region.isTop ? .topEdgeBrightnessChanged : .brightnessChanged }
            NotificationCenter.default.post(name: name, object: measured, userInfo: info)
        case .appVolume: OSDOverlay.shared.show(type: .appVolume, value: measured, placement: placement)
        case .nightShift: OSDOverlay.shared.show(type: .nightShift, value: measured, placement: placement)
        case .extraDim: OSDOverlay.shared.show(type: .extraDim, value: measured, placement: placement)
        default: break
        }
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
        case .audioApps: return AppVolumeController.isSupported
        case .nightShift: return NightShiftController.shared.isAvailable
        case .trueTone: return TrueToneController.shared.isAvailable
        case .runShortcut:
            return ShortcutsRunner.isAvailable && !(binding.shortcut.isEmpty && binding.downShortcut.isEmpty)
        case .extraDim, .seek, .nowPlaying, .cheatSheet, .ambientLight, .audioOutput: return true
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

    /// Detents follow the finger: the level it asked for, on the frame it asked.
    /// Device readback arrives late, paced and quantized, so ticks driven by it
    /// landed somewhere different every slide. Returns whether it tapped.
    @discardableResult
    private func haptic(at value: Double, bounds: ClosedRange<Double>, notches: [Double]) -> Bool {
        guard settings.hapticFeedback else { haptics.end(); return false }
        guard let style = haptics.update(value: value, bounds: bounds, at: ProcessInfo.processInfo.systemUptime,
                                         notches: notches) else { return false }
        HapticOutput.shared.play(style)
        return true
    }

    /// A one-off tap that keeps the slide's cadence, such as precision engaging.
    private func cue(_ style: HapticStyle) {
        guard settings.hapticFeedback,
              let style = haptics.cue(style, at: ProcessInfo.processInfo.systemUptime) else { return }
        HapticOutput.shared.play(style)
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
        KinaraLog.info(.taps, "Input tap installed")
        watchTaps()
        return true
    }

    private func removeEventTap() {
        removeFreezeTap()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if eventTap != nil { KinaraLog.info(.taps, "Input tap removed") }
        eventTap = nil
        runLoopSource = nil
        watchTaps()
    }

    /// The watchdog guards whichever taps are in the input path right now.
    private func watchTaps() {
        MainThreadWatchdog.shared.watch([eventTap, freezeTap].compactMap { $0 })
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
        watchTaps()
    }

    private func removeFreezeTap() {
        if let freezeTap {
            CGEvent.tapEnable(tap: freezeTap, enable: false)
            CFMachPortInvalidate(freezeTap)
        }
        if let freezeSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), freezeSource, .commonModes) }
        freezeTap = nil
        freezeSource = nil
        watchTaps()
    }

    private func handleFreezeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverTap(freezeTap, type)
            return Unmanaged.passUnretained(event)
        }
        guard cursorFreezeActive || pointerHeldForPicker else { return Unmanaged.passUnretained(event) }
        // Never call back into the window server from inside its own tap: that can
        // stall both. Put the pointer back on the next turn, once, however many moves.
        if !warpScheduled {
            warpScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.warpScheduled = false
                if self.cursorFreezeActive || self.pointerHeldForPicker { CGWarpMouseCursorPosition(self.frozenCursorPosition) }
            }
        }
        return nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard isRunning else { return pass }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelCurrentGesture(reason: "Input monitoring was interrupted. Lift your fingers to reset.")
            scrollCapture = GestureScrollCapture()
            claimedButtons.removeAll()
            recoverTap(eventTap, type)
            return pass
        }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .keyDown {
            if event.getIntegerValueField(.eventSourceUserData) == EdgeActionController.eventMarker { return pass }
            // Like a screensaver, the ambient light ends at the first key; the key still goes through.
            if AmbientLight.shared.isRunning { AmbientLight.shared.stop() }
            // While a picker is up, its keys (typing to search, esc, return,
            // arrows, ⌘1–9) choose; the app in front keeps focus and receives nothing.
            if let picker = TrackpadPickers.open,
               picker.handleKey(code: event.getIntegerValueField(.keyboardEventKeycode),
                                characters: NSEvent(cgEvent: event)?.characters, flags: event.flags) {
                return nil
            }
            // ⌘C / ⌘X: let clipboard history read the result once, shortly after.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if event.flags.contains(.maskCommand), [7, 8].contains(code) {
                ClipboardHistory.shared.noteCopy()
            }
            // ⌘⌃⇧3: a screenshot straight to the clipboard, ready a moment later.
            if event.flags.isSuperset(of: [.maskCommand, .maskControl, .maskShift]), code == 20 {
                ClipboardHistory.shared.noteCopy(after: 1.0)
            }
            let decision = recognizer.keyDown(at: now)
            taps.keyDown(at: now)
            if rest.interrupt(at: now) == .hide { CornerBloom.shared.endPreview() }
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
        if (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown),
           TrackpadPickers.claimsClick(at: now) {
            // Clicks belong to a picker while it is up: a press chooses, and
            // the tap-to-click after a choosing lift never reaches the app.
            if let picker = TrackpadPickers.open, picker.isTouchMode, lastContactCount > 0 { picker.commit() }
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
            // A real click ends the ambient light; a tap's own claimed click (above) doesn't.
            if AmbientLight.shared.isRunning { AmbientLight.shared.stop() }
            if rest.interrupt() == .hide { CornerBloom.shared.endPreview() }
            cancelCurrentGesture(reason: "Click detected. Lift your fingers before swiping.")
            return pass
        }
        guard type == .scrollWheel else { return pass }
        guard let scrolling = NSEvent(cgEvent: event), scrolling.hasPreciseScrollingDeltas else { return pass }
        // The open picker owns the trackpad; pages behind it don't scroll.
        if TrackpadPickers.open?.isTouchMode == true { return nil }
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

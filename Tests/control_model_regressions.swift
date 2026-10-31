import Foundation
import CoreAudio
import CoreGraphics

private final class ModelAudioBackend: AudioOutputBackend {
    private let lock = NSLock()
    var token = AudioOutputToken(device: 42, source: nil)
    var scalar: Float = 0.4
    var muted = false
    var failWrites = false
    var operations: [String] = []
    var blocker: (kind: String, entered: DispatchSemaphore, release: DispatchSemaphore)?
    private var queue: DispatchQueue?
    private var handler: ((AudioBackendEvent) -> Void)?
    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func start(on queue: DispatchQueue, handler: @escaping (AudioBackendEvent) -> Void) {
        locked { self.queue = queue; self.handler = handler }
    }
    func stop() { locked { handler = nil } }
    func currentOutput() -> AudioOutputToken? { locked { token } }
    func configuration(for token: AudioOutputToken) -> AudioOutputConfiguration {
        AudioOutputConfiguration(token: token, name: "Fake speakers", volumeElements: [0], volumeWritable: true,
                                 muteElements: [0], muteWritable: true)
    }
    func observe(_ configuration: AudioOutputConfiguration?) {}
    func volume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? { locked { scalar } }
    func mute(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? { locked { muted } }
    private func waitIfBlocked(_ kind: String) {
        let wait = locked { () -> (String, DispatchSemaphore, DispatchSemaphore)? in
            guard blocker?.kind == kind else { return nil }
            defer { blocker = nil }
            return blocker
        }
        wait?.1.signal()
        if let wait { _ = wait.2.wait(timeout: .now() + 3) }
    }
    func setVolume(_ value: Float, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        waitIfBlocked("volume")
        return locked { operations.append("volume"); if failWrites { return false }; scalar = value; return true }
    }
    func setMute(_ value: Bool, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        waitIfBlocked("mute")
        return locked { operations.append(value ? "mute" : "unmute"); if failWrites { return false }; muted = value; return true }
    }
    func emit(_ event: AudioBackendEvent) {
        let state = locked { (queue, handler) }
        state.0?.async { state.1?(event) }
    }
    func block(_ kind: String) -> (DispatchSemaphore, DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        locked { blocker = (kind, entered, release) }
        return (entered, release)
    }
}

private final class ModelDisplayBackend: BrightnessHardware {
    let canWrite = true
    private let lock = NSLock()
    private var value: Float = 0.7
    private var handler: (() -> Void)?
    func activeDisplays() -> [CGDirectDisplayID] { [17] }
    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool { display == 17 }
    func isActive(_ display: CGDirectDisplayID) -> Bool { display == 17 }
    func read(_ display: CGDirectDisplayID) -> Float? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: Float, to display: CGDirectDisplayID) -> Bool {
        lock.lock(); self.value = value; lock.unlock(); return true
    }
    func observeChanges(_ callback: @escaping () -> Void) { handler = callback }
}

private final class ModelFixture {
    let backend = ModelAudioBackend()
    let audio: VolumeController
    let display: BrightnessController
    let model: ControlCenterModel
    let suite = "Sway.ControlTests.\(UUID().uuidString)"
    init() {
        audio = VolumeController(backend: backend)
        display = BrightnessController(backend: ModelDisplayBackend())
        let settings = TrackpadSettings(defaults: UserDefaults(suiteName: suite)!)
        model = ControlCenterModel(settings: settings, preview: false, audio: audio, display: display)
        audio.flushWorkerForTesting()
        model.refresh()
        ControlModelTests.waitFor("fixture hardware ready") { model.volumeAvailable && model.brightnessAvailable }
    }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

@main private enum ControlModelTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }; checks += 1
    }
    static func close(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.0001 }
    static func waitFor(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
        expect(condition(), message)
    }
    static func main() {
        if CommandLine.arguments.contains("--probe-action-capabilities") {
            // Explicit read-only probe. Normal CI below uses fake hardware only.
            let input = VolumeController.microphone
            input.flushWorkerForTesting()
            let keyboard = KeyboardBacklightCapability.shared
            waitFor("keyboard capability discovery") { keyboard.checked }
            print("Read-only capabilities: keyboard backlight=\(keyboard.isAvailable), input gain=\(input.isAvailable), input hardware mute=\(input.supportsMute). No device writes or audio recording.")
            return
        }
        testRapidMute()
        testOptimisticDrag()
        testExternalAndFailures()
        testAtomicUndoAndRouteGuard()
        testVisibilityAndPreview()
        testActionLibrary()
        testMicrophoneSafety()
        testExpandedActions()
        print("\(checks) control model regression checks passed (fake audio/display hardware only).")
    }

    /// Pure helpers behind the new actions. Nothing here moves a window,
    /// switches audio, runs a Shortcut, or changes a display.
    static func testExpandedActions() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let left = WindowTiler.frame(for: .leftHalf, visibleFrame: visible, primaryHeight: 900)
        let right = WindowTiler.frame(for: .rightHalf, visibleFrame: visible, primaryHeight: 900)
        let fill = WindowTiler.frame(for: .fill, visibleFrame: visible, primaryHeight: 900)
        expect(left == CGRect(x: 0, y: 0, width: 720, height: 860), "left half starts below the menu bar in top-left coordinates")
        expect(right.minX == 720 && right.width == 720 && right.minY == 0, "right half meets the left half exactly")
        expect(fill == CGRect(x: 0, y: 0, width: 1440, height: 860), "fill uses the whole visible frame")
        let secondary = WindowTiler.frame(for: .rightHalf, visibleFrame: CGRect(x: 1440, y: -200, width: 1001, height: 1000), primaryHeight: 900)
        expect(secondary.minX == 1940 && secondary.width == 501 && secondary.minY == 100, "odd widths and lower secondary displays are covered")
        expect(WindowTiler.appKitPoint(CGPoint(x: 10, y: 100), primaryHeight: 900) == CGPoint(x: 10, y: 800), "coordinate conversion round-trips")

        let outputs = [AudioOutputDevice(id: 3, uid: "a", name: "AirPods"), AudioOutputDevice(id: 7, uid: "b", name: "Speakers"),
                       AudioOutputDevice(id: 9, uid: "c", name: "Studio Display")]
        expect(AudioOutputSwitcher.next(after: 3, in: outputs, forward: true)?.id == 7, "next output")
        expect(AudioOutputSwitcher.next(after: 9, in: outputs, forward: true)?.id == 3, "output order wraps forward")
        expect(AudioOutputSwitcher.next(after: 3, in: outputs, forward: false)?.id == 9, "output order wraps backward")
        expect(AudioOutputSwitcher.next(after: 42, in: outputs, forward: true)?.id == 3, "an unlisted current output starts at the first")
        expect(AudioOutputSwitcher.next(after: 3, in: [], forward: true) == nil, "no outputs means nothing to switch to")

        expect(ShortcutsRunner.parseList("Lights On\nFocus\n\nLights On\n  Arrive Home \n") == ["Arrive Home", "Focus", "Lights On"],
               "Shortcut names are trimmed, deduplicated and sorted")
        expect(!ShortcutsRunner.run("   "), "a blank Shortcut name never launches anything")

        func command(_ text: String) -> SwayURLCommand? { URL(string: text).flatMap(SwayURLCommand.parse) }
        expect(command("sway://pause") == .pause(minutes: nil) && command("sway://pause?minutes=15") == .pause(minutes: 15), "pause commands")
        expect(command("sway://pause?minutes=0") == nil && command("sway://pause?minutes=99999") == nil, "absurd pause lengths are refused")
        expect(command("sway://volume?level=40") == .volume(0.4) && command("SWAY://Brightness?level=100") == .brightness(1), "levels are percentages")
        expect(command("sway://volume?level=140") == nil && command("sway://volume?level=nan") == nil && command("sway://volume") == nil, "invalid levels are refused")
        expect(command("sway://resume") == .resume && command("sway://toggle") == .toggle && command("sway://edge-map") == .edgeMap, "simple commands")
        expect(command("sway://run-shortcut?name=x") == nil && command("https://example.com/pause") == nil, "unknown commands and other schemes do nothing")

        expect(GammaDimmer.scale(for: 0) == 1 && abs(GammaDimmer.scale(for: 1) - GammaDimmer.darkestScale) < 0.0001, "extra dim spans normal to the darkest safe level")
        expect(GammaDimmer.scale(for: .nan) == 1 && abs(GammaDimmer.scale(for: 7) - GammaDimmer.darkestScale) < 0.0001, "invalid dim levels stay safe")
        expect(GammaDimmer.darkestScale >= 0.2, "extra dim never goes fully black")

        expect(VolumeFeedbackSound.shouldPlay(setting: "system", systemPreference: true) && !VolumeFeedbackSound.shouldPlay(setting: "system", systemPreference: false),
               "system setting follows the Sound preference")
        expect(VolumeFeedbackSound.shouldPlay(setting: "on", systemPreference: false) && !VolumeFeedbackSound.shouldPlay(setting: "off", systemPreference: true),
               "explicit choices override the system")

        let suite = "com.sway.control-edgemap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TrackpadSettings(defaults: defaults)
        settings.setBaseBinding(EdgeBinding(.playPause), for: "left.doubleTap")
        settings.appProfiles["com.example.editor"] = ActionProfile(name: "Editor", bindings: ["right": EdgeBinding(.tabs)])
        let map = EdgeMapEntry.resolve(settings: settings, appBundleID: "com.example.editor", docked: false)
        expect(map.map(\.slot) == ["left", "right", "left.doubleTap"], "the edge map lists swipe edges and only assigned extras")
        expect(map[1].action == .tabs && map[1].source == .app && map[0].source == .everyday, "the edge map explains where each action comes from")
        for action in ZoneAction.allCases where action.worksAsTap { expect(!action.isContinuous, "\(action.rawValue) tap fires once") }
        expect(!ZoneAction.volume.worksAsTap && ZoneAction.outputMute.togglesOnTap, "levels cannot be taps; mute toggles")

        let command = CGEventFlags.maskCommand.rawValue, shift = CGEventFlags.maskShift.rawValue
        expect(EdgeCommand.resolve(.paste, increasing: false) == .key(9, command, global: false), "paste is Command-V to the app in front")
        expect(EdgeCommand.resolve(.pastePlain, increasing: true) == .key(9, command | shift | CGEventFlags.maskAlternate.rawValue, global: false), "plain paste adds Option-Shift")
        expect(EdgeCommand.resolve(.undoRedo, increasing: false) == .key(6, command, global: false), "down undoes")
        expect(EdgeCommand.resolve(.undoRedo, increasing: true) == .key(6, command | shift, global: false), "up redoes")
        expect(EdgeCommand.resolve(.newCloseTab, increasing: true) == .key(17, command, global: false)
               && EdgeCommand.resolve(.newCloseTab, increasing: false) == .key(13, command, global: false), "up opens a tab, down closes one")
        expect(EdgeCommand.resolve(.lockScreen, increasing: true) == .key(12, command | CGEventFlags.maskControl.rawValue, global: true), "lock screen is a global shortcut")
        expect(ZoneAction.undoRedo.repeatsWhileSwiping && ZoneAction.clipboardHistory.repeatsWhileSwiping && !ZoneAction.paste.repeatsWhileSwiping,
               "undo and history step as you swipe; paste fires once")
        expect(ZoneAction.paste.worksAsTap && ZoneAction.pastePrevious.worksAsTap && ZoneAction.categories.contains("Editing"), "editing actions fit corner taps")

        // Clipboard history rules, without touching the real pasteboard.
        expect(ClipboardHistory.shouldRecord(types: ["public.utf8-plain-text"], text: "hello"), "ordinary text is recorded")
        expect(!ClipboardHistory.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], text: "hunter2"), "concealed items are never recorded")
        expect(!ClipboardHistory.shouldRecord(types: ["org.nspasteboard.TransientType"], text: "otp"), "transient items are never recorded")
        expect(!ClipboardHistory.shouldRecord(types: [], text: "   \n") && !ClipboardHistory.shouldRecord(types: [], text: nil), "blank or missing text is skipped")
        expect(!ClipboardHistory.shouldRecord(types: [], text: String(repeating: "x", count: ClipboardHistory.maximumLength + 1)), "huge items are skipped")
        func item(_ text: String) -> ClipboardItem { ClipboardItem(text: text, appName: "Notes", bundleID: "com.apple.Notes", date: Date()) }
        var history = ClipboardHistory.inserting(item("b"), into: [item("a")])
        history = ClipboardHistory.inserting(item("a"), into: history)
        expect(history.map(\.text) == ["a", "b"], "re-copying moves an item to the front without duplicates")
        history = (0..<40).reduce(history) { ClipboardHistory.inserting(item("item \($1)"), into: $0) }
        expect(history.count == ClipboardHistory.capacity && history.first?.text == "item 39", "history keeps only the newest items")
        let now = Date()
        expect(ClipboardHistory.age(of: now, now: now) == "now" && ClipboardHistory.age(of: now.addingTimeInterval(-42), now: now) == "42s"
               && ClipboardHistory.age(of: now.addingTimeInterval(-600), now: now) == "10m" && ClipboardHistory.age(of: now.addingTimeInterval(-7200), now: now) == "2h"
               && ClipboardHistory.age(of: now.addingTimeInterval(-200_000), now: now) == "2d", "ages read at a glance")
        expect(ClipboardHistory.age(of: now.addingTimeInterval(60), now: now) == "now", "a clock change never shows a negative age")
        expect(ClipboardHistory.preview("one\n\n  two  \nthree") == "one ⏎ two ⏎ three", "multi-line previews fit one row")
        expect(ClipboardHistory.preview(String(repeating: "y", count: 200)).count == 90, "long previews are shortened")
        expect(!ClipboardHistory.shared.isEnabled, "history is off unless a clipboard action is assigned")
        expect(ClipboardPicker.initialSelection(count: 5) == 1 && ClipboardPicker.initialSelection(count: 1) == 0
               && ClipboardPicker.initialSelection(count: 0) == -1, "the picker opens on the previous item, or Cancel when empty")
        let step = ClipboardPicker.travelPerItem
        var position = 1.0
        position = ClipboardPicker.advance(position, by: -step * 2, count: 5)
        expect(ClipboardPicker.selection(at: position) == 3, "sliding down two items chooses older copies")
        position = ClipboardPicker.advance(position, by: -step * 50, count: 5)
        expect(ClipboardPicker.selection(at: position) == 4, "the oldest item is the floor")
        position = ClipboardPicker.advance(position, by: step * 50, count: 5)
        expect(ClipboardPicker.selection(at: position) == -1, "sliding up past the newest reaches Cancel")
        position = ClipboardPicker.advance(position, by: -step * 1, count: 5)
        expect(ClipboardPicker.selection(at: position) == 0, "one row back down from Cancel is the newest copy")
        expect(ClipboardPicker.advance(2, by: .nan, count: 5) == 2 && ClipboardPicker.advance(2, by: step, count: 0) == 2, "invalid travel changes nothing")
        let picker = ClipboardPicker.shared
        expect(!picker.isOpen && !picker.handleKey(code: 53, characters: nil), "a closed picker never swallows keys")
        ClipboardHistory.shared.noteCopy()
        expect(ClipboardHistory.shared.items.isEmpty, "a disabled history never reads the pasteboard")
    }

    static func testActionLibrary() {
        expect(EdgeActionController.canDispatch(hasAccess: true, testing: false, expectedApplication: 42, currentApplication: 42), "commands need a live matching app")
        expect(!EdgeActionController.canDispatch(hasAccess: false, testing: false, expectedApplication: 42, currentApplication: 42), "no command without Accessibility")
        expect(!EdgeActionController.canDispatch(hasAccess: true, testing: true, expectedApplication: 42, currentApplication: 42), "safe test blocks command dispatch")
        expect(!EdgeActionController.canDispatch(hasAccess: true, testing: false, expectedApplication: 42, currentApplication: 99), "app switch cancels command dispatch")
        expect(!EdgeActionController.canDispatch(hasAccess: true, testing: false, expectedApplication: 42, currentApplication: nil), "missing foreground app cancels dispatch")
        let events = EdgeActionController.keyboardEvents(code: 48, flags: CGEventFlags.maskCommand.rawValue, physicalFlags: [])!
        expect(events.count == 3 && events[0].type == .keyDown && events[1].type == .keyUp, "paired key events are constructed without posting")
        expect(events[2].type == .flagsChanged && events[2].flags.isEmpty, "Command-Tab explicitly releases its synthetic modifier")
        expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == EdgeActionController.eventMarker }, "own events never count as typing")
        let held = EdgeActionController.keyboardEvents(code: 48, flags: CGEventFlags.maskCommand.rawValue, physicalFlags: .maskCommand)!
        expect(held.count == 2, "physically held modifiers are not synthetically released")
        expect(ZoneAction.allCases.count == 50, "49 assignable actions plus Off")
        for action in ZoneAction.allCases {
            expect(!action.label.isEmpty && !action.icon.isEmpty && !action.guidance.isEmpty, "every action has usable metadata")
            expect(ZoneAction.categories.contains(action.category), "all actions appear in a category")
            let performedDirectly: [ZoneAction] = [.outputMute, .microphoneMute, .customShortcut, .disabled, .audioOutput,
                                                   .nowPlaying, .tileWindow, .trueTone, .runShortcut, .cheatSheet,
                                                   .pastePrevious, .clipboardHistory, .sleepDisplay]
            if action.isContinuous || performedDirectly.contains(action) {
                expect(EdgeCommand.resolve(action, increasing: true) == nil, "\(action.rawValue) never becomes a keystroke")
            } else {
                expect(EdgeCommand.resolve(action, increasing: true) != nil && EdgeCommand.resolve(action, increasing: false) != nil,
                       "both directions resolve for \(action.rawValue)")
            }
        }
        expect(EdgeCommand.resolve(.keyboardBrightness, increasing: true) == .media(21), "keyboard up maps to illumination key")
        expect(EdgeCommand.resolve(.keyboardBrightness, increasing: false) == .media(22), "keyboard down maps to illumination key")
        expect(EdgeCommand.resolve(.mediaTracks, increasing: true) == .media(17), "next track key")
        expect(EdgeCommand.resolve(.mediaTracks, increasing: false) == .media(18), "previous track key")
        expect(EdgeCommand.resolve(.playPause, increasing: false) == .media(16), "media toggle key")
        expect(EdgeCommand.resolve(.customShortcut, increasing: true) == nil, "empty custom shortcut cannot dispatch")
        expect(EdgeCommand.resolve(.customShortcut, increasing: true, custom: HotkeyCombo(keyCode: 300, modifiers: 256)) == nil, "invalid virtual key rejected")
        expect(EdgeCommand.resolve(.customShortcut, increasing: true, custom: HotkeyCombo(keyCode: 12, modifiers: 0)) == nil, "unmodified custom key rejected")
        var oneShot = GestureActionStepper()
        expect(oneShot.consume(delta: 0.01, sensitivity: 1, inverted: false, repeats: false, at: 1) == nil, "short motion does not trigger")
        expect(oneShot.consume(delta: 0.016, sensitivity: 1, inverted: false, repeats: false, at: 1.1) == true, "deliberate motion sends up")
        for index in 0..<100 {
            expect(oneShot.consume(delta: index % 2 == 0 ? -0.1 : 0.1, sensitivity: 1, inverted: false, repeats: false, at: Double(index + 2)) == nil,
                   "one-shot cannot repeat or reverse before lift")
        }
        var steps = GestureActionStepper()
        expect(steps.consume(delta: 0.03, sensitivity: 1, inverted: false, repeats: true, at: 1) == true, "repeatable action begins")
        expect(steps.consume(delta: 0.08, sensitivity: 1, inverted: false, repeats: true, at: 1.05) == nil, "fast events are dropped")
        expect(steps.consume(delta: 0.001, sensitivity: 1, inverted: false, repeats: true, at: 2) == nil, "dropped motion is not replayed")
        expect(steps.consume(delta: -0.04, sensitivity: 1, inverted: false, repeats: true, at: 3) == nil, "reversal starts fresh travel")
        expect(steps.consume(delta: -0.04, sensitivity: 1, inverted: false, repeats: true, at: 3.3) == false, "negative travel fires once")
        var inverted = GestureActionStepper()
        expect(inverted.consume(delta: 0.03, sensitivity: 1, inverted: true, repeats: false, at: 1) == false, "reversed direction works for commands")
        for invalid in [Double.nan, .infinity, 0.5] {
            var gate = GestureActionStepper()
            expect(gate.consume(delta: invalid, sensitivity: 1, inverted: false, repeats: true, at: 1) == nil, "invalid jumps rejected")
        }
        let fixture = ModelFixture()
        fixture.model.captureUndo(.volume)
        fixture.model.captureUndo(.microphoneLevel)
        expect(fixture.model.undoValues?.action == .volume, "new actions never capture a bogus brightness undo")
        expect(!fixture.model.adjust(.microphoneLevel, to: 0.8), "legacy slider rejects non-slider actions")
    }

    static func testMicrophoneSafety() {
        let backend = ModelAudioBackend()
        backend.muted = true
        let input = VolumeController(backend: backend, notification: .swayInputStateChanged, preservesMuteOnGain: true)
        input.flushWorkerForTesting()
        var result: VolumeRequestResult?
        input.requestVolume(0.7, muteAtZero: false) { result = $0 }
        waitFor("input gain completes") { result != nil }
        expect(backend.locked { backend.muted && backend.scalar == 0.7 }, "microphone gain never clears hardware mute")
        expect(backend.locked { backend.operations } == ["volume"], "no mute writes from microphone gain")
        result = nil
        input.requestMuted(false) { result = $0 }
        waitFor("explicit unmute completes") { result != nil }
        expect(!backend.locked { backend.muted }, "explicit microphone unmute still works")
        result = nil
        input.requestVolume(0, muteAtZero: true) { result = $0 }
        waitFor("zero input gain completes") { result != nil }
        expect(!backend.locked { backend.muted }, "zero input gain never masquerades as microphone mute")
    }

    static func testRapidMute() {
        let fixture = ModelFixture(), model = fixture.model
        let blocked = fixture.backend.block("mute")
        model.toggleMute()
        expect(model.isMuted, "first mute click is immediately reflected")
        expect(blocked.0.wait(timeout: .now() + 1) == .success, "slow mute driver entered")
        model.toggleMute()
        expect(!model.isMuted, "second rapid mute click reverses optimistic intention")
        blocked.1.signal()
        waitFor("rapid mute reaches final intended state") {
            fixture.backend.locked { fixture.backend.operations.count >= 2 && !fixture.backend.muted }
        }
        fixture.audio.flushWorkerForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        expect(!model.isMuted, "old mute readback never overrides final unmute")
        expect(fixture.backend.locked { fixture.backend.operations } == ["mute", "unmute"], "rapid clicks execute opposite mute states")
    }

    static func testOptimisticDrag() {
        let fixture = ModelFixture(), model = fixture.model
        model.captureUndo(.volume)
        let first = fixture.backend.block("volume")
        expect(model.adjust(.volume, to: 0.6), "first slider request accepted")
        expect(first.0.wait(timeout: .now() + 1) == .success, "first slow scalar entered")
        let second = fixture.backend.block("volume")
        expect(model.adjust(.volume, to: 0.8), "next slider request accepted")
        expect(close(model.volume, 0.8), "slider tracks latest desired position immediately")
        var measuredProgress: [Float] = []
        let observer = NotificationCenter.default.addObserver(forName: .volumeChanged, object: nil, queue: nil) {
            if let value = $0.object as? Float { measuredProgress.append(value) }
        }
        first.1.signal()
        expect(second.0.wait(timeout: .now() + 1) == .success, "latest scalar begins after first measured write")
        waitFor("measured in-flight progress is published") { !measuredProgress.isEmpty }
        expect(close(model.volume, 0.8), "old actual readback does not snap back a dragged slider")
        expect(close(Double(measuredProgress[0]), 0.6), "OSD notification is measured, not optimistic")
        second.1.signal()
        waitFor("final slider hardware value settles") { close(Double(fixture.audio.getVolume()), 0.8) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        expect(close(model.volume, 0.8), "settled slider matches device")
        expect(close(model.undoValues?.value ?? -1, 0.4), "drag undo captures preinteraction scalar")
        NotificationCenter.default.removeObserver(observer)
    }

    static func testExternalAndFailures() {
        let fixture = ModelFixture(), model = fixture.model
        var indicators = 0
        let observer = NotificationCenter.default.addObserver(forName: .volumeChanged, object: nil, queue: nil) { _ in indicators += 1 }
        fixture.backend.locked { fixture.backend.scalar = 0.22; fixture.backend.muted = true }
        fixture.backend.emit(.state)
        waitFor("external volume/mute refresh model") { close(model.volume, 0.22) && model.isMuted }
        expect(indicators == 0, "external state changes do not emit intentional OSD")
        fixture.backend.locked { fixture.backend.failWrites = true }
        model.captureUndo(.volume)
        expect(model.adjust(.volume, to: 0.9), "failed write starts optimistically")
        expect(close(model.volume, 0.9), "optimistic failure still responds immediately")
        waitFor("failure rolls back to measured state") { model.message != nil && close(model.volume, 0.22) }
        expect(model.isMuted, "failure reconciles measured mute state")
        expect(indicators == 0, "failed write never produces success OSD")
        expect(!model.adjust(.volume, to: .nan), "nonfinite input rejected")
        NotificationCenter.default.removeObserver(observer)
    }

    static func testAtomicUndoAndRouteGuard() {
        let fixture = ModelFixture(), model = fixture.model
        fixture.backend.locked { fixture.backend.muted = true }
        fixture.backend.emit(.state)
        waitFor("initial muted state ready") { model.isMuted }
        model.captureUndo(.volume)
        model.adjust(.volume, to: 0.9)
        waitFor("adjustment unmuted and settled") { !model.isMuted && close(Double(fixture.audio.getVolume()), 0.9) }
        fixture.backend.locked { fixture.backend.operations = [] }
        model.undo()
        waitFor("atomic undo settles") { model.undoValues == nil && model.isMuted && close(model.volume, 0.4) }
        expect(fixture.backend.locked { fixture.backend.operations } == ["mute", "volume"], "undo restores muted scalar without audible unmute")
        model.captureUndo(.volume)
        fixture.backend.locked { fixture.backend.token = AudioOutputToken(device: 43, source: nil); fixture.backend.operations = [] }
        fixture.backend.emit(.route)
        waitFor("replacement route reaches cache") { fixture.audio.targetIdentifier == "audio:43" }
        model.undo()
        expect(model.undoValues == nil && model.message?.contains("device changed") == true, "undo explains stale route and clears action")
        expect(fixture.backend.locked { fixture.backend.operations.isEmpty }, "undo never writes a replacement audio device")
        model.captureUndo(.brightness)
        model.adjust(.brightness, to: 0.3)
        waitFor("display slider settled") { close(model.brightness, 0.3) && close(Double(fixture.display.getBrightness()), 0.3) }
        model.undo()
        waitFor("display undo settled") { model.undoValues == nil && close(model.brightness, 0.7) }
    }

    static func testVisibilityAndPreview() {
        let fixture = ModelFixture(), model = fixture.model
        expect(!model.visibleRefreshActiveForTesting, "hidden model has no refresh timer")
        model.setVisible("settings", true)
        expect(model.visibleRefreshActiveForTesting, "visible settings enables fallback display refresh")
        model.setVisible("popover", true)
        model.setVisible("settings", false)
        expect(model.visibleRefreshActiveForTesting, "one remaining visible surface keeps refresh active")
        model.setVisible("popover", false)
        expect(!model.visibleRefreshActiveForTesting, "last surface closing releases refresh timer")
        let preview = ControlCenterModel(settings: TrackpadSettings(defaults: UserDefaults(suiteName: fixture.suite)!),
                                         preview: true, audio: fixture.audio, display: fixture.display)
        preview.refresh(); preview.toggleMute(); preview.undo(); preview.setVisible("test", true)
        expect(!preview.adjust(.volume, to: 1), "preview rejects hardware adjustment")
        expect(!preview.visibleRefreshActiveForTesting, "preview has no refresh timer")
        expect(fixture.backend.locked { fixture.backend.operations.isEmpty }, "preview performs no audio writes")
    }
}

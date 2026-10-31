import Foundation
import Carbon
import Combine

extension Notification.Name {
    /// Posted on main with a Bool object: true while the cheat-sheet hotkey is held.
    static let swayCheatSheetHotkey = Notification.Name("swayCheatSheetHotkey")
}

/// Carbon hotkeys remain active when the menu bar popover is closed.
/// Two registrations: pause/resume (press) and the edge cheat sheet (hold).
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published private(set) var registrationError: String?
    @Published private(set) var cheatSheetError: String?
    private var hotKeyRef: EventHotKeyRef?
    private var cheatSheetRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var currentHotkey: HotkeyCombo = .none
    private var currentCheatSheet: HotkeyCombo = .none
    private static let signature = OSType(0x5357_4159) // 'SWAY'
    private static let toggleID: UInt32 = 1
    private static let cheatSheetID: UInt32 = 2

    private init() {}

    @discardableResult
    func update(hotkey: HotkeyCombo) -> Bool {
        if hotkey == currentHotkey, hotKeyRef != nil { return true }
        if let failure = unregister(&hotKeyRef) { registrationError = failure; return false }
        currentHotkey = hotkey
        registrationError = register(hotkey, id: Self.toggleID, into: &hotKeyRef)
        return registrationError == nil
    }

    @discardableResult
    func updateCheatSheet(hotkey: HotkeyCombo) -> Bool {
        if hotkey == currentCheatSheet, cheatSheetRef != nil { return true }
        if let failure = unregister(&cheatSheetRef) { cheatSheetError = failure; return false }
        currentCheatSheet = hotkey
        guard hotkey != currentHotkey || hotkey.isEmpty else {
            cheatSheetError = "This shortcut already pauses Sway. Choose another one."
            return false
        }
        cheatSheetError = register(hotkey, id: Self.cheatSheetID, into: &cheatSheetRef)
        return cheatSheetError == nil
    }

    func startWithSavedHotkey() {
        update(hotkey: TrackpadSettings.shared.toggleHotkey)
        updateCheatSheet(hotkey: TrackpadSettings.shared.cheatSheetHotkey)
    }

    /// Returns a user-facing failure, or nil once registered (or cleared).
    private func register(_ hotkey: HotkeyCombo, id: UInt32, into reference: inout EventHotKeyRef?) -> String? {
        guard !hotkey.isEmpty else { return nil }
        guard hotkey.modifiers != 0 else { return "Include a modifier such as ⌘, ⌥, or ⌃ in your shortcut." }
        if let failure = installEventHandler() { return failure }
        let identifier = EventHotKeyID(signature: Self.signature, id: id)
        let result = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, identifier,
            GetApplicationEventTarget(), 0, &reference)
        guard result == noErr else {
            reference = nil
            return "This shortcut is unavailable. Try another combination. (\(result))"
        }
        return nil
    }

    private func installEventHandler() -> String? {
        if eventHandlerRef != nil { return nil }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                nil, &identifier)
            guard result == noErr, identifier.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            switch identifier.id {
            case HotkeyManager.toggleID:
                guard pressed else { return noErr }
                DispatchQueue.main.async { TrackpadSettings.shared.isEnabled.toggle() }
            case HotkeyManager.cheatSheetID:
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .swayCheatSheetHotkey, object: pressed)
                }
            default: return OSStatus(eventNotHandledErr)
            }
            return noErr
        }, eventTypes.count, &eventTypes, nil, &eventHandlerRef)
        guard result == noErr else {
            eventHandlerRef = nil
            return "macOS could not enable global shortcuts. (\(result))"
        }
        return nil
    }

    private func unregister(_ reference: inout EventHotKeyRef?) -> String? {
        guard let registered = reference else { return nil }
        let result = UnregisterEventHotKey(registered)
        guard result == noErr else { return "macOS could not release the previous shortcut. (\(result))" }
        reference = nil
        return nil
    }
}

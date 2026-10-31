import AppKit
import ApplicationServices
import CoreAudio

// MARK: - Window tiling

enum TilePlacement: String { case leftHalf, rightHalf, fill }

/// Moves the front window with the Accessibility permission Sway already has,
/// so it works in apps without a tiling shortcut and on macOS 13.
enum WindowTiler {
    /// Pure geometry: an AppKit visible frame (bottom-left origin) becomes an
    /// Accessibility frame (top-left origin at the primary display's top edge).
    static func frame(for placement: TilePlacement, visibleFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        var rect = visibleFrame.integral
        let half = floor(rect.width / 2)
        switch placement {
        case .leftHalf: rect.size.width = half
        case .rightHalf: rect.origin.x += half; rect.size.width -= half
        case .fill: break
        }
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts an Accessibility point back to AppKit coordinates.
    static func appKitPoint(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Main thread. A short messaging timeout keeps a hung app from stalling input.
    static func tile(_ placement: TilePlacement, pid: pid_t) -> Bool {
        guard pid > 0, let primary = NSScreen.screens.first else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = focused as! AXUIElement // Type checked above.
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? Bool) == true { return false }
        let current = frame(of: window) ?? .zero
        let center = appKitPoint(CGPoint(x: current.midX, y: current.midY), primaryHeight: primary.frame.height)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? primary
        let target = frame(for: placement, visibleFrame: screen.visibleFrame, primaryHeight: primary.frame.height)
        // Size, position, size: some apps clamp a size against the old position.
        return set(target.size, on: window) && set(target.origin, on: window) && set(target.size, on: window)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func set(_ point: CGPoint, on window: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private static func set(_ size: CGSize, on window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }
}

// MARK: - Audio output switching

struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Changes macOS's default output, the same choice as the Sound menu.
enum AudioOutputSwitcher {
    private static let worker = DispatchQueue(label: "com.sway.output-switcher", qos: .userInitiated)

    /// Pure: the device after `current`, wrapping, or the first one when the
    /// current output is missing from the list.
    static func next(after current: AudioDeviceID?, in devices: [AudioOutputDevice], forward: Bool) -> AudioOutputDevice? {
        guard !devices.isEmpty else { return nil }
        guard let current, let index = devices.firstIndex(where: { $0.id == current }) else { return devices[0] }
        let step = forward ? 1 : devices.count - 1
        return devices[(index + step) % devices.count]
    }

    /// Off main; completion on main with the device that macOS now reports.
    static func cycle(forward: Bool, completion: @escaping (AudioOutputDevice?) -> Void) {
        worker.async {
            let devices = outputs()
            let current = defaultOutput()
            var result: AudioOutputDevice?
            if let target = next(after: current, in: devices, forward: forward), target.id != current {
                var id = target.id
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                if AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                              UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr,
                   defaultOutput() == target.id {
                    result = target
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioDeviceUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioDeviceUnknown else { return nil }
        return device
    }

    /// Every device with output channels, minus private aggregates (including
    /// the ones Sway's app volume creates), sorted by name for a stable order.
    static func outputs() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = Array(repeating: AudioDeviceID(0), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id -> AudioOutputDevice? in
            guard hasOutput(id), !isPrivateAggregate(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Audio output")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isPrivateAggregate(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var composition: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &composition) == noErr,
              let dictionary = composition?.takeRetainedValue() as? [String: Any] else { return false }
        return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

// MARK: - Shortcuts

/// Runs the user's Shortcuts through Apple's own command-line tool. The name
/// is passed as a process argument, never through a shell.
enum ShortcutsRunner {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    /// Starts the Shortcut and returns; Sway never waits on what it does.
    static func run(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !trimmed.isEmpty else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", trimmed]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }

    /// Lists Shortcut names off main; completion on main (empty on failure).
    static func list(completion: @escaping ([String]) -> Void) {
        guard isAvailable else { completion([]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["list"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var names: [String] = []
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                names = parseList(String(decoding: data, as: UTF8.self))
            }
            DispatchQueue.main.async { completion(names) }
        }
    }

    static func parseList(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - URL commands

/// `sway://` commands for Shortcuts, scripts and launchers. Deliberately
/// small: pausing, levels within your comfort limits, and showing windows.
/// Nothing here can change assignments, install anything, or run Shortcuts.
enum SwayURLCommand: Equatable {
    case pause(minutes: Double?), resume, toggle
    case volume(Double), brightness(Double)
    case settings, controls, edgeMap

    static func parse(_ url: URL) -> SwayURLCommand? {
        guard url.scheme?.lowercased() == "sway" else { return nil }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func number(_ name: String) -> Double? {
            guard let raw = items.first(where: { $0.name.lowercased() == name })?.value,
                  let value = Double(raw), value.isFinite else { return nil }
            return value
        }
        switch command {
        case "pause":
            guard let minutes = number("minutes") else { return .pause(minutes: nil) }
            return (1...1440).contains(minutes) ? .pause(minutes: minutes) : nil
        case "resume": return .resume
        case "toggle": return .toggle
        case "volume", "brightness":
            // Percent, like the indicator: sway://volume?level=40
            guard let level = number("level"), (0...100).contains(level) else { return nil }
            return command == "volume" ? .volume(level / 100) : .brightness(level / 100)
        case "settings": return .settings
        case "controls": return .controls
        case "edge-map", "edgemap": return .edgeMap
        default: return nil
        }
    }
}

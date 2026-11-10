import AppKit
import os

/// Kinara's diagnostic log: what the monitor, its input taps, permissions and
/// gestures did, and when. Written twice, and both survive a forced restart:
/// - the unified log (subsystem com.trackpadcontrol.app), readable with
///   `log show --predicate 'subsystem == "com.trackpadcontrol.app"'`;
/// - a small file, ~/Library/Logs/Kinara/Kinara.log, flushed line by line,
///   that someone can send with a bug report.
/// It records events, never touch positions, typed keys or clipboard text.
enum KinaraLog {
    enum Category: String { case app, monitor, access, taps, gesture, watchdog, output }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Kinara/Kinara.log")
    /// One file of about a megabyte, then one previous file; older lines go.
    static let maximumBytes: UInt64 = 1_000_000

    private static let subsystem = "com.trackpadcontrol.app"
    private static let loggers = Dictionary(uniqueKeysWithValues: [Category.app, .monitor, .access, .taps, .gesture, .watchdog, .output]
        .map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })
    private static let queue = DispatchQueue(label: "com.kinara.log", qos: .utility)
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ category: Category, _ message: String) {
        loggers[category]?.notice("\(message, privacy: .public)")
        write(category, "", message)
    }

    static func warning(_ category: Category, _ message: String) {
        loggers[category]?.error("\(message, privacy: .public)")
        write(category, "WARNING ", message)
    }

    static func fault(_ category: Category, _ message: String) {
        loggers[category]?.fault("\(message, privacy: .public)")
        write(category, "FAULT ", message)
    }

    static func revealInFinder() {
        queue.sync { _ = openHandle() }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private static func write(_ category: Category, _ level: String, _ message: String) {
        let date = Date()
        queue.async {
            guard let handle = openHandle() else { return }
            let line = "\(stamp.string(from: date)) [\(category.rawValue)] \(level)\(message)\n"
            handle.write(Data(line.utf8))
            // On disk before anything else happens: a hang or a forced restart keeps it.
            try? handle.synchronize()
        }
    }

    /// Queue only.
    private static func openHandle() -> FileHandle? {
        let manager = FileManager.default
        if let handle {
            if let size = try? handle.offset(), size > maximumBytes {
                try? handle.close()
                self.handle = nil
                let previous = fileURL.deletingLastPathComponent().appendingPathComponent("Kinara.1.log")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: fileURL, to: previous)
            } else {
                return handle
            }
        }
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) { manager.createFile(atPath: fileURL.path, contents: nil) }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? opened.seekToEnd()
        handle = opened
        return opened
    }
}

/// Kinara's event taps sit in the input path: macOS waits on them before it
/// delivers clicks and keys. If Kinara's main thread ever stops answering,
/// input would wait with it. This watchdog runs on its own thread, checks the
/// main thread four times a second, and if it hasn't answered for a second it
/// switches the taps off from here, so input never waits on Kinara.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()
    static let limit: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "com.kinara.watchdog", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastAnswer = ProcessInfo.processInfo.systemUptime
    private var asked = false
    private var taps: [CFMachPort] = []
    private var tripped: TimeInterval?
    /// Main thread: called once the main thread is back after a trip.
    var onRecovered: (() -> Void)?

    /// Main thread: the taps currently in the input path (empty stops watching).
    func watch(_ taps: [CFMachPort]) {
        lock.lock()
        self.taps = taps
        lastAnswer = ProcessInfo.processInfo.systemUptime
        asked = false
        lock.unlock()
        if taps.isEmpty { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let silent = now - lastAnswer
        let watched = taps
        let alreadyTripped = tripped != nil
        let shouldAsk = !asked
        if shouldAsk { asked = true }
        if !alreadyTripped, silent > Self.limit, !watched.isEmpty { tripped = now }
        let trips = !alreadyTripped && tripped != nil
        lock.unlock()
        if trips {
            for tap in watched { CGEvent.tapEnable(tap: tap, enable: false) }
            KinaraLog.fault(.watchdog, String(format: "Main thread silent for %.1fs; input taps switched off so clicks and keys keep flowing", silent))
        }
        if shouldAsk {
            DispatchQueue.main.async { [weak self] in self?.answer() }
        }
    }

    private func answer() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastAnswer = now
        asked = false
        let trippedAt = tripped
        tripped = nil
        lock.unlock()
        if let trippedAt {
            KinaraLog.warning(.watchdog, String(format: "Main thread answered again %.1fs after the taps were switched off", now - trippedAt))
            onRecovered?()
        }
    }
}

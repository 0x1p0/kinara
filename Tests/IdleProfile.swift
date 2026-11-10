import AppKit
import Combine
import Darwin

/// Real application lifecycle, but a bounded paused/icon-only profile. Overrides
/// live only in NSArgumentDomain: no production preference is saved or changed.
/// No trackpad monitoring, shortcuts, control windows, screenshots, or hardware adjustments.
@main
struct IdleProfile {
    @MainActor
    static func main() throws {
        let defaults = UserDefaults.standard
        var overrides = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        overrides["isEnabled"] = false
        overrides["hasCompletedKinaraSetup"] = true
        overrides["hasRequestedLaunchAccessibility"] = true
        overrides["automaticallyCheckForUpdates"] = false
        overrides["showDockIcon"] = false
        overrides["toggleHotkey"] = "idle-profile-no-shortcut"
        overrides["menuBarValueSource"] = "icon"
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)

        // All static singletons are lazy. Validate before creating AppDelegate
        // or letting an application launch callback start the real lifecycle.
        let settings = TrackpadSettings.shared
        guard !settings.isEnabled, settings.toggleHotkey.isEmpty,
              settings.menuBarValueSource == "icon",
              !settings.showDockIcon,
              !defaults.bool(forKey: "automaticallyCheckForUpdates"),
              defaults.bool(forKey: "hasCompletedKinaraSetup"),
              defaults.bool(forKey: "hasRequestedLaunchAccessibility") else {
            throw ProfileError.unsafeConfiguration
        }
        let domains = Set(["com.trackpadcontrol.app", Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName])
        let saved = Dictionary(uniqueKeysWithValues: domains.map {
            ($0, defaults.persistentDomain(forName: $0) ?? [:])
        })

        let app = NSApplication.shared
        let delegate = AppDelegate(presentsSetupOnLaunch: false)
        app.delegate = delegate
        // Ignore input directed at this profiling process. Its real status
        // item exists, but cannot open controls or enable gestures during a run.
        let inputBlocker = NSEvent.addLocalMonitorForEvents(matching: .any) { _ in nil }
        let profiler = IdleResourceProfiler(defaults: defaults, savedDomains: saved)
        profiler.armDeadline()
        let launchObserver = NotificationCenter.default.publisher(
            for: NSApplication.didFinishLaunchingNotification, object: app)
            .sink { _ in profiler.start() }
        withExtendedLifetime((delegate, profiler, inputBlocker, launchObserver)) {
            app.run()
        }
    }
}

private enum ProfileError: Error {
    case unsafeConfiguration
    case resourceQueryFailed
}

private final class IdleResourceProfiler {
    private struct Sample {
        let wall: TimeInterval
        let cpu: TimeInterval
        let footprint: UInt64

        static func capture() throws -> Sample {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ProfileError.resourceQueryFailed }
            var memory = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let capacity = Int(count)
            let status = withUnsafeMutablePointer(to: &memory) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { throw ProfileError.resourceQueryFailed }
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            return Sample(wall: ProcessInfo.processInfo.systemUptime, cpu: user + system, footprint: memory.phys_footprint)
        }
    }

    private let defaults: UserDefaults
    private let savedDomains: [String: [String: Any]]
    private var timer: Timer?
    private var deadline: DispatchWorkItem?
    private var previous: Sample?
    private var totalCPU: TimeInterval = 0
    private var totalWall: TimeInterval = 0
    private var footprints: [UInt64] = []
    private var interval = 0
    private var started = false

    init(defaults: UserDefaults, savedDomains: [String: [String: Any]]) {
        self.defaults = defaults
        self.savedDomains = savedDomains
    }

    func start() {
        guard !started else { return }
        started = true
        print("Kinara paused idle profile — optimized production sources, real AppDelegate")
        print("Conditions: gestures disabled, icon-only menu, no controls opened, no shortcut, read-only device discovery.")
        print("Warm-up: 3 seconds. Sampling: three 5-second intervals. CPU percentages use one CPU core = 100%.")
        print("Physical footprint comes from task_vm_info; this is not virtual address space or an active-gesture benchmark.")
        fflush(stdout)
        let warmup = Timer(timeInterval: 3, repeats: false) { [weak self] _ in self?.beginSampling() }
        timer = warmup
        RunLoop.main.add(warmup, forMode: .common)
    }

    func armDeadline() {
        let deadline = DispatchWorkItem {
            fputs("Idle profile exceeded its 25-second runtime limit.\n", stderr)
            Darwin.exit(2)
        }
        self.deadline = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25, execute: deadline)
    }

    private func beginSampling() {
        guard !TrackpadSettings.shared.isEnabled, !TrackpadMonitor.shared.isRunning else {
            finish(error: "Safety check failed: gesture monitoring must remain disabled.")
            return
        }
        do { previous = try Sample.capture() }
        catch { finish(error: "Could not capture process resources."); return }
        let samples = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.captureInterval() }
        timer = samples
        RunLoop.main.add(samples, forMode: .common)
    }

    private func captureInterval() {
        guard !TrackpadSettings.shared.isEnabled, !TrackpadMonitor.shared.isRunning else {
            finish(error: "Safety check failed: gesture monitoring changed during profiling.")
            return
        }
        do {
            guard let previous else { throw ProfileError.resourceQueryFailed }
            let next = try Sample.capture()
            let elapsed = next.wall - previous.wall
            let cpu = next.cpu - previous.cpu
            guard elapsed > 0, cpu >= 0 else { throw ProfileError.resourceQueryFailed }
            interval += 1
            totalCPU += cpu
            totalWall += elapsed
            footprints.append(next.footprint)
            print(String(format: "Interval %d: %.3f s wall, %.6f s CPU, %.4f%% CPU, %.2f MiB physical footprint",
                         interval, elapsed, cpu, cpu / elapsed * 100, Double(next.footprint) / 1_048_576))
            fflush(stdout)
            self.previous = next
            if interval == 3 { finish(error: nil) }
        } catch { finish(error: "Could not capture process resources.") }
    }

    private func finish(error: String?) {
        timer?.invalidate()
        timer = nil
        deadline?.cancel()
        deadline = nil
        let unchanged = savedDomains.allSatisfy { domain, before in
            NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: domain) ?? [:])
        }
        if let error {
            fputs("\(error)\n", stderr)
        } else {
            let low = Double(footprints.min() ?? 0) / 1_048_576
            let high = Double(footprints.max() ?? 0) / 1_048_576
            print(String(format: "Observed paused-idle average: %.4f%% CPU over %.3f s; physical footprint %.2f–%.2f MiB.",
                         totalCPU / totalWall * 100, totalWall, low, high))
            print("Interpretation: one short paused/icon-only lower-bound sample, not a pre-change comparison, active gesture cost, or zero-resource guarantee.")
        }
        print("Persistent production/profile preference domains unchanged: \(unchanged ? "yes" : "NO")")
        fflush(stdout)
        if error != nil || !unchanged {
            // Run the production cleanup path before reporting a failing exit.
            NSApp.delegate?.applicationWillTerminate?(Notification(name: NSApplication.willTerminateNotification))
            Darwin.exit(1)
        }
        // NSApplication sends the normal termination callback, stopping the
        // actual exclusion monitor, visibility timers, and gesture session.
        NSApp.terminate(nil)
    }
}

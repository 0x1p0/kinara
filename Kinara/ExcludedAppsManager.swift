import AppKit
import Combine

// MARK: - Excluded Apps Monitor
// Watches NSWorkspace for app activation events and temporarily
// suppresses Kinara when the frontmost app is in the exclusion list.
// This is separate from isEnabled — it doesn't change the user's
// preference, just silently passes through events for excluded apps.
final class ExcludedAppsManager: ObservableObject {
    static let shared = ExcludedAppsManager()

    // True when the currently active app is excluded.
    // TrackpadMonitor reads this instead of (or in addition to) isEnabled.
    @Published private(set) var activeAppIsExcluded: Bool = false
    @Published private(set) var currentAppName = "Current app"
    @Published private(set) var currentAppBundleID: String?

    private var cancellables = Set<AnyCancellable>()
    private var observer: Any?

    private init() {}

    func start() {
        guard observer == nil else { return }

        updateActiveApp(NSWorkspace.shared.frontmostApplication)

        // Watch for frontmost app changes
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.updateActiveApp(note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)
        }

        // Also react when the exclusion list itself changes
        TrackpadSettings.shared.$excludedApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] excluded in
                guard let self else { return }
                self.updateExclusion(using: excluded)
            }
            .store(in: &cancellables)
    }

    /// Opening Kinara must not discard the application the user was working in.
    /// This also makes “pause in this app” useful while the popover has focus.
    private func updateActiveApp(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = application.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        currentAppBundleID = bundleID
        currentAppName = application.localizedName ?? bundleID
        updateExclusion(using: TrackpadSettings.shared.excludedApps)
    }

    private func updateExclusion(using excluded: [String]) {
        let shouldExclude = currentAppBundleID.map { excluded.contains($0) } ?? false
        guard shouldExclude != activeAppIsExcluded else { return }
        activeAppIsExcluded = shouldExclude
        if shouldExclude { TrackpadMonitor.shared.cancelCurrentGesture() }
    }

    func stop() {
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            observer = nil
        }
        cancellables.removeAll()
    }

    // Returns a list of installed applications for the picker UI.
    static func installedApps() -> [AppInfo] {
        let ws = NSWorkspace.shared
        let urls = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .systemDomainMask)
        var apps: [AppInfo] = []
        var seen = Set<String>()

        for dir in urls {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                if let bundle = Bundle(url: url),
                   let bid = bundle.bundleIdentifier,
                   !seen.contains(bid) {
                    seen.insert(bid)
                    let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? url.deletingPathExtension().lastPathComponent
                    let icon = ws.icon(forFile: url.path)
                    apps.append(AppInfo(name: name, bundleID: bid, icon: icon))
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct AppInfo: Identifiable, Equatable {
    var id: String { bundleID }
    let name:     String
    let bundleID: String
    let icon:     NSImage
}

import Foundation
import AppKit
import Combine

/// Release metadata only. Never downloads or installs executable code.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let releasesURL = URL(string: "https://github.com/0x1p0/kinara/releases")!
    static let endpoint = URL(string: "https://api.github.com/repos/0x1p0/kinara/releases/latest")!
    static let checkInterval: TimeInterval = 86_400
    static let retryInterval: TimeInterval = 3_600

    @Published var automaticallyChecks: Bool {
        didSet {
            defaults.set(automaticallyChecks, forKey: "automaticallyCheckForUpdates")
            if automaticallyChecks { checkIfDue() }
            else {
                timer?.invalidate(); timer = nil
                if automaticRequest { cancelRequest() }
            }
        }
    }
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateURL: URL?
    @Published private(set) var isChecking = false
    @Published private(set) var checkError: String?
    @Published private(set) var updateAvailable = false
    @Published private(set) var lastChecked: Date?
    private let defaults: UserDefaults
    private let current: String?
    private let session: URLSession
    private let now: () -> Date
    private let openURL: (URL) -> Void
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var requestID: UInt64 = 0
    private var automaticRequest = false
    private var started = false

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
    }

    init(defaults: UserDefaults = .standard,
         current: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         session: URLSession? = nil, now: @escaping () -> Date = Date.init,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.current = current
        self.now = now
        self.openURL = openURL
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
        automaticallyChecks = defaults.object(forKey: "automaticallyCheckForUpdates") as? Bool ?? true
        lastChecked = defaults.object(forKey: "updateLastCheckDate") as? Date
    }

    deinit { timer?.invalidate(); task?.cancel() }

    var status: String {
        if isChecking { return "Checking GitHub…" }
        if let checkError { return checkError }
        if updateAvailable, let latestVersion { return "Kinara \(latestVersion) is available." }
        if latestVersion != nil { return "You’re up to date." }
        return "Check GitHub for the latest stable release."
    }

    func startPeriodicChecks() {
        guard !started else { return }
        started = true
        checkIfDue()
    }

    func stop() {
        started = false
        timer?.invalidate(); timer = nil
        cancelRequest()
    }

    func checkIfDue() {
        guard started, automaticallyChecks, !isChecking else { return }
        let next = defaults.object(forKey: "updateNextCheckDate") as? Date
            ?? lastChecked?.addingTimeInterval(Self.checkInterval) ?? .distantPast
        if next <= now() || next.timeIntervalSince(now()) > Self.checkInterval {
            check(automatic: true)
        } else { schedule(at: next) }
    }

    func check(automatic: Bool = false) {
        guard !isChecking, !automatic || (started && automaticallyChecks) else { return }
        guard let current, Self.versionParts(current) != nil else {
            checkError = "Update checks need a versioned build of Kinara."
            return
        }
        timer?.invalidate(); timer = nil
        checkError = nil
        isChecking = true
        automaticRequest = automatic
        requestID &+= 1
        let identity = requestID
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Kinara/\(current)", forHTTPHeaderField: "User-Agent")
        // Persist attempt deadlines too, so offline relaunches cannot flood GitHub.
        defaults.set(now().addingTimeInterval(Self.retryInterval), forKey: "updateNextCheckDate")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.requestID == identity else { return }
                self.task = nil
                self.isChecking = false
                self.automaticRequest = false
                let successful = self.accept(data: data, response: response, error: error)
                let next = self.now().addingTimeInterval(successful ? Self.checkInterval : Self.retryInterval)
                self.defaults.set(next, forKey: "updateNextCheckDate")
                self.schedule(at: next)
            }
        }
        task?.resume()
    }

    private func accept(data: Data?, response: URLResponse?, error: Error?) -> Bool {
        if error != nil {
            checkError = "Couldn’t reach GitHub. Check your connection and try again."
            return false
        }
        guard let response = response as? HTTPURLResponse else {
            checkError = "GitHub returned an invalid response."
            return false
        }
        guard response.statusCode == 200 else {
            switch response.statusCode {
            case 404: checkError = "Release feed unavailable. You can still open GitHub Releases."
            case 403, 429: checkError = "GitHub’s request limit was reached. Try again later."
            default: checkError = "Couldn’t check for updates (HTTP \(response.statusCode))."
            }
            return false
        }
        guard let data, data.count <= 1_048_576,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let remote = Self.versionParts(release.tag_name),
              let current, let local = Self.versionParts(current),
              !release.draft, !release.prerelease,
              Self.isTrustedReleaseURL(release.html_url, tag: release.tag_name) else {
            checkError = "GitHub did not return a valid stable Kinara release."
            return false
        }
        latestVersion = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        updateAvailable = local.lexicographicallyPrecedes(remote)
        updateURL = updateAvailable ? release.html_url : nil
        lastChecked = now()
        defaults.set(lastChecked, forKey: "updateLastCheckDate")
        return true
    }

    private func schedule(at date: Date) {
        timer?.invalidate(); timer = nil
        guard started, automaticallyChecks else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.checkIfDue()
        }
        timer.tolerance = 60
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelRequest() {
        requestID &+= 1
        task?.cancel(); task = nil
        isChecking = false
        automaticRequest = false
    }

    func openReleasePage() { openURL(updateURL ?? Self.releasesURL) }

    static func isTrustedReleaseURL(_ url: URL, tag: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && url.query == nil && url.fragment == nil
            && url.path == "/0x1p0/kinara/releases/tag/\(tag)"
    }

    static func versionParts(_ version: String) -> [Int]? {
        let value = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var result: [Int] = []
        for component in components {
            guard !component.isEmpty, component.utf8.allSatisfy({ (48...57).contains($0) }),
                  let part = Int(component) else { return nil }
            result.append(part)
        }
        return result + Array(repeating: 0, count: 3 - result.count)
    }

    #if KINARA_UPDATE_TESTS
    var hasScheduledCheck: Bool { timer != nil }
    #endif
}

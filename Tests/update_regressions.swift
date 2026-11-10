import Foundation
import AppKit

private final class ReleaseProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var responseStatus = 200
    private static var responseError: Error?
    private static var hold = false
    private static var observed: [URLRequest] = []
    static func prepare(data: Data, status: Int = 200, error: Error? = nil, hold: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        responseData = data; responseStatus = status; responseError = error; self.hold = hold
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.observed.append(request)
        let data = Self.responseData, status = Self.responseStatus, error = Self.responseError, hold = Self.hold
        Self.lock.unlock()
        if hold { return }
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum UpdateRegressionTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !value() { fputs("FAIL \(line): \(message)\n", stderr); exit(1) }
    }
    private static func drain(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        expect(condition(), "asynchronous request completes within its deadline")
    }
    private static func release(_ tag: String = "v1.0.5", url: String? = nil, draft: Bool = false, prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": url ?? "https://github.com/0x1p0/kinara/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease
        ])
    }
    static func main() {
        for (input, expected) in [("v1.0.4", [1, 0, 4]), ("1.10", [1, 10, 0]), ("2", [2, 0, 0])] {
            expect(UpdateChecker.versionParts(input) == expected, "numeric versions normalize")
        }
        for invalid in ["", "v", "1..4", "1.0.4-beta", "v1.0.4.1", " 1.0.4", "-1.0", "1.0.99999999999999999999999999", "１.0.4"] {
            expect(UpdateChecker.versionParts(invalid) == nil, "malformed/prerelease versions are rejected")
        }
        let suite = "com.kinara.update-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var clock = Date()
        var opened: [URL] = []
        let updates = UpdateChecker(defaults: defaults, current: "1.0.4", session: session,
                                    now: { clock }, openURL: { opened.append($0) })
        expect(updates.automaticallyChecks && !updates.isChecking, "construction is network-free and daily checks default on")
        updates.openReleasePage()
        expect(opened.last == UpdateChecker.releasesURL, "release fallback is the correct repository")
        ReleaseProtocol.prepare(data: release())
        updates.startPeriodicChecks()
        expect(updates.isChecking, "first eligible launch starts a request")
        updates.check(); updates.checkIfDue()
        drain { !updates.isChecking }
        expect(ReleaseProtocol.requests.count == 1, "manual, launch, and wake checks coalesce")
        expect(updates.updateAvailable && updates.latestVersion == "1.0.5", "new stable release surfaces")
        expect(updates.lastChecked == clock && updates.hasScheduledCheck, "success stores date and schedules a single next check")
        let request = ReleaseProtocol.requests.last!
        expect(request.url == UpdateChecker.endpoint, "correct public GitHub feed")
        expect(request.value(forHTTPHeaderField: "Authorization") == nil, "no token or account credential")
        expect(request.value(forHTTPHeaderField: "User-Agent") == "Kinara/1.0.4", "versioned user agent")
        expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28", "API contract is pinned")
        updates.openReleasePage()
        expect(opened.last?.path == "/0x1p0/kinara/releases/tag/v1.0.5", "opens validated release, never installs code")
        let count = ReleaseProtocol.requests.count
        updates.checkIfDue()
        expect(ReleaseProtocol.requests.count == count, "no request before tomorrow")
        clock = clock.addingTimeInterval(UpdateChecker.checkInterval + 1)
        ReleaseProtocol.prepare(data: release("v1.0.4"))
        updates.checkIfDue()
        drain { !updates.isChecking }
        expect(!updates.updateAvailable && updates.updateURL == nil && updates.checkError == nil, "same version is up to date")
        ReleaseProtocol.prepare(data: release("v0.9.9"))
        updates.check()
        drain { !updates.isChecking }
        expect(!updates.updateAvailable, "never suggests a downgrade")
        for (data, status) in [
            (release(draft: true), 200), (release(prerelease: true), 200),
            (release("v1.0.5-beta"), 200), (Data("bad json".utf8), 200),
            (release(url: "http://github.com/0x1p0/kinara/releases/tag/v1.0.5"), 200),
            (release(url: "https://example.com/0x1p0/kinara/releases/tag/v1.0.5"), 200),
            (release(url: "https://github.com/another/repo/releases/tag/v1.0.5"), 200),
            (release(url: "https://github.com/0x1p0/kinara/releases/tag/v1.0.6"), 200),
            (release(url: "https://name@github.com/0x1p0/kinara/releases/tag/v1.0.5"), 200),
            (release(url: "https://github.com/0x1p0/kinara/releases/tag/v1.0.5?redirect=bad"), 200),
            (release(), 404), (release(), 403), (release(), 429), (release(), 500)
        ] {
            ReleaseProtocol.prepare(data: data, status: status)
            updates.check()
            drain { !updates.isChecking }
            expect(updates.checkError != nil && !updates.updateAvailable, "invalid feeds and HTTP errors never claim success")
            expect(defaults.object(forKey: "updateNextCheckDate") as? Date == clock.addingTimeInterval(UpdateChecker.retryInterval), "failures back off")
        }
        ReleaseProtocol.prepare(data: Data(), error: URLError(.notConnectedToInternet))
        updates.check()
        drain { !updates.isChecking }
        expect(updates.checkError != nil, "offline status is actionable")
        updates.automaticallyChecks = false
        expect(!updates.hasScheduledCheck && !defaults.bool(forKey: "automaticallyCheckForUpdates"), "opt-out persists and removes timers")
        ReleaseProtocol.prepare(data: release())
        updates.check()
        drain { !updates.isChecking }
        expect(updates.updateAvailable && !updates.hasScheduledCheck, "manual checks work with automatic checks off")
        updates.automaticallyChecks = true
        expect(updates.hasScheduledCheck, "opt-in schedules without an unnecessary duplicate request")
        clock = clock.addingTimeInterval(UpdateChecker.checkInterval + 1)
        ReleaseProtocol.prepare(data: release(), hold: true)
        updates.checkIfDue()
        expect(updates.isChecking, "held automatic request starts")
        updates.automaticallyChecks = false
        expect(!updates.isChecking && !updates.hasScheduledCheck, "opt-out cancels an in-flight automatic check")
        updates.stop()
        expect(!updates.hasScheduledCheck, "shutdown removes scheduled work")
        let restored = UpdateChecker(defaults: defaults, current: "1.0.4", session: session)
        expect(!restored.automaticallyChecks, "opt-out survives restart")
        let development = UpdateChecker(defaults: defaults, current: nil, session: session)
        development.check()
        expect(!development.isChecking && development.checkError != nil, "unversioned builds do not make requests")
        print("\(checks) update assertions passed. Mock HTTP only; no network, downloads, or browser launches.")
    }
}

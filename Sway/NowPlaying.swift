import AppKit
import ImageIO

// Now Playing: read the current track, seek within it, and show a compact HUD.
//
// Sources, in order:
// 1. MediaRemote (private, dlopen'd). macOS 15.4+ withholds it from most
//    third-party processes, so empty data counts as "unavailable" and a hung
//    callback is abandoned after a short wait.
// 2. AppleScript for Music and Spotify, only ever addressed while running:
//    each script re-checks `is running` before its `tell`, so a target that
//    quits mid-request is never relaunched.
//
// Everything below the controller and HUD is pure and covered by
// Tests/now_playing_regressions.swift without Apple Events, MediaRemote,
// network, or windows.

// MARK: - Model

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double?      // seconds
    var position: Double?      // seconds, at `fetchedAt`
    var isPlaying: Bool
    var artwork: NSImage?
    var appName: String
    var appBundleID: String?
    var fetchedAt: Double      // ProcessInfo.systemUptime

    /// Position extrapolated to `now` while playing, clamped to duration.
    func position(at now: Double) -> Double? {
        guard let stored = self.position, stored.isFinite else { return nil }
        var value = max(0, stored)
        // A clock that runs backwards (or a bad timestamp) never rewinds.
        if isPlaying, now.isFinite, fetchedAt.isFinite, now > fetchedAt { value += now - fetchedAt }
        if let duration, duration.isFinite, duration > 0 { value = min(value, duration) }
        return value
    }
}

enum NowPlayingPlayer: String, CaseIterable {
    // Declaration order is the tie-break when nothing else distinguishes them.
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var bundleID: String { rawValue }
    var displayName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }
}

enum NowPlayingPlaybackState: String {
    case playing, paused, stopped
}

// MARK: - Pure helpers

enum NowPlayingText {
    static let maximumLength = 512

    /// Control characters become spaces, the result is trimmed and capped so a
    /// hostile or broken tag can neither break single-line layout nor balloon.
    static func clean(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maximumLength ? String(trimmed.prefix(maximumLength)) : trimmed
    }
}

enum NowPlayingTime {
    static let placeholder = "--:--"
    /// 99:59:59. Also keeps `Int(_:)` far away from overflow.
    static let maximumSeconds = 359_999.0

    /// `0:07`, `3:05`, `1:02:03`. Negative clamps to zero; NaN, infinity, and
    /// nil render the placeholder. Integer arithmetic, so no locale is involved.
    static func format(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return placeholder }
        let total = Int(min(max(seconds, 0), maximumSeconds))
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let secs = total % 60
        if hours > 0 { return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))" }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// `-2:31`. Whole displayed seconds are subtracted, so elapsed plus
    /// remaining always equals the displayed duration. Unknown duration is the placeholder.
    static func remaining(position: Double?, duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return placeholder }
        let elapsed = position.flatMap { $0.isFinite ? min(max($0, 0), duration) : nil } ?? 0
        let total = min(duration, maximumSeconds).rounded(.down)
        let left = max(0, total - min(elapsed, maximumSeconds).rounded(.down))
        return "-" + format(left)
    }

    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}

struct NowPlayingCandidate: Equatable {
    var bundleID: String
    var isRunning: Bool
    var isPlaying: Bool
    var isFrontmost: Bool
    var hasTrack: Bool = true
}

enum NowPlayingPlayerChoice {
    /// Playing beats frontmost beats merely running. Players that are not
    /// running or have no track are never chosen. Ties keep input order.
    static func choose(_ candidates: [NowPlayingCandidate]) -> Int? {
        var best: (index: Int, score: Int)?
        for (index, candidate) in candidates.enumerated() where candidate.isRunning && candidate.hasTrack {
            let score = (candidate.isPlaying ? 2 : 0) + (candidate.isFrontmost ? 1 : 0)
            if score > best?.score ?? -1 { best = (index, score) }
        }
        return best?.index
    }
}

/// One AppleScript reply: `state␟title␟artist␟album␟durationMs␟positionMs␟key`
/// joined by U+001F, or the single field `stopped`. Anything else is rejected,
/// including a title that happens to contain the separator, rather than
/// guessing which field moved.
struct NowPlayingScriptReply: Equatable {
    static let separator: Unicode.Scalar = "\u{1F}"
    static let fieldCount = 7
    static let maximumReplyLength = 16_384

    var state: NowPlayingPlaybackState
    var title = ""
    var artist = ""
    var album = ""
    /// Music: milliseconds. Spotify: its raw `duration`, milliseconds in
    /// current builds; see `durationSeconds(for:)`.
    var durationMilliseconds: Double?
    var positionMilliseconds: Double?
    /// Music: persistent ID (artwork cache key). Spotify: artwork URL.
    var key = ""

    var hasTrack: Bool { state != .stopped }
    var positionSeconds: Double? { positionMilliseconds.map { $0 / 1000 } }

    static func parse(_ reply: String?) -> NowPlayingScriptReply? {
        guard let reply, !reply.isEmpty, reply.utf8.count <= maximumReplyLength else { return nil }
        let fields = reply.unicodeScalars
            .split(separator: separator, omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        guard let first = fields.first,
              let state = NowPlayingPlaybackState(rawValue: first.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        if state == .stopped { return NowPlayingScriptReply(state: .stopped) }
        guard fields.count == fieldCount else { return nil }
        var parsed = NowPlayingScriptReply(state: state)
        parsed.title = NowPlayingText.clean(fields[1])
        parsed.artist = NowPlayingText.clean(fields[2])
        parsed.album = NowPlayingText.clean(fields[3])
        parsed.durationMilliseconds = number(fields[4]).flatMap { $0 > 0 ? $0 : nil }
        parsed.positionMilliseconds = number(fields[5]).flatMap { $0 >= 0 ? $0 : nil }
        parsed.key = NowPlayingText.clean(fields[6])
        return parsed
    }

    /// Integers in practice. Tolerates a locale's decimal comma or exponent
    /// form for values AppleScript could not coerce to an integer.
    static func number(_ field: String) -> Double? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 32 else { return nil }
        let normalized = trimmed.contains(".") ? trimmed : trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    func durationSeconds(for player: NowPlayingPlayer) -> Double? {
        guard let raw = durationMilliseconds else { return nil }
        let seconds = raw / 1000
        // Spotify's dictionary says seconds but current builds return
        // milliseconds. If the position proves the value was seconds, use it.
        if player == .spotify, let position = positionSeconds, seconds + 1 < position, raw >= position { return raw }
        return seconds
    }
}

enum NowPlayingAppleScript {
    static let maximumSeekSeconds = 7 * 86_400.0

    /// Constant per player. No user-controlled text is ever placed in source.
    static func readSource(for player: NowPlayingPlayer) -> String {
        switch player {
        case .music: return musicRead
        case .spotify: return spotifyRead
        }
    }

    /// The only variable in any script is this number, built with integer
    /// arithmetic so no locale can introduce a decimal comma or grouping.
    static func seekLiteral(_ seconds: Double) -> String? {
        guard seconds.isFinite else { return nil }
        let clamped = min(max(seconds, 0), maximumSeekSeconds)
        let milliseconds = Int((clamped * 1000).rounded())
        let fraction = milliseconds % 1000
        let padding = fraction < 10 ? "00" : fraction < 100 ? "0" : ""
        return "\(milliseconds / 1000).\(padding)\(fraction)"
    }

    static func seekSource(for player: NowPlayingPlayer, seconds: Double) -> String? {
        guard let literal = seekLiteral(seconds) else { return nil }
        return """
        if application id "\(player.bundleID)" is not running then return false
        tell application id "\(player.bundleID)"
            with timeout of 2 seconds
                set player position to \(literal)
            end timeout
        end tell
        return true
        """
    }

    static let musicRead = """
    if application id "com.apple.Music" is not running then return ""
    set fieldSeparator to character id 31
    set stateName to "paused"
    set trackName to ""
    set trackArtist to ""
    set trackAlbum to ""
    set trackDuration to -1
    set trackPosition to -1
    set trackKey to ""
    tell application id "com.apple.Music"
        with timeout of 2 seconds
            set currentState to player state
            if currentState is stopped then return "stopped"
            if currentState is playing then set stateName to "playing"
            try
                set currentTrack to current track
            on error
                return "stopped"
            end try
            try
                set trackName to (name of currentTrack) as text
            end try
            try
                set trackArtist to (artist of currentTrack) as text
            end try
            try
                set trackAlbum to (album of currentTrack) as text
            end try
            try
                set trackDuration to ((duration of currentTrack) * 1000) as integer
            end try
            try
                set trackPosition to ((player position) * 1000) as integer
            end try
            try
                set trackKey to (persistent ID of currentTrack) as text
            end try
        end timeout
    end tell
    return stateName & fieldSeparator & trackName & fieldSeparator & trackArtist & fieldSeparator & trackAlbum & fieldSeparator & trackDuration & fieldSeparator & trackPosition & fieldSeparator & trackKey
    """

    static let spotifyRead = """
    if application id "com.spotify.client" is not running then return ""
    set fieldSeparator to character id 31
    set stateName to "paused"
    set trackName to ""
    set trackArtist to ""
    set trackAlbum to ""
    set trackDuration to -1
    set trackPosition to -1
    set trackKey to ""
    tell application id "com.spotify.client"
        with timeout of 2 seconds
            set currentState to player state
            if currentState is stopped then return "stopped"
            if currentState is playing then set stateName to "playing"
            try
                set currentTrack to current track
            on error
                return "stopped"
            end try
            try
                set trackName to (name of currentTrack) as text
            end try
            try
                set trackArtist to (artist of currentTrack) as text
            end try
            try
                set trackAlbum to (album of currentTrack) as text
            end try
            try
                set trackDuration to (duration of currentTrack) as integer
            end try
            try
                set trackPosition to ((player position) * 1000) as integer
            end try
            try
                set trackKey to (artwork url of currentTrack) as text
            end try
        end timeout
    end tell
    return stateName & fieldSeparator & trackName & fieldSeparator & trackArtist & fieldSeparator & trackAlbum & fieldSeparator & trackDuration & fieldSeparator & trackPosition & fieldSeparator & trackKey
    """

    static let musicArtwork = """
    if application id "com.apple.Music" is not running then return missing value
    tell application id "com.apple.Music"
        with timeout of 2 seconds
            try
                return raw data of artwork 1 of current track
            end try
            try
                return data of artwork 1 of current track
            end try
        end timeout
    end tell
    return missing value
    """
}

enum NowPlayingArtworkPolicy {
    static let spotifyHostSuffixes = ["scdn.co", "spotifycdn.com"]

    static func isAllowedSpotifyHost(_ host: String) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" })
        else { return false }
        return spotifyHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// An https URL on a Spotify image CDN, or nil. Older Spotify builds report
    /// `http://i.scdn.co/...`; those are upgraded so the request is still TLS.
    static func spotifyArtworkURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2048,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host, isAllowedSpotifyHost(host)
        else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        return components.url
    }
}

enum NowPlayingMediaRemoteParser {
    static let titleKey = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artistKey = "kMRMediaRemoteNowPlayingInfoArtist"
    static let albumKey = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let durationKey = "kMRMediaRemoteNowPlayingInfoDuration"
    static let elapsedKey = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let rateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    static let timestampKey = "kMRMediaRemoteNowPlayingInfoTimestamp"
    static let artworkKey = "kMRMediaRemoteNowPlayingInfoArtworkData"

    /// Nil for an empty or title-less dictionary, which is what restricted
    /// processes receive. The elapsed time is advanced from MediaRemote's own
    /// timestamp to `wallClock`, so `position` is valid at `uptime`.
    static func info(from dictionary: [String: Any], isPlaying: Bool?, appName: String, bundleID: String?,
                     artwork: NSImage?, wallClock: Date, uptime: Double) -> NowPlayingInfo? {
        let title = NowPlayingText.clean(dictionary[titleKey] as? String)
        let artist = NowPlayingText.clean(dictionary[artistKey] as? String)
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        let duration = number(dictionary[durationKey]).flatMap { $0 > 0 ? $0 : nil }
        let rate = number(dictionary[rateKey])
        let playing = isPlaying ?? ((rate ?? 0) > 0)
        var position = number(dictionary[elapsedKey]).map { max(0, $0) }
        if playing, let elapsed = position, let stamp = dictionary[timestampKey] as? Date {
            let delta = wallClock.timeIntervalSince(stamp)
            if delta.isFinite, delta > 0, delta < 86_400 {
                position = elapsed + delta * (rate.flatMap { $0 > 0 ? $0 : nil } ?? 1)
            }
        }
        if let current = position, let duration { position = min(current, duration) }
        return NowPlayingInfo(title: title, artist: artist, album: NowPlayingText.clean(dictionary[albumKey] as? String),
                              duration: duration, position: position, isPlaying: playing, artwork: artwork,
                              appName: NowPlayingText.clean(appName), appBundleID: bundleID, fetchedAt: uptime)
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

/// Everything the HUD draws, derived from one info and one position.
struct NowPlayingDisplay: Equatable {
    var title: String
    var subtitle: String
    var elapsed: String
    var remaining: String
    var progress: Double
    var isPlaying: Bool
    var accessibilityValue: String

    init(info: NowPlayingInfo, position: Double?) {
        let trackTitle = NowPlayingText.clean(info.title)
        let artist = NowPlayingText.clean(info.artist)
        let album = NowPlayingText.clean(info.album)
        let app = NowPlayingText.clean(info.appName)
        title = !trackTitle.isEmpty ? trackTitle : (!app.isEmpty ? app : "Unknown Track")
        let details = [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
        subtitle = !details.isEmpty ? details : (trackTitle.isEmpty ? "" : app)
        let duration = info.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var current = position.flatMap { $0.isFinite ? max(0, $0) : nil }
        if let value = current, let duration { current = min(value, duration) }
        elapsed = NowPlayingTime.format(current)
        remaining = current == nil ? NowPlayingTime.format(duration) : NowPlayingTime.remaining(position: current, duration: duration)
        if let current, let duration { progress = min(1, max(0, current / duration)) } else { progress = 0 }
        isPlaying = info.isPlaying
        var spoken = title
        if !artist.isEmpty { spoken += " by \(artist)" }
        if let current {
            spoken += ", \(NowPlayingTime.format(current))"
            if let duration { spoken += " of \(NowPlayingTime.format(duration))" }
        }
        if !info.isPlaying { spoken += ", paused" }
        accessibilityValue = spoken
    }
}

enum NowPlayingArtwork {
    static let maximumSourceBytes = 16 << 20
    static let maximumDownloadBytes = 4 << 20
    /// 3x the 52 pt tile; decoding through ImageIO keeps a 3000 px cover from
    /// costing tens of megabytes and refuses anything that is not an image.
    static let maximumPixelSize = 156

    static func thumbnail(from data: Data) -> NSImage? {
        guard data.count >= 16, data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

// MARK: - Controller

final class NowPlayingController {
    static let shared = NowPlayingController()

    /// A fetch that has not answered by then answers nil; a late result is dropped.
    static let fetchDeadline: TimeInterval = 3
    /// Likewise for a seek, which then answers false.
    static let seekDeadline: TimeInterval = 3
    static let mediaRemoteTimeout: TimeInterval = 0.3
    /// After MediaRemote hangs, skip it for a while instead of paying the wait on every fetch.
    static let mediaRemoteBackoff: TimeInterval = 30
    static let artworkWait: TimeInterval = 0.6

    private enum Source: Equatable { case mediaRemote, player(NowPlayingPlayer) }

    private struct PlayerReading {
        let player: NowPlayingPlayer
        let reply: NowPlayingScriptReply
        let app: NSRunningApplication
        let readAt: Double
    }

    /// One seek request. `finish` is main-thread only and answers exactly once.
    private final class SeekTicket {
        let seconds: Double
        let frontmost: String?
        private var completion: ((Bool) -> Void)?
        init(seconds: Double, frontmost: String?, completion: @escaping (Bool) -> Void) {
            self.seconds = seconds
            self.frontmost = frontmost
            self.completion = completion
        }
        func finish(_ success: Bool) {
            let completion = self.completion
            self.completion = nil
            completion?(success)
        }
    }

    // Main-thread state. One read runs at a time; callers that arrive during
    // it wait for the next read so they never receive pre-request data.
    private var activeWaiters: [Int: (NowPlayingInfo?) -> Void] = [:]
    private var queuedWaiters: [Int: (NowPlayingInfo?) -> Void] = [:]
    private var isReading = false
    private var nextWaiterID = 0

    private let seekLock = NSLock()
    private var pendingSeek: SeekTicket?

    // Worker-confined state. NSAppleScript instances are only touched here.
    private let worker = DispatchQueue(label: "com.sway.now-playing", qos: .userInitiated)
    private let mediaRemoteQueue = DispatchQueue(label: "com.sway.now-playing.media-remote", qos: .userInitiated)
    private var mediaRemoteLoaded = false
    private var mediaRemote: NowPlayingMediaRemote?
    private var mediaRemoteRetryAfter: Double = 0
    private var compiledScripts: [String: NSAppleScript] = [:]
    private var lastSource: Source?
    private var lastDuration: Double?

    private let artworkStore = NowPlayingArtworkStore()
    private let downloader = NowPlayingArtworkDownloader()

    private init() {}

    /// Async, off main; completion exactly once on main (nil when nothing is playing or nothing is readable).
    func fetch(completion: @escaping (NowPlayingInfo?) -> Void) {
        if Thread.isMainThread { addWaiter(completion) }
        else { DispatchQueue.main.async { [self] in addWaiter(completion) } }
    }

    /// Latest-wins, off main; completion on main with success. Never launches an app that isn't running.
    /// Completes exactly once: `false` for non-finite input, for a request replaced by a newer one
    /// before it ran, or when the player has not confirmed within `seekDeadline`.
    func requestSeek(to seconds: Double, completion: @escaping (Bool) -> Void) {
        guard seconds.isFinite else { DispatchQueue.main.async { completion(false) }; return }
        let enqueue = { [self] in
            // Read on main; the worker must not query AppKit's frontmost state.
            let ticket = SeekTicket(seconds: seconds,
                                    frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                    completion: completion)
            seekLock.lock()
            let superseded = pendingSeek
            pendingSeek = ticket
            seekLock.unlock()
            superseded?.finish(false)
            worker.async { [self] in drainSeek() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.seekDeadline) { [self] in
                // Still queued behind a stuck read: withdraw it so it never runs late.
                seekLock.lock()
                if pendingSeek === ticket { pendingSeek = nil }
                seekLock.unlock()
                ticket.finish(false)
            }
        }
        if Thread.isMainThread { enqueue() } else { DispatchQueue.main.async(execute: enqueue) }
    }

    // MARK: Fetch scheduling (main)

    private func addWaiter(_ completion: @escaping (NowPlayingInfo?) -> Void) {
        nextWaiterID &+= 1
        let id = nextWaiterID
        if isReading { queuedWaiters[id] = completion }
        else { activeWaiters[id] = completion; startRead() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fetchDeadline) { [self] in
            if let expired = activeWaiters.removeValue(forKey: id) ?? queuedWaiters.removeValue(forKey: id) { expired(nil) }
        }
    }

    private func startRead() {
        isReading = true
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        worker.async { [self] in
            let info = autoreleasepool { readNowPlaying(frontmost: frontmost) }
            DispatchQueue.main.async { [self] in finishRead(info) }
        }
    }

    private func finishRead(_ info: NowPlayingInfo?) {
        isReading = false
        let finished = activeWaiters
        activeWaiters = queuedWaiters
        queuedWaiters = [:]
        // Start the follow-up before delivering, so a completion that fetches
        // again joins the queue instead of displacing anyone.
        if !activeWaiters.isEmpty { startRead() }
        for id in finished.keys.sorted() { finished[id]?(info) }
    }

    // MARK: Reading (worker)

    private func readNowPlaying(frontmost: String?) -> NowPlayingInfo? {
        if let info = readMediaRemote() {
            lastSource = .mediaRemote
            lastDuration = info.duration
            return info
        }
        guard let reading = choosePlayer(frontmost: frontmost) else {
            lastSource = nil
            lastDuration = nil
            return nil
        }
        let reply = reading.reply
        let duration = reply.durationSeconds(for: reading.player)
        lastSource = .player(reading.player)
        lastDuration = duration
        var position = reply.positionSeconds
        if let current = position, let duration { position = min(current, duration) }
        let appName = NowPlayingText.clean(reading.app.localizedName)
        return NowPlayingInfo(title: reply.title, artist: reply.artist, album: reply.album,
                              duration: duration, position: position, isPlaying: reply.state == .playing,
                              artwork: artwork(for: reading),
                              appName: appName.isEmpty ? reading.player.displayName : appName,
                              appBundleID: reading.player.bundleID, fetchedAt: reading.readAt)
    }

    private func runningApplication(_ player: NowPlayingPlayer) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first { !$0.isTerminated }
    }

    /// Reads every supported player that is already running; never addresses
    /// one that is not, so no script here can launch an app.
    private func choosePlayer(frontmost: String?) -> PlayerReading? {
        var readings: [PlayerReading] = []
        for player in NowPlayingPlayer.allCases {
            guard let app = runningApplication(player),
                  let result = execute(NowPlayingAppleScript.readSource(for: player), cacheKey: "read." + player.bundleID),
                  let reply = NowPlayingScriptReply.parse(result.stringValue) else { continue }
            readings.append(PlayerReading(player: player, reply: reply, app: app,
                                          readAt: ProcessInfo.processInfo.systemUptime))
        }
        let candidates = readings.map {
            NowPlayingCandidate(bundleID: $0.player.bundleID, isRunning: true, isPlaying: $0.reply.state == .playing,
                                isFrontmost: $0.player.bundleID == frontmost, hasTrack: $0.reply.hasTrack)
        }
        return NowPlayingPlayerChoice.choose(candidates).map { readings[$0] }
    }

    private func execute(_ source: String, cacheKey: String?) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cacheKey, let cached = compiledScripts[cacheKey] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { return nil }
            var compileError: NSDictionary?
            guard created.compileAndReturnError(&compileError) else { return nil }
            if let cacheKey { compiledScripts[cacheKey] = created }
            script = created
        }
        var error: NSDictionary?
        let result: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private func artwork(for reading: PlayerReading) -> NSImage? {
        switch reading.player {
        case .music:
            let reply = reading.reply
            let identity = reply.key.isEmpty ? [reply.title, reply.artist, reply.album].joined(separator: "\u{1F}") : reply.key
            let key = "music:" + identity
            // Streaming covers can arrive late, so a miss is retried soon.
            if case let .hit(image) = artworkStore.lookup(key, negativeLifetime: 10) { return image }
            let image = execute(NowPlayingAppleScript.musicArtwork, cacheKey: "artwork.music")
                .flatMap { NowPlayingArtwork.thumbnail(from: $0.data) }
            artworkStore.store(image, for: key)
            return image
        case .spotify:
            guard let url = NowPlayingArtworkPolicy.spotifyArtworkURL(reading.reply.key) else { return nil }
            return spotifyArtwork(url)
        }
    }

    private func spotifyArtwork(_ url: URL) -> NSImage? {
        let key = "spotify:" + url.absoluteString
        if case let .hit(image) = artworkStore.lookup(key, negativeLifetime: 30) { return image }
        let (group, isNew) = artworkStore.beginDownload(key)
        if isNew {
            let store = artworkStore
            downloader.load(url) { image in store.finishDownload(key, image: image) }
        }
        // Wait briefly; a slow cover lands in the cache for the next fetch.
        _ = group.wait(timeout: .now() + Self.artworkWait)
        if case let .hit(image) = artworkStore.lookup(key, negativeLifetime: 30) { return image }
        return nil
    }

    private func loadMediaRemote() -> NowPlayingMediaRemote? {
        if !mediaRemoteLoaded {
            mediaRemoteLoaded = true
            mediaRemote = NowPlayingMediaRemote()
        }
        return mediaRemote
    }

    private func readMediaRemote() -> NowPlayingInfo? {
        guard ProcessInfo.processInfo.systemUptime >= mediaRemoteRetryAfter, let remote = loadMediaRemote() else { return nil }
        let group = DispatchGroup()
        let dictionaryBox = NowPlayingLockedBox<[String: Any]?>(nil)
        let playingBox = NowPlayingLockedBox<Bool?>(nil)
        let pidBox = NowPlayingLockedBox<Int32?>(nil)

        let infoToken = NowPlayingGroupToken(group)
        remote.getInfo(mediaRemoteQueue) { dictionary in
            if let dictionary, let bridged = (dictionary as NSDictionary) as? [String: Any], !bridged.isEmpty {
                dictionaryBox.set(bridged)
            }
            infoToken.leave()
        }
        let playingToken = NowPlayingGroupToken(group)
        remote.getIsPlaying(mediaRemoteQueue) { playing in
            playingBox.set(playing.boolValue)
            playingToken.leave()
        }
        if let getPID = remote.getPID {
            let pidToken = NowPlayingGroupToken(group)
            getPID(mediaRemoteQueue) { pid in
                pidBox.set(pid)
                pidToken.leave()
            }
        }
        let timedOut = group.wait(timeout: .now() + Self.mediaRemoteTimeout) == .timedOut
        guard let dictionary = dictionaryBox.get() else {
            if timedOut { mediaRemoteRetryAfter = ProcessInfo.processInfo.systemUptime + Self.mediaRemoteBackoff }
            return nil
        }
        let app = pidBox.get().flatMap { $0 > 0 ? NSRunningApplication(processIdentifier: $0) : nil }
        var artwork: NSImage?
        if let data = dictionary[NowPlayingMediaRemoteParser.artworkKey] as? Data {
            let identity = [NowPlayingMediaRemoteParser.titleKey, NowPlayingMediaRemoteParser.artistKey, NowPlayingMediaRemoteParser.albumKey]
                .map { dictionary[$0] as? String ?? "" }.joined(separator: "\u{1F}")
            let key = "media-remote:\(identity)\u{1F}\(data.count)"
            if case let .hit(image) = artworkStore.lookup(key, negativeLifetime: 10) { artwork = image }
            else {
                artwork = NowPlayingArtwork.thumbnail(from: data)
                artworkStore.store(artwork, for: key)
            }
        }
        return NowPlayingMediaRemoteParser.info(from: dictionary, isPlaying: playingBox.get(),
                                                appName: app?.localizedName ?? "", bundleID: app?.bundleIdentifier,
                                                artwork: artwork, wallClock: Date(),
                                                uptime: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Seeking (worker)

    private func drainSeek() {
        seekLock.lock()
        let ticket = pendingSeek
        pendingSeek = nil
        seekLock.unlock()
        guard let ticket else { return }
        let success = autoreleasepool { performSeek(to: ticket.seconds, frontmost: ticket.frontmost) }
        DispatchQueue.main.async { ticket.finish(success) }
    }

    private func performSeek(to seconds: Double, frontmost: String?) -> Bool {
        func clamped(_ value: Double, _ duration: Double?) -> Double {
            guard let duration, duration.isFinite, duration > 0 else { return max(0, value) }
            return min(max(0, value), duration)
        }
        // Seek whatever the last fetch showed, so the HUD and the seek agree.
        if lastSource == .mediaRemote, let setElapsed = loadMediaRemote()?.setElapsed {
            setElapsed(clamped(seconds, lastDuration))
            return true
        }
        if case let .player(player)? = lastSource, runningApplication(player) != nil {
            return seekPlayer(player, to: clamped(seconds, lastDuration))
        }
        guard let reading = choosePlayer(frontmost: frontmost) else { return false }
        let duration = reading.reply.durationSeconds(for: reading.player)
        lastSource = .player(reading.player)
        lastDuration = duration
        return seekPlayer(reading.player, to: clamped(seconds, duration))
    }

    private func seekPlayer(_ player: NowPlayingPlayer, to seconds: Double) -> Bool {
        guard runningApplication(player) != nil,
              let source = NowPlayingAppleScript.seekSource(for: player, seconds: seconds),
              let result = execute(source, cacheKey: nil) else { return false }
        return result.booleanValue
    }
}

/// Typed MediaRemote entry points. Nil when the framework or a required read
/// symbol is missing, so every caller fails closed.
private final class NowPlayingMediaRemote {
    typealias InfoFunction = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias PlayingFunction = @convention(c) (DispatchQueue, @escaping @convention(block) (DarwinBoolean) -> Void) -> Void
    typealias PIDFunction = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    typealias SetElapsedFunction = @convention(c) (Double) -> Void

    static let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    let getInfo: InfoFunction
    let getIsPlaying: PlayingFunction
    let getPID: PIDFunction?
    let setElapsed: SetElapsedFunction?

    init?() {
        // Never dlclose'd: the symbols live for the process lifetime.
        guard let handle = dlopen(Self.path, RTLD_LAZY | RTLD_LOCAL),
              let info = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo"),
              let playing = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else { return nil }
        getInfo = unsafeBitCast(info, to: InfoFunction.self)
        getIsPlaying = unsafeBitCast(playing, to: PlayingFunction.self)
        getPID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID").map { unsafeBitCast($0, to: PIDFunction.self) }
        setElapsed = dlsym(handle, "MRMediaRemoteSetElapsedTime").map { unsafeBitCast($0, to: SetElapsedFunction.self) }
    }
}

private final class NowPlayingLockedBox<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

/// Enters on creation and leaves at most once, so a private framework that
/// calls back twice cannot unbalance the group.
private final class NowPlayingGroupToken {
    private let lock = NSLock()
    private let group: DispatchGroup
    private var left = false
    init(_ group: DispatchGroup) {
        self.group = group
        group.enter()
    }
    func leave() {
        lock.lock()
        let shouldLeave = !left
        left = true
        lock.unlock()
        if shouldLeave { group.leave() }
    }
}

private enum NowPlayingCachedArtwork {
    case miss
    case hit(NSImage?)
}

/// Small LRU of decoded covers. A failed lookup is remembered briefly so a
/// track without art does not cost an Apple Event or request on every fetch.
private final class NowPlayingArtworkStore {
    private struct Entry {
        let image: NSImage?
        let storedAt: Double
    }

    private let lock = NSLock()
    private let capacity = 12
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var downloads: [String: DispatchGroup] = [:]

    func lookup(_ key: String, negativeLifetime: Double) -> NowPlayingCachedArtwork {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return .miss }
        if entry.image == nil, ProcessInfo.processInfo.systemUptime - entry.storedAt > negativeLifetime {
            entries[key] = nil
            order.removeAll { $0 == key }
            return .miss
        }
        return .hit(entry.image)
    }

    func store(_ image: NSImage?, for key: String) {
        lock.lock()
        insert(image, for: key)
        lock.unlock()
    }

    /// The group for an in-flight download of `key`; `isNew` means the caller owns starting it.
    func beginDownload(_ key: String) -> (group: DispatchGroup, isNew: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = downloads[key] { return (existing, false) }
        let group = DispatchGroup()
        group.enter()
        downloads[key] = group
        return (group, true)
    }

    func finishDownload(_ key: String, image: NSImage?) {
        lock.lock()
        insert(image, for: key)
        let group = downloads.removeValue(forKey: key)
        lock.unlock()
        group?.leave()
    }

    private func insert(_ image: NSImage?, for key: String) {
        entries[key] = Entry(image: image, storedAt: ProcessInfo.processInfo.systemUptime)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }
}

/// Spotify covers only: ephemeral, cookie-less, short timeouts, and redirects
/// are followed only to another https Spotify CDN host.
private final class NowPlayingArtworkDownloader: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Completion runs exactly once, on a URLSession queue.
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpShouldHandleCookies = false
        session.dataTask(with: request) { data, response, error in
            guard error == nil, let data, data.count <= NowPlayingArtwork.maximumDownloadBytes,
                  let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let finalURL = response.url, finalURL.scheme?.lowercased() == "https",
                  let host = finalURL.host, NowPlayingArtworkPolicy.isAllowedSpotifyHost(host)
            else { completion(nil); return }
            completion(NowPlayingArtwork.thumbnail(from: data))
        }.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let host = url.host, NowPlayingArtworkPolicy.isAllowedSpotifyHost(host) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

// MARK: - HUD

/// A lazy Now Playing indicator styled like OSDOverlay. No window exists until
/// the first show; no timer runs while it is hidden.
final class NowPlayingHUD {
    static let shared = NowPlayingHUD()
    static let size = NSSize(width: 340, height: 76)
    /// Above the volume pill, which sits 24 pt above `visibleFrame`.
    static let bottomInset: CGFloat = 92
    static let visibleDuration: TimeInterval = 2
    private static let fadeDuration: TimeInterval = 0.16
    private static let tickInterval: TimeInterval = 0.25

    private var window: NowPlayingWindow?
    private var surface: NowPlayingSurfaceView?
    private var hideTimer: Timer?
    private var fadeTimer: Timer?
    private var updateTimer: Timer?
    private var tickTimer: Timer?
    private var hideDeadline: TimeInterval = 0
    private var lastDisplayTime: TimeInterval = 0
    private var info: NowPlayingInfo?
    private var scrubPosition: Double?
    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.repositionWindow()
        }
    }

    /// Shows or updates the HUD; hides itself ~2 s after the last call.
    /// `scrubPosition`, when set, draws that position instead of the live one (used while seeking).
    func show(_ info: NowPlayingInfo, scrubPosition: Double? = nil) {
        if Thread.isMainThread { present(info, scrubPosition: scrubPosition) }
        else { DispatchQueue.main.async { [weak self] in self?.present(info, scrubPosition: scrubPosition) } }
    }

    func hide() {
        if Thread.isMainThread { dismiss() }
        else { DispatchQueue.main.async { [weak self] in self?.dismiss() } }
    }

    private func present(_ info: NowPlayingInfo, scrubPosition: Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        hideDeadline = now + Self.visibleDuration
        let isStarting = window?.isVisible != true
        if window == nil {
            let surface = NowPlayingSurfaceView()
            let window = NowPlayingWindow(contentRect: NSRect(origin: .zero, size: Self.size))
            window.contentView = surface
            self.surface = surface
            self.window = window
        }
        // Cancel the sole owned fade. No old completion can hide a new request.
        if fadeTimer != nil {
            fadeTimer?.invalidate()
            fadeTimer = nil
            window?.alphaValue = 1
        }
        self.info = info
        self.scrubPosition = scrubPosition.flatMap { $0.isFinite ? max(0, $0) : nil }
        if isStarting {
            window?.appearance = Self.preferredAppearance()
            repositionWindow()
            window?.alphaValue = 1
            lastDisplayTime = 0
        }
        // Scrubbing can call this every input frame; draw at most once per display frame.
        let remaining = 1.0 / 60.0 - (now - lastDisplayTime)
        if remaining <= 0 || isStarting {
            updateTimer?.invalidate()
            updateTimer = nil
            displayCurrent()
        } else if updateTimer == nil {
            updateTimer = scheduledTimer(after: remaining) { [weak self] in
                self?.updateTimer = nil
                self?.displayCurrent()
            }
        }
        // Commit the first frame before the compositor can display the window.
        if isStarting { window?.orderFrontRegardless() }
        if hideTimer == nil { scheduleHideCheck(after: Self.visibleDuration) }
        refreshTicker()
    }

    private func displayCurrent() {
        guard let info else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastDisplayTime = now
        let position = scrubPosition ?? info.position(at: now)
        surface?.content.update(NowPlayingDisplay(info: info, position: position), artwork: info.artwork)
    }

    /// Advances elapsed time only while visible, playing, and not scrubbing.
    private func refreshTicker() {
        let needsTicks = window?.isVisible == true && scrubPosition == nil
            && info?.isPlaying == true && info?.position != nil
        if needsTicks, tickTimer == nil {
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.displayCurrent() }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !needsTicks {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func scheduleHideCheck(after delay: TimeInterval) {
        hideTimer = scheduledTimer(after: delay, tolerance: 0.04) { [weak self] in
            guard let self else { return }
            self.hideTimer = nil
            let remaining = self.hideDeadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { self.scheduleHideCheck(after: remaining) }
            else { self.beginFade() }
        }
    }

    private func beginFade() {
        guard window?.isVisible == true else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { dismiss(); return }
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = (ProcessInfo.processInfo.systemUptime - started) / Self.fadeDuration
            if progress >= 1 { self.dismiss() }
            else { self.window?.alphaValue = 1 - progress }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func dismiss() {
        hideTimer?.invalidate()
        fadeTimer?.invalidate()
        updateTimer?.invalidate()
        tickTimer?.invalidate()
        hideTimer = nil
        fadeTimer = nil
        updateTimer = nil
        tickTimer = nil
        info = nil
        scrubPosition = nil
        window?.orderOut(nil)
        window?.alphaValue = 1
    }

    private func repositionWindow() {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(x: (frame.midX - size.width / 2).rounded(), y: frame.minY + Self.bottomInset)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    /// Follows Sway's stored appearance preference without depending on its settings type.
    private static func preferredAppearance() -> NSAppearance? {
        switch UserDefaults.standard.string(forKey: "appearanceMode") {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    private func scheduledTimer(after delay: TimeInterval, tolerance: TimeInterval = 0,
                                action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { _ in action() }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

final class NowPlayingWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Liquid Glass on macOS 26+, a HUD material before that, and an opaque
/// surface whenever Reduce Transparency is on. Same contract as OSDSurfaceView.
final class NowPlayingSurfaceView: NSView {
    static let cornerRadius: CGFloat = 24
    let content = NowPlayingContentView(frame: .zero)
    private var material: NSView?
    private let forceReduceTransparency: Bool?
    private var accessibilityObserver: NSObjectProtocol?

    init(forceReduceTransparency: Bool? = nil) {
        self.forceReduceTransparency = forceReduceTransparency
        super.init(frame: .zero)
        rebuildMaterial()
        if forceReduceTransparency == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.rebuildMaterial() }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    private func rebuildMaterial() {
        content.removeFromSuperview()
        material?.removeFromSuperview()
        let reduced = forceReduceTransparency ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let background: NSView
        if reduced {
            let opaque = NowPlayingOpaqueSurface(frame: bounds)
            opaque.addSubview(content)
            background = opaque
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            background = glass
        } else {
            let vibrant = NSVisualEffectView(frame: bounds)
            vibrant.material = .hudWindow
            vibrant.blendingMode = .behindWindow
            vibrant.state = .active
            vibrant.wantsLayer = true
            vibrant.layer?.cornerRadius = Self.cornerRadius
            vibrant.layer?.masksToBounds = true
            vibrant.addSubview(content)
            background = vibrant
        }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        background.autoresizingMask = [.width, .height]
        material = background
        addSubview(background)
    }
    override func layout() {
        super.layout()
        material?.frame = bounds
        content.frame = bounds
    }
}

private final class NowPlayingOpaqueSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: NowPlayingSurfaceView.cornerRadius,
                     yRadius: NowPlayingSurfaceView.cornerRadius).fill()
    }
}

/// Native labels, one artwork tile, and two tiny progress layers. Exposed to
/// accessibility as a single element.
final class NowPlayingContentView: NSView {
    private let artworkView = NowPlayingArtworkView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let remainingLabel = NSTextField(labelWithString: "")
    private let stateIcon = NSImageView()
    private let track = CALayer()
    private let fill = CALayer()
    private var display: NowPlayingDisplay?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configure(titleLabel, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        configure(subtitleLabel, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        configure(elapsedLabel, font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: .secondaryLabelColor)
        configure(remainingLabel, font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: .secondaryLabelColor)
        remainingLabel.alignment = .right
        stateIcon.imageScaling = .scaleProportionallyDown
        stateIcon.contentTintColor = .secondaryLabelColor
        stateIcon.setAccessibilityElement(false)
        for view in [artworkView, titleLabel, subtitleLabel, elapsedLabel, remainingLabel, stateIcon] as [NSView] {
            addSubview(view)
        }
        track.cornerRadius = 2
        fill.cornerRadius = 2
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        updateColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Now playing")
    }
    required init?(coder: NSCoder) { nil }

    func update(_ display: NowPlayingDisplay, artwork: NSImage?) {
        if artworkView.image !== artwork { artworkView.image = artwork }
        guard display != self.display else { return }
        let previous = self.display
        self.display = display
        if previous?.title != display.title { titleLabel.stringValue = display.title }
        if previous?.subtitle != display.subtitle { subtitleLabel.stringValue = display.subtitle }
        if previous?.elapsed != display.elapsed { elapsedLabel.stringValue = display.elapsed }
        if previous?.remaining != display.remaining { remainingLabel.stringValue = display.remaining }
        if previous?.isPlaying != display.isPlaying {
            stateIcon.image = NSImage(systemSymbolName: display.isPlaying ? "play.fill" : "pause.fill",
                                      accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        }
        if previous?.progress != display.progress { updateFill() }
        if previous?.accessibilityValue != display.accessibilityValue { setAccessibilityValue(display.accessibilityValue) }
    }

    override func layout() {
        super.layout()
        let tile: CGFloat = 52
        artworkView.frame = NSRect(x: 12, y: ((bounds.height - tile) / 2).rounded(), width: tile, height: tile)
        let left = artworkView.frame.maxX + 12
        let right = bounds.width - 16
        let width = max(0, right - left)
        let top = artworkView.frame.maxY
        let bottom = artworkView.frame.minY
        stateIcon.frame = NSRect(x: right - 12, y: top - 14, width: 12, height: 12)
        titleLabel.frame = NSRect(x: left, y: top - 17, width: max(0, width - 18), height: 17)
        subtitleLabel.frame = NSRect(x: left, y: top - 31, width: width, height: 14)
        elapsedLabel.frame = NSRect(x: left, y: bottom - 3, width: width / 2, height: 13)
        remainingLabel.frame = NSRect(x: left + width / 2, y: bottom - 3, width: width / 2, height: 13)
        withoutAnimation { track.frame = NSRect(x: left, y: bottom + 13, width: width, height: 4) }
        updateFill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func configure(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.setAccessibilityElement(false)
    }
    private func updateFill() {
        var frame = track.frame
        frame.size.width *= CGFloat(display?.progress ?? 0)
        withoutAnimation { fill.frame = frame }
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutAnimation {
                track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
                fill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.88).cgColor
            }
        }
    }
    private func withoutAnimation(_ action: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        action()
        CATransaction.commit()
    }
}

/// 8 pt rounded cover, aspect-filled, with a monochrome `music.note` placeholder.
final class NowPlayingArtworkView: NSView {
    var image: NSImage? {
        didSet {
            placeholder.isHidden = image != nil
            needsDisplay = true
        }
    }
    private let placeholder = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        placeholder.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))
        placeholder.imageScaling = .scaleProportionallyDown
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.setAccessibilityElement(false)
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = image == nil ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
        }
        layer.contents = image.map { $0.layerContents(forContentsScale: layer.contentsScale) }
    }
    override func layout() {
        super.layout()
        placeholder.frame = bounds
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

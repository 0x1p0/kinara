import AppKit

/// Pure logic only. Nothing here touches `NowPlayingController.shared` or
/// `NowPlayingHUD.shared`, so no Apple Event, MediaRemote query, network
/// request, or window can occur.
@main
enum NowPlayingRegressionTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    private static let separator = "\u{1F}"

    private static func info(position: Double? = 10, duration: Double? = 180, isPlaying: Bool = true,
                             fetchedAt: Double = 100, title: String = "Song", artist: String = "Artist",
                             album: String = "Album", appName: String = "Music") -> NowPlayingInfo {
        NowPlayingInfo(title: title, artist: artist, album: album, duration: duration, position: position,
                       isPlaying: isPlaying, artwork: nil, appName: appName, appBundleID: "com.apple.Music",
                       fetchedAt: fetchedAt)
    }

    static func main() {
        positionExtrapolation()
        timeFormatting()
        playerChoice()
        replyParsing()
        seekFormatting()
        scriptSafety()
        artworkPolicy()
        mediaRemoteParsing()
        displayModel()
        textCleaning()
        playbackHold()
        print("\(checks) now-playing assertions passed. Pure logic only; no Apple Events, MediaRemote, network, or windows.")
    }

    private static func positionExtrapolation() {
        expect(info().position(at: 105) == 15, "playing position advances with the clock")
        expect(info(isPlaying: false).position(at: 105) == 10, "paused position stays put")
        expect(info().position(at: 1_000) == 180, "extrapolation clamps to duration")
        expect(info(duration: nil).position(at: 1_000) == 910, "unknown duration does not clamp")
        expect(info(duration: .nan).position(at: 105) == 15, "nonfinite duration is ignored")
        expect(info(duration: 0).position(at: 105) == 15, "zero duration is ignored")
        expect(info().position(at: 90) == 10, "a clock before fetchedAt never rewinds")
        expect(info().position(at: .nan) == 10, "nonfinite clock returns the stored position")
        expect(info(fetchedAt: .nan).position(at: 105) == 10, "nonfinite fetch time returns the stored position")
        expect(info(position: nil).position(at: 105) == nil, "unknown position stays unknown")
        expect(info(position: .nan).position(at: 105) == nil, "nonfinite position is unknown")
        expect(info(position: .infinity).position(at: 105) == nil, "infinite position is unknown")
        expect(info(position: -4, isPlaying: false).position(at: 105) == 0, "negative position clamps to zero")
        expect(info(position: 200, isPlaying: false).position(at: 105) == 180, "stored overrun clamps to duration")
    }

    private static func timeFormatting() {
        expect(NowPlayingTime.format(7) == "0:07", "seconds pad to two digits")
        expect(NowPlayingTime.format(185) == "3:05", "minutes and seconds")
        expect(NowPlayingTime.format(3_723) == "1:02:03", "hours pad minutes and seconds")
        expect(NowPlayingTime.format(0) == "0:00", "zero")
        expect(NowPlayingTime.format(59.999) == "0:59", "elapsed rounds down")
        expect(NowPlayingTime.format(600) == "10:00", "two-digit minutes are not padded further")
        expect(NowPlayingTime.format(3_600) == "1:00:00", "exact hour")
        expect(NowPlayingTime.format(-5) == "0:00", "negative clamps to zero")
        expect(NowPlayingTime.format(.nan) == "--:--", "NaN renders the placeholder")
        expect(NowPlayingTime.format(.infinity) == "--:--", "infinity renders the placeholder")
        expect(NowPlayingTime.format(nil) == "--:--", "unknown renders the placeholder")
        expect(NowPlayingTime.format(1e300) == "99:59:59", "huge values cannot overflow Int")
        expect(NowPlayingTime.remaining(position: 0.3, duration: 180) == "-3:00", "remaining rounds up")
        expect(NowPlayingTime.remaining(position: 179.5, duration: 180) == "-0:01", "last partial second still shows")
        expect(NowPlayingTime.remaining(position: 180, duration: 180) == "-0:00", "end of track")
        expect(NowPlayingTime.remaining(position: 200, duration: 180) == "-0:00", "overrun never goes positive")
        expect(NowPlayingTime.remaining(position: 55, duration: 180) == "-2:05", "whole seconds subtract exactly")
        expect(NowPlayingTime.remaining(position: .nan, duration: 180) == "-3:00", "NaN position counts from zero")
        expect(NowPlayingTime.remaining(position: 10, duration: nil) == "--:--", "unknown duration")
        expect(NowPlayingTime.remaining(position: 10, duration: 0) == "--:--", "zero duration")
        expect(NowPlayingTime.remaining(position: 10, duration: .infinity) == "--:--", "infinite duration")
        for elapsed in stride(from: 0.0, through: 185, by: 0.37) {
            let left = NowPlayingTime.remaining(position: elapsed, duration: 185)
            let parts = (NowPlayingTime.format(elapsed) + ":" + left.dropFirst()).split(separator: ":").compactMap { Int($0) }
            expect(parts.count == 4 && parts[0] * 60 + parts[1] + parts[2] * 60 + parts[3] == 185,
                   "elapsed plus remaining always equals the duration (\(elapsed))")
        }
    }

    private static func playerChoice() {
        typealias C = NowPlayingCandidate
        let music = NowPlayingPlayer.music.bundleID
        let spotify = NowPlayingPlayer.spotify.bundleID
        func pick(_ candidates: [C]) -> String? { NowPlayingPlayerChoice.choose(candidates).map { candidates[$0].bundleID } }

        expect(pick([]) == nil, "nothing to choose")
        expect(pick([C(bundleID: music, isRunning: false, isPlaying: true, isFrontmost: true),
                     C(bundleID: spotify, isRunning: false, isPlaying: true, isFrontmost: false)]) == nil,
               "apps that are not running are never addressed, whatever their flags")
        expect(pick([C(bundleID: music, isRunning: false, isPlaying: false, isFrontmost: false),
                     C(bundleID: spotify, isRunning: true, isPlaying: false, isFrontmost: false)]) == spotify,
               "the only running player")
        expect(pick([C(bundleID: music, isRunning: true, isPlaying: false, isFrontmost: true),
                     C(bundleID: spotify, isRunning: true, isPlaying: true, isFrontmost: false)]) == spotify,
               "playing beats frontmost")
        expect(pick([C(bundleID: music, isRunning: true, isPlaying: true, isFrontmost: false),
                     C(bundleID: spotify, isRunning: true, isPlaying: true, isFrontmost: true)]) == spotify,
               "both playing: frontmost wins")
        expect(pick([C(bundleID: music, isRunning: true, isPlaying: true, isFrontmost: false),
                     C(bundleID: spotify, isRunning: true, isPlaying: true, isFrontmost: false)]) == music,
               "both playing in the background: stable order")
        expect(pick([C(bundleID: music, isRunning: true, isPlaying: false, isFrontmost: false),
                     C(bundleID: spotify, isRunning: true, isPlaying: false, isFrontmost: true)]) == spotify,
               "nothing playing: frontmost wins")
        expect(pick([C(bundleID: music, isRunning: true, isPlaying: false, isFrontmost: false),
                     C(bundleID: spotify, isRunning: true, isPlaying: false, isFrontmost: false)]) == music,
               "nothing playing or frontmost: either running one, deterministically")
        expect(pick([C(bundleID: music, isRunning: true, isPlaying: false, isFrontmost: true, hasTrack: false),
                     C(bundleID: spotify, isRunning: true, isPlaying: false, isFrontmost: false)]) == spotify,
               "a stopped player with no track is skipped")
        expect(pick([C(bundleID: music, isRunning: true, isPlaying: false, isFrontmost: true, hasTrack: false)]) == nil,
               "no track anywhere means nothing to show or seek")
        expect(NowPlayingPlayer.allCases.map(\.bundleID) == [music, spotify], "supported players and their tie-break order")
    }

    private static func replyParsing() {
        let full = ["playing", "Song", "Artist", "Album", "215000", "42500", "ABC123"].joined(separator: separator)
        guard let reply = NowPlayingScriptReply.parse(full) else { expect(false, "full reply parses"); return }
        expect(reply.state == .playing && reply.hasTrack, "state")
        expect(reply.title == "Song" && reply.artist == "Artist" && reply.album == "Album", "text fields in order")
        expect(reply.durationMilliseconds == 215_000 && reply.positionMilliseconds == 42_500, "numeric fields")
        expect(reply.durationSeconds(for: .music) == 215 && reply.positionSeconds == 42.5, "milliseconds become seconds")
        expect(reply.key == "ABC123", "key field")

        let paused = NowPlayingScriptReply.parse(["paused", "", "", "", "-1", "-1", ""].joined(separator: separator))
        expect(paused?.state == .paused && paused?.title == "", "empty text fields are allowed")
        expect(paused?.durationMilliseconds == nil && paused?.positionMilliseconds == nil, "-1 sentinels mean unknown")
        expect(NowPlayingScriptReply.parse(["paused", "S", "A", "B", "0", "0", ""].joined(separator: separator))?.positionMilliseconds == 0,
               "zero position is valid; zero duration is not")
        expect(NowPlayingScriptReply.parse(["paused", "S", "A", "B", "0", "0", ""].joined(separator: separator))?.durationMilliseconds == nil,
               "zero duration is unknown")

        expect(NowPlayingScriptReply.parse("stopped") == NowPlayingScriptReply(state: .stopped), "stopped is a single field")
        expect(NowPlayingScriptReply.parse("stopped")?.hasTrack == false, "stopped has no track")
        expect(NowPlayingScriptReply.parse(" stopped\n") == NowPlayingScriptReply(state: .stopped), "state whitespace is trimmed")
        expect(NowPlayingScriptReply.parse(nil) == nil, "no reply")
        expect(NowPlayingScriptReply.parse("") == nil, "not running guard returns empty")
        expect(NowPlayingScriptReply.parse("playing") == nil, "playing without fields is malformed")
        expect(NowPlayingScriptReply.parse(["buffering", "S", "A", "B", "1", "1", ""].joined(separator: separator)) == nil,
               "unknown state is rejected")
        expect(NowPlayingScriptReply.parse(["playing", "S", "A"].joined(separator: separator)) == nil, "too few fields")
        let injected = ["playing", "Evil\(separator)Title", "Artist", "Album", "1000", "0", ""].joined(separator: separator)
        expect(NowPlayingScriptReply.parse(injected) == nil, "a separator inside a field is rejected, not shifted")
        expect(NowPlayingScriptReply.parse(String(repeating: "x", count: 20_000)) == nil, "oversized reply is rejected")

        let messy = NowPlayingScriptReply.parse(["playing", "  Line\nBreak\t", "A\u{0}B", "Album", "1234,5", "nan", ""].joined(separator: separator))
        expect(messy?.title == "Line Break", "control characters become spaces and edges are trimmed")
        expect(messy?.artist == "A B", "NUL is neutralised")
        expect(messy?.durationMilliseconds == 1_234.5, "decimal comma from a localized coercion")
        expect(messy?.positionMilliseconds == nil, "NaN is unknown")
        let emoji = NowPlayingScriptReply.parse(["playing", "Fam 👨‍👩‍👧 ñ", "Ärtist", "", "1", "1", ""].joined(separator: separator))
        expect(emoji?.title == "Fam 👨‍👩‍👧 ñ" && emoji?.artist == "Ärtist", "joiners and non-ASCII text survive")

        expect(NowPlayingScriptReply.number("42") == 42, "integer")
        expect(NowPlayingScriptReply.number(" 7 ") == 7, "whitespace")
        expect(NowPlayingScriptReply.number("1.0E+12") == 1e12, "exponent form")
        expect(NowPlayingScriptReply.number("1,5E+9") == 1.5e9, "exponent form with decimal comma")
        expect(NowPlayingScriptReply.number("inf") == nil, "infinity rejected")
        expect(NowPlayingScriptReply.number("") == nil, "empty rejected")
        expect(NowPlayingScriptReply.number("12abc") == nil, "garbage rejected")
        expect(NowPlayingScriptReply.number(String(repeating: "9", count: 40)) == nil, "absurd length rejected")

        var spotify = NowPlayingScriptReply(state: .playing)
        spotify.durationMilliseconds = 215_000
        spotify.positionMilliseconds = 30_000
        expect(spotify.durationSeconds(for: .spotify) == 215, "current Spotify reports milliseconds")
        spotify.durationMilliseconds = 215
        expect(spotify.durationSeconds(for: .spotify) == 215, "legacy Spotify seconds are recognised from the position")
        expect(spotify.durationSeconds(for: .music) == 0.215, "Music is always milliseconds")
        spotify.positionMilliseconds = nil
        expect(spotify.durationSeconds(for: .spotify) == 0.215, "without a position the documented unit is used")
    }

    private static func seekFormatting() {
        expect(NowPlayingAppleScript.seekLiteral(12.3456) == "12.346", "three decimals, rounded")
        expect(NowPlayingAppleScript.seekLiteral(0) == "0.000", "zero")
        expect(NowPlayingAppleScript.seekLiteral(-3) == "0.000", "negative clamps to zero")
        expect(NowPlayingAppleScript.seekLiteral(61.5) == "61.500", "trailing zeros")
        expect(NowPlayingAppleScript.seekLiteral(5.05) == "5.050", "binary fraction rounding")
        expect(NowPlayingAppleScript.seekLiteral(0.01) == "0.010", "leading fraction zero")
        expect(NowPlayingAppleScript.seekLiteral(3_723.007) == "3723.007", "two leading fraction zeros")
        expect(NowPlayingAppleScript.seekLiteral(.nan) == nil, "NaN is refused")
        expect(NowPlayingAppleScript.seekLiteral(.infinity) == nil, "infinity is refused")
        expect(NowPlayingAppleScript.seekLiteral(-.infinity) == nil, "negative infinity is refused")
        expect(NowPlayingAppleScript.seekLiteral(1e300) == "604800.000", "huge values clamp")
        for value in stride(from: 0.0, through: 4_000, by: 13.37) {
            let literal = NowPlayingAppleScript.seekLiteral(value) ?? ""
            let parts = literal.split(separator: ".", omittingEmptySubsequences: false)
            expect(parts.count == 2 && parts[1].count == 3 && literal.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") },
                   "locale-free digits, one point, three decimals (\(literal))")
            expect(abs((Double(literal) ?? -1) - value) <= 0.0005, "literal round-trips (\(literal))")
        }
        let previous = setlocale(LC_ALL, nil).map { String(cString: $0) }
        setlocale(LC_ALL, "de_DE.UTF-8")
        expect(NowPlayingAppleScript.seekLiteral(1.5) == "1.500", "a decimal-comma C locale cannot change the literal")
        setlocale(LC_ALL, previous ?? "C")

        for player in NowPlayingPlayer.allCases {
            guard let source = NowPlayingAppleScript.seekSource(for: player, seconds: 90.25) else {
                expect(false, "seek source builds"); continue
            }
            expect(source.hasPrefix("if application id \"\(player.bundleID)\" is not running then return false\n"),
                   "seek re-checks that the player is running before any tell")
            expect(source.contains("set player position to 90.250\n"), "seek carries only the formatted number")
            expect(NowPlayingAppleScript.seekSource(for: player, seconds: .nan) == nil, "no script for NaN")
        }
    }

    private static func scriptSafety() {
        let reads = NowPlayingPlayer.allCases.map { ($0, NowPlayingAppleScript.readSource(for: $0)) }
        let transport = NowPlayingPlayer.allCases.flatMap { player in
            [(player, NowPlayingAppleScript.stateSource(for: player)),
             (player, NowPlayingAppleScript.transportSource(for: player, play: true)),
             (player, NowPlayingAppleScript.transportSource(for: player, play: false))]
        }
        let scripts = reads + transport + [(NowPlayingPlayer.music, NowPlayingAppleScript.musicArtwork)]
        for player in NowPlayingPlayer.allCases {
            expect(!NowPlayingAppleScript.transportSource(for: player, play: false).contains("playpause"), "a pause is never a toggle")
        }
        for (player, source) in scripts {
            let lines = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            expect(lines.first?.hasPrefix("if application id \"\(player.bundleID)\" is not running then return") == true,
                   "every script starts with a running guard")
            let tells = lines.filter { $0.hasPrefix("tell ") }
            expect(tells == ["tell application id \"\(player.bundleID)\""], "one tell, by bundle ID, to the guarded player")
            let lowered = source.lowercased()
            for forbidden in ["activate", "launch", "open ", "do shell script", "run script", "system events"] {
                expect(!lowered.contains(forbidden), "script never contains \(forbidden)")
            }
            expect(lowered.contains("with timeout of 2 seconds"), "every Apple Event is bounded")
        }
        for (player, source) in reads {
            expect(source.contains("character id 31"), "read replies use the unit separator")
            expect(source.components(separatedBy: "& fieldSeparator &").count == NowPlayingScriptReply.fieldCount,
                   "read script emits exactly \(NowPlayingScriptReply.fieldCount) fields for \(player)")
            expect(source.contains("return \"stopped\""), "stopped and trackless states are explicit")
        }
        expect(NowPlayingAppleScript.musicRead.contains("persistent ID of currentTrack"), "Music key is the persistent ID")
        expect(NowPlayingAppleScript.spotifyRead.contains("artwork url of currentTrack"), "Spotify key is the artwork URL")
        expect(NowPlayingAppleScript.musicArtwork.contains("data of artwork 1 of current track"), "Music artwork source")
    }

    private static func artworkPolicy() {
        func allowed(_ string: String) -> String? { NowPlayingArtworkPolicy.spotifyArtworkURL(string)?.absoluteString }
        expect(allowed("https://i.scdn.co/image/ab67616d0000b273") == "https://i.scdn.co/image/ab67616d0000b273", "Spotify image CDN")
        expect(allowed("https://mosaic.scdn.co/640/abc") != nil, "playlist mosaic CDN")
        expect(allowed("https://image-cdn-ak.spotifycdn.com/image/abc") != nil, "spotifycdn.com CDN")
        expect(allowed("  https://I.SCDN.CO/image/abc \n") == "https://i.scdn.co/image/abc", "trimmed and lowercased host")
        expect(allowed("http://i.scdn.co/image/abc") == "https://i.scdn.co/image/abc", "legacy http is upgraded to https")
        expect(allowed("https://i.scdn.co.evil.example/image") == nil, "suffix must be the registrable domain")
        expect(allowed("https://evilscdn.co/image") == nil, "no partial-label match")
        expect(allowed("https://example.com/i.scdn.co") == nil, "path does not count")
        expect(allowed("https://user:pass@i.scdn.co/image") == nil, "credentials refused")
        expect(allowed("https://i.scdn.co:8443/image") == nil, "custom port refused")
        expect(allowed("file:///etc/passwd") == nil, "file URL refused")
        expect(allowed("ftp://i.scdn.co/image") == nil, "other schemes refused")
        expect(allowed("") == nil, "empty refused")
        expect(allowed("https://" + String(repeating: "a", count: 3_000) + ".scdn.co/") == nil, "oversized refused")
        expect(NowPlayingArtworkPolicy.isAllowedSpotifyHost("i.scdn.co"), "host check")
        expect(!NowPlayingArtworkPolicy.isAllowedSpotifyHost("i.scdn.co\u{0}.evil"), "control characters in host refused")
        expect(!NowPlayingArtworkPolicy.isAllowedSpotifyHost(""), "empty host refused")
    }

    private static func mediaRemoteParsing() {
        typealias P = NowPlayingMediaRemoteParser
        let now = Date(timeIntervalSince1970: 1_000_000)
        func parse(_ dictionary: [String: Any], playing: Bool? = nil) -> NowPlayingInfo? {
            P.info(from: dictionary, isPlaying: playing, appName: "Safari", bundleID: "com.apple.Safari",
                   artwork: nil, wallClock: now, uptime: 50)
        }
        expect(parse([:]) == nil, "empty dictionary (restricted process) is unavailable")
        expect(parse([P.albumKey: "Only album"]) == nil, "no title and no artist is unavailable")
        expect(parse([P.titleKey: "   "]) == nil, "whitespace title is unavailable")
        let base: [String: Any] = [P.titleKey: "Video", P.artistKey: "Channel", P.albumKey: "",
                                   P.durationKey: 300.0, P.elapsedKey: 100.0,
                                   P.timestampKey: now.addingTimeInterval(-4), P.rateKey: 1.0]
        let playing = parse(base, playing: true)
        expect(playing?.title == "Video" && playing?.artist == "Channel", "text fields")
        expect(playing?.position == 104 && playing?.fetchedAt == 50, "elapsed advances from MediaRemote's timestamp")
        expect(playing?.appName == "Safari" && playing?.appBundleID == "com.apple.Safari", "app identity is carried")
        expect(parse(base, playing: false)?.position == 100, "paused elapsed is not advanced")
        var fast = base
        fast[P.rateKey] = 2.0
        expect(parse(fast, playing: true)?.position == 108, "playback rate scales extrapolation")
        expect(parse(base)?.isPlaying == true, "rate stands in for a missing isPlaying answer")
        var stopped = base
        stopped[P.rateKey] = 0.0
        expect(parse(stopped)?.isPlaying == false, "zero rate means paused")
        var overrun = base
        overrun[P.timestampKey] = now.addingTimeInterval(-1_000)
        expect(parse(overrun, playing: true)?.position == 300, "extrapolation clamps to duration")
        var future = base
        future[P.timestampKey] = now.addingTimeInterval(60)
        expect(parse(future, playing: true)?.position == 100, "a future timestamp is not applied")
        var broken = base
        broken[P.durationKey] = Double.nan
        broken[P.elapsedKey] = "100"
        let brokenInfo = parse(broken, playing: true)
        expect(brokenInfo?.duration == nil && brokenInfo?.position == nil, "nonfinite and mistyped numbers are unknown")
    }

    private static func displayModel() {
        let display = NowPlayingDisplay(info: info(), position: 65)
        expect(display.title == "Song" && display.subtitle == "Artist — Album", "title and joined subtitle")
        expect(display.elapsed == "1:05" && display.remaining == "-1:55", "elapsed and remaining")
        expect(abs(display.progress - 65.0 / 180.0) < 1e-9, "progress fraction")
        expect(display.accessibilityValue == "Song by Artist, 1:05 of 3:00", "spoken value")
        expect(NowPlayingDisplay(info: info(isPlaying: false), position: 65).accessibilityValue == "Song by Artist, 1:05 of 3:00, paused",
               "paused state is spoken, not only drawn")
        expect(NowPlayingDisplay(info: info(), position: 500).progress == 1, "overrun clamps progress")
        expect(NowPlayingDisplay(info: info(), position: -1).elapsed == "0:00", "negative scrub clamps")
        expect(NowPlayingDisplay(info: info(), position: .nan).elapsed == "--:--", "NaN scrub is unknown")
        let live = NowPlayingDisplay(info: info(duration: nil), position: 42)
        expect(live.remaining == "--:--" && live.progress == 0, "streams without duration")
        expect(live.accessibilityValue == "Song by Artist, 0:42", "spoken value without duration")
        let unknownPosition = NowPlayingDisplay(info: info(position: nil), position: nil)
        expect(unknownPosition.elapsed == "--:--" && unknownPosition.remaining == "3:00", "unknown position shows total length")
        expect(unknownPosition.accessibilityValue == "Song by Artist", "spoken value without position")
        let untitled = NowPlayingDisplay(info: info(title: "", artist: "", album: ""), position: 0)
        expect(untitled.title == "Music" && untitled.subtitle == "", "app name stands in for a missing title")
        let bare = NowPlayingDisplay(info: info(title: "Song", artist: "", album: ""), position: 0)
        expect(bare.subtitle == "Music", "app name stands in for missing details")
        expect(NowPlayingDisplay(info: info(title: "", artist: "", album: "", appName: ""), position: 0).title == "Unknown Track",
               "last-resort title")
        expect(NowPlayingDisplay(info: info(artist: "", album: "LP"), position: 0).subtitle == "LP", "single detail has no dash")
    }

    private static func textCleaning() {
        expect(NowPlayingText.clean(nil) == "", "nil")
        expect(NowPlayingText.clean("\u{7}bell\u{1B}[0m") == "bell [0m", "escape sequences cannot reach a label as controls")
        expect(NowPlayingText.clean(String(repeating: "é", count: 2_000)).count == NowPlayingText.maximumLength, "length cap")
        expect(NowPlayingText.clean("a\u{200D}b") == "a\u{200D}b", "format characters such as ZWJ are kept")
    }

    private static func playbackHold() {
        let spotify = "com.spotify.client", music = "com.apple.Music", safari = "com.apple.Safari", chrome = "com.google.Chrome"
        // One app playing: as before.
        expect(PlaybackRules.plan(PlaybackSnapshot(others: [safari]), hold: nil) == .key, "a lone video gets the key, as before")
        expect(PlaybackRules.plan(PlaybackSnapshot(players: [spotify: true]), hold: nil) == .pause(players: [spotify], key: false),
               "a lone Spotify is paused directly, never by a key that might land elsewhere")
        // Several playing: everything pauses, the key only for apps Kinara can't pause itself.
        expect(PlaybackRules.plan(PlaybackSnapshot(players: [spotify: true, music: true]), hold: nil) == .pause(players: [spotify, music], key: false),
               "two music apps both pause, no key")
        expect(PlaybackRules.plan(PlaybackSnapshot(players: [spotify: true, music: false], others: [safari]), hold: nil) == .pause(players: [spotify], key: true),
               "Spotify and a video: pause Spotify, key for the video")
        expect(PlaybackRules.plan(PlaybackSnapshot(players: [music: false], others: [safari]), hold: nil) == .pause(players: [], key: true),
               "a video with Music paused in the background: the key, checked against Music")
        // Nothing playing: bring back exactly what was paused.
        let held = PlaybackHold(players: [spotify], keyPaused: true)
        expect(PlaybackRules.plan(PlaybackSnapshot(players: [spotify: false]), hold: held) == .resume(held), "the next press resumes the hold")
        expect(PlaybackRules.plan(PlaybackSnapshot(players: [spotify: false]), hold: nil) == .key, "with nothing held, the key resumes as macOS chooses")
        expect(PlaybackRules.plan(PlaybackSnapshot(players: [spotify: false], others: [safari]), hold: PlaybackHold(muted: [safari])) == .resume(PlaybackHold(muted: [safari])),
               "an app held silent doesn't count as playing")
        expect(PlaybackRules.plan(PlaybackSnapshot(players: [spotify: true]), hold: held) == .pause(players: [spotify], key: false),
               "something started again: a press pauses it instead of resuming")
        // Where the key landed.
        expect(PlaybackRules.landing(before: [spotify: true], after: [spotify: true]) == .other, "players unchanged: the key reached another app")
        expect(PlaybackRules.landing(before: [spotify: true, music: false], after: [spotify: false, music: false]) == .player(spotify), "a player that paused caught the key")
        expect(PlaybackRules.landing(before: [music: false], after: [music: true]) == .player(music), "a player that started caught the key")
        // The resulting hold.
        let snapshot = PlaybackSnapshot(players: [spotify: true], others: [safari, chrome])
        let reached = PlaybackRules.hold(after: ([spotify], true), landing: .other, snapshot: snapshot, previous: nil)
        expect(reached.hold == PlaybackHold(players: [spotify], keyPaused: true) && reached.pause == [spotify] && reached.mute.isEmpty,
               "the key paused the video; Kinara pauses Spotify")
        let missed = PlaybackRules.hold(after: ([spotify], true), landing: .player(spotify), snapshot: snapshot, previous: nil)
        expect(missed.hold == PlaybackHold(players: [spotify], muted: [safari, chrome]) && missed.mute == [safari, chrome],
               "the key hit Spotify: the videos are held silent instead")
        let started = PlaybackRules.hold(after: ([], true), landing: .player(music), snapshot: PlaybackSnapshot(players: [music: false], others: [safari]), previous: nil)
        expect(started.pause == [music] && !started.hold.players.contains(music) && started.hold.muted == [safari],
               "a key that started Music is undone, and Music isn't resumed later")
        let kept = PlaybackRules.hold(after: ([spotify], false), landing: nil, snapshot: PlaybackSnapshot(players: [spotify: true]), previous: PlaybackHold(muted: [safari]))
        expect(kept.hold.muted == [safari], "a new pause keeps apps already held silent")

        // A press that started nothing: Safari may have put its page to sleep.
        expect(PlaybackRules.sleepingPage(audioApps: [chrome, safari], sounding: []) == safari, "a quiet Safari that played is the sleeper")
        expect(PlaybackRules.sleepingPage(audioApps: [chrome], sounding: []) == nil, "other browsers answer the key while hidden")
        expect(PlaybackRules.sleepingPage(audioApps: [safari], sounding: [music]) == nil, "something started, so nothing slept")
    }
}

import AppKit
import CoreAudio

/// Hand-built Float32 AudioBufferList. Every buffer has trailing sentinel
/// samples beyond mDataByteSize so out-of-bounds writes are caught.
private final class TestBuffers {
    static let sentinel: Float = 12_345
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []
    private let frames: Int

    init(channels: [Int], frames: Int, nilData: Set<Int> = [], fill: (Int, Int, Int) -> Float = { _, _, _ in 0 }) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: max(1, channels.count))
        list.count = channels.count
        for (index, count) in channels.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: count * frames + 4)
            samples.initialize(repeating: Self.sentinel, count: count * frames + 4)
            for frame in 0..<frames { for channel in 0..<count { samples[frame * count + channel] = fill(index, channel, frame) } }
            storage.append(samples)
            list[index] = AudioBuffer(mNumberChannels: UInt32(count), mDataByteSize: UInt32(count * frames * MemoryLayout<Float>.size),
                                      mData: nilData.contains(index) ? nil : UnsafeMutableRawPointer(samples))
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var pointer: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }
    func sample(_ buffer: Int, _ channel: Int, _ frame: Int) -> Float {
        storage[buffer][frame * Int(list[buffer].mNumberChannels) + channel]
    }
    func raw(_ buffer: Int, _ index: Int) -> Float { storage[buffer][index] }
    var sentinelsIntact: Bool {
        storage.indices.allSatisfy { index in
            let used = Int(list[index].mNumberChannels) * frames
            return (used..<used + 4).allSatisfy { storage[index][$0] == Self.sentinel }
        }
    }
}

@main
enum AppVolumeRegressionTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }
    private static func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.00001 }
    private static func tone(_ buffer: Int, _ channel: Int, _ frame: Int) -> Float {
        Float(buffer * 100 + channel * 10 + frame + 1) / 1_000
    }
    private static func garbage(_: Int, _: Int, _: Int) -> Float { 9 }

    private static func render(_ input: TestBuffers?, _ output: TestBuffers, gain: Float) {
        AppVolumeMixer.render(input: input.map { UnsafePointer($0.pointer) }, output: output.pointer, gain: gain)
    }

    static func main() {
        mixerFormatTests()
        mixerChannelTests()
        mixerEdgeTests()
        stagingTests()
        ownershipTests()
        clampingTests()
        queueTests()
        print("\(checks) app volume assertions passed. Hand-built buffers and full-level requests only; no tap, aggregate device, routing change, or permission prompt was created.")
    }

    private static func mixerFormatTests() {
        let input = TestBuffers(channels: [2], frames: 8, fill: tone)
        for gain: Float in [0, 0.5, 1] {
            let output = TestBuffers(channels: [2], frames: 8, fill: garbage)
            render(input, output, gain: gain)
            let scaled = (0..<2).allSatisfy { c in (0..<8).allSatisfy { f in close(output.sample(0, c, f), input.sample(0, c, f) * gain) } }
            expect(scaled, "interleaved stereo is scaled by \(gain)")
            expect(output.sentinelsIntact, "no write past an interleaved buffer at gain \(gain)")
        }
        let cases: [(Float, Float, String)] = [(.nan, 0, "NaN renders silence"), (.infinity, 1, "+inf clamps to unity"),
                                               (-.infinity, 0, "-inf clamps to silence"), (2, 1, "gain above 1 never amplifies"),
                                               (-0.5, 0, "negative gain clamps to silence")]
        for (gain, effective, message) in cases {
            let output = TestBuffers(channels: [2], frames: 8, fill: garbage)
            render(input, output, gain: gain)
            expect((0..<2).allSatisfy { c in (0..<8).allSatisfy { f in close(output.sample(0, c, f), input.sample(0, c, f) * effective) } }, message)
        }

        let planar = TestBuffers(channels: [1, 1], frames: 8, fill: tone)
        let interleavedOut = TestBuffers(channels: [2], frames: 8, fill: garbage)
        render(planar, interleavedOut, gain: 0.5)
        expect((0..<2).allSatisfy { c in (0..<8).allSatisfy { f in close(interleavedOut.sample(0, c, f), planar.sample(c, 0, f) * 0.5) } },
               "non-interleaved input lands on interleaved output channels")
        let planarOut = TestBuffers(channels: [1, 1], frames: 8, fill: garbage)
        render(input, planarOut, gain: 0.5)
        expect((0..<2).allSatisfy { c in (0..<8).allSatisfy { f in close(planarOut.sample(c, 0, f), input.sample(0, c, f) * 0.5) } },
               "interleaved input lands on non-interleaved output buffers")
        expect(planarOut.sentinelsIntact && interleavedOut.sentinelsIntact, "no write past planar buffers")
    }

    private static func mixerChannelTests() {
        let mono = TestBuffers(channels: [1], frames: 6, fill: tone)
        let stereo = TestBuffers(channels: [2], frames: 6, fill: garbage)
        render(mono, stereo, gain: 0.5)
        expect((0..<6).allSatisfy { f in close(stereo.sample(0, 0, f), mono.sample(0, 0, f) * 0.5)
                                       && close(stereo.sample(0, 1, f), mono.sample(0, 0, f) * 0.5) }, "mono duplicates to both stereo channels")
        let quad = TestBuffers(channels: [4], frames: 6, fill: garbage)
        render(mono, quad, gain: 1)
        expect((0..<6).allSatisfy { f in close(quad.sample(0, 0, f), mono.sample(0, 0, f)) && close(quad.sample(0, 1, f), mono.sample(0, 0, f))
                                     && quad.sample(0, 2, f) == 0 && quad.sample(0, 3, f) == 0 }, "mono fills only the stereo pair")
        let planarTriple = TestBuffers(channels: [1, 1, 1], frames: 6, fill: garbage)
        render(mono, planarTriple, gain: 1)
        expect((0..<6).allSatisfy { f in close(planarTriple.sample(1, 0, f), mono.sample(0, 0, f)) && planarTriple.sample(2, 0, f) == 0 },
               "mono duplicates across planar buffers and silences the third")

        let source = TestBuffers(channels: [2], frames: 6, fill: tone)
        let surround = TestBuffers(channels: [6], frames: 6, fill: garbage)
        render(source, surround, gain: 1)
        expect((0..<6).allSatisfy { f in close(surround.sample(0, 0, f), source.sample(0, 0, f)) && close(surround.sample(0, 1, f), source.sample(0, 1, f))
                                     && (2..<6).allSatisfy { surround.sample(0, $0, f) == 0 } }, "extra output channels are silenced")
        let pairs = TestBuffers(channels: [2, 2, 2], frames: 6, fill: garbage)
        render(source, pairs, gain: 1)
        expect((0..<6).allSatisfy { f in close(pairs.sample(0, 1, f), source.sample(0, 1, f))
                                     && (0..<2).allSatisfy { pairs.sample(1, $0, f) == 0 && pairs.sample(2, $0, f) == 0 } },
               "extra output buffers are silenced")
        let monoOut = TestBuffers(channels: [1], frames: 6, fill: garbage)
        render(source, monoOut, gain: 0.5)
        expect((0..<6).allSatisfy { f in close(monoOut.sample(0, 0, f), (source.sample(0, 0, f) + source.sample(0, 1, f)) * 0.25) },
               "stereo averages to a mono output without clipping")
    }

    private static func mixerEdgeTests() {
        let short = TestBuffers(channels: [2], frames: 4, fill: tone)
        let long = TestBuffers(channels: [2], frames: 6, fill: garbage)
        render(short, long, gain: 1)
        expect((0..<4).allSatisfy { f in close(long.sample(0, 0, f), short.sample(0, 0, f)) }, "shorter input copies its frames")
        expect((4..<6).allSatisfy { f in long.sample(0, 0, f) == 0 && long.sample(0, 1, f) == 0 }, "frames past the input are zeroed")
        let longInput = TestBuffers(channels: [2], frames: 6, fill: tone)
        let shortOutput = TestBuffers(channels: [2], frames: 4, fill: garbage)
        render(longInput, shortOutput, gain: 1)
        expect((0..<4).allSatisfy { f in close(shortOutput.sample(0, 1, f), longInput.sample(0, 1, f)) } && shortOutput.sentinelsIntact,
               "longer input stops at the output's frame count")

        let silentTargets = [TestBuffers(channels: [2], frames: 4, fill: garbage), TestBuffers(channels: [2], frames: 4, fill: garbage)]
        render(nil, silentTargets[0], gain: 1)
        render(TestBuffers(channels: [], frames: 4), silentTargets[1], gain: 1)
        expect(silentTargets.allSatisfy { out in (0..<2).allSatisfy { c in (0..<4).allSatisfy { out.sample(0, c, $0) == 0 } } },
               "nil and empty input render silence")
        let halfMissing = TestBuffers(channels: [1, 1], frames: 4, nilData: [1], fill: tone)
        let halfOut = TestBuffers(channels: [2], frames: 4, fill: garbage)
        render(halfMissing, halfOut, gain: 1)
        expect((0..<4).allSatisfy { f in close(halfOut.sample(0, 0, f), halfMissing.sample(0, 0, f)) && halfOut.sample(0, 1, f) == 0 },
               "a nil input buffer silences only its channels")
        let zeroChannelInput = TestBuffers(channels: [0, 2], frames: 4, fill: tone)
        let afterEmpty = TestBuffers(channels: [2], frames: 4, fill: garbage)
        render(zeroChannelInput, afterEmpty, gain: 1)
        expect((0..<4).allSatisfy { f in close(afterEmpty.sample(0, 1, f), zeroChannelInput.sample(1, 1, f)) }, "zero-channel input buffers are skipped")
        let skipped = TestBuffers(channels: [2, 2], frames: 4, nilData: [0], fill: garbage)
        render(TestBuffers(channels: [2], frames: 4, fill: tone), skipped, gain: 1)
        expect((0..<4).allSatisfy { f in skipped.sample(1, 0, f) == 0 && skipped.sample(1, 1, f) == 0 } && skipped.sentinelsIntact,
               "a nil output buffer is skipped and channel numbering stays aligned")
        let unknownLayout = TestBuffers(channels: [2], frames: 2, fill: garbage)
        unknownLayout.list[0].mNumberChannels = 0
        render(TestBuffers(channels: [2], frames: 2, fill: tone), unknownLayout, gain: 1)
        expect((0..<4).allSatisfy { unknownLayout.raw(0, $0) == 0 }, "an output buffer without a channel count is zeroed")
        let ragged = TestBuffers(channels: [2], frames: 3, fill: garbage)
        ragged.list[0].mDataByteSize = UInt32(5 * MemoryLayout<Float>.size)
        let raggedInput = TestBuffers(channels: [2], frames: 3, fill: tone)
        render(raggedInput, ragged, gain: 1)
        expect(close(ragged.raw(0, 3), raggedInput.raw(0, 3)) && ragged.raw(0, 4) == 0 && ragged.raw(0, 5) == 9,
               "a partial trailing frame is zeroed and bytes past mDataByteSize are untouched")

        let ones = TestBuffers(channels: [1], frames: 4) { _, _, _ in 1 }
        let ramp = TestBuffers(channels: [1], frames: 4, fill: garbage)
        AppVolumeMixer.render(input: UnsafePointer(ones.pointer), output: ramp.pointer, from: 0, to: 1)
        expect((0..<4).allSatisfy { close(ramp.sample(0, 0, $0), Float($0 + 1) / 4) }, "gain ramps linearly and ends on target")
        AppVolumeMixer.render(input: UnsafePointer(ones.pointer), output: ramp.pointer, from: .nan, to: 0.5)
        expect(close(ramp.sample(0, 0, 0), 0.125) && ramp.sample(0, 0, 3) == 0.5, "a NaN ramp start is treated as silence")
    }

    private static func stagingTests() {
        let staging = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(staging.unsafeMutablePointer) }
        let single = TestBuffers(channels: [2], frames: 4, fill: tone)
        expect(AppVolumeMixer.tapBuffers(in: single.pointer, from: 0, staging: staging.unsafeMutablePointer, capacity: 2) == UnsafePointer(single.pointer),
               "a tap-only input is used without copying")

        let micAndTap = TestBuffers(channels: [1, 2], frames: 4) { buffer, channel, frame in buffer == 0 ? 0.9 : tone(buffer, channel, frame) }
        let selected = AppVolumeMixer.tapBuffers(in: micAndTap.pointer, from: 1, staging: staging.unsafeMutablePointer, capacity: 2)
        expect(selected == UnsafePointer(staging.unsafeMutablePointer) && staging.count == 1 && staging[0].mData == micAndTap.list[1].mData,
               "the device's input buffer is excluded from the tap")
        let output = TestBuffers(channels: [2], frames: 4, fill: garbage)
        AppVolumeMixer.render(input: selected, output: output.pointer, gain: 0.5)
        expect((0..<2).allSatisfy { c in (0..<4).allSatisfy { f in close(output.sample(0, c, f), micAndTap.sample(1, c, f) * 0.5) } },
               "microphone samples never reach the output")

        let planarTap = TestBuffers(channels: [1, 1, 1, 1], frames: 4, fill: tone)
        _ = AppVolumeMixer.tapBuffers(in: planarTap.pointer, from: 1, staging: staging.unsafeMutablePointer, capacity: 2)
        expect(staging.count == 2 && staging[0].mData == planarTap.list[1].mData && staging[1].mData == planarTap.list[2].mData,
               "planar tap buffers are staged in order up to capacity")
        expect(AppVolumeMixer.tapBuffers(in: micAndTap.pointer, from: 2, staging: staging.unsafeMutablePointer, capacity: 2) == nil,
               "missing tap buffers render as silence")
        expect(AppVolumeMixer.tapBuffers(in: micAndTap.pointer, from: -1, staging: staging.unsafeMutablePointer, capacity: 2) == nil
               && AppVolumeMixer.tapBuffers(in: micAndTap.pointer, from: 1, staging: staging.unsafeMutablePointer, capacity: 0) == nil,
               "invalid offsets or capacity select nothing")
    }

    private static func ownershipTests() {
        let chrome = "com.google.Chrome"
        expect(AppVolumeController.processBundleID(chrome, belongsTo: chrome), "the app owns its own process")
        expect(AppVolumeController.processBundleID("com.google.Chrome.helper", belongsTo: chrome), "the app owns its helpers")
        expect(AppVolumeController.processBundleID("com.google.Chrome.helper.Renderer", belongsTo: chrome), "nested helpers belong too")
        expect(AppVolumeController.processBundleID("COM.GOOGLE.CHROME.helper", belongsTo: chrome), "bundle IDs compare case-insensitively")
        expect(!AppVolumeController.processBundleID("com.google.ChromeCanary", belongsTo: chrome), "a longer sibling ID is another app")
        expect(!AppVolumeController.processBundleID("com.google.Chrome.", belongsTo: chrome), "an empty trailing component is not a helper")
        expect(!AppVolumeController.processBundleID("com.google", belongsTo: chrome), "a parent prefix is not the app")
        expect(!AppVolumeController.processBundleID("", belongsTo: chrome) && !AppVolumeController.processBundleID(chrome, belongsTo: ""),
               "empty IDs never match")

        let safari = "com.apple.Safari"
        func owned(_ bundleID: String?, pid: pid_t, responsible: pid_t?, own: pid_t = 1) -> Bool {
            AppVolumeController.process(bundleID: bundleID, pid: pid, responsiblePID: responsible, belongsTo: safari,
                                        appPIDs: [500], ownPID: own)
        }
        expect(owned("com.apple.WebKit.GPU", pid: 900, responsible: 500), "an XPC helper the app is responsible for belongs to it")
        expect(!owned("com.apple.WebKit.GPU", pid: 901, responsible: 700), "another app's WebKit helper does not")
        expect(owned(nil, pid: 500, responsible: nil), "the app's own PID matches without a bundle ID")
        expect(!owned(safari, pid: 1, responsible: nil), "Sway's own process never matches, even by bundle ID")
        expect(!owned("com.example.child", pid: 902, responsible: 1, own: 1), "processes Sway is responsible for never match")
        expect(!owned(nil, pid: -1, responsible: nil), "an unreadable PID never matches")
    }

    private static func clampingTests() {
        expect(AppVolumeController.clampedGain(0.5) == 0.5, "in-range gain is unchanged")
        expect(AppVolumeController.clampedGain(-1) == 0 && AppVolumeController.clampedGain(2) == 1, "out-of-range gain clamps")
        expect(AppVolumeController.clampedGain(.infinity) == 1 && AppVolumeController.clampedGain(-.infinity) == 0, "infinities clamp")
        expect(AppVolumeController.clampedGain(.nan) == nil, "NaN is rejected")
        expect(AppVolumeMixer.clamp(.nan) == 0 && AppVolumeMixer.clamp(0.25) == 0.25, "the IO path clamps NaN to silence")
    }

    /// Only NaN, empty-ID and full-level requests: none of these can reach Core
    /// Audio, and the controller traps if one ever tried while under test.
    private static func queueTests() {
        let controller = AppVolumeController.shared
        let app = "com.example.untapped"
        var results: [Int: [AppVolumeResult]] = [:]
        var allOnMain = true
        func record(_ id: Int) -> (AppVolumeResult) -> Void {
            { result in
                allOnMain = allOnMain && Thread.isMainThread
                results[id, default: []].append(result)
            }
        }
        func settle(_ ids: ClosedRange<Int>) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !ids.allSatisfy({ results[$0] != nil }), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return ids.allSatisfy { results[$0]?.count == 1 }
        }

        expect(controller.gain(for: app) == 1, "untapped apps report full level")
        expect(AppVolumeController.isSupported, "this test host runs macOS 14.2 or later")
        controller.requestGain(.nan, for: app, completion: record(0))
        controller.requestGain(0.5, for: "", completion: record(1))
        expect(results.isEmpty, "rejections still complete asynchronously")
        expect(settle(0...1), "rejections complete exactly once")
        expect(results[0] == [.failed("That volume level isn't valid.")], "NaN fails")
        expect(results[1] == [.failed("Sway can't change this app's volume.")], "an empty bundle ID fails")

        for id in 2...21 { controller.requestGain(1, for: app, completion: record(id)) }
        expect(settle(2...21), "a burst completes every request exactly once")
        expect(results[21] == [.applied(1)], "the latest request always runs")
        expect((2...20).allSatisfy { results[$0] == [.applied(1)] || results[$0] == [.cancelled] }, "superseded requests are cancelled, never failed")

        controller.requestGain(1, for: app, completion: record(22))
        controller.resetAll()
        controller.requestGain(1, for: app, completion: record(23))
        expect(settle(22...23), "reset completes pending and later requests exactly once")
        expect(results[22] == [.cancelled], "reset cancels the request before it")
        expect(results[23] == [.applied(1)], "a request after reset runs after the teardown")
        controller.flushWorkerForTesting()
        expect(controller.gain(for: app) == 1, "full-level requests never create a tap")
        expect(allOnMain, "every completion arrives on main")
    }
}

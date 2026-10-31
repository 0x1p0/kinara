import Foundation
import CoreGraphics

/// A simulated scaler behind one DDC endpoint. It validates packets the way a
/// monitor would, so these tests cover the exact bytes Sway puts on the bus.
private final class FakeMonitor {
    var current: UInt16
    var maximum: UInt16
    var supportsLuminance = true
    var pendingReply: [UInt8]?
    init(current: UInt16, maximum: UInt16) { self.current = current; self.maximum = maximum }
}

private struct Transfer {
    let time: TimeInterval
    let monitor: ObjectIdentifier
    let packet: [UInt8]?
    var isSet: Bool { packet?.count == 6 && packet?[1] == 0x03 }
}

private final class FakeDDCHardware: DDCHardware {
    private let lock = NSLock()
    private var now: TimeInterval = 100
    private var _available = true
    private var _displays: [(display: CGDirectDisplayID, identity: DDCDisplayIdentity)] = []
    private var _records: [DDCServiceRecord] = []
    private var _walks = 0
    private var _transfers: [Transfer] = []
    private var _pauses: [TimeInterval] = []
    private var _failWrites = 0
    private var _corruptReplies = 0
    private var setGate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
    private var _onNextRead: (() -> Void)?
    let builtIn: CGDirectDisplayID = 1

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var isAvailable: Bool { locked { _available } }
    var uptime: TimeInterval { locked { now } }
    func pause(_ seconds: TimeInterval) { locked { _pauses.append(seconds); now += seconds } }
    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool { display == builtIn }
    func externalDisplays() -> [(display: CGDirectDisplayID, identity: DDCDisplayIdentity)] { locked { _displays } }
    func externalServices() -> [DDCServiceRecord] { locked { _walks += 1; return _records } }

    func write(_ packet: [UInt8], to service: AnyObject) -> Bool {
        let isSet = packet.count == 6 && packet[1] == 0x03
        let gate: (entered: DispatchSemaphore, release: DispatchSemaphore)? = locked {
            guard isSet, let gate = setGate else { return nil }
            setGate = nil; return gate
        }
        if let gate { gate.entered.signal(); _ = gate.release.wait(timeout: .now() + 3) }
        return locked {
            guard let monitor = service as? FakeMonitor else { return false }
            _transfers.append(Transfer(time: now, monitor: ObjectIdentifier(monitor), packet: packet))
            if _failWrites > 0 { _failWrites -= 1; return false }
            // A scaler ACKs the bytes but ignores a malformed packet.
            guard packet.count >= 3, packet[0] == 0x80 | UInt8(packet.count - 2),
                  packet.reduce(0x6E ^ 0x51, ^) == 0 else { return true }
            if packet[1] == 0x01, packet.count == 4 {
                monitor.pendingReply = monitor.supportsLuminance && packet[2] == 0x10
                    ? DDCRegressionTests.reply(code: packet[2], current: monitor.current, maximum: monitor.maximum)
                    : DDCRegressionTests.reply(code: packet[2], current: 0, maximum: 0, result: 0x01)
            } else if isSet, monitor.supportsLuminance, packet[2] == 0x10 {
                monitor.current = min(monitor.maximum, UInt16(packet[3]) << 8 | UInt16(packet[4]))
            }
            return true
        }
    }

    func read(_ length: Int, from service: AnyObject) -> [UInt8]? {
        let hook: (() -> Void)? = locked { defer { _onNextRead = nil }; return _onNextRead }
        hook?()
        return locked {
            guard let monitor = service as? FakeMonitor else { return nil }
            _transfers.append(Transfer(time: now, monitor: ObjectIdentifier(monitor), packet: nil))
            guard var reply = monitor.pendingReply, reply.count == length else { return nil }
            monitor.pendingReply = nil
            if _corruptReplies > 0 { _corruptReplies -= 1; reply[10] ^= 0xFF }
            return reply
        }
    }

    func configure(displays: [(display: CGDirectDisplayID, identity: DDCDisplayIdentity)], records: [DDCServiceRecord]) {
        locked { _displays = displays; _records = records }
    }
    func setAvailable(_ value: Bool) { locked { _available = value } }
    func failNextWrites(_ count: Int) { locked { _failWrites = count } }
    func corruptNextReplies(_ count: Int) { locked { _corruptReplies = count } }
    func advance(_ seconds: TimeInterval) { locked { now += seconds } }
    func onNextRead(_ hook: @escaping () -> Void) { locked { _onNextRead = hook } }
    func blockNextSet() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        locked { setGate = gate }
        return gate
    }
    var walks: Int { locked { _walks } }
    var transfers: [Transfer] { locked { _transfers } }
    var pauses: [TimeInterval] { locked { _pauses } }
}

@main
enum DDCRegressionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        checks += 1
        guard condition() else { fatalError("FAIL line \(line): \(message)") }
    }
    static func near(_ value: Float?, _ expected: Float) -> Bool {
        guard let value else { return false }; return abs(value - expected) < 0.000_001
    }

    /// Independent reply builder (not the code under test) for well-formed and tampered replies.
    static func reply(code: UInt8, current: UInt16, maximum: UInt16, result: UInt8 = 0, opcode: UInt8 = 0x02) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x88, opcode, result, code, 0x00,
                              UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        bytes.append(bytes.reduce(0x50, ^))
        return bytes
    }

    static func main() {
        messages()
        identities()
        matching()
        pairing()
        controller()
        latestWriteWins()
        print("PASS: \(checks) DDC/CI regression checks (in-memory monitors only; no I2C or IORegistry access)")
    }

    static func messages() {
        // Reference packets, hand-computed from the VESA DDC/CI checksum (as ddcutil sends them).
        expect(DDCMessage.getVCPRequest(0x10) == [0x82, 0x01, 0x10, 0xAC], "Get VCP luminance request bytes")
        expect(DDCMessage.setVCP(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A], "Set VCP luminance 50 bytes")
        let wide = DDCMessage.setVCP(0x10, value: 0x1234)
        expect(wide[3] == 0x12 && wide[4] == 0x34, "Set VCP value is big-endian")
        let codes = UInt8.min...UInt8.max
        expect(codes.allSatisfy { DDCMessage.getVCPRequest($0).reduce(0x6E ^ 0x51, ^) == 0 }, "Get VCP checksum for every code")
        expect(codes.allSatisfy { DDCMessage.setVCP($0, value: UInt16($0) * 257).reduce(0x6E ^ 0x51, ^) == 0 },
               "Set VCP checksum for every code")

        let known: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        let parsed = DDCMessage.parseVCPReply(known, expecting: 0x10)
        expect(parsed?.current == 50 && parsed?.maximum == 100, "hand-computed reply parses")
        for (current, maximum) in [(0, 1), (37, 100), (0x1234, 0xFFFF), (300, 255)] as [(UInt16, UInt16)] {
            let roundTrip = DDCMessage.parseVCPReply(reply(code: 0x10, current: current, maximum: maximum), expecting: 0x10)
            expect(roundTrip?.current == current && roundTrip?.maximum == maximum, "reply round trip \(current)/\(maximum)")
        }

        var badChecksum = known; badChecksum[10] ^= 0x01
        expect(DDCMessage.parseVCPReply(badChecksum, expecting: 0x10) == nil, "bad checksum rejected")
        var flipped = known; flipped[9] ^= 0x01
        expect(DDCMessage.parseVCPReply(flipped, expecting: 0x10) == nil, "corrupted payload rejected")
        expect(DDCMessage.parseVCPReply(reply(code: 0x10, current: 5, maximum: 100, opcode: 0x03), expecting: 0x10) == nil,
               "wrong opcode rejected even with a valid checksum")
        expect(DDCMessage.parseVCPReply(reply(code: 0x10, current: 5, maximum: 100, result: 0x01), expecting: 0x10) == nil,
               "unsupported-VCP result code rejected")
        expect(DDCMessage.parseVCPReply(reply(code: 0x12, current: 5, maximum: 100), expecting: 0x10) == nil,
               "reply for a different VCP code rejected")
        expect(DDCMessage.parseVCPReply(reply(code: 0x10, current: 0, maximum: 0), expecting: 0x10) == nil,
               "zero maximum rejected")
        expect(DDCMessage.parseVCPReply(Array(known.prefix(10)), expecting: 0x10) == nil, "truncated reply rejected")
        expect(DDCMessage.parseVCPReply([], expecting: 0x10) == nil, "empty reply rejected")
        expect(DDCMessage.parseVCPReply(known + [0], expecting: 0x10) == nil, "overlong reply rejected")
        var badLength = reply(code: 0x10, current: 5, maximum: 100); badLength[1] = 0x87
        badLength[10] = badLength.dropLast().reduce(0x50, ^)
        expect(DDCMessage.parseVCPReply(badLength, expecting: 0x10) == nil, "wrong length byte rejected")
        var badSource = reply(code: 0x10, current: 5, maximum: 100); badSource[0] = 0x6F
        badSource[10] = badSource.dropLast().reduce(0x50, ^)
        expect(DDCMessage.parseVCPReply(badSource, expecting: 0x10) == nil, "wrong source address rejected")

        expect(DDCMessage.scaledValue(0.5, maximum: 100) == 50, "half of 100")
        expect(DDCMessage.scaledValue(0.5, maximum: 255) == 128, "rounds to nearest step")
        expect(DDCMessage.scaledValue(1, maximum: 0xFFFF) == 0xFFFF, "full scale at the widest maximum")
        expect(DDCMessage.scaledValue(1.7, maximum: 100) == 100, "above range clamps to maximum")
        expect(DDCMessage.scaledValue(-3, maximum: 100) == 0, "below range clamps to zero")
        expect(DDCMessage.scaledValue(.nan, maximum: 100) == nil, "NaN rejected")
        expect(DDCMessage.scaledValue(.infinity, maximum: 100) == nil, "infinity rejected")
        expect(DDCMessage.scaledValue(0.5, maximum: 0) == nil, "zero maximum cannot be scaled")
        expect(near(DDCMessage.normalized(current: 40, maximum: 100), 0.4), "normalized reading")
        expect(near(DDCMessage.normalized(current: 300, maximum: 255), 1), "current above maximum clamps")
        expect(DDCMessage.normalized(current: 1, maximum: 0) == nil, "zero maximum cannot be normalized")
    }

    static func identities() {
        let lg = DDCDisplayIdentity(productAttributes: ["LegacyManufacturerID": 7789, "ProductID": 30471, "SerialNumber": 12345])
        expect(lg == DDCDisplayIdentity(vendor: 7789, model: 30471, serial: 12345), "registry product attributes")
        expect(DDCDisplayIdentity(productAttributes: ["LegacyManufacturerID": 7789, "ProductID": 30471])?.serial == 0,
               "absent serial is EDID's unset serial")
        expect(DDCDisplayIdentity(productAttributes: ["ProductID": 30471]) == nil, "vendor required")
        expect(DDCDisplayIdentity(productAttributes: ["LegacyManufacturerID": 7789]) == nil, "product required")
        expect(DDCDisplayIdentity(productAttributes: ["LegacyManufacturerID": 1552, "ProductID": 61_801_092_953_153]) == nil,
               "out-of-range product (built-in panels) never matches")
        expect(DDCDisplayIdentity(productAttributes: ["LegacyManufacturerID": -1, "ProductID": 1]) == nil, "negative rejected")
        expect(DDCDisplayIdentity(productAttributes: ["LegacyManufacturerID": "GSM", "ProductID": 1]) == nil, "string rejected")
        expect(DDCDisplayIdentity(productAttributes: ["LegacyManufacturerID": 1.5, "ProductID": 1]) == nil, "fraction rejected")
        expect(DDCDisplayIdentity(productAttributes: ["LegacyManufacturerID": 1, "ProductID": 1, "SerialNumber": "x"]) == nil,
               "malformed serial fails closed")
    }

    static func matching() {
        let a = DDCDisplayIdentity(vendor: 7789, model: 100, serial: 11)
        let b = DDCDisplayIdentity(vendor: 4268, model: 200, serial: 22)
        let a2 = DDCDisplayIdentity(vendor: 7789, model: 100, serial: 33)
        let sidecar = DDCDisplayIdentity(vendor: 1552, model: 999, serial: 0)
        expect(DDCDisplayMatcher.match(displays: [(2, a)], services: [nil]) == [2: 0], "one display, one service")
        expect(DDCDisplayMatcher.match(displays: [(2, a)], services: [a]) == [2: 0], "one display, one agreeing service")
        expect(DDCDisplayMatcher.match(displays: [(2, a)], services: [DDCDisplayIdentity(vendor: 7789, model: 100, serial: 0)]) == [2: 0],
               "single pairing ignores serial reporting")
        expect(DDCDisplayMatcher.match(displays: [(2, sidecar)], services: [a]).isEmpty,
               "virtual display is not mapped to a different monitor's service")
        expect(DDCDisplayMatcher.match(displays: [], services: [a]).isEmpty, "no displays")
        expect(DDCDisplayMatcher.match(displays: [(2, a)], services: []).isEmpty, "no services")
        expect(DDCDisplayMatcher.match(displays: [(2, a), (3, b)], services: [nil]).isEmpty,
               "unknown service with two displays is not guessed")
        expect(DDCDisplayMatcher.match(displays: [(2, a), (3, sidecar)], services: [a]) == [2: 0],
               "real monitor matched beside a virtual display")
        expect(DDCDisplayMatcher.match(displays: [(2, a), (3, b)], services: [b, a]) == [2: 1, 3: 0],
               "different models matched regardless of order")
        expect(DDCDisplayMatcher.match(displays: [(2, a), (3, a2)], services: [a2, a]) == [2: 1, 3: 0],
               "identical models separated by serial")
        let anonymous = DDCDisplayIdentity(vendor: 7789, model: 100, serial: 0)
        expect(DDCDisplayMatcher.match(displays: [(2, anonymous), (3, anonymous)], services: [anonymous, anonymous]).isEmpty,
               "identical models without serials are ambiguous")
        expect(DDCDisplayMatcher.match(displays: [(2, a), (3, b)], services: [nil, b]) == [3: 1],
               "only the attributed service is matched")
        expect(DDCDisplayMatcher.match(displays: [(2, a), (3, b)],
                                       services: [DDCDisplayIdentity(vendor: 7789, model: 100, serial: 0), b]) == [2: 0, 3: 1],
               "unreported serial falls back to a unique model")
        expect(DDCDisplayMatcher.match(displays: [(2, a), (3, b)],
                                       services: [DDCDisplayIdentity(vendor: 7789, model: 100, serial: 44), b]) == [3: 1],
               "contradicting serials veto the model fallback")
        expect(DDCDisplayMatcher.match(displays: [(2, a)], services: [b, a]) == [2: 1], "one display, extra service")
        expect(DDCDisplayMatcher.match(displays: [(2, a)], services: [a, a]).isEmpty, "duplicate services are ambiguous")
        expect(DDCDisplayMatcher.match(displays: [(2, a), (3, a2)], services: [anonymous]).isEmpty,
               "one unserialized service for two same-model displays is ambiguous")
    }

    static func pairing() {
        typealias P = DDCRegistryPairing
        expect(P.framebufferToken(parentName: "dispext0@84000000") == "dispext0", "framebuffer token")
        expect(P.framebufferToken(parentName: "disp0@8000000") == "disp0", "built-in framebuffer token")
        expect(P.serviceToken(parentName: "dispext1:dcpav-service-epic:0") == "dispext1", "service token")
        expect(P.serviceToken(parentName: "dcpav-service-epic") == nil, "plain parent has no token")
        expect(P.serviceToken(parentName: "dcpav-service-epic:0") == nil, "non-display prefix ignored")
        expect(P.framebufferToken(parentName: "disp@1") == nil, "bare prefix ignored")
        expect(P.framebufferToken(parentName: nil) == nil, "missing parent")

        let a = DDCDisplayIdentity(vendor: 1, model: 1, serial: 1)
        let b = DDCDisplayIdentity(vendor: 2, model: 2, serial: 2)
        let c = DDCDisplayIdentity(vendor: 3, model: 3, serial: 3)
        expect(P.identities(for: [.framebuffer(token: "disp0", identity: a), .framebuffer(token: "dispext0", identity: b),
                                  .externalService(token: "dispext0"), .framebuffer(token: "dispext1", identity: c),
                                  .externalService(token: "dispext1")]) == [b, c], "observed Apple Silicon layout")
        expect(P.identities(for: [.framebuffer(token: "dispext0", identity: b), .framebuffer(token: "dispext1", identity: c),
                                  .externalService(token: "dispext0"), .externalService(token: "dispext1")]) == [b, c],
               "names pair framebuffers and services out of order")
        expect(P.identities(for: [.framebuffer(token: nil, identity: b), .externalService(token: nil),
                                  .framebuffer(token: nil, identity: c), .externalService(token: nil)]) == [b, c],
               "unnamed layouts pair by registry order")
        expect(P.identities(for: [.framebuffer(token: "dispext0", identity: b), .externalService(token: "dispext1")]) == [nil],
               "contradicting names are not paired")
        expect(P.identities(for: [.framebuffer(token: nil, identity: b), .externalService(token: nil),
                                  .externalService(token: nil)]) == [nil, nil], "a framebuffer claimed twice is trusted by neither")
        expect(P.identities(for: [.externalService(token: nil), .framebuffer(token: nil, identity: b)]) == [nil],
               "service before any framebuffer")
        expect(P.identities(for: [.framebuffer(token: "dispext0", identity: nil), .externalService(token: "dispext0")]) == [nil],
               "framebuffer without attributes")
    }

    static func controller() {
        let monitorA = FakeMonitor(current: 40, maximum: 100)
        let identityA = DDCDisplayIdentity(vendor: 7789, model: 100, serial: 11)
        let hardware = FakeDDCHardware()
        hardware.configure(displays: [(2, identityA)], records: [DDCServiceRecord(service: monitorA, identity: nil)])
        let ddc = ExternalDisplayDDC(hardware: hardware)

        expect(!ddc.supports(hardware.builtIn), "built-in display is never a DDC target")
        expect(ddc.readBrightness(hardware.builtIn) == nil, "built-in display is never read")
        expect(!ddc.writeBrightness(0.5, to: hardware.builtIn), "built-in display is never written")
        expect(hardware.walks == 0 && hardware.transfers.isEmpty, "built-in requests cause no registry or bus work")

        expect(ddc.supports(2), "single external monitor with luminance is supported")
        expect(hardware.walks == 1, "registry walked once")
        let probeTransfers = hardware.transfers.count
        expect(probeTransfers == 2, "probe is one request and one reply")
        expect(ddc.supports(2) && hardware.transfers.count == probeTransfers, "support is cached")
        expect(near(ddc.readBrightness(2), 0.4), "reading normalized to the monitor maximum")
        expect(hardware.walks == 1, "services cached across calls")

        expect(ddc.writeBrightness(0.5, to: 2), "write succeeds")
        expect(monitorA.current == 50, "monitor received the scaled value")
        expect(hardware.transfers.last?.packet == DDCMessage.setVCP(0x10, value: 50), "exact Set VCP packet on the bus")
        let before = hardware.transfers.count
        expect(!ddc.writeBrightness(.nan, to: 2) && !ddc.writeBrightness(.infinity, to: 2), "non-finite writes rejected")
        expect(hardware.transfers.count == before, "rejected writes touch no hardware")
        expect(ddc.writeBrightness(1.7, to: 2) && monitorA.current == 100, "above-range write clamps to maximum")
        expect(ddc.writeBrightness(-2, to: 2) && monitorA.current == 0, "below-range write clamps to zero")

        // Pacing: back-to-back calls are spaced on the caller's thread, never queued.
        for step in 1...5 { _ = ddc.writeBrightness(Float(step) / 10, to: 2) }
        let times = hardware.transfers.map(\.time)
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        expect(gaps.count > 10 && gaps.allSatisfy { $0 >= ExternalDisplayDDC.minimumTransferSpacing - 0.000_001 },
               "every transfer is spaced from the previous one")
        expect(hardware.pauses.allSatisfy { $0 > 0 && $0 <= 0.05 + 0.000_001 }, "pauses are short and bounded")
        let pausesBeforeIdle = hardware.pauses.count
        hardware.advance(1)
        expect(ddc.writeBrightness(0.3, to: 2) && hardware.pauses.count == pausesBeforeIdle, "no pause after the bus was idle")

        hardware.failNextWrites(1)
        expect(ddc.writeBrightness(0.6, to: 2) && monitorA.current == 60, "a failed I2C write is retried")
        hardware.failNextWrites(10)
        expect(!ddc.writeBrightness(0.7, to: 2) && monitorA.current == 60, "persistent I2C failure returns false")
        hardware.failNextWrites(0)

        monitorA.maximum = 200
        monitorA.current = 150
        expect(near(ddc.readBrightness(2), 0.75), "reading follows a changed maximum")
        expect(ddc.writeBrightness(0.5, to: 2) && monitorA.current == 100, "writes scale to the refreshed maximum")
        monitorA.current = 300
        expect(near(ddc.readBrightness(2), 1), "over-maximum report clamps to full brightness")
        monitorA.current = 100

        hardware.corruptNextReplies(1)
        ddc.invalidate()
        expect(near(ddc.readBrightness(2), 0.5), "corrupt reply is retried during a fresh probe")
        expect(hardware.walks == 2, "invalidate drops cached services")

        // A reconfiguration landing mid-probe (invalidate() runs while the bus is
        // busy, which also proves it never waits on I/O) must not cache the result.
        ddc.invalidate()
        hardware.onNextRead { ddc.invalidate() }
        _ = ddc.supports(2)
        let walksAfterRace = hardware.walks
        expect(ddc.supports(2) && hardware.walks == walksAfterRace + 1, "stale mid-reconfiguration probe is not cached")

        // Monitor without DDC luminance: failed probe cached until invalidate().
        let monitorB = FakeMonitor(current: 10, maximum: 100)
        monitorB.supportsLuminance = false
        hardware.configure(displays: [(3, identityA)], records: [DDCServiceRecord(service: monitorB, identity: nil)])
        ddc.invalidate()
        expect(!ddc.supports(3), "monitor rejecting VCP 0x10 is unsupported")
        let failedProbe = hardware.transfers.count
        expect(!ddc.supports(3) && ddc.readBrightness(3) == nil && !ddc.writeBrightness(0.5, to: 3),
               "unsupported result is cached")
        expect(hardware.transfers.count == failedProbe, "cached failure does no I/O")
        monitorB.supportsLuminance = true
        expect(!ddc.supports(3), "failure stays cached until invalidate")
        ddc.invalidate()
        expect(ddc.supports(3), "invalidate allows a fresh probe")

        // Two external monitors: routed by registry attributes, never crossed.
        let monitorC = FakeMonitor(current: 20, maximum: 100)
        let monitorD = FakeMonitor(current: 80, maximum: 255)
        let identityC = DDCDisplayIdentity(vendor: 7789, model: 100, serial: 11)
        let identityD = DDCDisplayIdentity(vendor: 4268, model: 200, serial: 22)
        hardware.configure(displays: [(4, identityC), (5, identityD)],
                           records: [DDCServiceRecord(service: monitorD, identity: identityD),
                                     DDCServiceRecord(service: monitorC, identity: identityC)])
        ddc.invalidate()
        expect(near(ddc.readBrightness(4), 0.2) && near(ddc.readBrightness(5), 80.0 / 255), "each display reads its own monitor")
        expect(ddc.writeBrightness(0.5, to: 5) && monitorD.current == 128 && monitorC.current == 20,
               "write reaches only the matched monitor")
        expect(!ddc.supports(6), "an unknown display is unsupported")

        hardware.configure(displays: [(4, identityC), (5, identityD)],
                           records: [DDCServiceRecord(service: monitorC, identity: nil),
                                     DDCServiceRecord(service: monitorD, identity: nil)])
        ddc.invalidate()
        let unmatched = hardware.transfers.count
        expect(!ddc.supports(4) && !ddc.supports(5), "unattributed services with several displays are not guessed")
        expect(hardware.transfers.count == unmatched, "unmatched displays never reach the bus")

        let offline = FakeDDCHardware()
        offline.setAvailable(false)
        offline.configure(displays: [(2, identityA)], records: [DDCServiceRecord(service: monitorA, identity: nil)])
        let intel = ExternalDisplayDDC(hardware: offline)
        expect(!intel.supports(2) && intel.readBrightness(2) == nil && !intel.writeBrightness(0.5, to: 2),
               "missing IOAVService (or Intel) fails closed")
        expect(offline.walks == 0 && offline.transfers.isEmpty, "unavailable hardware does no work")
    }

    /// Writes waiting behind a busy bus collapse to the newest value.
    static func latestWriteWins() {
        let monitor = FakeMonitor(current: 0, maximum: 100)
        let hardware = FakeDDCHardware()
        hardware.configure(displays: [(2, DDCDisplayIdentity(vendor: 1, model: 1, serial: 0))],
                           records: [DDCServiceRecord(service: monitor, identity: nil)])
        let ddc = ExternalDisplayDDC(hardware: hardware)
        expect(ddc.supports(2), "probe before the concurrency check")

        let gate = hardware.blockNextSet()
        let results = NSLock()
        var outcome: [Float: Bool] = [:]
        let group = DispatchGroup()
        func write(_ value: Float) {
            DispatchQueue.global().async(group: group) {
                let ok = ddc.writeBrightness(value, to: 2)
                results.lock(); outcome[value] = ok; results.unlock()
            }
        }
        write(0.2)
        expect(gate.entered.wait(timeout: .now() + 3) == .success, "first write reached the bus")
        write(0.4)
        Thread.sleep(forTimeInterval: 0.1)
        write(0.6)
        Thread.sleep(forTimeInterval: 0.1)
        gate.release.signal()
        expect(group.wait(timeout: .now() + 3) == .success, "writes finish without timeout")
        let values = hardware.transfers.filter(\.isSet).compactMap { $0.packet.map { Int($0[4]) } }
        expect(outcome[0.2] == true && outcome[0.4] == false && outcome[0.6] == true, "superseded write reports false")
        expect(values == [20, 60] && monitor.current == 60, "stale value never reaches the bus")
    }
}

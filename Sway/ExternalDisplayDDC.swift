import Foundation
import CoreGraphics
import IOKit

/// Pure, hardware-free packet helpers so tests can cover them.
///
/// Packets are the bytes IOAVService puts on the bus after the I2C address
/// (0x37, written as 0x6E) and the host source byte (0x51, sent as the data
/// address): length | 0x80, payload, checksum.
enum DDCMessage {
    /// 7-bit I2C address of the DDC/CI interface; 0x6E/0x6F on the wire.
    static let chipAddress: UInt8 = 0x37
    /// Host source address. IOAVService transmits it ahead of each packet.
    static let hostAddress: UInt8 = 0x51
    /// Source, length, opcode, result, code, type, max (2), current (2), checksum.
    static let vcpReplyLength = 11

    static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        packet([0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func getVCPRequest(_ code: UInt8) -> [UInt8] {
        packet([0x01, code])
    }

    /// Parses a VCP feature reply; validates length, opcode 0x02, result code, VCP code, and checksum.
    /// A zero maximum is rejected too: nothing can be scaled against it.
    static func parseVCPReply(_ bytes: [UInt8], expecting code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard bytes.count == vcpReplyLength,
              bytes[0] == 0x6E, bytes[1] == 0x88, bytes[2] == 0x02,
              bytes[3] == 0x00, bytes[4] == code,
              // Display replies are checksummed against the virtual host address 0x50.
              checksum(bytes.dropLast(), seed: 0x50) == bytes[10] else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0 else { return nil }
        return (current, maximum)
    }

    /// Monitor-native value for a 0...1 level. nil for non-finite input or a zero maximum.
    static func scaledValue(_ level: Float, maximum: UInt16) -> UInt16? {
        guard level.isFinite, maximum > 0 else { return nil }
        let scaled = (min(1, max(0, level)) * Float(maximum)).rounded()
        return UInt16(min(Float(maximum), max(0, scaled)))
    }

    /// Some monitors report a current value above their own maximum; clamp rather than overshoot.
    static func normalized(current: UInt16, maximum: UInt16) -> Float? {
        guard maximum > 0 else { return nil }
        return Float(min(current, maximum)) / Float(maximum)
    }

    /// VESA DDC/CI checksum: XOR of every byte including the destination (0x6E)
    /// and source (0x51) bytes the bus adds, the same packets ddcutil sends.
    private static func packet(_ payload: [UInt8]) -> [UInt8] {
        let body = [0x80 | UInt8(payload.count)] + payload
        return body + [checksum(body, seed: 0x6E ^ hostAddress)]
    }

    private static func checksum<Bytes: Sequence>(_ bytes: Bytes, seed: UInt8) -> UInt8 where Bytes.Element == UInt8 {
        bytes.reduce(seed, ^)
    }
}

/// EDID identity as CoreGraphics and the IORegistry both report it.
struct DDCDisplayIdentity: Equatable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }

    /// Reads a framebuffer's DisplayAttributes → ProductAttributes. Vendor and
    /// product are required. An absent serial is EDID's "unset" (0), which is
    /// also what CGDisplaySerialNumber reports; a malformed one fails closed.
    init?(productAttributes: [String: Any]) {
        guard let vendor = Self.number(productAttributes["LegacyManufacturerID"]),
              let model = Self.number(productAttributes["ProductID"]) else { return nil }
        var serial: UInt32 = 0
        if let raw = productAttributes["SerialNumber"] {
            guard let value = Self.number(raw) else { return nil }
            serial = value
        }
        self.init(vendor: vendor, model: model, serial: serial)
    }

    private static func number(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber else { return nil }
        let wide = number.int64Value
        guard wide >= 0, wide <= Int64(UInt32.max), NSNumber(value: wide) == number else { return nil }
        return UInt32(wide)
    }
}

/// Maps CoreGraphics displays to discovered DDC services without guessing.
enum DDCDisplayMatcher {
    /// - Returns: display → index into `services`. A display absent from the
    ///   result could not be matched unambiguously and must be treated as unsupported.
    static func match(displays: [(display: CGDirectDisplayID, identity: DDCDisplayIdentity)],
                      services: [DDCDisplayIdentity?]) -> [CGDirectDisplayID: Int] {
        // One monitor, one service: the pairing is physical, not inferred. Known
        // attributes may still veto it, so a virtual display (Sidecar, AirPlay)
        // standing in for a sleeping monitor is never driven blind.
        if displays.count == 1, services.count == 1 {
            let only = displays[0]
            if let known = services[0], known.vendor != only.identity.vendor || known.model != only.identity.model {
                return [:]
            }
            return [only.display: 0]
        }
        var result: [CGDirectDisplayID: Int] = [:]
        for entry in displays {
            if let index = unique(entry.identity, displays, services, by: ==)
                ?? unique(entry.identity, displays, services, by: compatible) {
                result[entry.display] = index
            }
        }
        // Defense in depth: a service claimed twice is dropped from both displays.
        let claims = Dictionary(grouping: result.values, by: { $0 }).mapValues(\.count)
        return result.filter { claims[$0.value] == 1 }
    }

    /// Same EDID model, and serials that do not contradict (0 means unreported).
    private static func compatible(_ lhs: DDCDisplayIdentity, _ rhs: DDCDisplayIdentity) -> Bool {
        lhs.vendor == rhs.vendor && lhs.model == rhs.model &&
            (lhs.serial == rhs.serial || lhs.serial == 0 || rhs.serial == 0)
    }

    /// The single service equal to `identity`, provided exactly one display shares it too.
    private static func unique(_ identity: DDCDisplayIdentity,
                               _ displays: [(display: CGDirectDisplayID, identity: DDCDisplayIdentity)],
                               _ services: [DDCDisplayIdentity?],
                               by equal: (DDCDisplayIdentity, DDCDisplayIdentity) -> Bool) -> Int? {
        let candidates = services.indices.filter { services[$0].map { equal($0, identity) } ?? false }
        guard candidates.count == 1, displays.filter({ equal($0.identity, identity) }).count == 1 else { return nil }
        return candidates[0]
    }
}

/// Pairs each external DCPAVServiceProxy with the framebuffer that drives it,
/// so multi-display matching can use that framebuffer's EDID attributes.
enum DDCRegistryPairing {
    enum Node: Equatable {
        case framebuffer(token: String?, identity: DDCDisplayIdentity?)
        case externalService(token: String?)
    }

    /// Recent macOS names both sides after the display pipe (dispext0@… and
    /// dispext0:dcpav-service-epic:0), which pairs them regardless of order.
    /// Without names, the service belongs to the nearest framebuffer before it
    /// in the IOService plane (MonitorControl's Arm64DDC pairing), unless names
    /// contradict. A framebuffer claimed twice is trusted by neither service.
    static func identities(for nodes: [Node]) -> [DDCDisplayIdentity?] {
        var owners: [Int?] = []
        var latest: Int?
        for (index, node) in nodes.enumerated() {
            switch node {
            case .framebuffer:
                latest = index
            case .externalService(let token):
                let named = token.map { name in
                    nodes.indices.filter { if case .framebuffer(name?, _) = nodes[$0] { return true }; return false }
                } ?? []
                if named.count == 1 {
                    owners.append(named[0])
                } else if let latest, case .framebuffer(let owner, _) = nodes[latest],
                          token == nil || owner == nil || token == owner {
                    owners.append(latest)
                } else {
                    owners.append(nil)
                }
            }
        }
        let claims = Dictionary(grouping: owners.compactMap { $0 }, by: { $0 }).mapValues(\.count)
        return owners.map { owner in
            guard let owner, claims[owner] == 1, case .framebuffer(_, let identity) = nodes[owner] else { return nil }
            return identity
        }
    }

    /// "dispext0@84000000" → "dispext0".
    static func framebufferToken(parentName: String?) -> String? { token(parentName, end: "@") }

    /// "dispext0:dcpav-service-epic:0" → "dispext0". Older layouts name the parent plainly: nil.
    static func serviceToken(parentName: String?) -> String? { token(parentName, end: ":") }

    private static func token(_ name: String?, end: Character) -> String? {
        guard let name, let stop = name.firstIndex(of: end) else { return nil }
        let token = String(name[..<stop])
        return token.hasPrefix("disp") && token.count > 4 ? token : nil
    }
}

/// A discovered external DDC endpoint. `service` is an opaque IOAVService.
struct DDCServiceRecord {
    let service: AnyObject
    let identity: DDCDisplayIdentity?
}

/// The test implementation is entirely in memory: no IORegistry walk or I2C
/// transfer runs while exercising probing, pacing, caching and routing.
protocol DDCHardware: AnyObject {
    /// False on Intel and when the private IOAVService symbols are missing.
    var isAvailable: Bool { get }
    /// Monotonic seconds.
    var uptime: TimeInterval { get }
    func pause(_ seconds: TimeInterval)
    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool
    /// Online displays that are not built in, with their EDID identity.
    func externalDisplays() -> [(display: CGDirectDisplayID, identity: DDCDisplayIdentity)]
    /// External DDC endpoints, with the identity of the display each drives when known.
    func externalServices() -> [DDCServiceRecord]
    func write(_ packet: [UInt8], to service: AnyObject) -> Bool
    func read(_ length: Int, from service: AnyObject) -> [UInt8]?
}

/// Blocking DDC/CI I/O. Call only from a background serial queue, never main.
final class ExternalDisplayDDC {
    static let shared = ExternalDisplayDDC(hardware: DDCSystemHardware())

    /// MCCS VCP 0x10 (luminance) is what monitor menus call brightness.
    private static let luminance: UInt8 = 0x10
    /// Monitors drop or NAK commands sent back to back, so every transfer to a
    /// display starts at least this long after the previous one ended.
    static let minimumTransferSpacing: TimeInterval = 0.03
    /// DDC/CI gives the display 40 ms to prepare a reply; slow scalers need a margin.
    private static let replyDelay: TimeInterval = 0.05
    private static let readAttempts = 4
    private static let writeAttempts = 2

    private struct Monitor {
        let service: AnyObject
        let maximum: UInt16
    }
    private enum Probe {
        case supported(Monitor)
        case unsupported
    }
    private struct Resolved {
        let monitor: Monitor
        /// Present when this call ran the probe, so callers need not read twice.
        let reading: (current: UInt16, maximum: UInt16)?
        let generation: UInt64
    }

    private let hardware: DDCHardware
    /// Guards cached state only and is never held across I/O, so invalidate()
    /// from a reconfiguration callback never waits on a slow monitor.
    private let stateLock = NSLock()
    private var probes: [CGDirectDisplayID: Probe] = [:]
    private var services: [DDCServiceRecord]?
    private var generation: UInt64 = 0
    private var writeTickets: [CGDirectDisplayID: UInt64] = [:]
    /// Serializes every registry walk and I2C transfer.
    private let ioLock = NSLock()
    private var lastTransfer: [CGDirectDisplayID: TimeInterval] = [:] // ioLock

    init(hardware: DDCHardware) {
        self.hardware = hardware
    }

    /// Cached per display after the first probe; a failed probe is cached as unsupported until invalidate().
    func supports(_ display: CGDirectDisplayID) -> Bool {
        guard isCandidate(display) else { return false }
        stateLock.lock()
        let cached = probes[display]
        stateLock.unlock()
        switch cached {
        case .supported?: return true
        case .unsupported?: return false
        case nil:
            ioLock.lock(); defer { ioLock.unlock() }
            return resolveLocked(display) != nil
        }
    }

    /// Normalized 0...1 using the monitor's reported VCP maximum for code 0x10 (luminance). nil on failure.
    func readBrightness(_ display: CGDirectDisplayID) -> Float? {
        guard isCandidate(display) else { return nil }
        ioLock.lock(); defer { ioLock.unlock() }
        guard let resolved = resolveLocked(display),
              let reading = resolved.reading ?? readVCPLocked(Self.luminance, display: display,
                                                              service: resolved.monitor.service) else { return nil }
        if reading.maximum != resolved.monitor.maximum {
            store(.supported(Monitor(service: resolved.monitor.service, maximum: reading.maximum)),
                  for: display, generation: resolved.generation)
        }
        return DDCMessage.normalized(current: reading.current, maximum: reading.maximum)
    }

    /// Writes VCP 0x10 scaled to the monitor's maximum. Returns true only if the I2C write succeeded.
    /// Calls are never buffered: one superseded by a newer value before reaching
    /// the bus returns false without writing, so callers cannot build a backlog.
    func writeBrightness(_ value: Float, to display: CGDirectDisplayID) -> Bool {
        guard value.isFinite, isCandidate(display) else { return false }
        stateLock.lock()
        let ticket = (writeTickets[display] ?? 0) &+ 1
        writeTickets[display] = ticket
        stateLock.unlock()
        ioLock.lock(); defer { ioLock.unlock() }
        guard isLatest(ticket, for: display), let resolved = resolveLocked(display),
              let raw = DDCMessage.scaledValue(value, maximum: resolved.monitor.maximum) else { return false }
        let packet = DDCMessage.setVCP(Self.luminance, value: raw)
        for _ in 0..<Self.writeAttempts {
            waitForSpacingLocked(display)
            guard isLatest(ticket, for: display) else { return false }
            let written = hardware.write(packet, to: resolved.monitor.service)
            lastTransfer[display] = hardware.uptime
            if written { return true }
        }
        return false
    }

    /// Drop cached services/capabilities (called on display reconfiguration).
    func invalidate() {
        stateLock.lock()
        generation &+= 1
        probes.removeAll()
        services = nil
        stateLock.unlock()
    }

    private func isCandidate(_ display: CGDirectDisplayID) -> Bool {
        hardware.isAvailable && !hardware.isBuiltIn(display)
    }

    private func isLatest(_ ticket: UInt64, for display: CGDirectDisplayID) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return writeTickets[display] == ticket
    }

    /// Caller holds ioLock. Probes once per display per generation.
    private func resolveLocked(_ display: CGDirectDisplayID) -> Resolved? {
        stateLock.lock()
        let generation = self.generation
        let cached = probes[display]
        let known = services
        stateLock.unlock()
        switch cached {
        case .supported(let monitor)?: return Resolved(monitor: monitor, reading: nil, generation: generation)
        case .unsupported?: return nil
        case nil: break
        }
        let records = known ?? hardware.externalServices()
        let mapping = DDCDisplayMatcher.match(displays: hardware.externalDisplays(), services: records.map(\.identity))
        var resolved: Resolved?
        if let index = mapping[display], records.indices.contains(index),
           let reading = readVCPLocked(Self.luminance, display: display, service: records[index].service) {
            resolved = Resolved(monitor: Monitor(service: records[index].service, maximum: reading.maximum),
                                reading: reading, generation: generation)
        }
        stateLock.lock()
        if self.generation == generation, services == nil { services = records }
        stateLock.unlock()
        store(resolved.map { .supported($0.monitor) } ?? .unsupported, for: display, generation: generation)
        return resolved
    }

    private func store(_ probe: Probe, for display: CGDirectDisplayID, generation: UInt64) {
        stateLock.lock(); defer { stateLock.unlock() }
        // A reconfiguration landed mid-probe; the result may describe the old topology.
        guard self.generation == generation else { return }
        probes[display] = probe
    }

    /// Caller holds ioLock.
    private func readVCPLocked(_ code: UInt8, display: CGDirectDisplayID,
                               service: AnyObject) -> (current: UInt16, maximum: UInt16)? {
        let request = DDCMessage.getVCPRequest(code)
        for _ in 0..<Self.readAttempts {
            waitForSpacingLocked(display)
            let sent = hardware.write(request, to: service)
            lastTransfer[display] = hardware.uptime
            guard sent else { continue }
            hardware.pause(Self.replyDelay)
            let reply = hardware.read(DDCMessage.vcpReplyLength, from: service)
            lastTransfer[display] = hardware.uptime
            if let reply, let parsed = DDCMessage.parseVCPReply(reply, expecting: code) { return parsed }
        }
        return nil
    }

    /// Caller holds ioLock. Sleeps the caller's background thread only as long as needed.
    private func waitForSpacingLocked(_ display: CGDirectDisplayID) {
        guard let last = lastTransfer[display] else { return }
        let wait = last + Self.minimumTransferSpacing - hardware.uptime
        if wait > 0 { hardware.pause(min(wait, Self.minimumTransferSpacing)) }
    }
}

/// Apple Silicon: private IOAVService I2C on each external display's
/// DCPAVServiceProxy, resolved with dlsym so a missing symbol fails closed.
/// Intel Macs reach DDC through IOFramebuffer I2C instead; that path is not
/// implemented, so every external display reports unsupported there.
private final class DDCSystemHardware: DDCHardware {
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func pause(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        usleep(useconds_t(min(seconds, 1) * 1_000_000))
    }

    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(display) != 0 }

    func externalDisplays() -> [(display: CGDirectDisplayID, identity: DDCDisplayIdentity)] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map {
            (display: $0, identity: DDCDisplayIdentity(vendor: CGDisplayVendorNumber($0),
                                                       model: CGDisplayModelNumber($0),
                                                       serial: CGDisplaySerialNumber($0)))
        }
    }

#if arch(arm64)
    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private let createService: CreateService?
    private let readI2C: TransferI2C?
    private let writeI2C: TransferI2C?

    init() {
        // Private IOKit exports on Apple Silicon, the ABI MonitorControl's Arm64DDC uses.
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL)
        createService = handle.flatMap { dlsym($0, "IOAVServiceCreateWithService") }
            .map { unsafeBitCast($0, to: CreateService.self) }
        readI2C = handle.flatMap { dlsym($0, "IOAVServiceReadI2C") }
            .map { unsafeBitCast($0, to: TransferI2C.self) }
        writeI2C = handle.flatMap { dlsym($0, "IOAVServiceWriteI2C") }
            .map { unsafeBitCast($0, to: TransferI2C.self) }
    }

    var isAvailable: Bool { createService != nil && readI2C != nil && writeI2C != nil }

    func externalServices() -> [DDCServiceRecord] {
        guard let createService else { return [] }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        // Any registry change mid-walk (a hot plug, or an unrelated device)
        // invalidates the iterator. Walk again rather than trust, and cache, a
        // partial picture; give up after a few tries and report nothing.
        for _ in 0..<3 {
            let records = walk(iterator, createService)
            if IOIteratorIsValid(iterator) != 0 { return records }
            IOIteratorReset(iterator)
        }
        return []
    }

    private func walk(_ iterator: io_iterator_t, _ createService: CreateService) -> [DDCServiceRecord] {
        var nodes: [DDCRegistryPairing.Node] = []
        var handles: [AnyObject] = []
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            switch Self.name(of: entry) ?? "" {
            case "AppleCLCD2", "IOMobileFramebufferShim":
                let display = Self.property(entry, "DisplayAttributes") as? [String: Any]
                let product = display?["ProductAttributes"] as? [String: Any]
                nodes.append(.framebuffer(token: DDCRegistryPairing.framebufferToken(parentName: Self.parentName(of: entry)),
                                          identity: product.flatMap(DDCDisplayIdentity.init(productAttributes:))))
            case "DCPAVServiceProxy":
                guard Self.property(entry, "Location") as? String == "External",
                      let service = createService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                nodes.append(.externalService(token: DDCRegistryPairing.serviceToken(parentName: Self.parentName(of: entry))))
                handles.append(service)
            default:
                continue
            }
        }
        return zip(handles, DDCRegistryPairing.identities(for: nodes)).map {
            DDCServiceRecord(service: $0, identity: $1)
        }
    }

    func write(_ packet: [UInt8], to service: AnyObject) -> Bool {
        guard let writeI2C, !packet.isEmpty else { return false }
        var bytes = packet
        return bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            return writeI2C(service, UInt32(DDCMessage.chipAddress), UInt32(DDCMessage.hostAddress),
                            base, UInt32(buffer.count)) == kIOReturnSuccess
        }
    }

    func read(_ length: Int, from service: AnyObject) -> [UInt8]? {
        guard let readI2C, length > 0 else { return nil }
        var reply = [UInt8](repeating: 0, count: length)
        let succeeded = reply.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return readI2C(service, UInt32(DDCMessage.chipAddress), UInt32(DDCMessage.hostAddress),
                           base, UInt32(buffer.count)) == kIOReturnSuccess
        }
        return succeeded ? reply : nil
    }

    private static func name(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func parentName(of entry: io_registry_entry_t) -> String? {
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
              parent != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(parent) }
        return name(of: parent)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
#else
    // Intel: IOFramebuffer I2C (IOFBCopyI2CInterfaceForBus) is not implemented.
    var isAvailable: Bool { false }
    func externalServices() -> [DDCServiceRecord] { [] }
    func write(_ packet: [UInt8], to service: AnyObject) -> Bool { false }
    func read(_ length: Int, from service: AnyObject) -> [UInt8]? { nil }
#endif
}

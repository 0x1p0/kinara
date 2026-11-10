import Foundation
import CryptoKit

// Independent verification against the public key shipped in the app. No
// private key is needed, and XML is parsed only after its signature validates.
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "Kinara.UpdateFeed", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
do {
    try require(CommandLine.arguments.count == 4, "Usage: verify-update-feed.swift appcast.xml archive.zip Info.plist")
    let feed = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
    let infoData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let keyString = info["SUPublicEDKey"] as? String, let key = Data(base64Encoded: keyString),
          let version = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String else {
        throw NSError(domain: "Kinara.UpdateFeed", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing app signing/version configuration"])
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = feed.range(of: marker, options: .backwards),
          let block = String(data: feed[range.lowerBound...], encoding: .utf8) else {
        throw NSError(domain: "Kinara.UpdateFeed", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsigned update feed"])
    }
    let lines = block.components(separatedBy: "\n")
    try require(lines.count == 5 && lines[0] == "<!-- sparkle-signatures:" && lines[3] == "-->" && lines[4].isEmpty, "Invalid signing block")
    try require(lines[1].hasPrefix("edSignature: ") && lines[2].hasPrefix("length: "), "Invalid signing fields")
    guard let signature = Data(base64Encoded: String(lines[1].dropFirst(13))),
          let length = Int(lines[2].dropFirst(8)), length == range.lowerBound else {
        throw NSError(domain: "Kinara.UpdateFeed", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid signature or content length"])
    }
    let content = feed.prefix(length)
    try require(publicKey.isValidSignature(signature, for: content), "Feed signature does not match the app's public key")
    let document = try XMLDocument(data: content, options: .nodeLoadExternalEntitiesNever)
    let items = try document.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Expected exactly one stable update")
    guard let item = items.first as? XMLElement,
          let enclosure = item.elements(forName: "enclosure").first,
          let archiveSignatureText = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
          let archiveSignature = Data(base64Encoded: archiveSignatureText) else {
        throw NSError(domain: "Kinara.UpdateFeed", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing signed archive"])
    }
    let expectedURL = "https://github.com/0x1p0/kinara/releases/download/v\(version)/Kinara-\(version)-macos-universal.zip"
    try require(enclosure.attribute(forName: "url")?.stringValue == expectedURL, "Unexpected download URL")
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count), "Archive length mismatch")
    try require(item.elements(forName: "sparkle:version").first?.stringValue == build, "Build version mismatch")
    try require(item.elements(forName: "sparkle:shortVersionString").first?.stringValue == version, "Release version mismatch")
    try require(publicKey.isValidSignature(archiveSignature, for: archive), "Archive signature does not match the app's public key")
    print("Verified signed feed, stable release URL, build version, and archive against the shipped public key.")
} catch {
    fputs("Update verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

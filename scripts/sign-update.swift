import Foundation
import CryptoKit
import Security

// A small, dependency-free signing boundary. Archives are opaque bytes: never
// unpacked, loaded as bundles, or executed in the process holding the key.
// Ed25519 is provided by Apple's CryptoKit, not a custom implementation.
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "Kinara.Signing", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func regularFile(_ url: URL, maximumSize: Int) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    try require(attributes[.type] as? FileAttributeType == .typeRegular, "Only regular files may be signed")
    let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
    try require(size > 0 && size <= maximumSize, "Input is empty or exceeds the signing size limit")
    return try Data(contentsOf: url)
}

func signingKey(expectedPublicKey: Data) throws -> Curve25519.Signing.PrivateKey {
    let encoded: String
    if let secret = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY"] {
        encoded = secret
    } else {
        try require(ProcessInfo.processInfo.environment["CI"] != "true", "CI signing requires the protected environment secret")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "https://sparkle-project.org",
            kSecAttrLabel as String: "Private key for signing Sparkle updates",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Kinara.Signing", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read the existing signing key from Keychain"])
        }
        encoded = value
    }
    // Sparkle's current export format is a base64 32-byte Ed25519 seed.
    // Never include the input value in errors, including malformed values.
    guard let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32 else {
        throw NSError(domain: "Kinara.Signing", code: 3, userInfo: [NSLocalizedDescriptionKey: "Signing key must use the 32-byte seed format"])
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    try require(key.publicKey.rawRepresentation == expectedPublicKey, "Signing key does not match the app's public key")
    return key
}

func xml(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

do {
    try require(CommandLine.arguments.count == 5, "Usage: sign-update artifacts Info.plist release-notes.md vVERSION")
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let infoData = try regularFile(URL(fileURLWithPath: CommandLine.arguments[2]), maximumSize: 65_536)
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String,
          let minimumOS = info["LSMinimumSystemVersion"] as? String,
          let encodedPublicKey = info["SUPublicEDKey"] as? String,
          let publicKey = Data(base64Encoded: encodedPublicKey), publicKey.count == 32 else {
        throw NSError(domain: "Kinara.Signing", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing version or public-key configuration"])
    }
    try require(version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil, "Invalid release version")
    try require(build.range(of: "^[0-9]+$", options: .regularExpression) != nil, "Invalid build number")
    try require(minimumOS.range(of: "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil, "Minimum macOS version must be explicit")
    try require(CommandLine.arguments[4] == "v\(version)", "Tag and app version differ")
    let archiveName = "Kinara-\(version)-macos-universal.zip"
    let dmgName = "Kinara-\(version)-macos-universal.dmg"
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    let expected = Set([archiveName, dmgName, "SHA256SUMS.txt"])
    try require(Set(names) == expected, "Expected only the unsigned ZIP, DMG, and checksum file; will not overwrite a signed feed")
    _ = try regularFile(root.appendingPathComponent("SHA256SUMS.txt"), maximumSize: 4_096)
    let archive = try regularFile(root.appendingPathComponent(archiveName), maximumSize: 1_073_741_824)
    let dmg = try regularFile(root.appendingPathComponent(dmgName), maximumSize: 1_073_741_824)
    try require(archive.starts(with: [0x50, 0x4b, 0x03, 0x04]), "Invalid ZIP header")
    try require(dmg.count >= 512 && dmg.suffix(512).starts(with: Data("koly".utf8)), "Invalid disk-image trailer")
    let notesData = try regularFile(URL(fileURLWithPath: CommandLine.arguments[3]), maximumSize: 131_072)
    guard let notes = String(data: notesData, encoding: .utf8) else {
        throw NSError(domain: "Kinara.Signing", code: 5, userInfo: [NSLocalizedDescriptionKey: "Release notes must be UTF-8"])
    }
    let key = try signingKey(expectedPublicKey: publicKey)
    let archiveSignature = try key.signature(for: archive).base64EncodedString()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    let feed = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <!-- Signed update feed. Any modification requires a new signature. -->
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><title>Kinara</title><item>
        <title>\(version)</title><pubDate>\(formatter.string(from: Date()))</pubDate>
        <sparkle:version>\(build)</sparkle:version>
        <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>\(minimumOS)</sparkle:minimumSystemVersion>
        <description sparkle:format="markdown">\(xml(notes))</description>
        <enclosure url="https://github.com/0x1p0/kinara/releases/download/v\(version)/\(archiveName)" length="\(archive.count)" type="application/octet-stream" sparkle:edSignature="\(archiveSignature)"/>
      </item></channel>
    </rss>

    """.utf8)
    let signedFeed = feed + Data("<!-- sparkle-signatures:\nedSignature: \(try key.signature(for: feed).base64EncodedString())\nlength: \(feed.count)\n-->\n".utf8)
    let digest: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    let checksums = "\(digest(archive))  \(archiveName)\n\(digest(dmg))  \(dmgName)\n\(digest(signedFeed))  appcast.xml\n"
    try signedFeed.write(to: root.appendingPathComponent("appcast.xml"), options: .withoutOverwriting)
    try Data(checksums.utf8).write(to: root.appendingPathComponent("SHA256SUMS.txt"), options: .atomic)
    print("Signed ZIP and feed with the existing app key; no archive was extracted or executed.")
} catch {
    fputs("Signing failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

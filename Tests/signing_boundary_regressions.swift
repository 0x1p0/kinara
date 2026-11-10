import Foundation
import CryptoKit

@main
struct SigningBoundaryRegressions {
    static func main() throws {
        let signer = CommandLine.arguments[1]
        let verifier = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let sparkleTool = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil
        let key = Curve25519.Signing.PrivateKey()
        let encodedSeed = key.rawRepresentation.base64EncodedString()
        let archiveName = "Kinara-1.0.7-macos-universal.zip"
        let dmgName = "Kinara-1.0.7-macos-universal.dmg"
        let archive = Data([0x50, 0x4b, 0x03, 0x04]) + Data("Opaque test bytes. Never execute me.".utf8)
        let dmg = Data("koly".utf8) + Data(repeating: 0, count: 508)
        let notes = "Release notes: <tag> & \"quotes\" ]]> <!DOCTYPE x SYSTEM 'file:///etc/passwd'>"
        let notesURL = directory.appendingPathComponent("notes.md")
        try Data(notes.utf8).write(to: notesURL)
        let infoURL = directory.appendingPathComponent("source.plist")
        let info: [String: Any] = ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
                                   "CFBundleShortVersionString": "1.0.7", "CFBundleVersion": "8", "LSMinimumSystemVersion": "13.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        var checks = 0
        func expect(_ condition: Bool, _ name: String) {
            guard condition else { fatalError(name) }
            checks += 1
        }
        func run(_ executable: String, _ args: [String], secret: String = encodedSeed, input: Data? = nil) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["SPARKLE_PRIVATE_KEY"] = secret
            environment["CI"] = "true"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            expect(!text.contains(encodedSeed) && (secret.isEmpty || !text.contains(secret)), "Never disclose key inputs in process output")
            return (process.terminationStatus, text)
        }
        func fixture(_ name: String) throws -> URL {
            let root = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try archive.write(to: root.appendingPathComponent(archiveName))
            try dmg.write(to: root.appendingPathComponent(dmgName))
            try Data("unsigned checksums\n".utf8).write(to: root.appendingPathComponent("SHA256SUMS.txt"))
            return root
        }
        func invoke(_ root: URL, secret: String = encodedSeed, tag: String = "v1.0.7") throws -> Int32 {
            try run(signer, [root.path, infoURL.path, notesURL.path, tag], secret: secret).0
        }
        let valid = try fixture("valid")
        expect(try invoke(valid) == 0, "Valid opaque archive signs")
        expect(try run(verifier, [valid.appendingPathComponent("appcast.xml").path, valid.appendingPathComponent(archiveName).path, infoURL.path]).0 == 0, "Independent verifier accepts generated feed")
        let feed = try Data(contentsOf: valid.appendingPathComponent("appcast.xml"))
        let document = try XMLDocument(data: feed, options: .nodeLoadExternalEntitiesNever)
        expect(try document.nodes(forXPath: "/rss/channel/item/description").first?.stringValue == notes, "Notes are XML-escaped data, not active markup")
        expect(try invoke(valid) != 0, "Never overwrite an existing signed feed")
        expect(try Data(contentsOf: valid.appendingPathComponent("appcast.xml")) == feed, "Failed re-sign leaves the original unchanged")
        for (name, secret, tag) in [
            ("wrong-key", Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString(), "v1.0.7"),
            ("malformed-key", "INVALID_PRIVATE_INPUT_MUST_NEVER_APPEAR", "v1.0.7"),
            ("missing-key", "", "v1.0.7"),
            ("wrong-tag", encodedSeed, "v1.0.8")
        ] {
            let root = try fixture(name)
            expect(try invoke(root, secret: secret, tag: tag) != 0, "Reject \(name)")
            expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("appcast.xml").path), "No feed is created after invalid signing input")
        }
        let extra = try fixture("extra-file")
        try Data("unexpected payload".utf8).write(to: extra.appendingPathComponent("run-me.sh"))
        expect(try invoke(extra) != 0, "Reject unexpected artifact files")
        let symlink = try fixture("symlink")
        let checksum = symlink.appendingPathComponent("SHA256SUMS.txt")
        try FileManager.default.removeItem(at: checksum)
        try FileManager.default.createSymbolicLink(at: checksum, withDestinationURL: notesURL)
        expect(try invoke(symlink) != 0, "Reject symlinked output manifest")
        expect(try String(contentsOf: notesURL, encoding: .utf8) == notes, "Symlink target remains untouched")
        let badZIP = try fixture("bad-zip")
        try Data("not a ZIP".utf8).write(to: badZIP.appendingPathComponent(archiveName))
        expect(try invoke(badZIP) != 0, "Reject malformed ZIP header")
        let badDMG = try fixture("bad-dmg")
        try Data("not a DMG".utf8).write(to: badDMG.appendingPathComponent(dmgName))
        expect(try invoke(badDMG) != 0, "Reject malformed DMG trailer")
        if let sparkleTool {
            let enclosure = try document.nodes(forXPath: "/rss/channel/item/enclosure").first as! XMLElement
            let signature = enclosure.attribute(forName: "sparkle:edSignature")!.stringValue!
            expect(try run(sparkleTool, ["--verify", "--ed-key-file", "-", valid.appendingPathComponent(archiveName).path, signature], input: Data(encodedSeed.utf8)).0 == 0, "Official Sparkle verifies archive interoperability")
            expect(try run(sparkleTool, ["--verify", "--ed-key-file", "-", valid.appendingPathComponent("appcast.xml").path], input: Data(encodedSeed.utf8)).0 == 0, "Official Sparkle verifies signed-feed interoperability")
        }
        print("\(checks) isolated-signing boundary assertions passed using disposable keys; no app was executed.")
    }
}

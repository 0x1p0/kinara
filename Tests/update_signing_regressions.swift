import Foundation
import CryptoKit

@main
struct UpdateSigningRegressions {
    static func main() throws {
        let verifier = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("A disposable update archive fixture".utf8)
        let signature = try key.signature(for: archive).base64EncodedString()
        let item = """
        <item><sparkle:version>7</sparkle:version><sparkle:shortVersionString>1.0.6</sparkle:shortVersionString>
        <enclosure url="https://github.com/0x1p0/kinara/releases/download/v1.0.6/Kinara-1.0.6-macos-universal.zip" length="\(archive.count)" sparkle:edSignature="\(signature)" type="application/octet-stream"/></item>
        """
        func xml(_ entries: String) -> Data {
            Data("<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\(entries)</channel></rss>\n".utf8)
        }
        func signed(_ data: Data) throws -> Data {
            data + Data("<!-- sparkle-signatures:\nedSignature: \(try key.signature(for: data).base64EncodedString())\nlength: \(data.count)\n-->\n".utf8)
        }
        let content = xml(item)
        let valid = try signed(content)
        var count = 0
        func check(_ name: String, feed: Data, payload: Data = archive,
                   publicKey: Data = key.publicKey.rawRepresentation, expected: Bool) throws {
            let feedURL = directory.appendingPathComponent("test.xml")
            let archiveURL = directory.appendingPathComponent("test.zip")
            let infoURL = directory.appendingPathComponent("test.plist")
            try feed.write(to: feedURL)
            try payload.write(to: archiveURL)
            let info: [String: Any] = ["SUPublicEDKey": publicKey.base64EncodedString(),
                                       "CFBundleShortVersionString": "1.0.6", "CFBundleVersion": "7"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: verifier)
            process.arguments = [feedURL.path, archiveURL.path, infoURL.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            guard (process.terminationStatus == 0) == expected else {
                let details = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                fatalError("\(name): unexpected verification result: \(details)")
            }
            count += 1
        }
        try check("valid feed and archive", feed: valid, expected: true)
        try check("unsigned feed", feed: content, expected: false)
        try check("altered feed", feed: Data([0x20]) + valid.dropFirst(), expected: false)
        try check("trailing unsigned bytes", feed: valid + Data("extra".utf8), expected: false)
        try check("truncated signing block", feed: valid.dropLast(4), expected: false)
        try check("different archive, same length", feed: valid, payload: Data(repeating: 0, count: archive.count), expected: false)
        try check("truncated archive", feed: valid, payload: archive.dropLast(), expected: false)
        try check("wrong public key", feed: valid, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, expected: false)
        try check("invalid public key", feed: valid, publicKey: Data([1, 2]), expected: false)
        try check("wrong download host", feed: signed(xml(item.replacingOccurrences(of: "github.com", with: "example.com"))), expected: false)
        try check("wrong build", feed: signed(xml(item.replacingOccurrences(of: ">7<", with: ">8<"))), expected: false)
        try check("wrong release version", feed: signed(xml(item.replacingOccurrences(of: ">1.0.6<", with: ">1.0.7<"))), expected: false)
        try check("no archive signature", feed: signed(xml(item.replacingOccurrences(of: "sparkle:edSignature", with: "unsigned"))), expected: false)
        try check("duplicate releases", feed: signed(xml(item + item)), expected: false)
        try check("empty feed", feed: signed(xml("")), expected: false)
        print("\(count) signed-update verification assertions passed (disposable keys, no network or installation).")
    }
}

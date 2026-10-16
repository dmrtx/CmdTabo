#!/usr/bin/env swift
import CryptoKit
import Foundation

// Public-key-only verification; never opens the Keychain.
final class Feed: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "enclosure" { enclosures.append(attributeDict) }
    }
}

do {
    guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
    let feedURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let publicBytes = Data(base64Encoded: CommandLine.arguments[3]) else { throw CocoaError(.fileReadCorruptFile) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    let data = try Data(contentsOf: feedURL)
    let text = String(decoding: data, as: UTF8.self)
    // Signature verification must cover the original bytes, never a lossy
    // replacement of invalid UTF-8 with U+FFFD.
    guard Data(text.utf8) == data else { throw CocoaError(.fileReadCorruptFile) }
    let pattern = #"(?s)\A(.*)<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*\z"#
    let regex = try NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let bodyRange = Range(match.range(at: 1), in: text),
          let signatureRange = Range(match.range(at: 2), in: text),
          let lengthRange = Range(match.range(at: 3), in: text),
          let signature = Data(base64Encoded: String(text[signatureRange])),
          let length = Int(text[lengthRange]) else { throw CocoaError(.fileReadCorruptFile) }
    let body = Data(text[bodyRange].utf8)
    guard body.count == length, key.isValidSignature(signature, for: body),
          !text[bodyRange].contains("<!DOCTYPE") else { throw CocoaError(.fileReadCorruptFile) }
    let feed = Feed(), parser = XMLParser(data: body)
    parser.shouldResolveExternalEntities = false
    parser.delegate = feed
    guard parser.parse() else { throw CocoaError(.fileReadCorruptFile) }
    let matches = feed.enclosures.filter { URL(string: $0["url"] ?? "")?.lastPathComponent == archiveURL.lastPathComponent }
    guard matches.count == 1, let item = matches.first,
          let archiveSignature = Data(base64Encoded: item["sparkle:edSignature"] ?? ""),
          let archiveLength = Int(item["length"] ?? "") else { throw CocoaError(.fileReadCorruptFile) }
    let archive = try Data(contentsOf: archiveURL)
    guard archive.count == archiveLength, key.isValidSignature(archiveSignature, for: archive) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    print("PASS public-key verification: signed feed and archive.")
} catch {
    fputs("FAIL signed update verification.\n", stderr)
    exit(1)
}

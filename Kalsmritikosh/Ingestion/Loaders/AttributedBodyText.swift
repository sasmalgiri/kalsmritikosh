//
//  AttributedBodyText.swift
//  Kalsmritikosh
//
//  Recovers the message text from a Messages `attributedBody` blob.
//
//  WHY THIS EXISTS. From macOS Ventura / iOS 16 onward, Messages stopped
//  filling `message.text` for many rows and puts the message in
//  `message.attributedBody` instead — an NSAttributedString archived in
//  Apple's LEGACY typedstream format (the old `NSArchiver`, not
//  `NSKeyedArchiver`, so no modern unarchiver reads it). The previous reader
//  filtered on `message.text IS NOT NULL`, which meant those messages were
//  not merely rendered badly: they were DROPPED, silently. A modern
//  conversation could arrive almost empty with nothing saying so.
//
//  THE LAYOUT IS NOT GUESSED. Every offset and length encoding below was
//  measured against archives produced by Apple's own `NSArchiver` on this
//  platform, and `TypedStreamArchive` in the tests reproduces those bytes
//  exactly — a test asserts our writer is byte-identical to Apple's output for
//  a known string, so the fixtures the decoder is tested against are Apple's
//  encoding rather than a reading of it.
//
//  Measured layout:
//    04 0b "streamtyped"      file header
//    …class records…          "NSAttributedString", "NSObject", then "NSString"
//    01 94 84 01 2b           the string marker, ending in '+' (0x2B)
//    <length>                 UTF-8 BYTE count, typedstream-encoded:
//                               < 0x81      → that single byte
//                               0x81        → next 2 bytes, little-endian
//                               0x82        → next 4 bytes, little-endian
//                               0x83        → next 8 bytes, little-endian
//    <length bytes>           the text, UTF-8
//
//  SAFETY PROPERTY. This is a best-effort text layer over an exact row layer.
//  When recovery fails it returns nil, and the caller still emits the message
//  with its date, sender and direction plus a stated "text not recoverable"
//  note. A message must never vanish, and the reader must never be left
//  guessing whether a gap is silence or absence.
//

import Foundation

public struct AttributedBodyText: Sendable, Equatable {
    /// The recovered text, with attachment placeholders made visible.
    public let text: String
    /// Whether the message body was (or contained) an attachment placeholder —
    /// U+FFFC, the object-replacement character Messages uses where a picture or
    /// file sits. Rendering it raw would put an invisible character in evidence.
    public let containsAttachmentPlaceholder: Bool

    /// The 13-byte legacy-archive header: `04 0b` then "streamtyped".
    nonisolated static let header = Data([0x04, 0x0B]) + Data("streamtyped".utf8)
    /// The byte that immediately precedes a string's length.
    nonisolated static let stringMarker: UInt8 = 0x2B
    /// Class names that introduce the text payload. `NSAttributedString`
    /// contains "String" but NOT "NSString", so this cannot match the wrong
    /// record.
    nonisolated static let stringClasses = ["NSString", "NSMutableString"]
    /// How far past the class name the marker may sit. Measured at 5 bytes
    /// (`01 94 84 01 2b`); the window allows for version drift without letting
    /// the search wander into another record.
    nonisolated static let markerWindow = 16
    /// A single message is not megabytes of text. A larger declared length means
    /// the length was misread, so the recovery is refused rather than used.
    nonisolated static let maximumTextBytes = 4 * 1024 * 1024

    /// Attachment placeholder, spelled out so an answer quoting the message says
    /// something a reader can act on.
    nonisolated static let attachmentPlaceholder = "[attachment]"

    // MARK: - Decoding

    /// Recover the text, or nil when these bytes do not yield it. Nil is a
    /// first-class outcome: the caller keeps the message and says the text could
    /// not be read.
    public nonisolated static func decode(_ blob: Data) -> AttributedBodyText? {
        guard blob.count > header.count, blob.prefix(header.count) == header else { return nil }
        let bytes = [UInt8](blob)

        guard let classEnd = firstStringClassEnd(in: bytes) else { return nil }
        guard let markerIndex = markerIndex(in: bytes, from: classEnd) else { return nil }
        guard let (length, textStart) = length(in: bytes, after: markerIndex) else { return nil }
        guard length <= maximumTextBytes, textStart + length <= bytes.count else { return nil }

        // A zero-length string is a real state — an empty message — and is
        // distinct from "could not decode", so it is NOT reported as a failure.
        let raw = Data(bytes[textStart..<(textStart + length)])
        guard let decoded = String(data: raw, encoding: .utf8) else { return nil }

        let hasPlaceholder = decoded.unicodeScalars.contains { $0 == "\u{FFFC}" }
        var text = decoded
        if hasPlaceholder {
            text = text.replacingOccurrences(of: "\u{FFFC}", with: attachmentPlaceholder)
        }
        return AttributedBodyText(text: text, containsAttachmentPlaceholder: hasPlaceholder)
    }

    /// Index just past the first string class name.
    private nonisolated static func firstStringClassEnd(in bytes: [UInt8]) -> Int? {
        var best: Int?
        for name in stringClasses {
            let needle = [UInt8](name.utf8)
            guard needle.count <= bytes.count else { continue }
            for start in 0...(bytes.count - needle.count) {
                if Array(bytes[start..<(start + needle.count)]) == needle {
                    let end = start + needle.count
                    if best == nil || end < best! { best = end }
                    break
                }
            }
        }
        return best
    }

    private nonisolated static func markerIndex(in bytes: [UInt8], from start: Int) -> Int? {
        let limit = min(start + markerWindow, bytes.count)
        guard start < limit else { return nil }
        for index in start..<limit where bytes[index] == stringMarker { return index }
        return nil
    }

    /// Typedstream length encoding, measured against Apple's encoder.
    private nonisolated static func length(in bytes: [UInt8], after marker: Int)
    -> (length: Int, textStart: Int)? {
        let at = marker + 1
        guard at < bytes.count else { return nil }
        let first = bytes[at]
        if first < 0x81 { return (Int(first), at + 1) }

        let width: Int
        switch first {
        case 0x81: width = 2
        case 0x82: width = 4
        case 0x83: width = 8
        // 0x84 and up are typedstream TYPE markers, not lengths. Reading one as
        // a length would produce a wrong offset and, from there, plausible-looking
        // wrong text — so this refuses instead.
        default: return nil
        }
        guard at + 1 + width <= bytes.count else { return nil }
        var value = 0
        for offset in 0..<width {
            value |= Int(bytes[at + 1 + offset]) << (8 * offset)
        }
        guard value >= 0 else { return nil }
        return (value, at + 1 + width)
    }
}

//
//  TypedStreamArchive.swift
//  KalsmritikoshTests
//
//  Test support — builds Messages `attributedBody` blobs in Apple's LEGACY
//  typedstream format.
//
//  PROVENANCE, which is the whole point of this file. The layout and the length
//  encoding were not read off a spec and hoped for: they were MEASURED from
//  archives produced by Apple's own `NSArchiver` on this platform, and
//  `writerMatchesApplesOwnEncoder` asserts this writer's output is
//  byte-identical to Apple's for a known string. So the fixtures the decoder is
//  tested against carry Apple's encoding rather than my reading of it — the
//  usual "a fixture writer and a parser can be wrong in the same way" risk does
//  not apply here.
//
//  Measured length encoding (all four verified against real output):
//    length < 0x81 → one byte                 ("…locker" = 32 → 0x20)
//    0x81 + 2 bytes little-endian             (200 → 81 c8 00 ; 400 → 81 90 01)
//    0x82 + 4 bytes little-endian             (70000 → 82 70 11 01 00)
//  The count is UTF-8 BYTES, not characters (emoji → 17, "café — naïve" → 16).
//

import Foundation

struct TypedStreamArchive {

    /// The exact 138 bytes Apple's `NSArchiver` produced for
    /// `NSAttributedString(string: "the drive is in the depot locker")` on
    /// macOS. Kept verbatim as the anchor this writer is checked against; it can
    /// be regenerated with `NSArchiver.archivedData(withRootObject:)`.
    static let appleReferenceArchive: [UInt8] = [
        0x04, 0x0b, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64,
        0x81, 0xe8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12,
        0x4e, 0x53, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65, 0x64,
        0x53, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x00, 0x84, 0x84, 0x08,
        0x4e, 0x53, 0x4f, 0x62, 0x6a, 0x65, 0x63, 0x74, 0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08,
        0x4e, 0x53, 0x53, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x01, 0x94, 0x84, 0x01, 0x2b,
        0x20,
        0x74, 0x68, 0x65, 0x20, 0x64, 0x72, 0x69, 0x76, 0x65, 0x20, 0x69, 0x73, 0x20,
        0x69, 0x6e, 0x20, 0x74, 0x68, 0x65, 0x20, 0x64, 0x65, 0x70, 0x6f, 0x74, 0x20,
        0x6c, 0x6f, 0x63, 0x6b, 0x65, 0x72,
        0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x20, 0x92, 0x84, 0x84, 0x84, 0x0c,
        0x4e, 0x53, 0x44, 0x69, 0x63, 0x74, 0x69, 0x6f, 0x6e, 0x61, 0x72, 0x79,
        0x00, 0x94, 0x84, 0x01, 0x69, 0x00, 0x86, 0x86
    ]

    static let referenceString = "the drive is in the depot locker"

    /// An `attributedBody` blob for `text`, in the shape Messages stores.
    static func archive(_ text: String) -> Data {
        var out = Data([0x04, 0x0b]) + Data("streamtyped".utf8)
        out += Data([0x81, 0xe8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12])
        out += Data("NSAttributedString".utf8)
        out += Data([0x00, 0x84, 0x84, 0x08])
        out += Data("NSObject".utf8)
        out += Data([0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08])
        out += Data("NSString".utf8)
        out += Data([0x01, 0x94, 0x84, 0x01, 0x2b])          // string marker, ends in '+'
        out += lengthBytes(text.utf8.count)
        out += Data(text.utf8)
        // Trailer: the attribute run and its (empty) attribute dictionary.
        out += Data([0x86, 0x84, 0x02, 0x69, 0x49, 0x01])
        out += lengthBytes(text.utf8.count)                   // run length
        out += Data([0x92, 0x84, 0x84, 0x84, 0x0c])
        out += Data("NSDictionary".utf8)
        out += Data([0x00, 0x94, 0x84, 0x01, 0x69, 0x00, 0x86, 0x86])
        return out
    }

    /// The measured typedstream integer encoding.
    static func lengthBytes(_ value: Int) -> Data {
        if value < 0x81 { return Data([UInt8(value)]) }
        if value <= 0xFFFF {
            return Data([0x81, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
        }
        return Data([0x82,
                     UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                     UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    /// Apple's encoder, when the legacy class is still present at runtime. Used
    /// by the provenance test; nil means the check is skipped rather than
    /// silently passing.
    static func appleArchive(_ text: String) -> Data? {
        guard let cls = NSClassFromString("NSArchiver") else { return nil }
        let selector = NSSelectorFromString("archivedDataWithRootObject:")
        guard (cls as AnyObject).responds(to: selector) else { return nil }
        guard let result = (cls as AnyObject).perform(
            selector, with: NSAttributedString(string: text)) else { return nil }
        return result.takeUnretainedValue() as? Data
    }
}

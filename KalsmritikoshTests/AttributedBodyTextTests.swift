//
//  AttributedBodyTextTests.swift
//  KalsmritikoshTests
//
//  The fix for silent data loss in the iMessage lane.
//
//  From macOS Ventura / iOS 16 onward Messages often leaves `message.text`
//  NULL and puts the body in `attributedBody`. The reader filtered on
//  `message.text IS NOT NULL`, so those messages were DROPPED — a modern
//  conversation could arrive nearly empty and look complete. Two tests carry
//  the weight:
//
//   - `writerMatchesApplesOwnEncoder` — this suite's fixtures are Apple's
//     encoding, not a reading of it. Without this, decoder and fixture could be
//     wrong in the same way and pass.
//   - `aMessageIsNeverDropped` — when no text can be recovered at all, the
//     message still arrives with its time, sender and direction. Absence of
//     text must never become absence of the message.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Messages attributedBody recovery")
struct AttributedBodyTextTests {

    // MARK: - Provenance

    @Test("This suite's archive writer is byte-identical to Apple's NSArchiver")
    func writerMatchesApplesOwnEncoder() throws {
        // The anchor. Everything else in this file is built on the writer, so
        // if the writer matches Apple byte-for-byte, the decoder is being tested
        // against Apple's encoding rather than my understanding of it.
        let mine = TypedStreamArchive.archive(TypedStreamArchive.referenceString)
        #expect([UInt8](mine) == TypedStreamArchive.appleReferenceArchive)

        // And when the legacy encoder is still present, check live rather than
        // against a recorded constant.
        if let apple = TypedStreamArchive.appleArchive(TypedStreamArchive.referenceString) {
            #expect([UInt8](apple) == TypedStreamArchive.appleReferenceArchive,
                    "Apple's output changed — the recorded reference needs regenerating")
            #expect(mine == apple)
        }
    }

    @Test("Every measured length encoding round-trips")
    func allLengthEncodingsDecode() throws {
        // Single byte, 0x81 + u16, 0x82 + u32 — each verified against real
        // NSArchiver output before being relied on here.
        for count in [1, 32, 127, 128, 200, 400, 65_535, 70_000] {
            let text = String(repeating: "A", count: count)
            let decoded = try #require(
                AttributedBodyText.decode(TypedStreamArchive.archive(text)),
                "length \(count) failed to decode")
            #expect(decoded.text == text, "length \(count) decoded wrongly")
        }
    }

    @Test("Live Apple archives decode, not just this writer's")
    func applesOwnArchivesDecode() throws {
        // Belt and braces: decode what Apple produces, for the shapes where the
        // encoding changes.
        for text in ["short one", String(repeating: "B", count: 300),
                     "café — naïve", "meet at 3 👍 ok"] {
            guard let apple = TypedStreamArchive.appleArchive(text) else { return }
            let decoded = try #require(AttributedBodyText.decode(apple))
            #expect(decoded.text == text)
        }
    }

    // MARK: - Content fidelity

    @Test("Non-ASCII text survives, because the length counts BYTES not characters")
    func multiByteTextSurvives() throws {
        // "café — naïve" is 12 characters but 16 UTF-8 bytes. Reading the length
        // as characters would truncate mid-sequence and corrupt the text.
        for text in ["café — naïve", "meet at 3 👍 ok", "मिलते हैं", "  spaced  out  "] {
            let decoded = try #require(AttributedBodyText.decode(TypedStreamArchive.archive(text)))
            #expect(decoded.text == text)
        }
    }

    @Test("An attachment placeholder is made visible, not left as an invisible character")
    func attachmentPlaceholderIsNamed() throws {
        // Messages stores U+FFFC where a picture or file sits. Rendering it raw
        // puts an invisible character into evidence.
        let decoded = try #require(
            AttributedBodyText.decode(TypedStreamArchive.archive("\u{FFFC}")))
        #expect(decoded.text == "[attachment]")
        #expect(decoded.containsAttachmentPlaceholder)

        let mixed = try #require(
            AttributedBodyText.decode(TypedStreamArchive.archive("look \u{FFFC} here")))
        #expect(mixed.text == "look [attachment] here")
        #expect(mixed.containsAttachmentPlaceholder)
    }

    @Test("An empty message decodes as empty — a real state, not a failure")
    func emptyStringIsNotAFailure() throws {
        let decoded = try #require(AttributedBodyText.decode(TypedStreamArchive.archive("")))
        #expect(decoded.text.isEmpty)
        #expect(!decoded.containsAttachmentPlaceholder)
    }

    // MARK: - Refusals: nil rather than invented text

    @Test("Bytes that are not a legacy archive are refused")
    func nonArchiveIsRefused() {
        #expect(AttributedBodyText.decode(Data()) == nil)
        #expect(AttributedBodyText.decode(Data("hello".utf8)) == nil)
        // A modern keyed archive is a DIFFERENT format and must not be guessed at.
        let keyed = try? NSKeyedArchiver.archivedData(
            withRootObject: NSAttributedString(string: "x"), requiringSecureCoding: false)
        if let keyed { #expect(AttributedBodyText.decode(keyed) == nil) }
    }

    @Test("A declared length that overruns the blob is refused, not clamped")
    func overlongLengthIsRefused() {
        // Clamping would hand back a truncated message as though it were whole.
        var bytes = [UInt8](TypedStreamArchive.archive("hello"))
        let marker = bytes.lastIndex(of: 0x2B)!
        bytes[marker + 1] = 0x7F        // claim 127 bytes where ~5 remain
        #expect(AttributedBodyText.decode(Data(bytes)) == nil)
    }

    @Test("A type marker where a length should be is refused")
    func typeMarkerIsNotReadAsALength() {
        // 0x84 and up are typedstream TYPE markers. Treating one as a length
        // would shift the offset and produce plausible-looking wrong text —
        // the failure mode that matters, so it refuses instead.
        var bytes = [UInt8](TypedStreamArchive.archive("hello"))
        let marker = bytes.firstIndex(of: 0x2B)!
        bytes[marker + 1] = 0x84
        #expect(AttributedBodyText.decode(Data(bytes)) == nil)
    }

    @Test("An archive with no string record is refused")
    func noStringRecordIsRefused() {
        let header = Data([0x04, 0x0b]) + Data("streamtyped".utf8)
        #expect(AttributedBodyText.decode(header + Data(repeating: 0x84, count: 40)) == nil)
    }

    @Test("Invalid UTF-8 in the payload is refused rather than mangled")
    func invalidUTF8IsRefused() {
        var bytes = [UInt8](TypedStreamArchive.archive("hello"))
        let marker = bytes.firstIndex(of: 0x2B)!
        let textStart = marker + 2
        bytes[textStart] = 0xFF        // never valid UTF-8
        bytes[textStart + 1] = 0xFE
        #expect(AttributedBodyText.decode(Data(bytes)) == nil)
    }

    // MARK: - THE loss that started this

    @Test("Text is recovered from attributedBody when message.text is NULL")
    func attributedBodyIsUsedWhenTextIsNull() {
        // The exact modern row shape that used to be dropped.
        let blob = TypedStreamArchive.archive("the drive is in the depot locker")
        let result = IMessageLoader.messageText(plainText: nil, attributedBody: blob)
        #expect(result.text == "the drive is in the depot locker")
        #expect(result.origin == .attributedBody)
    }

    @Test("message.text wins when present — the decoder is only ever a fallback")
    func plainTextIsPreferred() {
        // Apple's own plain copy is authoritative; the archive decoder must not
        // override it.
        let blob = TypedStreamArchive.archive("archived version")
        let result = IMessageLoader.messageText(plainText: "plain version", attributedBody: blob)
        #expect(result.text == "plain version")
        #expect(result.origin == .plainText)
    }

    @Test("A message is NEVER dropped, even when no text can be recovered")
    func aMessageIsNeverDropped() {
        // This is the whole point. A row with neither a usable text column nor a
        // decodable body still has a time, a sender and a direction — that is
        // evidence. Dropping it makes a conversation look complete when it is not.
        for (plain, blob) in [(nil, nil), ("", nil), (nil, Data("not an archive".utf8)),
                              ("   ", Data())] as [(String?, Data?)] {
            let result = IMessageLoader.messageText(plainText: plain, attributedBody: blob)
            #expect(result.origin == .unrecoverable)
            #expect(!result.text.isEmpty)
            #expect(result.text.contains("not recoverable"))
        }
    }

    @Test("An empty archived body falls through to the stated note")
    func emptyBodyIsReportedNotSilent() {
        // An archive that decodes to "" carries no message text, so the row is
        // reported as unrecoverable rather than rendered as a blank line that
        // reads like something was said.
        let result = IMessageLoader.messageText(
            plainText: nil, attributedBody: TypedStreamArchive.archive(""))
        #expect(result.origin == .unrecoverable)
        #expect(result.text.contains("not recoverable"))
    }

    @Test("Recovery is deterministic")
    func deterministic() {
        let blob = TypedStreamArchive.archive("meet at the depot 03:00")
        let first = AttributedBodyText.decode(blob)
        let second = AttributedBodyText.decode(blob)
        #expect(first == second)
    }
}

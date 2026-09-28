//
//  TextChatExportTests.swift
//  KalsmritikoshTests
//
//  DISC-6 — WhatsApp / Signal / Slack text exports become per-message records.
//
//  This is an upgrade, not a new platform: ChatExportLoader has read these files
//  since Phase K but produced one text blob, so no message had an author the
//  entity layer could unify or a date the timeline could use. Two defects in that
//  path are pinned here:
//
//    • A WhatsApp system notice (`[3/14/25, 9:12 AM] Messages and calls are
//      end-to-end encrypted.`) has no `sender:`, so the old normalizer appended
//      it to the PREVIOUS person's message — attributing platform text to a human.
//    • The date order was never resolved. `3/4/25` is 3 April or 4 March
//      depending on the exporting phone's locale, and guessing moves a message by
//      up to eleven months while still looking like a date.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Text chat exports — WhatsApp / Signal / Slack (DISC-6)")
@MainActor
struct TextChatExportTests {

    private let parser = DiscussionStructuralParser()

    private func parse(_ text: String, _ filename: String) async throws -> ParsedDocument {
        try await parser.parse(data: Data(text.utf8), filename: filename, type: .chatExport,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }
    private func messages(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .discussionMessage }.map(\.rawText)
    }
    private func attribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let v)? = block.attributes[key]?.value { return v }
        return nil
    }

    /// A realistic WhatsApp export: the encryption notice, two named senders, a
    /// multi-line message, a media placeholder, and a membership notice. Days are
    /// above 12 so the date order is decisive.
    private var whatsappExport: String {
        """
        [14/03/2026, 9:12:34 AM] Messages and calls are end-to-end encrypted.
        [14/03/2026, 9:13:01 AM] André Müller: Did you sign the contract?
        [14/03/2026, 9:14:00 AM] Riyaz Ahmed: Yes — uploaded.
        Second line of the same message.
        [15/03/2026, 10:00:00 AM] André Müller: <Media omitted>
        [15/03/2026, 10:05:00 AM] Riyaz Ahmed added Priya to this group
        """
    }

    // MARK: - Correction 1: system notices

    @Test("A system notice is its own activity record, not appended to a person")
    func systemNoticeIsNotAttributedToAHuman() async throws {
        let doc = try await parse(whatsappExport, "WhatsApp Chat with André Müller.txt")
        let notice = try #require(doc.blocks.first {
            $0.rawText.contains("end-to-end encrypted")
        })
        #expect(attribute(notice, "kind") == "activity")
        #expect(notice.attributes["authorHandle"] == nil)
        // The bug this guards: the notice glued onto whatever a human last said.
        for line in messages(doc) where line.contains("Did you sign") {
            #expect(!line.contains("end-to-end encrypted"))
        }
    }

    @Test("A membership notice is activity too, not speech by the person named")
    func membershipNoticeIsActivity() async throws {
        // "Riyaz Ahmed added Priya to this group" has no colon, so it is a notice
        // ABOUT Riyaz, not something Riyaz said.
        let doc = try await parse(whatsappExport, "chat.txt")
        let notice = try #require(doc.blocks.first { $0.rawText.contains("added Priya") })
        #expect(attribute(notice, "kind") == "activity")
    }

    @Test("A multi-line message stays one message with its author intact")
    func multiLineMessageStaysWhole() async throws {
        let doc = try await parse(whatsappExport, "chat.txt")
        let line = try #require(messages(doc).first { $0.contains("Yes — uploaded") })
        #expect(line.contains("Second line of the same message"))
        #expect(line.hasPrefix("Riyaz Ahmed"))
    }

    // MARK: - Correction 2: date order

    @Test("A day above 12 settles the date order for the whole file")
    func dayAboveTwelveIsDecisive() async throws {
        // 14/03 can only be day-first, and that decides every other stamp too.
        let doc = try await parse(whatsappExport, "chat.txt")
        let block = try #require(doc.blocks.first { $0.rawText.contains("Did you sign") })
        #expect(attribute(block, "timestamp") == "2026-03-14T09:13:01Z")
    }

    @Test("Chronology settles an order that no single date could")
    func chronologyBreaksTheTie() {
        // 04/03 then 05/03: day-first is 4 then 5 March (ordered); month-first is
        // 3 April then 3 May — also ordered. Both work, so this must stay
        // ambiguous rather than pick one.
        let bothOrdered = ChatTimestampResolver.resolve(
            ["04/03/2026, 9:00:00 AM", "05/03/2026, 9:00:00 AM"], shape: .whatsapp)
        #expect(bothOrdered.dates.allSatisfy { $0 == nil })
        #expect(bothOrdered.warning?.code == "chatexport.ambiguous_date_order")

        // 05/03 then 04/04: day-first is 5 March then 4 April (ordered);
        // month-first is 3 May then 4 April (BACKWARDS). Only one reading is
        // chronological, so it is the right one.
        let decided = ChatTimestampResolver.resolve(
            ["05/03/2026, 9:00:00 AM", "04/04/2026, 9:00:00 AM"], shape: .whatsapp)
        #expect(decided.order == .dayFirst)
        #expect(decided.dates.compactMap { $0 }.count == 2)
    }

    @Test("A wholly ambiguous export is recorded undated, in order, and says so")
    func ambiguousExportIsUndatedNotGuessed() async throws {
        // Every component under 13 and both readings chronological. A coin flip
        // presented as a fact is worse than no date at all.
        let ambiguous = """
        [03/04/2026, 9:00:00 AM] André Müller: first
        [04/05/2026, 9:00:00 AM] Riyaz Ahmed: second
        [05/06/2026, 9:00:00 AM] André Müller: third
        """
        let doc = try await parse(ambiguous, "chat.txt")
        #expect(doc.blocks.filter { $0.kind == .discussionMessage }
                    .allSatisfy { $0.attributes["timestamp"] == nil })
        #expect(doc.warnings.contains { $0.code == "chatexport.ambiguous_date_order" })
        // Sequence is still evidence, so the ORDER must survive the missing dates.
        let bodies = messages(doc)
        #expect(bodies.count == 3)
        #expect(bodies[0].contains("first"))
        #expect(bodies[1].contains("second"))
        #expect(bodies[2].contains("third"))
    }

    // MARK: - Signal and Slack

    @Test("Signal's dash-separated ISO stamp parses to a real time, not midnight")
    func signalTimestampParses() async throws {
        // Signal writes no comma between date and time; a decomposer that assumed
        // one produced 00:00 for every message.
        let signal = """
        2026-03-14 09:12:34 - André Müller: Did you sign?
        2026-03-14 09:13:00 - Riyaz Ahmed: Yes.
        2026-03-14 09:14:00 - André Müller: Good.
        """
        let doc = try await parse(signal, "signal-export.txt")
        let block = try #require(doc.blocks.first { $0.rawText.contains("Did you sign") })
        #expect(attribute(block, "timestamp") == "2026-03-14T09:12:34Z")
        #expect(attribute(block, "platform") == "Signal")
    }

    @Test("Slack's bracketed ISO stamp with AM/PM parses correctly")
    func slackTimestampParses() async throws {
        let slack = """
        [2026-03-14, 09:12 AM] alice: standup in 5
        [2026-03-14, 01:30 PM] bob: pushed the fix
        [2026-03-14, 02:00 PM] alice: thanks
        """
        let doc = try await parse(slack, "slack-export-general.txt")
        let afternoon = try #require(doc.blocks.first { $0.rawText.contains("pushed the fix") })
        // 01:30 PM must be 13:30, not 01:30.
        #expect(attribute(afternoon, "timestamp") == "2026-03-14T13:30:00Z")
        #expect(attribute(afternoon, "platform") == "Slack")
    }

    // MARK: - Records, attribution, threads

    @Test("Every message carries its real sender as the author")
    func realSendersBecomeAuthors() async throws {
        // The gap this closes: senders used to exist only as characters in a blob.
        let doc = try await parse(whatsappExport, "chat.txt")
        let handles = doc.blocks
            .filter { $0.kind == .discussionMessage }
            .compactMap { attribute($0, "authorHandle") }
        #expect(Set(handles) == ["André Müller", "Riyaz Ahmed"])
    }

    @Test("A media placeholder is kept — it is evidence a message existed")
    func mediaPlaceholderKept() async throws {
        let doc = try await parse(whatsappExport, "chat.txt")
        #expect(messages(doc).contains { $0.contains("<Media omitted>") })
    }

    @Test("The thread is named after the other party from the export filename")
    func threadTitleFromFilename() async throws {
        let doc = try await parse(whatsappExport, "WhatsApp Chat with André Müller.txt")
        let head = try #require(doc.blocks.first { $0.kind == .sectionHeading })
        #expect(head.rawText.contains("André Müller"))
        // WhatsApp's generic "_chat.txt" gets an honest fallback, not a blank name.
        #expect(TextChatExportMapper.threadTitle(filename: "_chat.txt", shape: .whatsapp)
                == "WhatsApp chat")
    }

    @Test("Record ids are sequence-numbered and zero-padded so order is lexical")
    func recordIDsPreserveOrder() async throws {
        // With no dates resolvable, sorting falls back to record id — so the id
        // must sort chronologically or the conversation is reordered.
        let doc = try await parse(whatsappExport, "chat.txt")
        let ids = doc.blocks
            .filter { $0.kind == .discussionMessage }
            .compactMap { attribute($0, "recordID") }
        #expect(ids == ids.sorted())
        #expect(ids.count == 5)
    }

    @Test("A file that matches no chat shape is not claimed")
    func nonChatTextIsUnclaimed() {
        let data = Data("just some notes\nabout a thing\nnothing timestamped\n".utf8)
        let claimants = DiscussionExportRegistry.standard.allMappers.filter {
            $0.claims(filename: "notes.txt", sample: data)
        }
        #expect(claimants.isEmpty)
    }

    // MARK: - The feature gate must stay closed

    @Test("chatExport stays preserved-only while its feature flag is off")
    func gateStaysClosedWhenFlagIsOff() throws {
        // The discussion parser now supports .chatExport, which would otherwise
        // let the type activate through the structural text-fallback and silently
        // open an opt-in gate.
        let off = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        #expect(try off.resolve(.chatExport) is PreservedOnlyPlugin)

        let on = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR(), chatExportEnabled: true)
        let plugin = try on.resolve(.chatExport)
        #expect(plugin is ExistingParserPluginAdapter)
        #expect(plugin.capabilities.producesStructure)   // and now yields records
    }

    @Test("The other opt-in adapters stay gated the same way")
    func otherGatesStayClosed() throws {
        let off = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        for type in [SourceType.imessage, .safariHistory, .chromeHistory] {
            #expect(try off.resolve(type) is PreservedOnlyPlugin, "\(type.rawValue) is not gated")
        }
    }

    @Test("The loader turns a chat export into one thread object with records")
    func loaderProducesThreadObject() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("WhatsApp Chat with André Müller.txt")
        try Data(whatsappExport.utf8).write(to: url)

        let objects = try await DiscussionExportLoader().ingestMany(fileAt: url, type: .chatExport)
        #expect(objects.count == 1)
        #expect(objects[0].content.contains("André Müller"))
        #expect(objects[0].content.contains("2026-03-14T09:13:01Z"))
        if case .int(let count)? = objects[0].metadata["messageCount"]?.value {
            #expect(count == 5)
        } else {
            Issue.record("thread object is missing messageCount")
        }
    }
}

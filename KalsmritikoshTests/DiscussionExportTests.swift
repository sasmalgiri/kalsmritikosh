//
//  DiscussionExportTests.swift
//  KalsmritikoshTests
//
//  DISC-1 — proves the discussion lane on synthetic exports shaped like the real
//  Google Takeout artifacts. The cases are the ones that decide whether a forum
//  or comment export is usable evidence: an author, a time, a thread, and a reply
//  target on every utterance; conversations ordered as they happened; and honest
//  behaviour when a platform is unknown or an export is damaged.
//
//  Also pinned: detection must NOT claim an ordinary spreadsheet that happens to
//  be called comments.csv.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Discussion-platform exports (DISC-1)")
@MainActor
struct DiscussionExportTests {

    private let parser = DiscussionStructuralParser()

    /// A Takeout comments.csv with a top-level comment, a reply to it, the newer
    /// JSON-wrapped text form, and a body containing a comma, a newline and a
    /// doubled quote — all of which real comments contain and a naive split loses.
    private var commentsCSV: String {
        // Raw delimiters (#"""…"""#): the last field deliberately ends with an
        // escaped CSV quote followed by the field's own closing quote, which is
        // three consecutive quote marks — enough to terminate a plain Swift
        // multi-line literal early.
        #"""
        Comment ID,Channel ID,Comment Create Timestamp,Price,Parent Comment ID,Video ID,Comment Text
        Ug001,UCauthorA,2026-03-14T09:26:53.123Z,,,vid42,"First, and it's fine"
        Ug002,UCauthorB,2026-03-14T10:00:00Z,,Ug001,vid42,"{""takeoutSegments"":[{""text"":""Replying to that""}]}"
        Ug003,UCauthorA,2026-03-15T08:00:00Z,,,vid99,"Line one
        line two with a ""quote"""
        """#
    }

    private func parse(_ text: String, _ filename: String = "comments.csv") async throws -> ParsedDocument {
        try await parser.parse(data: Data(text.utf8), filename: filename, type: .discussionExport,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func messages(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .discussionMessage }.map(\.rawText)
    }
    private func threads(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .sectionHeading }.map(\.rawText)
    }

    // MARK: - Detection

    @Test("An export inside a Takeout tree is a discussion export")
    func detectsInsideExportTree() {
        let url = URL(fileURLWithPath:
            "/case/Takeout/YouTube and YouTube Music/comments/comments.csv")
        #expect(SourceType.detect(from: url) == .discussionExport)
    }

    @Test("An ordinary spreadsheet called comments.csv stays a CSV")
    func doesNotHijackOrdinaryCSV() {
        // The whole reason detection requires path context: claiming this would
        // silently route a user's own spreadsheet through a platform mapper.
        let url = URL(fileURLWithPath: "/Users/me/Documents/comments.csv")
        #expect(SourceType.detect(from: url) == .csv)
    }

    @Test("An unambiguous export filename needs no path context")
    func unambiguousNamesStandAlone() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/x/tweets.js")) == .discussionExport)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/x/direct-messages.js")) == .discussionExport)
    }

    @Test("Discussion exports are conversations, so they carry the chat category")
    func categoryIsChat() {
        #expect(SourceType.discussionExport.category == .chat)
    }

    // MARK: - Records

    @Test("Every comment becomes one message block with author, time and body")
    func commentsBecomeMessages() async throws {
        let doc = try await parse(commentsCSV)
        #expect(doc.extractionStatus == .complete)
        let lines = messages(doc)
        #expect(lines.count == 3)
        #expect(lines.contains { $0.contains("UCauthorA") && $0.contains("2026-03-14T09:26:53Z")
                                 && $0.contains("First, and it's fine") })
    }

    @Test("A reply names what it replies to — the exchange, not just the remarks")
    func repliesCarryTheirParent() async throws {
        let doc = try await parse(commentsCSV)
        let reply = try #require(doc.blocks.first {
            $0.kind == .discussionMessage && $0.rawText.contains("Replying to that")
        })
        #expect(reply.rawText.contains("replying to Ug001"))
        if case .string(let parent)? = reply.attributes["parentID"]?.value {
            #expect(parent == "Ug001")
        } else {
            Issue.record("reply is missing its parentID attribute")
        }
        if case .string(let kind)? = reply.attributes["kind"]?.value {
            #expect(kind == "reply")          // not "comment"
        }
    }

    @Test("Newer Takeout's JSON-wrapped comment text is unwrapped, not indexed raw")
    func jsonWrappedTextIsUnwrapped() async throws {
        let doc = try await parse(commentsCSV)
        let lines = messages(doc).joined(separator: "\n")
        #expect(lines.contains("Replying to that"))
        // Indexing the wrapper would put machine scaffolding into the evidence.
        #expect(!lines.contains("takeoutSegments"))
    }

    @Test("Commas, newlines and doubled quotes inside a comment survive intact")
    func csvQuotingIsHandled() async throws {
        let doc = try await parse(commentsCSV)
        let lines = messages(doc).joined(separator: "\n")
        #expect(lines.contains("First, and it's fine"))     // embedded comma
        #expect(lines.contains("line two with a \"quote\"")) // doubled quote unescaped
        #expect(lines.contains("Line one"))                  // embedded newline kept the row
        #expect(messages(doc).count == 3)                    // and did not split it into 4
    }

    @Test("Messages group into threads, and threads are ordered by when they started")
    func threadsGroupAndOrder() async throws {
        let doc = try await parse(commentsCSV)
        let heads = threads(doc)
        #expect(heads.count == 2)                            // vid42 and vid99
        #expect(heads[0].contains("vid42"))                  // started 03-14, so first
        #expect(heads[1].contains("vid99"))
        #expect(heads[0].contains("2 message(s)"))
        #expect(heads[0].contains("2026-03-14T09:26:53Z to 2026-03-14T10:00:00Z"))
    }

    @Test("A message is citable by platform, thread and record id")
    func messagesAreCitable() async throws {
        let doc = try await parse(commentsCSV)
        let block = try #require(doc.blocks.first {
            $0.kind == .discussionMessage && $0.rawText.contains("First,")
        })
        #expect(block.locator.sectionPath == ["YouTube", "YouTube video vid42", "Ug001"])
        if case .string(let link)? = block.attributes["permalink"]?.value {
            #expect(link == "https://www.youtube.com/watch?v=vid42&lc=Ug001")
        } else {
            Issue.record("message is missing its permalink")
        }
    }

    @Test("Two people's words never share a chunk")
    func messagesAreHardChunkBoundaries() {
        // If a discussion message were an ordinary paragraph, one chunk could mix
        // two authors and a quote would be attributed to the wrong person.
        #expect(EvidenceBlockKind.discussionMessage.isHardChunkBoundary)
    }

    // MARK: - Activity JSON

    @Test("Watch and search history map as activity, not as speech")
    func activityIsNotSpeech() async throws {
        let json = #"""
        [{"header":"YouTube","title":"Watched How to file a patent",
          "titleUrl":"https://www.youtube.com/watch?v=abc",
          "subtitles":[{"name":"PatentChannel"}],"time":"2026-03-14T09:00:00Z"},
         {"header":"YouTube","title":"Searched for patent filing fee",
          "time":"2026-03-14T09:05:00Z"}]
        """#
        let doc = try await parse(json, "watch-history.json")
        let lines = messages(doc)
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains("Watched How to file a patent")
                                 && $0.contains("channel: PatentChannel") })
        // Kept a distinct kind so "what did they say" cannot return a search box.
        let kinds = doc.blocks.compactMap { block -> String? in
            if case .string(let k)? = block.attributes["kind"]?.value { return k }
            return nil
        }
        #expect(Set(kinds) == ["activity"])
    }

    // MARK: - Honesty

    @Test("An export from an unsupported platform says so and names what is supported")
    func unknownPlatformIsNamed() async throws {
        let doc = try await parse("id,text\n1,hello\n", "messages.csv")
        #expect(doc.extractionStatus == .corrupt)
        #expect(messages(doc).isEmpty)
        let warning = try #require(doc.warnings.first { $0.code == "discussion.no_mapper" })
        #expect(warning.message.contains("YouTube"))     // names the platforms we DO support
    }

    @Test("Rows with no id or empty text are counted as skipped, not dropped quietly")
    func skippedRowsAreReported() async throws {
        let csv = """
        Comment ID,Channel ID,Comment Create Timestamp,Price,Parent Comment ID,Video ID,Comment Text
        Ug001,UCa,2026-03-14T09:26:53Z,,,vid42,Real comment
        ,UCb,2026-03-14T09:27:00Z,,,vid42,Orphan with no id
        Ug003,UCc,2026-03-14T09:28:00Z,,,vid42,
        """
        let doc = try await parse(csv)
        #expect(messages(doc).count == 1)
        #expect(doc.extractionStatus == .partial)
        let warning = try #require(doc.warnings.first { $0.code == "youtube.rows_skipped" })
        #expect(warning.message.contains("2 row(s)"))
    }

    @Test("An empty file is empty, not corrupt")
    func emptyIsEmpty() async throws {
        let doc = try await parse("")
        #expect(doc.extractionStatus == .empty)
        #expect(doc.warnings.contains { $0.code == "discussion.empty" })
    }

    @Test("A timestamp that is not RFC 3339 yields no date rather than a guessed one")
    func badTimestampIsNil() {
        #expect(YouTubeTakeoutMapper.parseTimestamp("14/03/2026") == nil)
        #expect(YouTubeTakeoutMapper.parseTimestamp("2026-03-14T09:26:53Z") != nil)
        #expect(YouTubeTakeoutMapper.parseTimestamp("2026-03-14T09:26:53.123Z") != nil)
    }

    @Test("Parsing is deterministic — same export, same block order")
    func deterministic() async throws {
        let first = try await parse(commentsCSV).blocks.map(\.rawText)
        let second = try await parse(commentsCSV).blocks.map(\.rawText)
        #expect(first == second)
    }

    // MARK: - Loader + registry wiring

    @Test("The loader yields one KnowledgeObject per thread, keeping exchanges whole")
    func loaderGroupsByThread() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("comments.csv")
        try Data(commentsCSV.utf8).write(to: url)

        let objects = try await DiscussionExportLoader().ingestMany(fileAt: url, type: .discussionExport)
        #expect(objects.count == 2)
        // The exchange stays in one object, so retrieval returns the conversation.
        let vid42 = try #require(objects.first { $0.content.contains("vid42") })
        #expect(vid42.content.contains("First,"))
        #expect(vid42.content.contains("Replying to that"))
        if case .int(let count)? = vid42.metadata["messageCount"]?.value {
            #expect(count == 2)
        } else {
            Issue.record("thread object is missing messageCount")
        }
    }

    @Test("The universal registry gives .discussionExport a real immediate plugin")
    func registryOwnsDiscussionExports() throws {
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.discussionExport)
        #expect(plugin.pluginID == "format.discussionExport")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }
}

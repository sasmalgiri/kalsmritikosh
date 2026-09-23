//
//  TelegramExportTests.swift
//  KalsmritikoshTests
//
//  DISC-5 — Telegram Desktop JSON exports. The two traps pinned here both lose
//  or corrupt evidence silently:
//    • `text` becomes an ARRAY when a message contains a link, mention or format
//      run. Read as a string it yields nothing, so precisely the messages that
//      contain links vanish.
//    • `date` carries NO time zone; `date_unixtime` beside it is absolute.
//      Parsing `date` as UTC shifts every message by the exporter's offset — up
//      to 14 hours, enough to reorder a day and cross midnight.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Telegram exports (DISC-5)")
@MainActor
struct TelegramExportTests {

    private let parser = DiscussionStructuralParser()

    private func parse(_ text: String, _ filename: String = "result.json") async throws -> ParsedDocument {
        try await parser.parse(data: Data(text.utf8), filename: filename, type: .discussionExport,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }
    private func messages(_ doc: ParsedDocument) -> [String] {
        doc.blocks.filter { $0.kind == .discussionMessage }.map(\.rawText)
    }
    private func attribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let v)? = block.attributes[key]?.value { return v }
        return nil
    }

    /// A full export: a named sender, a plain message, a message whose text is an
    /// ARRAY containing a link entity, a reply, and a service entry.
    private var fullExport: String {
        #"""
        {"about":"Telegram Desktop","chats":{"list":[
          {"name":"André Müller","type":"personal_chat","id":12345,"messages":[
            {"id":1,"type":"message","date":"2026-03-14T14:56:53","date_unixtime":"1773480413",
             "from":"André Müller","from_id":"user999","text":"the filing is in"},
            {"id":2,"type":"message","date":"2026-03-14T15:00:00","date_unixtime":"1773480600",
             "from":"Riyaz Ahmed","from_id":"user111","reply_to_message_id":1,
             "text":["see ",{"type":"link","text":"here","href":"https://example.com/notice"}," for the notice"]},
            {"id":3,"type":"service","date":"2026-03-14T15:05:00","date_unixtime":"1773480900",
             "actor":"André Müller","actor_id":"user999","action":"phone_call","duration_seconds":42}
          ]}
        ]}}
        """#
    }

    // MARK: - Shapes

    @Test("A full export's chat list is read")
    func fullExportParses() async throws {
        let doc = try await parse(fullExport)
        #expect(doc.extractionStatus == .complete)
        #expect(messages(doc).count == 3)
        #expect(messages(doc).contains { $0.contains("the filing is in") })
    }

    @Test("A single-chat export, where the chat object is the root, is also read")
    func singleChatExportParses() async throws {
        let single = #"""
        {"name":"André Müller","type":"personal_chat","id":12345,"messages":[
          {"id":1,"type":"message","date":"2026-03-14T14:56:53","date_unixtime":"1773480413",
           "from":"André Müller","from_id":"user999","text":"just us"}
        ]}
        """#
        let doc = try await parse(single)
        #expect(messages(doc).count == 1)
        #expect(messages(doc)[0].contains("just us"))
    }

    // MARK: - Trap 1: text is sometimes an array

    @Test("A message whose text is an ARRAY with a link entity is not lost")
    func textArrayIsFlattened() async throws {
        // Read as a plain string this message yields nothing and disappears —
        // and it is exactly the kind that carries a link.
        let doc = try await parse(fullExport)
        let line = try #require(messages(doc).first { $0.contains("for the notice") })
        #expect(line.contains("see here"))
        #expect(line.contains("https://example.com/notice"))
    }

    @Test("A link's href is kept when it differs from its display text")
    func linkHrefIsKept() {
        // "click here" as display text makes the href the only real evidence.
        let flattened = TelegramExportMapper.flatten([
            "click ", ["type": "link", "text": "here", "href": "https://example.com/x"]
        ])
        #expect(flattened == "click here <https://example.com/x>")
        // When display text IS the url, it is not duplicated.
        #expect(TelegramExportMapper.flatten([
            ["type": "link", "text": "https://example.com/x", "href": "https://example.com/x"]
        ]) == "https://example.com/x")
        // A plain string still works.
        #expect(TelegramExportMapper.flatten("plain") == "plain")
        #expect(TelegramExportMapper.flatten(nil).isEmpty)
    }

    // MARK: - Trap 2: local-only dates

    @Test("date_unixtime is used, not the zone-less local date beside it")
    func absoluteTimeWins() async throws {
        // The fixture's `date` reads 14:56:53 local while date_unixtime is
        // 09:26:53Z. Trusting `date` would shift the message by 5.5 hours.
        let doc = try await parse(fullExport)
        let block = try #require(doc.blocks.first { $0.rawText.contains("the filing is in") })
        #expect(attribute(block, "timestamp") == "2026-03-14T09:26:53Z")
        #expect(attribute(block, "timestamp") != "2026-03-14T14:56:53Z")
    }

    @Test("A message with ONLY a zone-less date is recorded undated, and says so")
    func localOnlyDateIsNotGuessed() async throws {
        // A wrong time is worse than a missing one on a timeline, so no zone is
        // assumed — but the omission is stated rather than passing silently.
        let noUnix = #"""
        {"name":"X","type":"personal_chat","id":1,"messages":[
          {"id":1,"type":"message","date":"2026-03-14T14:56:53","from":"A","from_id":"u1","text":"when?"}
        ]}
        """#
        let doc = try await parse(noUnix)
        let block = try #require(doc.blocks.first { $0.kind == .discussionMessage })
        #expect(block.attributes["timestamp"] == nil)
        #expect(doc.extractionStatus == .partial)
        let warning = try #require(doc.warnings.first { $0.code == "telegram.no_absolute_time" })
        #expect(warning.message.contains("1 message(s)"))
        #expect(warning.message.contains("without a timestamp")
                || warning.message.contains("WITHOUT a timestamp"))
    }

    // MARK: - Attribution and structure

    @Test("Telegram names real senders, so no account-holder marker is used")
    func realSenders() async throws {
        let doc = try await parse(fullExport)
        let handles = doc.blocks
            .filter { $0.kind == .discussionMessage }
            .compactMap { attribute($0, "authorHandle") }
        #expect(Set(handles) == ["André Müller", "Riyaz Ahmed"])
        #expect(!handles.contains { $0.contains("account holder") })
        // And the stable id travels too, for cross-platform unification.
        let block = try #require(doc.blocks.first { $0.rawText.contains("the filing is in") })
        #expect(attribute(block, "authorID") == "user999")
    }

    @Test("reply_to_message_id becomes a real reply relationship")
    func replyGraph() async throws {
        let doc = try await parse(fullExport)
        let reply = try #require(doc.blocks.first { $0.rawText.contains("for the notice") })
        #expect(attribute(reply, "kind") == "reply")
        #expect(attribute(reply, "parentID") == "1")
    }

    @Test("A service entry is activity, not speech")
    func serviceEntryIsActivity() async throws {
        // Otherwise "what did they say" answers with "André joined the group".
        let doc = try await parse(fullExport)
        let service = try #require(doc.blocks.first { $0.rawText.contains("phone call") })
        #expect(attribute(service, "kind") == "activity")
    }

    @Test("A media-only message keeps its attachment rather than vanishing")
    func mediaOnlyMessageKept() async throws {
        let media = #"""
        {"name":"X","type":"personal_chat","id":1,"messages":[
          {"id":1,"type":"message","date_unixtime":"1773480413","from":"A","from_id":"u1",
           "text":"","photo":"photos/photo_1@14-03-2026.jpg"},
          {"id":2,"type":"message","date_unixtime":"1773480500","from":"A","from_id":"u1",
           "text":"","location_information":{"latitude":22.57,"longitude":88.36}}
        ]}
        """#
        let doc = try await parse(media)
        #expect(messages(doc).contains { $0.contains("[photo: photos/photo_1@14-03-2026.jpg]") })
        #expect(messages(doc).contains { $0.contains("[location: 22.57, 88.36]") })
    }

    @Test("A group chat's type is stated in the thread title")
    func groupChatTypeIsStated() async throws {
        let group = #"""
        {"name":"Patent group","type":"private_group","id":77,"messages":[
          {"id":1,"type":"message","date_unixtime":"1773480413","from":"A","from_id":"u1","text":"hi"}
        ]}
        """#
        let doc = try await parse(group)
        let head = try #require(doc.blocks.first { $0.kind == .sectionHeading })
        #expect(head.rawText.contains("Patent group (private group)"))
    }

    @Test("Record ids are scoped to their chat so two chats cannot collide")
    func recordIDsAreChatScoped() async throws {
        // Telegram numbers messages from 1 within each chat, so an unscoped id
        // would make message 1 of chat A and chat B the same record.
        let doc = try await parse(fullExport)
        let ids = doc.blocks
            .filter { $0.kind == .discussionMessage }
            .compactMap { attribute($0, "recordID") }
        #expect(ids.allSatisfy { $0.hasPrefix("12345#") })
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Honesty and disjointness

    @Test("An export with no chats says so rather than looking empty-but-fine")
    func noChatsIsReported() async throws {
        let doc = try await parse(#"{"about":"Telegram Desktop","personal_information":{}}"#)
        #expect(messages(doc).isEmpty)
        #expect(doc.warnings.contains { $0.code == "telegram.no_chats" }
                || doc.warnings.contains { $0.code == "discussion.no_mapper" })
    }

    @Test("One artifact per platform, each claimed by exactly one mapper")
    func everyPlatformClaimIsDisjoint() {
        let samples: [(String, String)] = [
            ("youtube comments", "Comment ID,Channel ID,Comment Create Timestamp,Price,Parent Comment ID,Video ID,Comment Text\nUg1,UCa,2026-03-14T09:00:00Z,,,v1,hi"),
            ("discord json", #"[{"ID":"1","Timestamp":"2026-03-14 09:00:00","Contents":"hi","Attachments":""}]"#),
            ("reddit comments", "id,permalink,date,ip,subreddit,gildings,link,parent,body\nc1,p,2026-03-14 09:00:00 UTC,,s,0,t3_x,t3_x,hi"),
            ("x tweets", #"window.YTD.tweets.part0 = [{"tweet":{"id_str":"1","created_at":"Sat Mar 14 09:00:00 +0000 2026","full_text":"hi"}}]"#),
            ("meta thread", #"{"participants":[{"name":"A"}],"title":"t","messages":[{"sender_name":"A","timestamp_ms":1773480413000,"content":"hi"}]}"#),
            ("telegram full", #"{"chats":{"list":[{"name":"A","type":"personal_chat","id":1,"messages":[{"id":1,"type":"message","date_unixtime":"1773480413","from":"A","from_id":"u1","text":"hi"}]}]}}"#)
        ]
        let registry = DiscussionExportRegistry.standard
        for (label, text) in samples {
            let data = Data(text.utf8)
            let claimants = registry.allMappers.filter {
                $0.claims(filename: "probe", sample: data.prefix(DiscussionExportRegistry.sampleSize))
            }
            #expect(claimants.count == 1,
                    "\(label) claimed by \(claimants.count): \(claimants.map(\.platform))")
        }
    }

    @Test("The loader keeps a Telegram chat whole")
    func loaderGroupsChat() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("result.json")
        try Data(fullExport.utf8).write(to: url)

        let objects = try await DiscussionExportLoader().ingestMany(fileAt: url, type: .discussionExport)
        #expect(objects.count == 1)
        #expect(objects[0].content.contains("André Müller"))
        #expect(objects[0].content.contains("Riyaz Ahmed"))
    }
}

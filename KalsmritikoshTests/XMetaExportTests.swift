//
//  XMetaExportTests.swift
//  KalsmritikoshTests
//
//  DISC-4 — X account archives and Meta "Download Your Information" threads.
//
//  Four format traps are pinned here, each of which fails SILENTLY if unhandled,
//  which is the worst failure mode for evidence:
//    • X archive files are JavaScript, not JSON (`window.YTD.x.part0 = [...]`).
//    • X's legacy tweet date is `Tue Mar 14 09:26:53 +0000 2026`.
//    • Meta escapes UTF-8 bytes as Latin-1, so "é" arrives as "Ã©" — plausible
//      enough never to be questioned, while searching the real name fails.
//    • Meta's timestamp_ms is MILLISECONDS; reading it as seconds dates 2026
//      messages to 1970 and destroys every timeline.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("X + Meta exports (DISC-4)")
@MainActor
struct XMetaExportTests {

    private let parser = DiscussionStructuralParser()

    private func parse(_ text: String, _ filename: String) async throws -> ParsedDocument {
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

    // MARK: - X archive

    private var tweetsJS: String {
        #"""
        window.YTD.tweets.part0 = [
          {"tweet":{"id_str":"111","created_at":"Sat Mar 14 09:26:53 +0000 2026",
                    "full_text":"filing went through","conversation_id_str":"111"}},
          {"tweet":{"id_str":"222","created_at":"Sat Mar 14 10:00:00 +0000 2026",
                    "full_text":"disagree with that","in_reply_to_status_id_str":"111",
                    "in_reply_to_screen_name":"patentdesk","conversation_id_str":"111"}}
        ]
        """#
    }

    @Test("The window.YTD JavaScript assignment is stripped and the array is read")
    func javascriptWrapperIsStripped() async throws {
        // These files are .js, not .json — a plain JSON reader fails outright.
        let doc = try await parse(tweetsJS, "tweets.js")
        #expect(doc.extractionStatus == .complete)
        #expect(messages(doc).count == 2)
        #expect(messages(doc).contains { $0.contains("filing went through") })
    }

    @Test("X's legacy tweet date is read as a real date")
    func tweetDateParses() {
        #expect(XArchiveMapper.parseTweetDate("Sat Mar 14 09:26:53 +0000 2026")
                == Date(timeIntervalSince1970: 1_773_480_413))
        // Newer fields are ISO; both must work, and neither may guess.
        #expect(XArchiveMapper.parseTweetDate("2026-03-14T09:26:53.000Z")
                == Date(timeIntervalSince1970: 1_773_480_413))
        #expect(XArchiveMapper.parseTweetDate("14 March 2026") == nil)
    }

    @Test("A reply records its parent AND names who was replied to")
    func replyNamesTheOtherParty() async throws {
        // tweets.js holds only the account holder's own posts, but
        // in_reply_to_screen_name DOES name the other party — usually the
        // question being asked of this evidence.
        let doc = try await parse(tweetsJS, "tweets.js")
        let reply = try #require(doc.blocks.first { $0.rawText.contains("disagree with that") })
        #expect(attribute(reply, "kind") == "reply")
        #expect(attribute(reply, "parentID") == "111")
        #expect(reply.rawText.contains("@patentdesk"))
    }

    @Test("A whole X exchange groups under its conversation id")
    func tweetsGroupByConversation() async throws {
        let doc = try await parse(tweetsJS, "tweets.js")
        let heads = doc.blocks.filter { $0.kind == .sectionHeading }
        #expect(heads.count == 1)
        #expect(heads.first?.rawText.contains("2 message(s)") == true)
    }

    @Test("X direct messages carry the real numeric sender id, not a display name")
    func dmSenderIsAnID() async throws {
        let dms = #"""
        window.YTD.direct_messages.part0 = [
          {"dmConversation":{"conversationId":"111-222","messages":[
            {"messageCreate":{"id":"m1","senderId":"111","recipientId":"222",
                              "text":"call me","createdAt":"2026-03-14T09:26:53.000Z"}}
          ]}}
        ]
        """#
        let doc = try await parse(dms, "direct-messages.js")
        let block = try #require(doc.blocks.first { $0.kind == .discussionMessage })
        // An account id is not a name, so it belongs in authorID where the entity
        // layer can unify it — never presented as a handle.
        #expect(attribute(block, "authorID") == "111")
        #expect(block.attributes["authorHandle"] == nil)
        #expect(block.rawText.contains("to 222: call me"))
        #expect(attribute(block, "kind") == "directMessage")
    }

    // MARK: - Meta DYI

    /// A Messenger thread with a real named sender, an accented name written in
    /// Meta's Latin-1-escaped UTF-8, a photo-only message, and an unsent message.
    private var messengerThread: String {
        #"""
        {"participants":[{"name":"Riyaz Ahmed"},{"name":"AndrÃ© MÃ¼ller"}],
         "title":"AndrÃ© MÃ¼ller",
         "thread_path":"inbox/andremuller_123",
         "messages":[
           {"sender_name":"AndrÃ© MÃ¼ller","timestamp_ms":1773480413000,
            "content":"the cafÃ© on Tuesday"},
           {"sender_name":"Riyaz Ahmed","timestamp_ms":1773484013000,
            "photos":[{"uri":"messages/inbox/andremuller_123/photos/1.jpg"}]},
           {"sender_name":"Riyaz Ahmed","timestamp_ms":1773487613000}
         ]}
        """#
    }

    @Test("Meta's Latin-1-escaped UTF-8 is repaired in names and message text")
    func mojibakeIsRepaired() async throws {
        // Unrepaired, "AndrÃ© MÃ¼ller" looks plausibly foreign rather than broken,
        // so it would never be questioned — while a search for "André" fails.
        let doc = try await parse(messengerThread, "messages/inbox/andremuller_123/message_1.json")
        let lines = messages(doc).joined(separator: "\n")
        #expect(lines.contains("André Müller"))
        #expect(lines.contains("the café on Tuesday"))
        #expect(!lines.contains("Ã©"))
        #expect(!lines.contains("Ã¼"))
    }

    @Test("Correct text is never mangled by the mojibake repair")
    func repairIsSafeOnGoodText() {
        // The repair must be a no-op on text that was already right, or it becomes
        // a corruption of its own.
        #expect(MetaDownloadMapper.repair("Riyaz Ahmed") == "Riyaz Ahmed")
        #expect(MetaDownloadMapper.repair("already fine: é") == "already fine: é")
        #expect(MetaDownloadMapper.repair("") == nil)
        #expect(MetaDownloadMapper.repair(nil) == nil)
    }

    @Test("timestamp_ms is milliseconds — 2026 messages must not date to 1970")
    func millisecondTimestamps() async throws {
        let doc = try await parse(messengerThread, "messages/inbox/andremuller_123/message_1.json")
        let block = try #require(doc.blocks.first { $0.rawText.contains("café") })
        #expect(attribute(block, "timestamp") == "2026-03-14T09:26:53Z")
        // The failure this guards: /1000 omitted would render 1970-01-21.
        #expect(!(attribute(block, "timestamp") ?? "").hasPrefix("1970"))
    }

    @Test("Each Meta message is attributed to its REAL sender, not a marker")
    func metaHasRealAttribution() async throws {
        // This is what makes Meta threads the strongest artifact in the lane:
        // unlike Discord or Reddit's own-content exports, both sides are named.
        let doc = try await parse(messengerThread, "messages/inbox/andremuller_123/message_1.json")
        let senders = doc.blocks
            .filter { $0.kind == .discussionMessage }
            .compactMap { attribute($0, "authorHandle") }
        #expect(Set(senders) == ["André Müller", "Riyaz Ahmed"])
        #expect(!senders.contains { $0.contains("account holder") })
    }

    @Test("A photo-only message is kept; a genuinely unsent one is counted")
    func attachmentOnlyKeptUnsentCounted() async throws {
        let doc = try await parse(messengerThread, "messages/inbox/andremuller_123/message_1.json")
        // In a conversation a missing message changes what the surrounding ones
        // mean, so a payload-only message must survive.
        #expect(messages(doc).contains { $0.contains("[photo: ") && $0.contains("1.jpg") })
        #expect(messages(doc).count == 2)
        let warning = try #require(doc.warnings.first { $0.code == "meta.messages_skipped" })
        #expect(warning.message.contains("1 message(s)"))
    }

    @Test("Instagram and Messenger threads are labelled as different surfaces")
    func surfaceIsDistinguished() async throws {
        // The same person's Instagram and Messenger threads are different
        // evidence, so the platform label must say which.
        let messenger = try await parse(messengerThread, "messages/inbox/x/message_1.json")
        let instagram = try await parse(messengerThread,
            "your_instagram_activity/messages/inbox/x/message_1.json")
        let header: (ParsedDocument) -> String = { doc in
            doc.blocks.first { $0.kind == .documentHeader }?.rawText ?? ""
        }
        #expect(header(messenger).hasPrefix("Messenger export"))
        #expect(header(instagram).hasPrefix("Instagram export"))
    }

    @Test("A group thread states its participant count")
    func groupThreadNamesParticipantCount() async throws {
        let group = #"""
        {"participants":[{"name":"A"},{"name":"B"},{"name":"C"}],
         "title":"Project chat","thread_path":"inbox/project_1",
         "messages":[{"sender_name":"A","timestamp_ms":1773480413000,"content":"hi all"}]}
        """#
        let doc = try await parse(group, "messages/inbox/project_1/message_1.json")
        let head = try #require(doc.blocks.first { $0.kind == .sectionHeading })
        #expect(head.rawText.contains("Project chat (3 participants)"))
    }

    // MARK: - Cross-platform

    @Test("All five mappers stay disjoint — no artifact is double-claimed")
    func fiveMappersStayDisjoint() {
        let samples: [(String, String)] = [
            ("youtube comments", "Comment ID,Channel ID,Comment Create Timestamp,Price,Parent Comment ID,Video ID,Comment Text\nUg1,UCa,2026-03-14T09:00:00Z,,,v1,hi"),
            ("youtube activity", #"[{"header":"YouTube","title":"Watched x","time":"2026-03-14T09:00:00Z"}]"#),
            ("discord json", #"[{"ID":"1","Timestamp":"2026-03-14 09:00:00","Contents":"hi","Attachments":""}]"#),
            ("reddit comments", "id,permalink,date,ip,subreddit,gildings,link,parent,body\nc1,p,2026-03-14 09:00:00 UTC,,s,0,t3_x,t3_x,hi"),
            ("x tweets", #"window.YTD.tweets.part0 = [{"tweet":{"id_str":"1","created_at":"Sat Mar 14 09:00:00 +0000 2026","full_text":"hi"}}]"#),
            ("x dms", #"window.YTD.direct_messages.part0 = [{"dmConversation":{"conversationId":"a-b","messages":[]}}]"#),
            ("meta thread", #"{"participants":[{"name":"A"}],"title":"t","messages":[{"sender_name":"A","timestamp_ms":1773480413000,"content":"hi"}]}"#)
        ]
        let registry = DiscussionExportRegistry.standard
        #expect(registry.allMappers.count == 5)
        for (label, text) in samples {
            let data = Data(text.utf8)
            let claimants = registry.allMappers.filter {
                $0.claims(filename: "probe", sample: data.prefix(DiscussionExportRegistry.sampleSize))
            }
            #expect(claimants.count == 1,
                    "\(label) claimed by \(claimants.count): \(claimants.map(\.platform))")
        }
    }

    @Test("An ordinary JSON document is claimed by nobody")
    func ordinaryJSONUnclaimed() {
        let data = Data(#"{"name":"Alice","age":30}"#.utf8)
        let claimants = DiscussionExportRegistry.standard.allMappers.filter {
            $0.claims(filename: "person.json", sample: data)
        }
        #expect(claimants.isEmpty)
    }

    @Test("The loader keeps each Meta thread whole")
    func loaderGroupsMetaThread() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("message_1.json")
        try Data(messengerThread.utf8).write(to: url)

        let objects = try await DiscussionExportLoader().ingestMany(fileAt: url, type: .discussionExport)
        #expect(objects.count == 1)
        #expect(objects[0].content.contains("André Müller"))
        #expect(objects[0].content.contains("Riyaz Ahmed"))
    }
}

//
//  DiscordRedditExportTests.swift
//  KalsmritikoshTests
//
//  DISC-2 / DISC-3 — Discord packages and Reddit exports through the SAME parser
//  and loader as YouTube, which is the point of the DiscussionRecord model: these
//  commits add mappers, not machinery.
//
//  The two invariants that matter most here are about attribution, because both
//  formats make it easy to be wrong in a way an examiner cannot see:
//    • A Discord package and Reddit's comments/posts contain ONLY the requesting
//      account's own content. The other side of a conversation is not in the file.
//      Nothing may be attributed to a name the export never stated.
//    • Reddit's `parent` prefix decides whether something replied to a PERSON
//      (t1_) or to a THREAD (t3_). Treating t3_ as a reply would invent a
//      relationship between two people.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Discord + Reddit exports (DISC-2 / DISC-3)")
@MainActor
struct DiscordRedditExportTests {

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

    // MARK: - Discord

    private var discordJSON: String {
        #"""
        [{"ID":"1111","Timestamp":"2026-03-14 09:26:53","Contents":"see the filing","Attachments":""},
         {"ID":"2222","Timestamp":"2026-03-14 09:30:00","Contents":"","Attachments":"https://cdn.discordapp.com/a/b/spec.pdf"},
         {"ID":"3333","Timestamp":"2026-03-14 09:31:00","Contents":"","Attachments":""}]
        """#
    }

    @Test("Discord messages.json becomes one message block each")
    func discordJSONParses() async throws {
        let doc = try await parse(discordJSON, "messages/c987654321/messages.json")
        let lines = messages(doc)
        // Third entry has neither text nor attachment, so it is skipped and counted.
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains("see the filing") })
        #expect(doc.warnings.contains { $0.code == "discord.rows_skipped" })
    }

    @Test("A Discord message with no text but an attachment is still evidence")
    func attachmentOnlyMessageIsKept() async throws {
        // Dropping these would silently lose every image, document and file the
        // account ever sent — often the most important messages in a case.
        let doc = try await parse(discordJSON, "messages/c987654321/messages.json")
        #expect(messages(doc).contains { $0.contains("[attachment: ") && $0.contains("spec.pdf") })
    }

    @Test("Discord's space-separated UTC timestamp is read as a real date")
    func discordTimestampParses() {
        let date = DiscordPackageMapper.parseTimestamp("2026-03-14 09:26:53")
        #expect(date == Date(timeIntervalSince1970: 1_773_480_413))
        // Newer packages use RFC 3339; both must work.
        #expect(DiscordPackageMapper.parseTimestamp("2026-03-14T09:26:53Z") == date)
        // And a format we do not recognize yields nil, never a guessed date.
        #expect(DiscordPackageMapper.parseTimestamp("14 March 2026") == nil)
    }

    @Test("The channel id comes from the directory, and is absent when the path lacks one")
    func discordChannelIDFromPath() {
        #expect(DiscordPackageMapper.channelID(fromPath: "messages/c987654321/messages.json") == "987654321")
        // No invented thread id when the path carries no channel directory.
        #expect(DiscordPackageMapper.channelID(fromPath: "messages.json") == nil)
        #expect(DiscordPackageMapper.channelID(fromPath: "messages/chat/messages.json") == nil)
    }

    @Test("Discord messages are attributed to the account holder, never to a guessed name")
    func discordAttributionIsHonest() async throws {
        // A Discord package holds only the requesting account's own messages.
        let doc = try await parse(discordJSON, "messages/c987654321/messages.json")
        let block = try #require(doc.blocks.first { $0.kind == .discussionMessage })
        #expect(block.rawText.hasPrefix(DiscordPackageMapper.accountHolder))
        // Not marked as a reply: the package records no parent message id, so any
        // reply relationship would be an invention.
        #expect(attribute(block, "kind") == "post")
        #expect(block.attributes["parentID"] == nil)
    }

    @Test("Discord's newer messages.csv form yields the same records as the JSON form")
    func discordCSVMatchesJSON() async throws {
        let csv = #"""
        ID,Timestamp,Contents,Attachments
        1111,2026-03-14 09:26:53,see the filing,
        2222,2026-03-14 09:30:00,,https://cdn.discordapp.com/a/b/spec.pdf
        """#
        let fromCSV = messages(try await parse(csv, "messages/c987654321/messages.csv")).sorted()
        let fromJSON = messages(try await parse(discordJSON, "messages/c987654321/messages.json")).sorted()
        #expect(fromCSV == fromJSON)
    }

    @Test("channel.json is metadata, so no mapper claims it as messages")
    func channelJSONIsNotClaimed() async throws {
        // Claiming it would yield an export with zero records, which reads as an
        // empty conversation rather than "this file is not a message log".
        let channel = #"""
        {"id":"987654321","type":1,"recipients":["111","222"]}
        """#
        let doc = try await parse(channel, "messages/c987654321/channel.json")
        #expect(doc.extractionStatus == .corrupt)
        #expect(doc.warnings.contains { $0.code == "discussion.no_mapper" })
    }

    // MARK: - Reddit

    private var redditComments: String {
        #"""
        id,permalink,date,ip,subreddit,gildings,link,parent,body
        c111,https://reddit.com/r/patents/c111,2026-03-14 09:26:53 UTC,,patents,0,t3_post1,t3_post1,"Top-level take"
        c222,https://reddit.com/r/patents/c222,2026-03-14 10:00:00 UTC,,patents,0,t3_post1,t1_c111,"Replying to that person"
        """#
    }

    @Test("Reddit comments.csv parses, and does NOT collide with YouTube's comments.csv")
    func redditCommentsParse() async throws {
        // Both platforms ship a file called comments.csv; only content can tell
        // them apart, which is why mappers claim on content.
        let doc = try await parse(redditComments, "comments.csv")
        #expect(doc.extractionStatus == .complete)
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.hasPrefix("Reddit export"))
        #expect(messages(doc).count == 2)
    }

    @Test("t1_ is a reply to a person; t3_ is a top-level comment on the thread")
    func redditParentPrefixDecidesReply() async throws {
        let doc = try await parse(redditComments, "comments.csv")
        let top = try #require(doc.blocks.first { $0.rawText.contains("Top-level take") })
        let reply = try #require(doc.blocks.first { $0.rawText.contains("Replying to that person") })

        // t3_ parent = the post itself. Calling this a reply would invent a
        // relationship between two people.
        #expect(attribute(top, "kind") == "comment")
        #expect(top.attributes["parentID"] == nil)

        #expect(attribute(reply, "kind") == "reply")
        #expect(attribute(reply, "parentID") == "t1_c111")
        #expect(reply.rawText.contains("replying to t1_c111"))
    }

    @Test("Reddit's ' UTC'-suffixed timestamp is read as a real date")
    func redditTimestampParses() {
        #expect(RedditExportMapper.parseTimestamp("2026-03-14 09:26:53 UTC")
                == Date(timeIntervalSince1970: 1_773_480_413))
        #expect(RedditExportMapper.parseTimestamp("2026-03-14T09:26:53Z")
                == Date(timeIntervalSince1970: 1_773_480_413))
        #expect(RedditExportMapper.parseTimestamp("not a date") == nil)
    }

    @Test("A link post with no body keeps its title and URL as the evidence")
    func redditLinkPostKeepsTitle() async throws {
        // A link post has an empty body. Requiring a body would drop the post
        // entirely, losing both what was posted and where it pointed.
        let posts = #"""
        id,permalink,date,ip,subreddit,gildings,title,url,body
        p111,https://reddit.com/r/patents/p111,2026-03-14 09:00:00 UTC,,patents,0,Filing deadline moved,https://example.com/notice,
        """#
        let doc = try await parse(posts, "posts.csv")
        let line = try #require(messages(doc).first)
        #expect(line.contains("Filing deadline moved"))
        #expect(line.contains("https://example.com/notice"))
    }

    @Test("A Reddit private message names its real sender and its recipient")
    func redditMessagesNameBothParties() async throws {
        // messages.csv is the ONE Reddit artifact that states the other party, so
        // it must use the real `from` rather than the account-holder marker.
        let dms = #"""
        id,permalink,thread_id,date,ip,from,to,subject,body
        m111,https://reddit.com/message/m111,th1,2026-03-14 09:00:00 UTC,,riyaz_a,mod_team,Appeal,"Please reconsider"
        """#
        let doc = try await parse(dms, "messages.csv")
        let block = try #require(doc.blocks.first { $0.kind == .discussionMessage })
        #expect(block.rawText.hasPrefix("riyaz_a"))
        #expect(!block.rawText.contains(RedditExportMapper.accountHolder))
        #expect(block.rawText.contains("to mod_team"))     // recipient is part of the meaning
        #expect(block.rawText.contains("Subject: Appeal"))
        #expect(attribute(block, "kind") == "directMessage")
    }

    @Test("Reddit comments and posts are attributed to the account holder")
    func redditOwnContentAttribution() async throws {
        let doc = try await parse(redditComments, "comments.csv")
        for line in messages(doc) {
            #expect(line.hasPrefix(RedditExportMapper.accountHolder))
        }
    }

    @Test("Reddit comments on one post group into a single thread")
    func redditCommentsGroupByPost() async throws {
        let doc = try await parse(redditComments, "comments.csv")
        let heads = doc.blocks.filter { $0.kind == .sectionHeading }
        #expect(heads.count == 1)                       // both comments are on t3_post1
        #expect(heads.first?.rawText.contains("2 message(s)") == true)
        #expect(heads.first?.rawText.contains("r/patents") == true)
    }

    // MARK: - Cross-platform invariants

    @Test("No export is claimed by more than one mapper")
    func mapperClaimsAreDisjoint() {
        // With three mappers reading overlapping filenames, an accidental double
        // claim would route a file to whichever happened to be registered first.
        let samples: [(String, String)] = [
            ("youtube comments", "Comment ID,Channel ID,Comment Create Timestamp,Price,Parent Comment ID,Video ID,Comment Text\nUg1,UCa,2026-03-14T09:00:00Z,,,v1,hi"),
            ("youtube activity", #"[{"header":"YouTube","title":"Watched x","time":"2026-03-14T09:00:00Z"}]"#),
            ("discord json", #"[{"ID":"1","Timestamp":"2026-03-14 09:00:00","Contents":"hi","Attachments":""}]"#),
            ("discord csv", "ID,Timestamp,Contents,Attachments\n1,2026-03-14 09:00:00,hi,"),
            ("reddit comments", "id,permalink,date,ip,subreddit,gildings,link,parent,body\nc1,p,2026-03-14 09:00:00 UTC,,s,0,t3_x,t3_x,hi"),
            ("reddit posts", "id,permalink,date,ip,subreddit,gildings,title,url,body\np1,p,2026-03-14 09:00:00 UTC,,s,0,t,u,b"),
            ("reddit messages", "id,permalink,thread_id,date,ip,from,to,subject,body\nm1,p,t,2026-03-14 09:00:00 UTC,,a,b,s,hi")
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

    @Test("An ordinary CSV is claimed by nobody rather than mis-routed")
    func ordinaryCSVIsUnclaimed() {
        let data = Data("name,age\nAlice,30\n".utf8)
        let claimants = DiscussionExportRegistry.standard.allMappers.filter {
            $0.claims(filename: "people.csv", sample: data)
        }
        #expect(claimants.isEmpty)
    }

    @Test("The unknown-platform warning names all three supported platforms")
    func unknownPlatformNamesAll() async throws {
        let doc = try await parse("alpha,beta\n1,2\n", "messages.csv")
        let warning = try #require(doc.warnings.first { $0.code == "discussion.no_mapper" })
        for platform in ["YouTube", "Discord", "Reddit"] {
            #expect(warning.message.contains(platform))
        }
    }

    @Test("The loader groups each platform's threads the same way")
    func loaderWorksForBothPlatforms() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc23-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reddit = dir.appendingPathComponent("comments.csv")
        try Data(redditComments.utf8).write(to: reddit)
        let redditObjects = try await DiscussionExportLoader()
            .ingestMany(fileAt: reddit, type: .discussionExport)
        #expect(redditObjects.count == 1)                       // one post thread
        #expect(redditObjects[0].content.contains("Replying to that person"))

        let discord = dir.appendingPathComponent("messages.json")
        try Data(discordJSON.utf8).write(to: discord)
        let discordObjects = try await DiscussionExportLoader()
            .ingestMany(fileAt: discord, type: .discussionExport)
        #expect(discordObjects.count == 1)                      // one channel
        #expect(discordObjects[0].content.contains("see the filing"))
    }
}

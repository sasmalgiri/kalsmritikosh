//
//  DiscussionForumAndTwitchTests.swift
//  KalsmritikoshTests
//
//  DISC-7 — Twitch VOD chat and saved forum threads, the last two platforms in
//  the discussion lane.
//
//  The load-bearing test is `aPostIsNeverAttributedToThePreviousPoster`. Cutting
//  HTML into posts and then hunting for the nearest author name is exactly how a
//  body ends up credited to the wrong person — the same defect DISC-6 found in
//  chat exports, where system notices were appended to the previous speaker's
//  message. In a forum thread that error would put words in someone's mouth.
//
//  Second: `aPageWithNoEngineMarkerIsNotClaimed`. Forum themes vary without
//  limit, so a generic "find the repeated blocks" heuristic would attribute text
//  to people on pages that are not forums. Declining leaves the file to the HTML
//  document lane, which is a working parse rather than a gap.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Twitch chat and saved forum threads (DISC-7)")
struct DiscussionForumAndTwitchTests {

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    // MARK: - Twitch VOD chat

    private let twitchJSON = #"""
    {"video":{"id":"2145678901","title":"late stream — Q&A"},
     "comments":[
       {"_id":"c1","created_at":"2026-03-12T02:14:07.123Z","content_offset_seconds":3714.2,
        "commenter":{"display_name":"RiyazA","name":"riyaza","_id":"88123"},
        "message":{"body":"the drive is in the depot locker"}},
       {"_id":"c2","created_at":"2026-03-12T02:15:00Z","content_offset_seconds":3767,
        "commenter":{"display_name":"anita_k","name":"anita_k","_id":"90021"},
        "message":{"body":"which locker"}},
       {"_id":"c3","content_offset_seconds":3800,
        "commenter":{"display_name":"modbot","name":"modbot","_id":"1"},
        "message":{"body":"message deleted by a moderator"}}
     ]}
    """#

    @Test("A Twitch chat export maps to per-message records with real authors")
    func twitchMapsEveryMessage() throws {
        let mapper = TwitchChatMapper()
        let data = Data(twitchJSON.utf8)
        #expect(mapper.claims(filename: "v2145678901.json", sample: data))

        let export = mapper.map(data: data, filename: "v2145678901.json")
        #expect(export.records.count == 3)
        let first = export.records[0]
        // A public channel names every participant, so attribution is real for
        // every record — no account-holder marker needed.
        #expect(first.authorHandle == "RiyazA")
        #expect(first.authorID == "88123")
        // Twitch writes FRACTIONAL seconds and the mapper keeps them, so this
        // cannot be an equality check against a whole second — nor against a
        // reconstructed fraction, which is not bit-identical to the parsed one.
        let expected = date("2026-03-12T02:14:07Z")
        let actual = try #require(first.timestamp)
        #expect(abs(actual.timeIntervalSince(expected) - 0.123) < 0.001)
        #expect(first.threadID == "2145678901")
        #expect(first.threadTitle == "late stream — Q&A")
        #expect(first.kind == .liveChat)
        #expect(export.records[1].authorHandle == "anita_k")
    }

    @Test("The video offset rides in the body as a timecode")
    func offsetBecomesACitableTimecode() {
        // The offset is the only thing that places a message inside the
        // recording, so it has to survive into the text an answer quotes.
        let export = TwitchChatMapper().map(data: Data(twitchJSON.utf8), filename: "v.json")
        #expect(export.records[0].body == "[1:01:54] the drive is in the depot locker")
        #expect(export.records[0].permalink == "https://www.twitch.tv/videos/2145678901?t=3714s")
        #expect(TwitchChatMapper.timecode(3714.2) == "1:01:54")
        #expect(TwitchChatMapper.timecode(65) == "1:05")
    }

    @Test("A message with only an offset is reported as having no absolute time")
    func offsetIsNotADate() throws {
        // A position in a video is not a wall-clock time. Treating it as one
        // would date a 2026 message to 1970 plus an hour.
        let export = TwitchChatMapper().map(data: Data(twitchJSON.utf8), filename: "v.json")
        let modbot = try #require(export.records.first { $0.authorHandle == "modbot" })
        #expect(modbot.timestamp == nil)
        #expect(modbot.body.hasPrefix("[1:03:20]"))
        #expect(export.warnings.contains { $0.code == "twitch.offset_only" })
    }

    @Test("Twitch claims by content, not by filename")
    func twitchClaimsByContent() {
        let mapper = TwitchChatMapper()
        // Renamed evidence is still recognized …
        #expect(mapper.claims(filename: "evidence-07.bin", sample: Data(twitchJSON.utf8)))
        // … and an ordinary JSON file is not hijacked.
        #expect(!mapper.claims(filename: "chat.json",
                               sample: Data(#"{"items":[{"text":"hello"}]}"#.utf8)))
    }

    @Test("A Twitch export with no messages says so rather than failing")
    func twitchEmptyIsHonest() {
        let export = TwitchChatMapper().map(
            data: Data(#"{"comments":[],"video":{"id":"1"}}"#.utf8), filename: "v.json")
        #expect(export.records.isEmpty)
        #expect(export.warnings.contains { $0.code == "twitch.no_messages" })
    }

    // MARK: - Saved forum threads

    /// A phpBB thread: two posts, the second with no author name in its block.
    private let phpBBThread = #"""
    <!DOCTYPE html><html><head><title>Depot logistics - Site Forum</title></head><body>
    <div class="post">
      <dl class="postprofile"><dt><a href="/u/12" class="username">riyaz</a></dt></dl>
      <div class="postbody"><p class="author"><time datetime="2026-03-10T08:15:00Z">10 Mar 2026</time></p>
      <div class="content">The shipment clears customs on the 14th.</div></div>
    </div>
    <div class="post">
      <dl class="postprofile"><dt>Guest</dt></dl>
      <div class="postbody"><p class="author"><time datetime="2026-03-10T09:02:00Z">10 Mar 2026</time></p>
      <div class="content">Confirmed, I will collect it myself.</div></div>
    </div>
    </body></html>
    """#

    @Test("A saved phpBB thread maps to per-post records with author and date")
    func phpBBThreadMaps() {
        let mapper = ForumThreadMapper()
        let data = Data(phpBBThread.utf8)
        #expect(mapper.claims(filename: "thread-4412.html", sample: data))

        let export = mapper.map(data: data, filename: "thread-4412.html")
        #expect(export.records.count == 2)
        #expect(export.platform.contains("phpBB"))
        let first = export.records[0]
        #expect(first.authorHandle == "riyaz")
        #expect(first.timestamp == date("2026-03-10T08:15:00Z"))
        #expect(first.body.contains("clears customs on the 14th"))
        #expect(first.threadTitle == "Depot logistics - Site Forum")
        #expect(first.kind == .post)
        #expect(export.records[1].kind == .reply)
        #expect(export.records[1].body.contains("collect it myself"))
    }

    // MARK: - THE attribution defect

    @Test("A post is NEVER attributed to the previous poster")
    func aPostIsNeverAttributedToThePreviousPoster() throws {
        // The second post's block carries no username element. A nearest-name
        // search would credit it to "riyaz" — putting words in the mouth of a
        // named person, which is the worst failure available here.
        let export = ForumThreadMapper().map(data: Data(phpBBThread.utf8), filename: "t.html")
        #expect(export.records.count == 2)
        #expect(export.records[0].authorHandle == "riyaz")
        #expect(export.records[1].authorHandle == nil)
        #expect(export.records[1].citedAuthor == "unattributed")
        #expect(export.warnings.contains { $0.code == "forum.unattributed_posts" })
        let warning = try #require(export.warnings.first { $0.code == "forum.unattributed_posts" })
        #expect(warning.message.contains("NOT attributed to the previous poster"))
    }

    @Test("A post's body cannot come from a neighbouring post's block")
    func bodiesDoNotBleedBetweenPosts() {
        let export = ForumThreadMapper().map(data: Data(phpBBThread.utf8), filename: "t.html")
        #expect(!export.records[0].body.contains("collect it myself"))
        #expect(!export.records[1].body.contains("clears customs"))
    }

    // MARK: - THE refusal

    @Test("A page with no forum-engine marker is NOT claimed")
    func aPageWithNoEngineMarkerIsNotClaimed() throws {
        // It stays an HTML document — a working parse, not a gap. Claiming it
        // would attribute text to people on a page that is not a forum.
        let blog = #"""
        <!DOCTYPE html><html><head><title>A blog</title></head><body>
        <article><h1>Notes</h1><p>Some prose about a forum I visited.</p></article>
        </body></html>
        """#
        let mapper = ForumThreadMapper()
        #expect(!mapper.claims(filename: "page.html", sample: Data(blog.utf8)))
        let export = mapper.map(data: Data(blog.utf8), filename: "page.html")
        #expect(export.records.isEmpty)
        #expect(export.warnings.contains { $0.code == "forum.no_engine" })
        #expect(try #require(export.warnings.first).message.contains("still ingested as an HTML document"))
    }

    @Test("Naming the software in prose is not enough to claim a page")
    func mentioningTheSoftwareIsNotAForum() {
        let page = #"""
        <html><head><title>Choosing forum software</title></head>
        <body><p>We compared phpBB, vBulletin and Discourse last year.</p></body></html>
        """#
        #expect(!ForumThreadMapper().claims(filename: "review.html", sample: Data(page.utf8)))
    }

    // MARK: - Other engines and honest states

    @Test("XenForo and Discourse markers are recognized")
    func otherEnginesAreRecognized() throws {
        let xenForo = #"""
        <html><body><article class="message" data-author="anita_k">
        <time datetime="2026-03-11T12:00:00Z">yesterday</time>
        <div class="message-body">Bring the second drive.</div></article></body></html>
        """#
        let export = ForumThreadMapper().map(data: Data(xenForo.utf8), filename: "x.html")
        #expect(export.platform.contains("XenForo"))
        #expect(export.records.first?.authorHandle == "anita_k")
        #expect(export.records.first?.timestamp == date("2026-03-11T12:00:00Z"))

        let discourse = #"""
        <html><body><div class="topic-post" data-post-number="1">
        <span itemprop="author">riyaz</span>
        <time datetime="2026-03-12T09:26:53Z">3h</time>
        <div class="cooked">Locker 14.</div></div></body></html>
        """#
        let second = ForumThreadMapper().map(data: Data(discourse.utf8), filename: "d.html")
        #expect(second.platform.contains("Discourse"))
        #expect(second.records.first?.authorHandle == "riyaz")
    }

    @Test("A relative date like \"2 hours ago\" is NOT converted into a timestamp")
    func relativeDatesAreNotInvented() throws {
        // It is relative to when the page was SAVED, which the page does not
        // state. Converting it would manufacture a time.
        let page = #"""
        <html><body><div class="post"><a class="username">riyaz</a>
        <div class="postbody"><span class="date">2 hours ago</span>
        <div class="content">On my way.</div></div></div></body></html>
        """#
        let export = ForumThreadMapper().map(data: Data(page.utf8), filename: "t.html")
        let record = try #require(export.records.first)
        #expect(record.timestamp == nil)
        #expect(record.body.contains("On my way."))
        #expect(export.warnings.contains { $0.code == "forum.undated_posts" })
        let warning = try #require(export.warnings.first { $0.code == "forum.undated_posts" })
        #expect(warning.message.contains("relative to when the page was saved"))
    }

    @Test("Script and style contents do not become post text")
    func scriptsAreNotPostText() throws {
        let page = #"""
        <html><body><div class="post"><a class="username">riyaz</a>
        <div class="postbody"><time datetime="2026-03-12T09:00:00Z">now</time>
        <script>var track = "analytics";</script>
        <style>.x{color:red}</style>
        <div class="content">Real words only.</div></div></div></body></html>
        """#
        let export = ForumThreadMapper().map(data: Data(page.utf8), filename: "t.html")
        let body = try #require(export.records.first?.body)
        #expect(body.contains("Real words only."))
        #expect(!body.contains("analytics"))
        #expect(!body.contains("color:red"))
    }

    @Test("HTML entities are resolved in bodies and author names")
    func entitiesAreResolved() throws {
        let page = #"""
        <html><body><div class="post"><a class="username">O&#39;Brien</a>
        <div class="postbody"><time datetime="2026-03-12T09:00:00Z">now</time>
        <div class="content">Cost is &lt;&pound;500 &amp; falling</div></div></div></body></html>
        """#
        let export = ForumThreadMapper().map(data: Data(page.utf8), filename: "t.html")
        let record = try #require(export.records.first)
        #expect(record.authorHandle == "O'Brien")
        #expect(record.body.contains("<"))
        #expect(record.body.contains("&"))
    }

    @Test("Mapping is deterministic")
    func deterministic() {
        let data = Data(phpBBThread.utf8)
        let first = ForumThreadMapper().map(data: data, filename: "t.html")
        let second = ForumThreadMapper().map(data: data, filename: "t.html")
        #expect(first.records.map(\.body) == second.records.map(\.body))
        #expect(first.records.map(\.recordID) == second.records.map(\.recordID))
    }

    // MARK: - Registry

    @Test("Both new platforms are registered, and no export is claimed twice")
    func registryIsDisjoint() {
        let registry = DiscussionExportRegistry.standard
        let names = registry.allMappers.map(\.platform)
        #expect(names.contains("Twitch"))
        #expect(names.contains("Forum"))

        // Disjointness is what makes registration order a tie-break rather than
        // a silent decision: each sample must be claimed by exactly one mapper.
        let samples: [(String, Data)] = [
            ("v1.json", Data(twitchJSON.utf8)),
            ("thread.html", Data(phpBBThread.utf8))
        ]
        for (filename, data) in samples {
            let claimants = registry.allMappers.filter {
                $0.claims(filename: filename, sample: data.prefix(DiscussionExportRegistry.sampleSize))
            }
            #expect(claimants.count == 1,
                    "\(filename) claimed by \(claimants.map(\.platform))")
        }
    }

    @Test("A Twitch export inside a recognized tree routes to the discussion lane")
    func twitchRoutesInsideAnExportTree() {
        // The `/twitch/` path marker already exists for this lane; a loose
        // renamed export outside any tree still routes by its extension, which
        // is stated in SUPPORTED_SOURCES rather than worked around here.
        #expect(SourceType.detect(from: URL(fileURLWithPath:
            "/case/twitch/messages.json")) == .discussionExport)
    }
}

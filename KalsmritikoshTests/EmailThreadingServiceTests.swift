//
//  EmailThreadingServiceTests.swift
//  KalsmritikoshTests
//
//  Locks the dedup + subject-threading behaviour of EmailThreadingService.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("EmailThreadingService — dedup + threading")
struct EmailThreadingServiceTests {

    private func row(_ subject: String, _ from: String, hash: String, day: Int) -> EmailDigestRow {
        let d = Date(timeIntervalSince1970: Double(day) * 86_400)
        return EmailDigestRow(
            id: UUID(),
            sourceFile: URL(fileURLWithPath: "/tmp/\(hash).eml"),
            subject: subject, from: from,
            date: d, contentHash: hash, preview: subject, createdAt: d)
    }

    @Test("Exact-hash duplicates are removed and counted")
    func dedup() {
        let rows = [
            row("Budget", "dave@x.com", hash: "h4", day: 1),
            row("Budget", "dave@x.com", hash: "h4", day: 1) // identical bytes
        ]
        let res = EmailThreadingService.organize(rows)
        #expect(res.duplicatesRemoved == 1)
        #expect(res.totalMessages == 1)
        #expect(res.threads.count == 1)
    }

    @Test("Re:/FWD: variants group into one conversation, ordered by date")
    func threading() {
        let rows = [
            row("Lunch plans", "alice@x.com", hash: "h1", day: 3),
            row("Re: Lunch plans", "bob@x.com", hash: "h2", day: 1),
            row("FWD: Lunch plans", "carol@x.com", hash: "h3", day: 2),
            row("Budget", "dave@x.com", hash: "h4", day: 1)
        ]
        let res = EmailThreadingService.organize(rows)
        #expect(res.threads.count == 2)
        let lunch = res.threads.first { $0.displaySubject.localizedCaseInsensitiveContains("lunch") }
        #expect(lunch?.count == 3)
        // Chronological within the thread.
        let dates = lunch?.messages.compactMap { $0.date } ?? []
        #expect(dates == dates.sorted())
        // Participants are unique + preserved.
        #expect(lunch?.participants.count == 3)
    }

    @Test("Subject normalization strips nested reply/forward prefixes and list tags")
    func normalization() {
        #expect(EmailThreadingService.normalizeSubject("Re: FWD: Re: Lunch plans") == "lunch plans")
        #expect(EmailThreadingService.normalizeSubject("[dev-list] Build broke") == "build broke")
        #expect(EmailThreadingService.normalizeSubject("   ") == "(no subject)")
    }

    @Test("Undated messages sort last and don't crash grouping")
    func undated() {
        let dated = row("Topic", "a@x.com", hash: "h1", day: 5)
        let undated = EmailDigestRow(
            id: UUID(), sourceFile: URL(fileURLWithPath: "/tmp/u.eml"),
            subject: "Re: Topic", from: "b@x.com", date: nil,
            contentHash: "h2", preview: "u", createdAt: Date(timeIntervalSince1970: 0))
        let res = EmailThreadingService.organize([undated, dated])
        #expect(res.threads.count == 1)
        #expect(res.threads[0].messages.last?.date == nil)
    }
}

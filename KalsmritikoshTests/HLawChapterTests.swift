//
//  HLawChapterTests.swift
//  Kalsmritikosh Tests
//
//  P4-U2 (GO 2 REVISED) — chapters under the H-laws:
//    H-5 episodes over threads (one chapter per thread, chronological)
//    H-3 certificate-class documents beat as ONE unit (never split)
//    H-2 equal ties are UNPLACED + a typed gap — never guessed
//    H-1 use-once holds by construction, and the placement twin re-checks it
//  An empty source context reproduces the original year-bucket outline.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P4-U2 — chapters under the H-laws")
struct HLawChapterTests {

    private let subjectID = UUID()

    private func material() -> HistoryMaterial {
        HistoryMaterial(
            subject: ResolvedHistorySubject(subject: .person(subjectID), displayName: "S",
                                            canonicalEntityID: subjectID, resolutionConfidence: 1.0),
            provenance: MaterialProvenance(canonicalEntityID: subjectID, eventCount: 0,
                assertionCount: 0, genericFactCount: 0, relationshipCount: 0, unscopedSubject: false))
    }

    private func item(_ title: String, day: Int, evidence: [UUID],
                      review: HistoryReviewStatus = .unreviewed) -> HistoryItem {
        HistoryItem(subject: .person(subjectID), kind: .event, title: title,
                    start: TemporalValue(start: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + day * 86_400)),
                                         precision: .day, confidence: 0.9),
                    evidenceStatus: .sourceAsserted, confidence: 0.9,
                    evidence: evidence.map { EvidenceReference(objectID: $0) },
                    reviewStatus: review)
    }

    @Test("H-5: items chapter by email episode, chronologically; fallback items keep year buckets")
    func episodesOverThreads() {
        let hearingMail1 = UUID(), hearingMail2 = UUID(), feeMail = UUID(), plainDoc = UUID()
        let context = StorySourceContext(
            episodeKeyByObject: [hearingMail1: "hearing notice", hearingMail2: "hearing notice",
                                 feeMail: "fee reminder"],
            episodeDisplayByKey: ["hearing notice": "Hearing notice", "fee reminder": "Fee reminder"],
            documentClassByObject: [:])
        let items = [
            item("Hearing scheduled", day: 10, evidence: [hearingMail1]),
            item("Hearing held", day: 20, evidence: [hearingMail2]),
            item("Fee demanded", day: 15, evidence: [feeMail]),
            item("Unthreaded note", day: 5, evidence: [plainDoc]),
        ]
        let outline = HistoryOutlineBuilder().build(material: material(), items: items, sourceContext: context)

        let titles = outline.chapters.map(\.title)
        #expect(titles == ["2023", "Hearing notice", "Fee reminder"],
                "year bucket first (day 5), then episodes by earliest date: \(titles)")
        let hearing = outline.chapters.first { $0.title == "Hearing notice" }
        #expect(hearing?.itemIDs.count == 2, "the thread's two beats ride together")
        #expect(outline.everyItemChaptered)

        // Determinism.
        let again = HistoryOutlineBuilder().build(material: material(), items: items, sourceContext: context)
        #expect(again.chapters.map(\.title) == titles)
    }

    @Test("H-3: a certificate-class document beats as one unit, even when threaded")
    func certificateWholeFileBeat() {
        let grant = UUID(), mail = UUID()
        let context = StorySourceContext(
            episodeKeyByObject: [grant: "patent grant", mail: "patent grant"],
            episodeDisplayByKey: ["patent grant": "Patent grant",
                                  "doc:\(grant.uuidString)": "Grant certificate"],
            documentClassByObject: [grant: DocumentClass.certificate.rawValue])
        let items = [
            item("Patent granted", day: 1, evidence: [grant]),
            item("Certificate issued", day: 2, evidence: [grant]),
            item("Grant announced by email", day: 3, evidence: [mail]),
        ]
        let outline = HistoryOutlineBuilder().build(material: material(), items: items, sourceContext: context)

        let cert = outline.chapters.first { $0.title == "Grant certificate" }
        #expect(cert?.itemIDs.count == 2, "the certificate's record is never split")
        #expect(cert?.subtitle?.contains("kept whole") == true)
        #expect(outline.chapters.first { $0.title == "Patent grant" }?.itemIDs.count == 1)
    }

    @Test("H-2: an equal tie between episodes is unplaced + a typed gap — never guessed")
    func ambiguityIsExpandedNeverGuessed() {
        let mailA = UUID(), mailB = UUID()
        let context = StorySourceContext(
            episodeKeyByObject: [mailA: "thread a", mailB: "thread b"],
            episodeDisplayByKey: ["thread a": "Thread A", "thread b": "Thread B"],
            documentClassByObject: [:])
        let items = [
            item("Anchor beat A", day: 1, evidence: [mailA]),
            item("Anchor beat B", day: 2, evidence: [mailB]),
            item("Torn between threads", day: 3, evidence: [mailA, mailB]),
        ]
        let outline = HistoryOutlineBuilder().build(material: material(), items: items, sourceContext: context)

        #expect(outline.chapters.last?.title == HistoryOutlineBuilder.unplacedChapterTitle)
        #expect(outline.chapters.last?.itemIDs.count == 1)
        #expect(outline.everyItemChaptered, "unplaced is still chaptered — nothing is dropped")

        // The gap engine turns the unplaced item into a typed, reviewable gap.
        let gaps = HistoryGapEngine().infer(outline: outline)
        let unplacedGaps = gaps.filter { $0.kind == .unplacedEvidence }
        #expect(unplacedGaps.count == 1)
        #expect(unplacedGaps.first?.description.contains("Torn between threads") == true)
    }

    @Test("An empty context reproduces the original year-bucket outline")
    func emptyContextIsTheOldLaw() {
        let items = [
            item("First", day: 0, evidence: [UUID()]),
            item("Second", day: 400, evidence: [UUID()]),
        ]
        let outline = HistoryOutlineBuilder().build(material: material(), items: items)
        #expect(outline.chapters.map(\.title) == ["2023", "2024"])
        #expect(outline.everyItemChaptered)
    }

    @Test("SR-5/SR-6: a correction outranks on the same date; a rejection is excluded visibly")
    func reviewLoop() {
        let src = UUID()
        let machine = item("Grant date per the letter", day: 10, evidence: [src])
        let correctedItem = item("Grant date as you corrected it", day: 10, evidence: [src], review: .corrected)
        let rejectedItem = item("A parse ghost", day: 12, evidence: [src], review: .rejected)

        let outline = HistoryOutlineBuilder().build(
            material: material(), items: [machine, correctedItem, rejectedItem])

        // Corrected outranks the machine reading on the same date.
        let year = outline.chapters.first { $0.title == "2023" }
        #expect(year?.itemIDs.first == correctedItem.id)
        // Rejected is excluded from the story chapters yet visible at the end.
        #expect(outline.chapters.last?.title == HistoryOutlineBuilder.reviewedOutChapterTitle)
        #expect(outline.chapters.last?.itemIDs == [rejectedItem.id])
        #expect(outline.everyItemChaptered, "excluded VISIBLY — never dropped")
        #expect(PlacementTwin.check(outline: outline).isEmpty)

        // The renderer speaks the review states.
        let narrative = HistoryNarrativeRenderer().render(outline: outline)
        #expect(narrative.chapters.first { $0.title == "2023" }?.prose.contains("(user-corrected)") == true)
        let reviewedOut = narrative.chapters.last
        #expect(reviewedOut?.prose == "A parse ghost (excluded by review).")
        #expect(reviewedOut?.gist == "1 item(s) excluded by your review.")
    }

    @Test("Placement twin: a lawful outline passes; a broken one is flagged; only advisory rows are written")
    func placementTwinLaws() async throws {
        let mail = UUID()
        let context = StorySourceContext(
            episodeKeyByObject: [mail: "thread"], episodeDisplayByKey: ["thread": "Thread"],
            documentClassByObject: [:])
        let items = [item("Beat", day: 1, evidence: [mail]), item("Beat 2", day: 2, evidence: [mail])]
        let lawful = HistoryOutlineBuilder().build(material: material(), items: items, sourceContext: context)
        #expect(PlacementTwin.check(outline: lawful).isEmpty)

        // A corrupted outline: the same item listed in two chapters (H-1 broken).
        let dup = items[0].id
        let broken = HistoryOutline(
            subject: lawful.subject, corpusSnapshotID: nil, items: items,
            chapters: [
                HistoryChapterPlan(ordinal: 0, title: "One", itemIDs: [dup, items[1].id]),
                HistoryChapterPlan(ordinal: 1, title: "Two", itemIDs: [dup]),
            ],
            actors: [], relationships: [], coverage: lawful.coverage)
        let findings = PlacementTwin.check(outline: broken)
        #expect(findings.contains { $0.contains("more than one chapter") })

        // Recording writes ONLY advisory rows; history tables stay untouched.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        let artifactID = UUID()
        await PlacementTwin.record(findings: findings, artifactID: artifactID, database: db)
        let flags = (try await db.query(
            "SELECT COUNT(*) FROM fact_reviews WHERE reviewer = 'twin.placement' AND action = 'flag';", [])).first?.int(0) ?? 0
        #expect(flags == Int64(findings.count))
        let artifacts = (try await db.query("SELECT COUNT(*) FROM history_artifacts;", [])).first?.int(0) ?? -1
        #expect(artifacts == 0, "checker, never writer")
    }
}

//
//  W5FixTests.swift
//  KalsmritikoshTests
//
//  U-2 acceptance — the W-5 findings (owner witness 1:55/1:56):
//  role-value gate · existence prefers the state-change milestone ·
//  event-title normalizer · thread copies are one independent source ·
//  Language-Contract fixes. All pure; fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-2 / W-5 fixes")
struct W5FixTests {

    // — 1. role-value gate: the three fragments die, the POA line lives —

    @Test func clauseFragmentsProduceZeroApplicantFacts() {
        let fragments = [
            "I am writing to state that the application is pending.",
            "I wish to bring to your kind attention the delay of the office.",
            "I would like to submit herewith the documents of record.",
        ]
        for text in fragments {
            let facts = PatentDomainPack.extractFacts(fromText: text, subjectLabel: "s", blockID: UUID())
            #expect(facts.filter { $0.field == "applicant" }.isEmpty,
                    "fragment minted an applicant fact: \(text)")
        }
    }

    @Test func poaLineProducesExactlyOneApplicant() {
        let poa = "I, Shirshendu Sasmal, son of Ranjit Sasmal, residing at Kolkata, hereby appoint…"
        let facts = PatentDomainPack.extractFacts(fromText: poa, subjectLabel: "s", blockID: UUID())
        let applicants = facts.filter { $0.field == "applicant" }
        #expect(applicants.count == 1)
        #expect(applicants.first?.value == "Shirshendu Sasmal")

        // A lowercase POA capture. The Title-Case law (W-5.1) refused it; the
        // later module .poaGrantorRecovery (default ON) reads it — but ONLY in
        // the exact "I, <name> having…" formula. RULING 2026-09-27 (P2.5): the
        // module is the current decision; this test pins BOTH of its states
        // instead of depending on the default.
        let lower = "I, shirshendu sasmal having nationality Indian, declare…"
        let saved = KnowledgeModuleFlags.isEnabled(.poaGrantorRecovery)
        defer { KnowledgeModuleFlags.setEnabled(.poaGrantorRecovery, saved) }
        KnowledgeModuleFlags.setEnabled(.poaGrantorRecovery, false)
        #expect(PatentDomainPack.extractFacts(fromText: lower, subjectLabel: "s", blockID: UUID())
            .filter { $0.field == "applicant" }.isEmpty, "module off: the Title-Case law holds")
        do {
            KnowledgeModuleFlags.setEnabled(.poaGrantorRecovery, true)
            let recovered = PatentDomainPack.extractFacts(fromText: lower, subjectLabel: "s", blockID: UUID())
                .filter { $0.field == "applicant" }
            #expect(recovered.count == 1, "module on: exactly one applicant from the formula")
            #expect(recovered.first?.value.lowercased() == "shirshendu sasmal")
        }
        // Never an ordinary sentence starting with "I,", whatever the module.
        #expect(PatentDomainPack.extractFacts(fromText: "I, for one, acknowledge receipt of the notice.",
                                              subjectLabel: "s", blockID: UUID())
            .filter { $0.field == "applicant" }.isEmpty)
    }

    @Test func roleGateRejectsInfraAndClauseShapes() {
        #expect(!PatentDomainPack.isPlausibleRoleValue("am writing to state"))
        #expect(!PatentDomainPack.isPlausibleRoleValue("wish to bring"))
        #expect(!PatentDomainPack.isPlausibleRoleValue("the undersigned applicant"))
        #expect(PatentDomainPack.isPlausibleRoleValue("Shirshendu Sasmal"))
        #expect(PatentDomainPack.isPlausibleRoleValue("SHIRSHENDU SASMAL"))
        #expect(!PatentDomainPack.isPlausibleRoleValue("shirshendu sasmal"))  // Title-Case law
        // Live junk the stoplist alone would have missed:
        #expect(!PatentDomainPack.isPlausibleRoleValue("acknowledge receipt"))
        #expect(!PatentDomainPack.isPlausibleRoleValue("need patent agent"))
    }

    // — 2. existence prefers the state-change milestone over the email —

    @Test func existenceLeadsWithTheMilestone() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!   // align with the composer's UTC formatter
        let grantDate = cal.date(from: DateComponents(year: 2024, month: 11, day: 28))!
        let mailDate = cal.date(from: DateComponents(year: 2024, month: 12, day: 2))!
        let milestone = Event(kind: .other, date: grantDate, title: "Patent granted",
                              sourceObjectID: UUID(), confidence: .high)
        let intimation = Event(kind: .emailReceived, date: mailDate,
                               title: "Intimation of grant of patent",
                               sourceObjectID: UUID(), confidence: .high)
        let composed = EventAnswerComposer.composeExistence(
            question: "was the patent granted?",
            events: [intimation, milestone],   // email is NEWER — must still lose
            documentsSearched: 10)
        #expect(composed != nil)
        #expect(composed?.primaryText.hasPrefix("Yes — patent granted on") == true)
        #expect(composed?.primaryText.contains("28") == true)
        #expect(composed?.primaryText.contains("Intimation received") == true)
    }

    // — 3. event-title normalizer —

    @Test func titleNormalizerStripsRoutingPrefixes() {
        #expect(RuleEventExtractor.normalizeEventTitle("Fwd: Fwd: Intimation of Grant")
                == "Intimation of Grant")
        #expect(RuleEventExtractor.normalizeEventTitle("RE: re: FW: hearing notice")
                == "hearing notice")
        #expect(RuleEventExtractor.normalizeEventTitle("[EXTERNAL] Re: Payment advice")
                == "Payment advice")
        #expect(RuleEventExtractor.normalizeEventTitle("Fwd:") == "Fwd:")  // never empty
        #expect(RuleEventExtractor.normalizeEventTitle("Plain subject") == "Plain subject")
        // Acceptance: no normalized title begins with a routing prefix.
        for raw in ["fwd: x1 report", "FW : quarterly", "Re: Re: Fwd: minutes"] {
            let t = RuleEventExtractor.normalizeEventTitle(raw).lowercased()
            #expect(!t.hasPrefix("fwd:") && !t.hasPrefix("fw:") && !t.hasPrefix("re:"))
        }
    }

    // — 4. thread copies collapse to one independent source —

    @Test func threadCopiesShareOneIndependenceKey() {
        let a = LedgerSourceIndependenceKeyProvider.threadKey(subject: "Intimation of Grant of Patent")
        let b = LedgerSourceIndependenceKeyProvider.threadKey(subject: "Fwd: Intimation of  Grant of Patent")
        let c = LedgerSourceIndependenceKeyProvider.threadKey(subject: "RE: FWD: intimation of grant of patent")
        #expect(a == b)
        #expect(a == c)

        let id1 = UUID(), id2 = UUID()
        let grouper = SourceIndependenceGrouper()
        let keys = [id1: "thread:" + a, id2: "thread:" + b]
        #expect(grouper.independentCount(objectIDs: [id1, id2], keys: keys) == 1,
                "the two intimation copies must count once")
        #expect(!grouper.isCorroborated(objectIDs: [id1, id2], keys: keys))
    }

    @Test func distinctSubjectsStayIndependent() {
        let a = LedgerSourceIndependenceKeyProvider.threadKey(subject: "Grant certificate attached")
        let b = LedgerSourceIndependenceKeyProvider.threadKey(subject: "Hearing notice for March")
        #expect(a != b)
    }

    // — 6. cross-block collision resolver (pass 2c) on the live shape —

    @Test func ghostPatentReassignsToApplicationNumber() {
        // The live archive shape at faebecf: the ghost ×2 vs the home ×115,
        // with the patent field holding its real answer ×84.
        let attn: [String: [String: Int]] = [
            "patentnumber": ["202331019665": 2, "555489": 84],
            "applicationnumber": ["202331019665": 115, "2023310": 3],
        ]
        let moves = LedgerDrainCoordinator.resolveCrossBlock(attestation: attn)
        #expect(moves == [.init(intruded: "patentnumber", home: "applicationnumber", value: "202331019665")])

        let folds = LedgerDrainCoordinator.resolvePrefixFolds(attestation: attn)
        #expect(folds == [.init(field: "applicationnumber", truncated: "2023310", dominant: "202331019665")])
    }

    @Test func coincidenceNeverReassigns() {
        // Two fields each holding the same value as a modest claim — no
        // dominance, no move (value equality is not identity of referent).
        let attn: [String: [String: Int]] = [
            "patentnumber": ["700321": 4],
            "applicationnumber": ["700321": 5],
        ]
        #expect(LedgerDrainCoordinator.resolveCrossBlock(attestation: attn).isEmpty)
        #expect(LedgerDrainCoordinator.resolvePrefixFolds(attestation: attn).isEmpty)
    }

    @Test func fusedSuffixNoLongerCaptured() {
        // W-5.6 — "202331019665Applicant" ×82 came from the case-insensitive
        // value tail swallowing the next word.
        let text = "Application number:202331019665Applicant name: Shirshendu Sasmal"
        let facts = PatentDomainPack.extractFacts(fromText: text, subjectLabel: "s", blockID: UUID())
        // Facts store field names LOWERCASE (generic_facts convention).
        let values = facts.filter { FactSchemaRegistry.normalizeField($0.field) == "applicationnumber" }.map(\.value)
        #expect(values.contains("202331019665"))
        #expect(!values.contains { $0.lowercased().contains("applicant") })
    }

    // — 5. Language Contract: the strip and the notes carry no jargon —

    @Test func stripAndNotesCarryNoBannedTokens() {
        let answer = VerifiedAnswer(
            body: "x", answerText: "x",
            citations: [.init(objectID: UUID(), snippet: "s")],
            confidence: Confidence(0.8))
        let line = QualityStrip.formatLine(answer)
        #expect(!line.lowercased().contains("claim"), "the quality strip still says 'claims': \(line)")
    }
}

@Suite("P4.4 — cross-field re-fielding counts evidence, not merged rows", .serialized)
struct CrossFieldAttestationTests {
    @Test("One merged application-number row with 12 sources still re-fields two 'Patent No.' mislabels")
    func mergedShape() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xfa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let facts = GenericFactRepository(database: db)
        func fact(_ field: String, _ value: String, blocks: Int, label: String) -> GenericFact {
            GenericFact(subjectLabel: label, field: field, value: value, status: .sourceAsserted,
                        confidence: 0.8, sourceBlockIDs: (0..<blocks).map { _ in UUID() },
                        producerVersion: DerivedProducerVersions.facts)
        }
        try await facts.upsert(fact("applicationnumber", "202331019665", blocks: 12, label: "Patent"))   // merged: 1 row, 12 sources
        try await facts.upsert(fact("patentnumber", "202331019665", blocks: 1, label: "Hearing 1"))
        try await facts.upsert(fact("patentnumber", "202331019665", blocks: 1, label: "Hearing 2"))
        try await facts.upsert(fact("patentnumber", "555489", blocks: 3, label: "Grant"))
        let drain = LedgerDrainCoordinator(database: db, objects: KnowledgeObjectRepository(database: db),
                                           entities: EntitiesRepository(database: db), events: EventsRepository(database: db),
                                           facts: facts, evidence: EvidenceStore(database: db))
        let moves = try await drain.crossBlockCollisions()
        #expect(moves.contains { $0.intruded == "patentnumber" && $0.home == "applicationnumber" && $0.value == "202331019665" },
                "got \(moves)")
    }
}

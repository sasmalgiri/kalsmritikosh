//
//  CaseContradictionFinderTests.swift
//  KalsmritikoshTests
//
//  P3 — the case contradiction check. Fixtures modelled on the real-case evaluation (2026-11-03): the
//  Logan arson releases ($75,000 vs $50,000 to the same insurance agent; three accounts of who spread the
//  fuel; which camera recorded it), different victims (no conflict), a same-person age difference, the
//  case scope (a document outside the case is never compared) and the cloud clearance (nothing sent
//  without it; privileged documents never sent). The AI side uses a fake reader: a pair with a fabricated
//  quote is dropped.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P3 — case contradiction check", .serialized)
struct CaseContradictionFinderTests {
    typealias F = CaseContradictionFinder

    static let release1 = """
    CHARLESTON, W.Va. – Four men were indicted in connection with the arson of the 317 Restaurant in Logan.
    Mr. Glick then paid co-defendant William Jamey Thompson, 44, an independent insurance agent from Chapmanville, approximately $75,000 to obtain a fraudulently-inflated $1 million insurance policy from General Star Indemnity Company in connection with the scheme.
    Robert Miller and Kevin Simon worked at the restaurant.
    Miller, Simon, and another person set the fire by allegedly spreading gasoline throughout the main floor.
    """
    static let release4 = """
    CHARLESTON, W.Va. – Jeffrey Glick was sentenced for the arson scheme.
    William Jamey Thompson placed the policy with General Star Indemnity Company.
    Thompson, in exchange for placing coverage, received $50,000.
    The three culprits were caught on 317’s security camera; Glick had Miller and Simon destroy the restaurant’s digital video recorder in order to conceal the crime.
    """
    static let release5 = """
    BECKLEY, W.Va. – Robert Miller pleaded guilty in the arson of the 317 Restaurant.
    Miller recruited Michael D. Williams, 44, of Logan to spread approximately fifteen gallons of gasoline throughout the first floor of the building and ignite the fire.
    The explosion was caught on the Logan County Courthouse video security system.
    """

    static func doc(_ text: String, date: Date? = nil) -> F.Document {
        F.Document(objectID: UUID(), sourceVersionID: UUID(), text: text, fileName: nil, date: date)
    }

    // MARK: - Rules

    @Test("Logan: $75,000 vs $50,000 paid to the same named agent across two releases is found by the rules")
    func loganPayment() {
        let a = Self.doc(Self.release1), b = Self.doc(Self.release4)
        let found = F.ruleFindings([a, b])
        let pay = found.filter { $0.kind == .amount && $0.subject == "William Jamey Thompson" }
        #expect(pay.count == 1)
        guard let p = pay.first else { return }
        #expect(Set([p.valueA, p.valueB]) == ["$75,000", "$50,000"])
        #expect(p.quoteA.contains("approximately $75,000") || p.quoteB.contains("approximately $75,000"))
        #expect(p.quoteA.contains("received $50,000") || p.quoteB.contains("received $50,000"))
        #expect(Set([p.objectA, p.objectB]) == Set([a.objectID, b.objectID]))
        #expect(p.provenance == .rules)
        let c = p.contradiction()
        #expect(c.kind == .amount && c.evidenceA != nil && c.evidenceB != nil && !c.claimA.isEmpty && !c.claimB.isEmpty)
        #expect(F.provenance(of: c) == .rules && F.kindLabel(of: c) == "Amount")
        #expect(c.id == p.contradiction().id)   // stable: a rerun adds nothing twice
    }

    @Test("Logan: who spread the fuel and which camera recorded it differ across releases")
    func loganRoleAndCamera() {
        let docs = [Self.doc(Self.release1), Self.doc(Self.release4), Self.doc(Self.release5)]
        let found = F.ruleFindings(docs)
        let role = found.filter { $0.kind == .role }
        #expect(role.count == 1)
        #expect(role.first.map { [$0.valueA, $0.valueB].contains { $0.contains("Williams") } } == true)
        let camera = found.filter { $0.kind == .account }
        #expect(camera.count == 1)
        #expect(camera.first.map { Set([$0.valueA, $0.valueB]) == ["317’s security camera", "the Logan County Courthouse video security system"] } == true)
    }

    @Test("A later account stated as a correction is not flagged by the rules")
    func correctionNotFlagged() {
        let corrected = """
        CHARLESTON, W.Va. – An update on the 317 Restaurant arson.
        Contrary to the earlier release, Michael D. Williams spread the gasoline throughout the first floor; Robert Miller and Kevin Simon did not.
        """
        let found = F.ruleFindings([Self.doc(Self.release1), Self.doc(corrected)])
        #expect(found.filter { $0.kind == .role }.isEmpty)
    }

    @Test("Payments to different victims are not a conflict")
    func differentVictims() {
        let a = Self.doc("Records show Paul Grant paid John Roe $5,000 for the false loan.")
        let b = Self.doc("Records show Paul Grant paid Mary Poe $8,000 for another false loan.")
        let c = Self.doc("Records show Paul Grant paid Victim A $5,000 and later dealt with Victim B.")
        #expect(F.ruleFindings([a, b, c]).filter { $0.kind == .amount }.isEmpty)
    }

    @Test("Two payments to one person in one document are two payments, not a disagreement")
    func twoPaymentsSameDocument() {
        let a = Self.doc("Jane Doe received $5,000 in May. Later Jane Doe received $9,000 in June.")
        let b = Self.doc("Jane Doe received $5,000 in May from the scheme.")
        #expect(F.ruleFindings([a, b]).filter { $0.kind == .amount }.isEmpty)
    }

    @Test("A same-person age difference is found; time between dated documents explains one")
    func ageDifference() {
        let a = Self.doc("Defendant Carlos Mendez, 39, of Miami was charged.")
        let b = Self.doc("Defendant Carlos Mendez, 45, of Miami pleaded guilty.")
        let undated = F.ruleFindings([a, b]).filter { $0.kind == .age }
        #expect(undated.count == 1)
        #expect(undated.first?.note?.contains("dates are not known") == true)
        let y2014 = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2014, month: 1, day: 22))!
        let y2020 = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2020, month: 3, day: 1))!
        let y2014b = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2014, month: 6, day: 1))!
        // 39 in 2014 and 45 in 2020: the years between explain it.
        #expect(F.ruleFindings([Self.doc(a.text, date: y2014), Self.doc(b.text, date: y2020)]).filter { $0.kind == .age }.isEmpty)
        // 39 and 45 months apart: they cannot both be right.
        #expect(F.ruleFindings([Self.doc(a.text, date: y2014), Self.doc(b.text, date: y2014b)]).filter { $0.kind == .age }.count == 1)
    }

    @Test("A bare surname shared by two people in the case names neither")
    func ambiguousSurname() {
        let a = Self.doc("Brock Taylor and Jonathan Taylor were charged. Taylor received $5,000.")
        let b = Self.doc("Brock Taylor and Jonathan Taylor were sentenced. Taylor received $9,000.")
        #expect(F.ruleFindings([a, b]).isEmpty)
    }

    // MARK: - AI reading verification

    static func batch(_ docs: [F.Document]) -> F.Batch {
        F.Batch(subject: "William Jamey Thompson", passages: docs.map { F.Passage(objectID: $0.objectID, sourceVersionID: $0.sourceVersionID, text: $0.text) })
    }

    @Test("A verified AI pair survives; a fabricated quote, a same-value pair and a stated correction are dropped")
    func aiVerification() {
        let a = Self.doc(Self.release1), b = Self.doc(Self.release4)
        let reply = """
        {"pairs": [
          {"about": "William Jamey Thompson", "kind": "amount",
           "a": {"passage": 1, "quote": "approximately $75,000 to obtain a fraudulently-inflated $1 million insurance policy"},
           "b": {"passage": 2, "quote": "Thompson, in exchange for placing coverage, received $50,000."},
           "value_a": "$75,000", "value_b": "$50,000"},
          {"about": "William Jamey Thompson", "kind": "amount",
           "a": {"passage": 1, "quote": "Mr. Glick then paid co-defendant William Jamey Thompson $90,000"},
           "b": {"passage": 2, "quote": "Thompson, in exchange for placing coverage, received $50,000."},
           "value_a": "$90,000", "value_b": "$50,000"},
          {"about": "William Jamey Thompson", "kind": "amount",
           "a": {"passage": 1, "quote": "approximately $75,000 to obtain a fraudulently-inflated $1 million insurance policy"},
           "b": {"passage": 2, "quote": "Thompson, in exchange for placing coverage, received $50,000."},
           "value_a": "$75,000", "value_b": "$75,000"}
        ]}
        """
        let v = F.verify(reply: reply, batch: Self.batch([a, b]), allDocuments: [a, b])
        #expect(v.verified.count == 1)
        #expect(v.dropped.count == 2)
        #expect(v.verified.first?.provenance == .aiRead)
        #expect(v.verified.first?.subject == "William Jamey Thompson")
        // Three accounts: the correcting release's sentence is explained, not a contradiction.
        let corrected = Self.doc("Contrary to the earlier release, Michael D. Williams spread the gasoline throughout the first floor.")
        let r2 = """
        {"pairs": [{"about": "the fire", "kind": "role",
          "a": {"passage": 1, "quote": "Miller, Simon, and another person set the fire by allegedly spreading gasoline throughout the main floor."},
          "b": {"passage": 2, "quote": "Michael D. Williams spread the gasoline throughout the first floor."},
          "value_a": "Miller, Simon", "value_b": "Michael D. Williams"}]}
        """
        let ev = F.Batch(subject: nil, passages: [a, corrected].map { F.Passage(objectID: $0.objectID, text: $0.text) })
        let v2 = F.verify(reply: r2, batch: ev, allDocuments: [a, corrected])
        #expect(v2.verified.isEmpty)
        #expect(v2.dropped.first?.contains("correction") == true)
        // Unreadable reply.
        #expect(F.verify(reply: "<<garbage>>", batch: Self.batch([a, b]), allDocuments: [a, b]).unreadable)
    }

    @Test("An AI pair about someone the passage does not name is dropped")
    func aiWrongPerson() {
        let a = Self.doc("Records show Paul Grant paid Mary Poe $8,000.")
        let b = Self.doc("Records show Paul Grant paid John Roe $5,000.")
        let reply = """
        {"pairs": [{"about": "Mary Poe", "kind": "amount",
          "a": {"passage": 1, "quote": "Paul Grant paid Mary Poe $8,000"}, "b": {"passage": 2, "quote": "Paul Grant paid John Roe $5,000"},
          "value_a": "$8,000", "value_b": "$5,000"}]}
        """
        let batch = F.Batch(subject: nil, passages: [a, b].map { F.Passage(objectID: $0.objectID, text: $0.text) })
        #expect(F.verify(reply: reply, batch: batch, allDocuments: [a, b]).verified.isEmpty)
    }

    // MARK: - Service: scope and privacy

    private let t0 = Date(timeIntervalSince1970: 1_767_500_000)

    private struct Rig {
        let db: Database
        let svc: InvestigationContradictionGapService
        let caseID: UUID
        let koA: UUID, koB: UUID, koOut: UUID
        let sent: Sent
    }

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        private var clearances: [CloudSourceClearance?] = []
        func add(_ p: String, _ c: CloudSourceClearance?) { lock.lock(); prompts.append(p); clearances.append(c); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
        var cleared: [CloudSourceClearance?] { lock.lock(); defer { lock.unlock() }; return clearances }
    }

    private func rig(texts: (String, String, String), privileged: Set<Int> = [], gate: Bool = true, reader: Bool = true,
                     reply: String = #"{"pairs": []}"#, failure: (any Error & Sendable)? = nil) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        var versions: [UUID] = [], kos: [UUID] = []
        for text in [texts.0, texts.1, texts.2] {
            let version = UUID(), logical = UUID(), ko = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                              [.uuid(logical), .text("file:///x/\(logical.uuidString)"), .text("txt"), .text("available")])
            try await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                    filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(version), .uuid(logical), .text(String(repeating: "e", count: 64)), .real(100), .integer(1), .real(100),
                      .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
            try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                              [.uuid(ko), .uuid(logical), .text("txt"), .text(text), .real(1), .real(1)])
            versions.append(version); kos.append(ko)
        }
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        var c = try await cases.createCase(workspaceID: ws, title: "Logan", actor: "analyst", at: t0)
        for v in versions.prefix(2) {   // the third document is NOT in the case
            c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: v.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        }
        let byVersion = Dictionary(uniqueKeysWithValues: zip(versions, zip(kos, [texts.0, texts.1, texts.2])))
        let privilegedIDs = Set(privileged.map { kos[$0] })
        let sent = Sent()
        let caseID = c.id
        let pass = CaseContradictionPass(
            // Deliberately returns EVERY document, so the service's own scope filter is what is tested.
            documents: { _ in byVersion.map { F.Document(objectID: $0.value.0, sourceVersionID: $0.key, text: $0.value.1) } },
            gate: { _ in
                guard gate else { return nil }
                return CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                       legacyPrivileged: { privilegedIDs })
                    .bound(to: CloudScopeBinding(scopeID: caseID) { Dictionary(uniqueKeysWithValues: zip(kos.prefix(2), versions.prefix(2).map { Set([$0]) })) })
            },
            reader: { reader ? CaseContradictionReader { prompt, clearance in
                sent.add(prompt, clearance); if let failure { throw failure }; return reply } : nil })
        let svc = InvestigationContradictionGapService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                       contradictions: ContradictionsRepository(database: db), gaps: GapNodeRepository(database: db),
                                                       reviews: InvestigationDeskReviewRepository(database: db), pass: pass)
        return Rig(db: db, svc: svc, caseID: caseID, koA: kos[0], koB: kos[1], koOut: kos[2], sent: sent)
    }

    @Test("The case check stores the pair in scope; a document outside the case is never compared or sent")
    func scopeAndStore() async throws {
        // The out-of-case document gives Thompson a third amount: it must never pair or be sent.
        let outside = "William Jamey Thompson received $10,000 from an unrelated client."
        let r = try await rig(texts: (Self.release1, Self.release4, outside))
        let run = try await r.svc.findContradictions(caseID: r.caseID, at: t0)
        #expect(run.documents == 2)
        #expect(run.ruleFindings.contains { $0.kind == .amount })
        #expect(run.findings.allSatisfy { Set([$0.objectA, $0.objectB]).isSubset(of: [r.koA, r.koB]) })
        #expect(!r.sent.all.isEmpty)
        #expect(r.sent.all.allSatisfy { !$0.contains("$10,000") })
        #expect(r.sent.cleared.allSatisfy { $0 != nil && !$0!.clearedObjectIDs.contains(r.koOut) })
        let items = try await r.svc.contradictions(caseID: r.caseID)
        #expect(items.contains { F.provenance(of: $0.contradiction) == .rules && $0.contradiction.kind == .amount })
        // Rerun: nothing stored twice.
        _ = try await r.svc.findContradictions(caseID: r.caseID, at: t0)
        #expect(try await r.svc.contradictions(caseID: r.caseID).count == items.count)
        // The archive-wide rescan's clear keeps the case check's rows.
        await ContradictionsRepository(database: r.db).clearKeepingCaseChecks()
        #expect(try await r.svc.contradictions(caseID: r.caseID).count == items.count)
    }

    @Test("No send without a clearance gate; a privileged document is never sent; the rules still run offline")
    func privacy() async throws {
        let noGate = try await rig(texts: (Self.release1, Self.release4, "x"), gate: false)
        let r1 = try await noGate.svc.findContradictions(caseID: noGate.caseID, at: t0)
        #expect(noGate.sent.all.isEmpty && r1.calls == 0 && r1.notSentReason != nil)
        #expect(!r1.ruleFindings.isEmpty)
        let priv = try await rig(texts: (Self.release1, Self.release4, "x"), privileged: [1])
        let r2 = try await priv.svc.findContradictions(caseID: priv.caseID, at: t0)
        #expect(priv.sent.all.isEmpty)               // only one document clears: nothing to compare in the cloud
        #expect(r2.deniedForCloud == 1)
        #expect(!r2.ruleFindings.isEmpty)            // the on-device rules still compared both
        let offline = try await rig(texts: (Self.release1, Self.release4, "x"), reader: false)
        let r3 = try await offline.svc.findContradictions(caseID: offline.caseID, at: t0)
        #expect(!r3.readerAvailable && offline.sent.all.isEmpty && !r3.ruleFindings.isEmpty)
    }

    @Test("A fabricated AI pair from the reader is dropped and never stored")
    func fabricatedPairDropped() async throws {
        let reply = """
        {"pairs": [{"about": "William Jamey Thompson", "kind": "amount",
          "a": {"passage": 1, "quote": "Thompson admitted taking $200,000 in cash"},
          "b": {"passage": 2, "quote": "Thompson, in exchange for placing coverage, received $50,000."},
          "value_a": "$200,000", "value_b": "$50,000"}]}
        """
        let r = try await rig(texts: (Self.release1, Self.release4, "x"), reply: reply)
        let run = try await r.svc.findContradictions(caseID: r.caseID, at: t0)
        #expect(run.aiFindings.isEmpty)
        #expect(!run.aiDropped.isEmpty)
        // Each drop says why and what the pair proposed (smoke 2026-11-03: "6 dropped", no reasons).
        #expect(run.aiDropped.contains { $0.hasPrefix("quote not in its passage — about William Jamey Thompson (amount): $200,000") }, "\(run.aiDropped)")
        let stored = try await r.svc.contradictions(caseID: r.caseID)
        #expect(stored.allSatisfy { !$0.contradiction.claimA.contains("200,000") && !$0.contradiction.claimB.contains("200,000") })
    }

    @Test("A failed reader call is recorded with the provider's reason, per call")
    func failedCallReason() async throws {
        let r = try await rig(texts: (Self.release1, Self.release4, "x"),
                              failure: OnlineRequestBuilder.ParseError.cutOff("1500 output tokens, 1500 of them thinking"))
        let run = try await r.svc.findContradictions(caseID: r.caseID, at: t0)
        #expect(run.calls == 0 && run.failedCalls >= 1 && run.failures.count == run.failedCalls)
        #expect(run.failures.allSatisfy { $0.hasPrefix("contradiction call (") && $0.contains("cut off at the output limit") }, "\(run.failures)")
        #expect(!run.ruleFindings.isEmpty)
    }
}

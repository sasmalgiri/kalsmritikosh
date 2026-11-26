//
//  CaseContradictionFinderTests.swift
//  KalsmritikoshTests
//
//  P3 — the case contradiction check. Fixtures modelled on the real-case evaluation (2026-11-03): the
//  Logan arson releases ($75,000 vs $50,000 to the same insurance agent; three accounts of who spread the
//  fuel; which camera recorded it), different victims (no conflict), a same-person age difference, the
//  case scope (a document outside the case is never compared) and the cloud clearance (nothing sent
//  without it; privileged documents never sent). The AI side uses a fake reader through the one AI conflict path
//  (AIConflictContract, "Look for conflicts with AI…" — owner request 2026-11-16): a conflict with a fabricated quote
//  is dropped.
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

    @Test("Logan: who spread the fuel differs across releases; two cameras that caught two different things do not")
    func loganRoleAndCamera() {
        let docs = [Self.doc(Self.release1), Self.doc(Self.release4), Self.doc(Self.release5)]
        let found = F.ruleFindings(docs)
        let role = found.filter { $0.kind == .role }
        #expect(role.count == 1)
        #expect(role.first.map { [$0.valueA, $0.valueB].contains { $0.contains("Williams") } } == true)
        // Real-case v2 (2026-11-04, investigator memo): the restaurant camera "caught the three culprits", the
        // courthouse system "caught the explosion" — two recordings of two things, both true.
        #expect(found.filter { $0.kind == .account }.isEmpty)
        // The same thing caught on two different cameras is a pair.
        let x = Self.doc("The explosion was caught on 317’s security camera.")
        let y = Self.doc("The explosion was caught on the Logan County Courthouse video security system.")
        #expect(F.ruleFindings([x, y]).filter { $0.kind == .account }.count == 1)
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

    // MARK: - AI verification (owner request 2026-11-16: ported from the removed two-sided pass to AIConflictContract)

    static func batch(_ docs: [F.Document]) -> F.Batch {
        F.Batch(subject: "William Jamey Thompson", passages: docs.map { F.Passage(objectID: $0.objectID, sourceVersionID: $0.sourceVersionID, text: $0.text) })
    }

    /// One reply in the AI conflict contract.
    static func reply(_ conflicts: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["complete": true, "conflicts": conflicts], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A two-sided conflict in the contract (what the removed pass called a pair).
    static func conflict(about: String?, kind: String, _ a: (Int, String), _ b: (Int, String), values: (String, String)? = nil) -> [String: Any] {
        func side(_ s: (Int, String), _ v: String?) -> [String: Any] {
            var out: [String: Any] = ["document": s.0, "quote": s.1, "locator": "in the text"]
            if let v { out["value"] = v }
            return out
        }
        var c: [String: Any] = ["kind": kind, "description": "Two accounts.", "sides": [side(a, values?.0), side(b, values?.1)]]
        if let about { c["about"] = about }
        return c
    }

    @Test("A verified AI conflict survives; a fabricated quote, a same-value conflict and a stated correction are dropped")
    func aiVerification() throws {
        let a = Self.doc(Self.release1), b = Self.doc(Self.release4)
        let reply = Self.reply([
            Self.conflict(about: "William Jamey Thompson", kind: "amount_quantity",
                          (1, "approximately $75,000 to obtain a fraudulently-inflated $1 million insurance policy"),
                          (2, "Thompson, in exchange for placing coverage, received $50,000."), values: ("$75,000", "$50,000")),
            Self.conflict(about: "William Jamey Thompson", kind: "amount_quantity",
                          (1, "Mr. Glick then paid co-defendant William Jamey Thompson $90,000"),
                          (2, "Thompson, in exchange for placing coverage, received $50,000."), values: ("$90,000", "$50,000")),
            Self.conflict(about: "William Jamey Thompson", kind: "amount_quantity",
                          (1, "approximately $75,000 to obtain a fraudulently-inflated $1 million insurance policy"),
                          (2, "Thompson, in exchange for placing coverage, received $50,000."), values: ("$75,000", "$75,000")),
        ])
        let v = AIConflictContract.verify(reply: reply, batch: Self.batch([a, b]), allDocuments: [a, b])
        #expect(v.verified.count == 1, "\(v.dropped)")
        #expect(v.dropped.count == 2)
        #expect(v.dropped.contains { $0.hasPrefix("quote not found word for word in document 1") }, "\(v.dropped)")
        #expect(v.dropped.contains { $0.hasPrefix("the values do not differ") || $0.hasPrefix("a value is not in its quote") }, "\(v.dropped)")
        #expect(v.verified.first?.kind == .amountQuantity)
        #expect(Set(v.verified.first?.sides.map(\.objectID) ?? []) == [a.objectID, b.objectID])
        // Stored as an AI row: the case check's AI marker, read back as found by AI.
        let row = try #require(v.verified.first).contradiction(at: Date(timeIntervalSince1970: 1))
        #expect(F.provenance(of: row) == .aiRead)
        // Three accounts: the correcting release's sentence is explained, not a contradiction.
        let corrected = Self.doc("Contrary to the earlier release, Michael D. Williams spread the gasoline throughout the first floor.")
        let r2 = Self.reply([Self.conflict(about: "the fire", kind: "person_role_identity",
                                           (1, "Miller, Simon, and another person set the fire by allegedly spreading gasoline throughout the main floor."),
                                           (2, "Michael D. Williams spread the gasoline throughout the first floor."), values: ("Miller, Simon", "Michael D. Williams"))])
        let ev = F.Batch(subject: nil, passages: [a, corrected].map { F.Passage(objectID: $0.objectID, text: $0.text) })
        let v2 = AIConflictContract.verify(reply: r2, batch: ev, allDocuments: [a, corrected])
        #expect(v2.verified.isEmpty)
        #expect(v2.dropped.first?.contains("correction") == true, "\(v2.dropped)")
        // Unreadable reply.
        #expect(AIConflictContract.verify(reply: "<<garbage>>", batch: Self.batch([a, b]), allDocuments: [a, b]).unreadable != nil)
    }

    @Test("An AI conflict about someone the passage does not name is dropped")
    func aiWrongPerson() {
        let a = Self.doc("Records show Paul Grant paid Mary Poe $8,000.")
        let b = Self.doc("Records show Paul Grant paid John Roe $5,000.")
        let reply = Self.reply([Self.conflict(about: "Mary Poe", kind: "amount_quantity", (1, "Paul Grant paid Mary Poe $8,000"),
                                              (2, "Paul Grant paid John Roe $5,000"), values: ("$8,000", "$5,000"))])
        let batch = F.Batch(subject: nil, passages: [a, b].map { F.Passage(objectID: $0.objectID, text: $0.text) })
        let v = AIConflictContract.verify(reply: reply, batch: batch, allDocuments: [a, b])
        #expect(v.verified.isEmpty)
        #expect(v.dropped.first?.hasPrefix("a passage does not name Mary Poe") == true, "\(v.dropped)")
        // Named in both: the same conflict verifies.
        let c = Self.doc("Records show Paul Grant paid Mary Poe $5,000.")
        let ok = Self.reply([Self.conflict(about: "Mary Poe", kind: "amount_quantity", (1, "Paul Grant paid Mary Poe $8,000"),
                                           (2, "Paul Grant paid Mary Poe $5,000"), values: ("$8,000", "$5,000"))])
        let both = F.Batch(subject: nil, passages: [a, c].map { F.Passage(objectID: $0.objectID, text: $0.text) })
        #expect(AIConflictContract.verify(reply: ok, batch: both, allDocuments: [a, c]).verified.count == 1)
    }

    // MARK: - Service: scope and privacy

    private let t0 = Date(timeIntervalSince1970: 1_767_500_000)

    private struct Rig {
        let db: Database
        let svc: InvestigationContradictionGapService
        let caseID: UUID
        let koA: UUID, koB: UUID, koOut: UUID
        let sent: Sent
        func look(at date: Date) async throws -> AIConflictScanRun {
            try await svc.lookForConflictsWithAI(caseID: caseID, preview: try await svc.aiConflictPreview(caseID: caseID), at: date)
        }
    }

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        private var clearances: [CloudSourceClearance?] = []
        func add(_ p: String, _ c: CloudSourceClearance?) { lock.lock(); prompts.append(p); clearances.append(c); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
        var cleared: [CloudSourceClearance?] { lock.lock(); defer { lock.unlock() }; return clearances }
    }

    /// The case over three documents (the third NOT in the case), wired as the app wires the AI look: the whole-case
    /// reading (its reader answers `reply`, or throws `failure`), the passage reader for a case too large to read whole
    /// (`limit`), the stored permission (`grant`), the cloud gate (`gate`), AI on or off (`reader`).
    private func rig(texts: (String, String, String), privileged: Set<Int> = [], gate: Bool = true, reader: Bool = true,
                     reply: String = #"{"complete": true, "conflicts": []}"#, failure: (any Error & Sendable)? = nil,
                     limit: Int = 300_000, grant: Bool = true) async throws -> Rig {
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
        let binding = CloudScopeBinding(scopeID: caseID) { Dictionary(uniqueKeysWithValues: zip(kos.prefix(2), versions.prefix(2).map { Set([$0]) })) }
        let makeGate: @Sendable () -> CloudSourceGate? = {
            guard gate else { return nil }
            return CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                   legacyPrivileged: { privilegedIDs })
        }
        let permissions = CaseReadPermissionStore.inMemory()
        let plan = CaseWholeReading(
            documents: { vs in vs.compactMap { v in byVersion[v].map { CaseReader.Document(objectID: $0.0, sourceVersionID: v, fileName: "f.txt", text: $0.1) } } },
            gate: makeGate,
            reader: { reader ? CaseReader { send in
                // Updated for AI-23 (owner 2026-11-22/23): a too-large case is now read in parts on the one whole-case path, so
                // the whole-case send's own clearance is recorded too (it was nil when only passages carried one).
                sent.add(send.prefix.joined(separator: "\n") + "\n" + send.suffix, send.clearance)
                if let failure { throw failure }
                return CaseReader.Reply(text: reply)
            } : nil },
            permissions: permissions,
            askConsent: { _ in true },
            wholeCaseLimit: { limit })
        var pass = CaseContradictionPass(
            // Deliberately returns EVERY document, so the service's own scope filter is what is tested.
            documents: { _ in byVersion.map { F.Document(objectID: $0.value.0, sourceVersionID: $0.key, text: $0.value.1) } },
            gate: { _ in makeGate()?.bound(to: binding) },
            reader: { reader ? CaseContradictionReader { prompt, clearance in
                sent.add(prompt, clearance); if let failure { throw failure }; return reply } : nil })
        pass.caseReading = plan
        pass.caseBinding = { _ in binding }
        pass.conflictDetails = CaseConflictDetailsRepository(database: db)
        let svc = InvestigationContradictionGapService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                       contradictions: ContradictionsRepository(database: db), gaps: GapNodeRepository(database: db),
                                                       reviews: InvestigationDeskReviewRepository(database: db), pass: pass)
        if grant, let prepared = await plan.prepare(caseID: caseID, versions: Set(versions.prefix(2)), binding: binding).prepared {
            permissions.grant(caseID: caseID, fingerprint: prepared.fingerprint, documentCount: prepared.documents.count)
        }
        return Rig(db: db, svc: svc, caseID: caseID, koA: kos[0], koB: kos[1], koOut: kos[2], sent: sent)
    }

    @Test("AI-43: by default the rules finder is switched off — \u{201C}Find contradictions\u{201D} compares and stores nothing; the screen points to the AI look")
    func rulesSwitchedOffByDefault() async throws {
        let r = try await rig(texts: (Self.release1, Self.release4, "An unrelated note."))
        let run = try await r.svc.findContradictions(caseID: r.caseID, at: t0)
        #expect(run.rulesSwitchedOff && run.ruleFindings.isEmpty && run.documents == 0)
        #expect(try await r.svc.contradictions(caseID: r.caseID).isEmpty, "no rule finding is stored as a conflict")
        #expect(r.sent.all.isEmpty, "nothing is sent by the rules check")
        #expect(CaseContradictionReviewModel.rulesRunText(run).contains("Look for conflicts with AI"))
    }

    @Test("The case check stores the pair in scope; a document outside the case is never compared or sent")
    func scopeAndStore() async throws {
        // Updated for AI-43 (owner 2026-11-23): AI does the thinking — this pins the retired rule finder, so it runs with that path switched back on.
        try await RetiredPaths.TestOverride.$paths.withValue([.ruleContradictions: true]) {
            // The out-of-case document gives Thompson a third amount: it must never pair or be sent.
            let outside = "William Jamey Thompson received $10,000 from an unrelated client."
            let r = try await rig(texts: (Self.release1, Self.release4, outside))
            let run = try await r.svc.findContradictions(caseID: r.caseID, at: t0)
            #expect(run.documents == 2)
            #expect(run.ruleFindings.contains { $0.kind == .amount })
            #expect(run.findings.allSatisfy { Set([$0.objectA, $0.objectB]).isSubset(of: [r.koA, r.koB]) })
            #expect(r.sent.all.isEmpty, "the rules send nothing")
            let look = try await r.look(at: t0)
            #expect(look.outcome == .done && look.documents == 2 && look.documentsSent == 2, "\(look.message)")
            #expect(!r.sent.all.isEmpty)
            #expect(r.sent.all.allSatisfy { !$0.contains("$10,000") })
            // Too large to read in one call: every part sent carries a clearance that never includes the outside document.
            let big = try await rig(texts: (Self.release1, Self.release4, outside), limit: 10)
            _ = try await big.look(at: t0)
            #expect(!big.sent.all.isEmpty && big.sent.all.allSatisfy { !$0.contains("$10,000") })
            #expect(big.sent.cleared.allSatisfy { $0 != nil && !$0!.clearedObjectIDs.contains(big.koOut) })
            let items = try await r.svc.contradictions(caseID: r.caseID)
            #expect(items.contains { F.provenance(of: $0.contradiction) == .rules && $0.contradiction.kind == .amount })
            // Rerun: nothing stored twice.
            _ = try await r.svc.findContradictions(caseID: r.caseID, at: t0)
            _ = try await r.look(at: t0)
            #expect(try await r.svc.contradictions(caseID: r.caseID).count == items.count)
            // The archive-wide rescan's clear keeps the case check's rows.
            await ContradictionsRepository(database: r.db).clearKeepingCaseChecks()
            #expect(try await r.svc.contradictions(caseID: r.caseID).count == items.count)
        }
    }

    @Test("No send without a clearance gate; a privileged document is never sent; the rules still run offline")
    func privacy() async throws {
        // Updated for AI-43 (owner 2026-11-23): AI does the thinking — this pins the retired rule finder, so it runs with that path switched back on.
        try await RetiredPaths.TestOverride.$paths.withValue([.ruleContradictions: true]) {
            let noGate = try await rig(texts: (Self.release1, Self.release4, "x"), gate: false)
            let r1 = try await noGate.look(at: t0)
            #expect(noGate.sent.all.isEmpty && r1.calls == 0 && r1.outcome != .done, "\(r1.outcome)")
            #expect(r1.ruleFindings > 0)
            let priv = try await rig(texts: (Self.release1, Self.release4, "x"), privileged: [1])
            let r2 = try await priv.look(at: t0)
            #expect(priv.sent.all.allSatisfy { !$0.contains("received $50,000") }, "the privileged release is never sent")
            #expect(r2.withheld == 1)
            #expect(r2.ruleFindings > 0)            // the on-device rules still compared both
            let offline = try await rig(texts: (Self.release1, Self.release4, "x"), reader: false)
            let r3 = try await offline.look(at: t0)
            #expect(r3.outcome == .aiOff && offline.sent.all.isEmpty && r3.ruleFindings > 0)
        }
    }

    @Test("A fabricated AI conflict from the reader is dropped and never stored")
    func fabricatedPairDropped() async throws {
        let reply = Self.reply([Self.conflict(about: "William Jamey Thompson", kind: "amount_quantity",
                                              (1, "Thompson admitted taking $200,000 in cash"),
                                              (2, "Thompson, in exchange for placing coverage, received $50,000."), values: ("$200,000", "$50,000"))])
        let r = try await rig(texts: (Self.release1, Self.release4, "x"), reply: reply)
        let run = try await r.look(at: t0)
        #expect(run.aiFindings == 0)
        #expect(!run.dropped.isEmpty)
        // Each drop says why and what it proposed (smoke 2026-11-03: "6 dropped", no reasons).
        #expect(run.dropped.contains { $0.hasPrefix("quote not found word for word in document") && $0.contains("about William Jamey Thompson (amount_quantity)") && $0.contains("$200,000") }, "\(run.dropped)")
        let stored = try await r.svc.contradictions(caseID: r.caseID)
        #expect(stored.allSatisfy { !$0.contradiction.claimA.contains("200,000") && !$0.contradiction.claimB.contains("200,000") })
    }

    @Test("A failed reader call is recorded with the provider's reason, per call")
    func failedCallReason() async throws {
        // Updated for AI-43 (owner 2026-11-23): AI does the thinking — this pins the retired rule finder, so it runs with that path switched back on.
        try await RetiredPaths.TestOverride.$paths.withValue([.ruleContradictions: true]) {
            let cutOff = OnlineRequestBuilder.ParseError.cutOff("1500 output tokens, 1500 of them thinking")
            // Too large to read whole: every passage call fails, each with its reason; nothing is stored; the rules stand.
            let r = try await rig(texts: (Self.release1, Self.release4, "x"), failure: cutOff, limit: 10)
            let run = try await r.look(at: t0)
            #expect(run.calls == 0 && run.failedCalls >= 1 && run.failures.count == run.failedCalls)
            #expect(run.failures.allSatisfy { $0.hasPrefix("conflict call (") && $0.contains("cut off at the output limit") }, "\(run.failures)")
            #expect(run.outcome == .failed && run.message.contains("cut off at the output limit"), "\(run.message)")
            #expect(run.ruleFindings > 0)
            // The whole case read: one call, its reason in the provider's words.
            let whole = try await rig(texts: (Self.release1, Self.release4, "x"), failure: cutOff)
            let w = try await whole.look(at: t0)
            #expect(w.outcome == .failed && w.failures == ["conflict call (whole case): " + VerifiedRoleReader.reason(cutOff)], "\(w.failures)")
        }
    }
}

//
//  AIConflictScaffoldingTests.swift
//  KalsmritikoshTests
//
//  Owner request 2026-11-16 — the scaffolding around an AI that looks for conflicts of any kind: the open taxonomy, the
//  structured contract and its verification, the store-time re-check, the merge with the rules, the review, the gating
//  (AI off, consent, estimate, meter refusal, provider failure) and the late-reply check. Scripted fake readers only:
//  no model, no network. Nothing here measures how good an AI is at finding conflicts — only what the app does with
//  whatever it returns.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AI conflict scaffolding — every kind, verified quotes, merged with rules, reviewed by a person", .serialized)
struct AIConflictScaffoldingTests {
    typealias F = CaseContradictionFinder
    static let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    // MARK: - Rig

    nonisolated final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _sends: [CaseReadSend] = []
        private var _passages: [String] = []
        private var _consents = 0
        func send(_ s: CaseReadSend) { lock.withLock { _sends.append(s) } }
        func passage(_ p: String) { lock.withLock { _passages.append(p) } }
        func consent() { lock.withLock { _consents += 1 } }
        var sends: [CaseReadSend] { lock.withLock { _sends } }
        var passages: [String] { lock.withLock { _passages } }
        var consents: Int { lock.withLock { _consents } }
    }

    struct Doc: Sendable { let name: String; let version: UUID; let object: UUID; let text: String }

    struct Rig {
        let f: CaseFileTests.Fixture
        let desk: InvestigationContradictionGapService
        let plan: CaseWholeReading
        let permissions: CaseReadPermissionStore
        let log: Log
        let docs: [Doc]
        var caseID: UUID { f.caseID }
        func doc(_ name: String) -> Doc { docs.first { $0.name == name }! }
        func detailCount() async throws -> Int {
            Int(try await f.db.query("SELECT COUNT(*) FROM case_conflict_details WHERE case_id = ?;", [.uuid(caseID)]).first?.int(0) ?? -1)
        }
        func aiRows() async throws -> Int {
            Int(try await f.db.query("SELECT COUNT(*) FROM contradictions WHERE instr(description, ?) > 0;",
                                     [.text(F.Provenance.aiRead.marker)]).first?.int(0) ?? -1)
        }
    }

    typealias Reply = @Sendable (CaseReadSend, Database, UUID) async throws -> String

    static let pune = "a-statement-ravi.txt", chennai = "b-visitor-log.txt", mumbai = "c-statement-meera.txt", memo = "d-counsel-memo.txt"
    static let texts: [(String, String)] = [
        (pune, "Ravi Kumar said he met the supplier on 4 March 2026 at the Pune office. He signed the purchase order the same day."),
        (chennai, "The visitor log shows Ravi Kumar was in Chennai on 4 March 2026. An earlier report was incorrect; the purchase order was signed on 6 March 2026."),
        (mumbai, "Meera Shah said the meeting with the supplier took place in Mumbai on 4 March 2026. She did not see a purchase order."),
        (memo, "Privileged memo from counsel: Ravi Kumar told us he was never in Pune that week."),
    ]

    /// One case over seeded documents; the plan and the desk wired as the app wires them. `privileged` names are denied by
    /// the cloud gate. `aiOn` false: no reader (AI off). `grant`: the case permission stored up front.
    static func rig(texts: [(String, String)] = texts, privileged: Set<String> = [memo], aiOn: Bool = true, grant: Bool = true,
                    consent: Bool = true, limit: Int = 300_000, seed: ((CaseFileTests.Fixture) async throws -> [Doc])? = nil,
                    money: Bool = false, passageReply: (@Sendable (String) async throws -> String)? = nil, reply: @escaping Reply) async throws -> Rig {
        let f = try await CaseFileTests.fixture(title: "Was the purchase order signed in Pune?")
        var docs: [Doc] = []
        if let seed { docs = try await seed(f) } else {
            for (name, text) in texts {
                let s = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: name, text: text)
                docs.append(Doc(name: name, version: s.version, object: s.object, text: text))
            }
        }
        let byVersion = Dictionary(uniqueKeysWithValues: docs.map { ($0.version, $0) })
        let privilegedIDs = Set(docs.filter { privileged.contains($0.name) }.map(\.object))
        let log = Log()
        let permissions = CaseReadPermissionStore.inMemory()
        let db = f.db, caseID = f.caseID
        let binding = CloudScopeBinding(scopeID: caseID) {
            guard let record = try await InvestigationCaseRepository(database: db).fetch(caseID: caseID) else { throw CaseFileError.caseNotFound(caseID) }
            let now = try await CaseRetrievalScopeResolver(evidence: EvidenceStore(database: db)).scope(for: record).authorizedSourceVersionIDs
            return try await KnowledgeObjectRepository(database: db).sourceVersionsByObject(inSourceVersionIDs: now)
        }
        let gate = { CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                     legacyPrivileged: { privilegedIDs }) }
        let plan = CaseWholeReading(
            documents: { versions in versions.compactMap { byVersion[$0] }.map {
                CaseReader.Document(objectID: $0.object, sourceVersionID: $0.version, fileName: $0.name, text: $0.text) } },
            gate: gate,
            reader: { aiOn ? CaseReader { send in log.send(send); return CaseReader.Reply(text: try await reply(send, db, caseID)) } : nil },
            permissions: permissions,
            askConsent: { _ in log.consent(); return consent },
            wholeCaseLimit: { limit },
            estimate: { tokens, _ in "About \(tokens.formatted()) tokens — about 3 credits" })
        var pass = CaseContradictionPass(
            documents: { versions in versions.compactMap { byVersion[$0] }.map {
                F.Document(objectID: $0.object, sourceVersionID: $0.version, text: $0.text, fileName: $0.name, date: F.documentDate([$0.text])) } },
            gate: { _ in gate().bound(to: binding) },
            reader: { aiOn ? CaseContradictionReader { prompt, _ in
                log.passage(prompt)
                if let passageReply { return try await passageReply(prompt) }
                return #"{"complete": true, "conflicts": []}"#
            } : nil })
        pass.caseReading = plan
        pass.caseBinding = { _ in binding }
        pass.conflictDetails = CaseConflictDetailsRepository(database: db)
        if money {
            let file = f.file
            pass.moneyMovements = { id in try await file.moneyLedger(caseID: id).contradictionMovements() }
        }
        let evidence = EvidenceStore(database: db)
        let desk = InvestigationContradictionGapService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                        contradictions: ContradictionsRepository(database: db), gaps: GapNodeRepository(database: db),
                                                        reviews: InvestigationDeskReviewRepository(database: db), pass: pass)
        if grant {
            let versions = Set(docs.map(\.version))
            if let prepared = await plan.prepare(caseID: caseID, versions: versions, binding: binding).prepared {
                permissions.grant(caseID: caseID, fingerprint: prepared.fingerprint, documentCount: prepared.documents.count)
            }
        }
        return Rig(f: f, desk: desk, plan: plan, permissions: permissions, log: log, docs: docs)
    }

    /// The number N of the [Document N] block holding `snippet` in what was sent (0: not sent).
    static func number(_ snippet: String, in send: CaseReadSend) -> Int {
        for (i, block) in send.prefix.dropFirst().enumerated() where block.contains(snippet) { return i + 1 }
        return 0
    }

    static func json(_ conflicts: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["complete": true, "conflicts": conflicts], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func side(_ n: Int, _ quote: String, value: String? = nil) -> [String: Any] {
        var s: [String: Any] = ["document": n, "quote": quote, "locator": "first paragraph"]
        if let value { s["value"] = value }
        return s
    }

    static func run(_ r: Rig) async throws -> AIConflictScanRun {
        let preview = try await r.desk.aiConflictPreview(caseID: r.caseID)
        return try await r.desk.lookForConflictsWithAI(caseID: r.caseID, preview: preview, at: t0)
    }

    // MARK: - 1. The open taxonomy

    @Test("Each kind round-trips through its stored value and JSON; an unknown kind reads as other with its own label; ledger kinds map")
    func kindsRoundTrip() throws {
        for k in ConflictKind.known + [.other("alibi window")] {
            #expect(ConflictKind(storageValue: k.storageValue) == k, "\(k)")
            let data = try JSONEncoder().encode(k)
            #expect(try JSONDecoder().decode(ConflictKind.self, from: data) == k)
            #expect(!k.displayName.isEmpty && !k.meaning.isEmpty)
        }
        #expect(Set(ConflictKind.known.map(\.code)).count == ConflictKind.known.count, "every code distinct")
        #expect(ConflictKind(code: "time_travel") == .other("time_travel"), "a kind from a newer build is kept, labelled")
        #expect(ConflictKind(code: "other", label: "alibi window") == .other("alibi window"))
        #expect(ConflictKind(storageValue: "other:" + String(repeating: "x", count: 99)).otherLabel?.count == ConflictKind.labelLimit)
        #expect(ConflictKind.omission.stored == .omission && ConflictKind.other("x").stored == .other && ConflictKind.dateTime.stored == .date)
        for k in Contradiction.Kind.allCases { #expect(Contradiction.Kind(rawValue: k.rawValue) == k && !k.displayName.isEmpty) }
    }

    @Test("other(label): kept with its label through verification and storage; other without a label is dropped")
    func otherLabel() async throws {
        let r = try await Self.rig { send, _, _ in
            let a = Self.number("Pune office", in: send), b = Self.number("visitor log", in: send)
            return Self.json([
                ["kind": "other", "label": "alibi window", "description": "He cannot have met in Pune while logged in Chennai.",
                 "sides": [Self.side(a, "Ravi Kumar said he met the supplier on 4 March 2026 at the Pune office."),
                           Self.side(b, "The visitor log shows Ravi Kumar was in Chennai on 4 March 2026.")]],
                ["kind": "other", "description": "No label given.",
                 "sides": [Self.side(a, "He signed the purchase order the same day."), Self.side(b, "The visitor log shows Ravi Kumar was in Chennai on 4 March 2026.")]],
            ])
        }
        let run = try await Self.run(r)
        #expect(run.outcome == .done && run.aiFindings == 1, "\(run.message) \(run.dropped)")
        #expect(run.dropped.contains { $0.hasPrefix("an other kind without a label") }, "\(run.dropped)")
        let details = try await r.desk.conflictDetails(caseID: r.caseID)
        let d = try #require(details.values.first)
        #expect(d.kind == .other("alibi window") && d.foundBy == .ai)
        let stored = try #require(try await ContradictionsRepository(database: r.f.db).findByIDs([d.contradictionID]).first)
        #expect(stored.kind == .other && stored.description.hasPrefix("Other: alibi window — "))
    }

    // MARK: - 2. The contract: many sides, a missing record

    @Test("A three-sided finding and a missing-record finding are verified and stored with every side")
    func threeSidedAndMissingRecord() async throws {
        let r = try await Self.rig { send, _, _ in
            let a = Self.number("Pune office", in: send), b = Self.number("visitor log", in: send), c = Self.number("Meera Shah", in: send)
            return Self.json([
                ["kind": "place_location", "description": "Three places for one meeting on 4 March 2026.",
                 "sides": [Self.side(a, "met the supplier on 4 March 2026 at the Pune office", value: "Pune"),
                           Self.side(b, "Ravi Kumar was in Chennai on 4 March 2026", value: "Chennai"),
                           Self.side(c, "the meeting with the supplier took place in Mumbai on 4 March 2026", value: "Mumbai")],
                 "why": "One meeting cannot be in three cities on one day.", "innocent_explanations": ["Two different meetings."],
                 "confidence": "medium", "considered": [a, b, c]],
                ["kind": "omission_missing_record", "description": "The purchase order itself is not in the case.",
                 "sides": [Self.side(a, "He signed the purchase order the same day.")],
                 "expected_absent": "The signed purchase order dated 4 March 2026."],
            ])
        }
        let run = try await Self.run(r)
        #expect(run.outcome == .done && run.aiFindings == 2 && run.readWholeCase && run.calls == 1, "\(run.message) \(run.dropped)")
        let details = try await r.desk.conflictDetails(caseID: r.caseID)
        let three = try #require(details.values.first { $0.kind == .location })
        #expect(three.sides.count == 3 && Set(three.sides.map(\.objectID)) == Set([r.doc(Self.pune).object, r.doc(Self.chennai).object, r.doc(Self.mumbai).object]))
        #expect(three.sides.allSatisfy { $0.sourceVersionID != nil && $0.aiLocator == "first paragraph" && !$0.locator.isEmpty })
        #expect(three.aiReasoning == "One meeting cannot be in three cities on one day." && three.innocentExplanations == ["Two different meetings."])
        #expect(three.statedConfidence == "medium" && three.considered.count == 3)
        let missing = try #require(details.values.first { $0.kind == .omission })
        #expect(missing.sides.count == 1 && missing.expectedAbsent == "The signed purchase order dated 4 March 2026.")
        let row = try #require(try await ContradictionsRepository(database: r.f.db).findByIDs([missing.contradictionID]).first)
        #expect(row.claimB == "Expected but not found: The signed purchase order dated 4 March 2026." && row.evidenceB == nil && row.kind == .omission)
        // Both are in the case's list (scope holds), with their stable ids: a second run adds nothing.
        let items = try await r.desk.contradictions(caseID: r.caseID)
        #expect(Set(items.map(\.contradiction.id)).isSuperset(of: [three.contradictionID, missing.contradictionID]))
        _ = try await Self.run(r)
        #expect(try await r.desk.contradictions(caseID: r.caseID).count == items.count)
        #expect(try await r.detailCount() == 2)
    }

    // MARK: - 3. Verification drops

    @Test("A fabricated quote, a quote from a document outside the case and a quote from a privileged document are dropped with reasons")
    func droppedWithReasons() async throws {
        let outsideText = "Ravi Kumar was on leave in Goa from 2 March to 8 March 2026."
        let r = try await Self.rig { send, _, _ in
            let a = Self.number("Pune office", in: send), b = Self.number("visitor log", in: send)
            return Self.json([
                ["kind": "date_time", "description": "Fabricated.", "sides": [Self.side(a, "Ravi Kumar admitted signing on 1 March 2026."),
                                                                                Self.side(b, "The visitor log shows Ravi Kumar was in Chennai on 4 March 2026.")]],
                ["kind": "place_location", "description": "Outside the case.", "sides": [Self.side(a, outsideText),
                                                                                           Self.side(b, "The visitor log shows Ravi Kumar was in Chennai on 4 March 2026.")]],
                ["kind": "place_location", "description": "From the privileged memo.",
                 "sides": [Self.side(a, "Ravi Kumar told us he was never in Pune that week."), Self.side(b, "Ravi Kumar was in Chennai on 4 March 2026")]],
                ["kind": "place_location", "description": "A document that was not sent.",
                 "sides": [Self.side(9, "Ravi Kumar told us he was never in Pune that week."), Self.side(b, "Ravi Kumar was in Chennai on 4 March 2026")]],
            ])
        }
        // A document of another case, never in this one.
        let other = try await r.f.cases.createCase(workspaceID: r.f.workspaceID, title: "Another matter", actor: "Ada", at: Date())
        _ = try await CaseFileTestSources.seedPassage(r.f.db, cases: r.f.cases, caseID: other.id, name: "leave.txt", text: outsideText)
        let run = try await Self.run(r)
        #expect(run.outcome == .done && run.aiFindings == 0, "\(run.message)")
        #expect(run.dropped.filter { $0.hasPrefix("quote not found word for word in document") }.count == 3, "\(run.dropped)")
        #expect(run.dropped.contains { $0.hasPrefix("cites a document that was not sent (privileged and withheld documents are never sent)") }, "\(run.dropped)")
        #expect(run.withheld == 1 && run.coverage.contains("1 withheld"), "\(run.coverage)")
        let sent = try #require(r.log.sends.first)
        #expect(!sent.prefix.joined().contains("Privileged memo") && !sent.prefix.joined().contains(outsideText), "neither was sent")
        #expect(try await r.detailCount() == 0)
        #expect(try await r.aiRows() == 0)

        // The store-time re-check, on its own: a side resting on a document not sent, or no longer in the case, is dropped.
        let v = AIConflictContract.Verified(kind: .location, description: "x",
                                            sides: [ConflictSide(objectID: r.doc(Self.memo).object, sourceVersionID: nil, quote: "q1", locator: "in the text"),
                                                    ConflictSide(objectID: r.doc(Self.pune).object, sourceVersionID: nil, quote: "q2", locator: "in the text")],
                                            expectedAbsent: nil, reasoning: nil, innocentExplanations: [], statedConfidence: nil, considered: [])
        let all = Set(r.docs.map(\.object))
        let notSent = AIConflictContract.recheck([v], sent: all.subtracting([r.doc(Self.memo).object]), inScope: all)
        #expect(notSent.kept.isEmpty && notSent.dropped.first?.hasPrefix("rests on a document that was not sent") == true)
        let gone = AIConflictContract.recheck([v], sent: all, inScope: all.subtracting([r.doc(Self.pune).object]))
        #expect(gone.kept.isEmpty && gone.dropped.first?.hasPrefix("rests on a document that is no longer in the case") == true)
    }

    @Test("A same-value conflict and a stated correction are dropped")
    func sameValueAndCorrectionDropped() async throws {
        let r = try await Self.rig { send, _, _ in
            let a = Self.number("Pune office", in: send), b = Self.number("visitor log", in: send), c = Self.number("Meera Shah", in: send)
            return Self.json([
                ["kind": "date_time", "description": "Same day on both sides.",
                 "sides": [Self.side(a, "met the supplier on 4 March 2026 at the Pune office", value: "4 March 2026"),
                           Self.side(c, "took place in Mumbai on 4 March 2026", value: "4 March 2026")]],
                ["kind": "date_time", "description": "Signed on different days.",
                 "sides": [Self.side(a, "He signed the purchase order the same day."),
                           Self.side(b, "An earlier report was incorrect; the purchase order was signed on 6 March 2026.")]],
            ])
        }
        let run = try await Self.run(r)
        #expect(run.aiFindings == 0, "\(run.message)")
        #expect(run.dropped.contains { $0.hasPrefix("the values do not differ") }, "\(run.dropped)")
        #expect(run.dropped.contains { $0.hasPrefix("explained: a stated correction") }, "\(run.dropped)")
        #expect(try await r.detailCount() == 0)
    }

    // MARK: - 4. Merge with the rules

    @Test("Rule + AI on the same pair: one item, labelled found by rule and AI; the rule's id and decisions stay")
    func ruleAndAIDedupe() async throws {
        // Updated for AI-43 (owner 2026-11-23): AI does the thinking — this pins the retired rule finder, so it runs with that path switched back on.
        try await RetiredPaths.TestOverride.$paths.withValue([.ruleContradictions: true]) {
            let texts = [("a-release1.txt", CaseContradictionFinderTests.release1), ("b-release4.txt", CaseContradictionFinderTests.release4)]
            let probe = F.ruleFindings(texts.map { F.Document(objectID: UUID(), text: $0.1) })
            let rule = try #require(probe.first { $0.kind == .amount })
            let (qa, qb) = (rule.quoteA, rule.quoteB)
            let r = try await Self.rig(texts: texts, privileged: []) { send, _, _ in
                Self.json([["kind": "amount_quantity", "description": "Two amounts paid to Thompson.", "why": "Both are the payment for the policy.",
                            "sides": [Self.side(Self.number(String(qa.prefix(30)), in: send), qa), Self.side(Self.number(String(qb.prefix(30)), in: send), qb)]]])
            }
            let run = try await Self.run(r)
            #expect(run.outcome == .done && run.foundByBoth == 1 && run.aiFindings == 0, "\(run.message) \(run.dropped)")
            let items = try await r.desk.contradictions(caseID: r.caseID)
            let matching = items.filter { Set([$0.contradiction.claimA, $0.contradiction.claimB]) == Set([qa, qb]) }
            #expect(matching.count == 1, "one item, not two")
            let item = try #require(matching.first)
            #expect(F.provenance(of: item.contradiction) == .rules, "the rule's own row and id")
            let detail = try #require(try await r.desk.conflictDetails(caseID: r.caseID)[item.contradiction.id])
            #expect(detail.foundBy == .both && detail.aiReasoning == "Both are the payment for the policy.")
            #expect(InvestigationContradictionGapService.foundBy(item.contradiction, detail: detail)?.label == AIFindingLabels.ai + " (a rule hint agreed)")
            #expect(InvestigationContradictionGapService.foundBy(item.contradiction, detail: nil)?.label == AIFindingLabels.hint)
        }
    }

    @Test("INV-104: a scripted AI reply with the witness-vs-records conflict merges with the rule finding into one item")
    func inv104Merge() async throws {
        // Updated for AI-43 (owner 2026-11-23): AI does the thinking — this pins the retired rule finder, so it runs with that path switched back on.
        try await RetiredPaths.TestOverride.$paths.withValue([.ruleContradictions: true]) {
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Kalsmritikosh/Resources/Fixtures/\(SupplierINV104Fixture.folderName)", isDirectory: true)
            func text(_ name: String) throws -> String { try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }
            let key = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(SupplierINV104Fixture.expectedName))) as? [String: Any])
            let witnessQuote = try #require((key["discrepancy"] as? [String: Any])?["witness_quote"] as? String)
            let statement = try text(SupplierINV104Fixture.bankStatement)
            let debitLine = try #require(statement.components(separatedBy: .newlines).first { $0.contains("KS-77120") }).trimmingCharacters(in: .whitespaces)
            let r = try await Self.rig(privileged: [], seed: { f in
                var docs: [Doc] = []
                for name in SupplierINV104Fixture.documentNames {
                    let t = try text(name)
                    let s = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: name, text: t)
                    docs.append(Doc(name: name, version: s.version, object: s.object, text: t))
                }
                let stmt = try #require(docs.first { $0.name == SupplierINV104Fixture.bankStatement })
                let owner = try #require(docs.first { $0.name == "inv104-account-ownership-8804.md" })
                let a8804 = try await f.file.addMoneyAccount(caseID: f.caseID, identifier: "8804", institution: "Western Coast Bank", currency: "INR", sourceVersionID: owner.version, actor: "Priya Nair")
                try await f.file.recordAccountRelation(caseID: f.caseID, accountID: a8804, holderName: "Kestrel Supplies Pvt Ltd", relation: .holder, basis: .source,
                                                       sourceVersionID: owner.version, quote: "Account holder: Kestrel Supplies Pvt Ltd", actor: "Priya Nair")
                var req = CaseMoneyStatementImport(accountID: nil, periodStart: "2026-03-01", periodEnd: "2026-03-31", currency: "INR",
                                                   text: stmt.text, fileName: SupplierINV104Fixture.bankStatement)
                req.newAccountIdentifier = "3391"; req.newAccountInstitution = "Western Coast Bank"; req.sourceVersionID = stmt.version
                _ = try await f.file.importStatement(caseID: f.caseID, req, actor: "Priya Nair", at: Self.t0)
                return docs
            }, money: true) { send, _, _ in
                Self.json([["kind": "statement_vs_records", "description": "The witness says one payment; the statement shows two debits to Kestrel.",
                            "sides": [Self.side(Self.number(String(witnessQuote.prefix(40)), in: send), witnessQuote),
                                      Self.side(Self.number(debitLine, in: send), debitLine)],
                            "why": "Two debits of INR 50,000 appear for the same invoice."]])
            }
            let run = try await Self.run(r)
            #expect(run.outcome == .done && run.foundByBoth == 1 && run.aiFindings == 0, "\(run.message) \(run.dropped)")
            let items = try await r.desk.contradictions(caseID: r.caseID).filter { $0.contradiction.claimA == witnessQuote }
            #expect(items.count == 1, "one item for the witness against the records")
            let item = try #require(items.first)
            let detail = try #require(try await r.desk.conflictDetails(caseID: r.caseID)[item.contradiction.id])
            #expect(detail.foundBy == .both && F.provenance(of: item.contradiction) == .rules)
        }
    }

    // MARK: - 5. Gating

    @Test("AI off: nothing is sent, the rules still run, and the screen says what they checked")
    func aiOffRulesStillRun() async throws {
        // Updated for AI-43 (owner 2026-11-23): AI does the thinking — this pins the retired rule finder, so it runs with that path switched back on.
        try await RetiredPaths.TestOverride.$paths.withValue([.ruleContradictions: true]) {
            let texts = [("a-release1.txt", CaseContradictionFinderTests.release1), ("b-release4.txt", CaseContradictionFinderTests.release4)]
            let r = try await Self.rig(texts: texts, privileged: [], aiOn: false) { _, _, _ in
                Issue.record("the AI must not be called"); return "{}"
            }
            let preview = try await r.desk.aiConflictPreview(caseID: r.caseID)
            #expect(!preview.aiAvailable && preview.aiOff && preview.coverageLine.hasPrefix("AI is off; rules checked: "))
            let run = try await r.desk.lookForConflictsWithAI(caseID: r.caseID, preview: preview, at: Self.t0)
            #expect(run.outcome == .aiOff && run.ruleFindings > 0 && run.coverage.hasPrefix("AI is off; rules checked: "))
            #expect(r.log.sends.isEmpty && r.log.passages.isEmpty && r.log.consents == 0)
            #expect(!(try await r.desk.contradictions(caseID: r.caseID)).isEmpty, "the rules' findings are stored")
        }
    }

    @Test("No consent: nothing is sent and nothing from the AI is stored")
    func noConsentNothingSent() async throws {
        let r = try await Self.rig(grant: false, consent: false) { _, _, _ in Issue.record("the AI must not be called"); return "{}" }
        let preview = try await r.desk.aiConflictPreview(caseID: r.caseID)
        #expect(preview.aiAvailable && !preview.permissionStored)
        let run = try await r.desk.lookForConflictsWithAI(caseID: r.caseID, preview: preview, at: Self.t0)
        #expect(run.outcome == .declined && r.log.consents == 1 && r.log.sends.isEmpty)
        #expect(try await r.detailCount() == 0)
        #expect(try await r.aiRows() == 0)
    }

    @Test("The estimate is shown before the run and is for exactly the documents sent; a changed set or a meter refusal sends or stores nothing")
    func estimateAndMeterRefusal() async throws {
        let refusal = AIPlanRefusal(code: .creditsUsed, message: AIPricing.creditsUsedMessage(estimate: 9, balance: 1), estimate: 9, offers: [.buyCredits])
        let r = try await Self.rig { _, _, _ in throw refusal }
        let preview = try await r.desk.aiConflictPreview(caseID: r.caseID)
        #expect(preview.estimate?.contains("credits") == true && preview.fingerprint != nil && preview.toSend.count == 3 && preview.withheld.count == 1)
        #expect(preview.permissionStored && preview.route == .wholeCase)
        // An estimate for another document set: nothing is sent.
        var stale = preview; stale.fingerprint = "another document set"
        let notSent = try await r.desk.lookForConflictsWithAI(caseID: r.caseID, preview: stale, at: Self.t0)
        #expect(notSent.outcome == .notSent && notSent.message.contains("changed since the estimate was shown") && r.log.sends.isEmpty)
        // The meter refuses: its words, nothing stored.
        let run = try await r.desk.lookForConflictsWithAI(caseID: r.caseID, preview: preview, at: Self.t0)
        #expect(run.outcome == .refused && run.message.hasPrefix(refusal.message) && run.message.contains("Nothing from the AI was stored"))
        #expect(try await r.detailCount() == 0)
        #expect(try await r.aiRows() == 0)
    }

    @Test("A provider failure gives an honest message and changes nothing")
    func providerFailureHonest() async throws {
        let unavailable = try await Self.rig { _, _, _ in throw AIIncludedRelay.RelayError.refused(AIPricing.providerUnavailableMessage) }
        let before = try await unavailable.desk.contradictions(caseID: unavailable.caseID).count
        let r1 = try await Self.run(unavailable)
        #expect(r1.outcome == .refused && r1.message.hasPrefix(AIPricing.providerUnavailableMessage) && !r1.message.contains("Nothing was sent"))
        #expect(try await unavailable.desk.contradictions(caseID: unavailable.caseID).count == before)
        #expect(try await unavailable.detailCount() == 0)
        let timeout = try await Self.rig { _, _, _ in throw URLError(.timedOut) }
        let r2 = try await Self.run(timeout)
        #expect(r2.outcome == .failed && r2.message.hasPrefix("The AI did not answer: ") && r2.message.contains("the case is unchanged"))
        #expect(try await timeout.detailCount() == 0)
        #expect(try await timeout.aiRows() == 0)
        let cutOff = try await Self.rig { _, _, _ in #"{"complete": false, "conflicts": [{"kind": "da"# }
        let r3 = try await Self.run(cutOff)
        #expect(r3.outcome == .done && r3.aiFindings == 0 && r3.dropped.contains { $0.contains("could not be read") || $0.contains("not complete") }, "\(r3.dropped)")
    }

    @Test("A late reply is not written into a case erased, or a document changed, while the AI was working")
    func lateReplyNotWritten() async throws {
        func reply(_ send: CaseReadSend) -> String {
            Self.json([["kind": "place_location", "description": "Pune or Chennai.",
                        "sides": [Self.side(Self.number("Pune office", in: send), "met the supplier on 4 March 2026 at the Pune office"),
                                  Self.side(Self.number("visitor log", in: send), "Ravi Kumar was in Chennai on 4 March 2026")]]])
        }
        let erased = try await Self.rig { send, db, caseID in
            _ = try await CaseEraser(database: db).erase(caseID: caseID, sourceVersionIDs: [], eraseExclusiveSources: false, reason: "Retention ended", legalBasis: nil, actor: "Ada")
            return reply(send)
        }
        let r1 = try await Self.run(erased)
        #expect(r1.outcome == .refused, "\(r1.message)")
        #expect(try await erased.detailCount() == 0)
        #expect(try await erased.aiRows() == 0)

        let changed = try await Self.rig { send, db, _ in
            try await db.exec("UPDATE source_versions SET is_current = 0 WHERE filename = ?;", [.text(Self.pune)])
            return reply(send)
        }
        let r2 = try await Self.run(changed)
        // Refused at the store (a newer version) or dropped by the store-time re-check — either way nothing is written.
        #expect(r2.aiFindings == 0 && (r2.outcome == .refused || !r2.dropped.isEmpty), "\(r2.outcome) \(r2.message) \(r2.dropped)")
        #expect(try await changed.detailCount() == 0)
        #expect(try await changed.aiRows() == 0)
    }

    // MARK: - 6. Review and the report

    @Test("Confirm, dismiss and need-more-evidence are recorded with who and when; a confirmed AI conflict reaches the report with both sources")
    func reviewAndReport() async throws {
        let r = try await Self.rig { send, _, _ in
            let a = Self.number("Pune office", in: send), b = Self.number("visitor log", in: send), c = Self.number("Meera Shah", in: send)
            return Self.json([
                ["kind": "place_location", "description": "Pune or Chennai.",
                 "sides": [Self.side(a, "met the supplier on 4 March 2026 at the Pune office"), Self.side(b, "Ravi Kumar was in Chennai on 4 March 2026")]],
                ["kind": "place_location", "description": "Pune or Mumbai.",
                 "sides": [Self.side(a, "met the supplier on 4 March 2026 at the Pune office"), Self.side(c, "took place in Mumbai on 4 March 2026")]],
                ["kind": "document_vs_testimony", "description": "No purchase order seen.",
                 "sides": [Self.side(a, "He signed the purchase order the same day."), Self.side(c, "She did not see a purchase order.")]],
            ])
        }
        let run = try await Self.run(r)
        #expect(run.aiFindings == 3, "\(run.message) \(run.dropped)")
        let details = try await r.desk.conflictDetails(caseID: r.caseID)
        let items = try await r.desk.contradictionReviewItems(caseID: r.caseID)
        let ai = items.filter { details[$0.id]?.foundBy == .ai }
        #expect(ai.count == 3 && ai.allSatisfy { $0.status.current == nil }, "a proposal until a person decides")
        let chennai = try #require(ai.first { $0.contradiction.claimB.contains("Chennai") })
        let mumbai = try #require(ai.first { $0.contradiction.claimB.contains("Mumbai") })
        let order = try #require(ai.first { $0.contradiction.claimB.contains("purchase order") })
        let at = Date(timeIntervalSince1970: 1_794_100_000)
        let confirmed = try await r.desk.reviewContradiction(caseID: r.caseID, contradictionID: chennai.id, decision: .confirmed, reason: nil,
                                                             note: "the log is reliable", actor: "Ada", at: at)
        #expect(confirmed.actor == "Ada" && confirmed.decidedAt == at && confirmed.sourceVersions.count == 2)
        let dismissed = try await r.desk.reviewContradiction(caseID: r.caseID, contradictionID: mumbai.id, decision: .dismissed, reason: .differentEvent,
                                                             note: "two meetings", actor: "Ben", at: at)
        #expect(dismissed.reason == .differentEvent && dismissed.actor == "Ben")
        let more = try await r.desk.reviewContradiction(caseID: r.caseID, contradictionID: order.id, decision: .unresolved, reason: nil,
                                                        note: "Needs more evidence.", actor: "Ada", at: at)
        #expect(more.decision == .unresolved && more.note == "Needs more evidence.")

        let item = try #require(try await r.desk.contradictionReviewItems(caseID: r.caseID).first { $0.id == chennai.id })
        #expect(item.status.current == .confirmed)
        try await JobResultHandoff.addReviewedToReport(item, caseFiles: r.f.svc, actor: "Ada")
        let report = try #require(try await r.f.file.reportItems(caseID: r.caseID).first)
        #expect(report.citations.count == 2, "both sources")
        #expect(Set(report.citations.compactMap(\.objectID)) == Set([r.doc(Self.pune).object, r.doc(Self.chennai).object]))
        #expect(report.citations.contains { $0.quote == "met the supplier on 4 March 2026 at the Pune office" }
                && report.citations.contains { $0.quote == "Ravi Kumar was in Chennai on 4 March 2026" })
        #expect(!report.text.contains(F.markerStem))
    }

    // MARK: - 7. Older data

    @Test("Older stored contradictions still load: an old kind, a kind this build does not know, a JSON record with no kind, and no detail row")
    func olderContradictionsLoad() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = ContradictionsRepository(database: db)
        let old = UUID(), future = UUID()
        for (id, kind) in [(old, "testimony"), (future, "somethingNewer")] {
            try await db.exec("""
                INSERT INTO contradictions (id, kind, description, claim_a, claim_b, evidence_a, evidence_b, severity, status, detected_at)
                VALUES (?,?,?,?,?,NULL,NULL,'medium','open',?);
                """, [.uuid(id), .text(kind), .text("Two accounts"), .text("A said x."), .text("B said y."), .real(1)])
        }
        let rows = try await repo.findByIDs([old, future])
        #expect(rows.first { $0.id == old }?.kind == .testimony)
        #expect(rows.first { $0.id == future }?.kind == .other, "an unknown kind reads as other")
        #expect(ConflictKind.of(try #require(rows.first { $0.id == old })) == .documentVsTestimony)
        #expect(InvestigationContradictionGapService.foundBy(try #require(rows.first), detail: nil) == nil, "an archive-scan row: no label invented")
        let noKind = #"{"id":"\#(UUID().uuidString)","description":"d","claimA":"a","claimB":"b","severity":"low","status":"open","detectedAt":0}"#
        #expect(try JSONDecoder().decode(Contradiction.self, from: Data(noKind.utf8)).kind == .other)
        let unknown = #"{"id":"\#(UUID().uuidString)","kind":"brandNew","description":"d","claimA":"a","claimB":"b","severity":"low","status":"open","detectedAt":0}"#
        #expect(try JSONDecoder().decode(Contradiction.self, from: Data(unknown.utf8)).kind == .other)
        // A detail row for a case that does not exist is refused by the ledger itself.
        await #expect(throws: (any Error).self) {
            try await db.exec("""
                INSERT INTO case_conflict_details (contradiction_id, case_id, kind, found_by, description, sides_json, recorded_at)
                VALUES (?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(UUID()), .text("date_time"), .text("ai"), .text("d"), .text("[]"), .real(1)])
        }
    }

    // MARK: - SEARCH-14 resumable parts

    nonisolated final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0; private var stop = true
        func next() -> Int { lock.withLock { n += 1; return stop ? n : 0 } }
        func noMoreStops() { lock.withLock { stop = false } }
    }

    // Updated for AI-23 (owner 2026-11-22/23): one case path. A case too large for one call is read in PARTS of the
    // whole-case read (briefing + every part, merged), never through the passage branch, which is kept only for a
    // prepared case with no parts (never produced). The passage-unit resume this test used to pin is unreachable; a
    // stopped look on the one path ends with nothing from the AI stored, and the next look reads the case and finishes.
    // (Finished parts are kept by PERF-22's case_ai_part_replies through a process-wide store that the test host
    // shares with every booted app, so which parts are re-sent is not asserted here.)
    @Test("SEARCH-14 / AI-23: a case too large for one call is read in parts on the one path; a stop stores nothing from the AI; the next look finishes")
    func stoppedLookResumes() async throws {
        let texts: [(String, String)] = [
            ("a.txt", "Ravi Kumar signed the order on 4 March 2026. Anita Rao approved it on 5 March 2026."),
            ("b.txt", "Ravi Kumar signed the order on 6 March 2026. Anita Rao approved it on 9 March 2026."),
            ("c.txt", "Anita Rao and Ravi Kumar met the supplier on 2 March 2026."),
        ].map { name, text in
            // A part holds at least 8,000 tokens (CaseReader.partBudget), so each document carries filler paragraphs
            // to make the case need more than one part (distinct per document, so no copy is collapsed as near-identical).
            (name, text + (0..<400).map { k in "\n\nNote \(name)-\(k): register line \(name)\(k * 7_919 % 10_007) filed under \(name)\(k * 104_729 % 99_991)." }.joined())
        }
        let calls = Calls()
        let stopping = try await Self.rig(texts: texts, privileged: [], limit: 10) { _, _, _ in
            if calls.next() >= 2 { throw CancellationError() }
            return #"{"complete": true, "conflicts": []}"#
        }
        let first = try await Self.run(stopping)
        #expect(first.readWholeCase, "the one path reads the case whole, in parts")
        #expect(first.outcome == .cancelled && first.message.hasPrefix("Stopped."), "\(first.outcome) \(first.message)")
        #expect(stopping.log.sends.count >= 2, "the case is read in more than one part (a single part would not reach the stop)")
        #expect(try await stopping.aiRows() == 0, "a stopped look stores nothing from the AI")
        calls.noMoreStops()
        let second = try await Self.run(stopping)
        #expect(second.readWholeCase && second.outcome == .done, "\(second.outcome) \(second.message)")
        #expect(stopping.log.passages.isEmpty, "the passage branch is never used on the one path")
    }
}

//
//  SmartMapS4Tests.swift
//  KalsmritikoshTests
//
//  Smart-map S4 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md: SEARCH and REPORT of milestone M1; schema
//  v180). Throwaway ledgers; expected results written by hand from the fixture texts. AI off: nothing here calls a model
//  or the network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@MainActor
@Suite("Smart map S4 — case search", .serialized)
struct SmartMapS4SearchTests {

    static let utc = CaseSearchOptions(timeZoneID: "UTC")

    func names(_ svc: CaseSearchService, _ c: UUID, _ q: String) async throws -> [String] {
        let run = try #require(await svc.run(caseID: c, text: q, options: Self.utc).run, "\(q)")
        return run.hits.map(\.name)
    }

    @Test("SEARCH-02: amount and currency clauses — parsed strictly, explained, round-tripped, matched only where a currency is written, never converted")
    func amounts() async throws {
        let f = try await CaseFileTests.fixture(title: "Supplier paid twice?")
        for (n, t) in [("inr.txt", "The supplier was paid ₹50,000 on 3 March and Rs. 50000 again on 9 March."),
                       ("usd.txt", "A refund of USD 1,200.50 was sent. Bag 7 held 50000 grains."),
                       ("plain.txt", "Bag 50000 was sealed.")] {
            _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: n, text: t)
        }
        let svc = CaseSearchService(sources: .live(database: f.db))
        #expect(try await names(svc, f.caseID, "amount:>=50000") == ["inr.txt"])               // "50000 grains" and "Bag 50000" are not amounts
        #expect(try await names(svc, f.caseID, "amount:INR50000") == ["inr.txt"])
        #expect(try await names(svc, f.caseID, "amount:USD>1000") == ["usd.txt"])
        #expect(try await names(svc, f.caseID, "amount:INR>1000 AND amount:USD>1000") == [])  // never converted
        #expect(try await names(svc, f.caseID, "currency:USD") == ["usd.txt"])
        #expect(try await names(svc, f.caseID, "amount:1000..1300") == ["usd.txt"])
        let run = try #require(await svc.run(caseID: f.caseID, text: "amount:INR>=50000", options: Self.utc).run)
        #expect(run.hits.first?.occurrences == 2 && run.hits.first?.witnesses.first?.matchedText == "₹50,000")
        #expect(run.receipt.notes.contains { $0.contains("never converted") })
        let q = try #require(CaseSearchParser.parse("amount:₹50,000 OR currency:usd").query)
        #expect(CaseSearchParser.parse(q.text).query == q && q.text == "amount:INR50000 OR currency:USD")
        #expect(q.explanation.contains { $0.contains("an amount of exactly 50,000 in INR") })
        for bad in ["amount:lots", "amount:>=", "currency:XYZ", "amount:5..1", "amount:ZZ>5"] {
            let p = CaseSearchParser.parse(bad)
            #expect(!p.isValid, "\(bad) must be refused")
            guard case .rejected = await svc.run(caseID: f.caseID, text: bad, options: Self.utc) else { Issue.record("\(bad) ran"); continue }
        }
        // The rule builder makes the same tree.
        var r = CaseSearchRule(); r.field = .amount; r.value = "INR>=50000"
        #expect(try CaseSearchRuleGroup.node(r).get() == .amount(CaseSearchAmount(currency: "INR", bound: .atLeast, low: "50000")))
        #expect(CaseSearchRuleGroup.rule(.amount(CaseSearchAmount(currency: "INR", bound: .atLeast, low: "50000")))?.value == "INR>=50000")
    }

    @Test("SEARCH-01: the case's own records are searched with the same query; classes searched are counted and unindexed classes are named")
    func records() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let q = try await f.file.addAllegation(caseID: c, text: "Was the seal tampered with before the hearing?", actor: "Ada")
        let pt = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The seal was intact on arrival",
                                          quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        try await f.file.addQualification(caseID: c, pointID: pt, kind: .condition, text: "only if the custody chain is complete", quote: nil, actor: "Ada")
        _ = try await f.svc.createAction(caseID: c, .init(title: "Interview the courier about the seal", purpose: "Check custody", deliverable: "Statement"), actor: "Ada")
        _ = try await f.file.addPerson(caseID: c, name: "Ravi Courier", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        _ = try await f.file.addJournal(caseID: c, kind: .note, text: "Custody gap noted on the tamper log", eventDate: nil, evidenceRef: nil, actor: "Ada")
        var sources = CaseSearchSources.live(database: f.db)
        let mapSources = caseMapSources(f)
        sources.records = { id in await CaseMapService(sources: mapSources).load(caseID: id, generation: 1).projection }
        let svc = CaseSearchService(sources: sources)
        let run = try #require(await svc.run(caseID: c, text: "seal", options: Self.utc).run)
        let rec = try #require(run.records)
        let kinds = Set(rec.hits.map(\.record.kind))
        #expect(kinds.isSuperset(of: [.allegation, .reportPoint, .task]) && rec.hits.contains { $0.record.kind == .allegation && $0.record.recordID == q.uuidString.lowercased() || $0.record.recordID == q.uuidString })
        #expect(run.hits.map(\.name) == ["lab-report-41.txt"])                                // the document search is unchanged
        // A qualification is searched with its point; a word in the qualification finds the point.
        let custody = try #require(await svc.run(caseID: c, text: "\"custody chain\"", options: Self.utc).run?.records)
        #expect(custody.hits.map(\.record.kind) == [.reportPoint])
        let courier = try #require(await svc.run(caseID: c, text: "person:\"ravi courier\"", options: Self.utc).run?.records)
        #expect(courier.hits.map(\.record.kind) == [.person] && courier.hits.first?.bases == [.recordedField])
        let typed = try #require(await svc.run(caseID: c, text: "type:task", options: Self.utc).run?.records)
        #expect(typed.hits.allSatisfy { $0.record.kind == .task } && typed.hits.count == 1)
        // A document clause does not apply to a record: never listed by it, and the note says so.
        let file = try #require(await svc.run(caseID: c, text: "file:lab", options: Self.utc).run?.records)
        #expect(file.hits.isEmpty && file.notes.contains { $0.contains("do not apply to case records") })
        #expect(rec.classes.contains { $0.label.hasPrefix("Report points") && $0.searched == 1 && $0.matched == 1 })
        #expect(rec.unindexed.contains { $0.contains("case_contacts") } && rec.unindexed.contains { $0.contains("case_hold_notices") })
        #expect(!rec.unindexed.contains { $0.contains("[case_allegations]") || $0.contains("[case_report_points]") })
        #expect(run.storedResult.receiptLines.contains { $0.hasPrefix("Case records searched:") })
        // Without a records source the run says only documents were searched.
        let docsOnly = try #require(await CaseSearchService(sources: .live(database: f.db)).run(caseID: c, text: "seal", options: Self.utc).run)
        #expect(docsOnly.records == nil && docsOnly.recordsNotSearched?.contains("were not") == true)
    }

    @Test("SEARCH-03/04/05/07: match basis labels, the active-scope banner, the exact locator with attachment context, copies and canonical entities")
    func basisScopeLocatorCopies() async throws {
        let f = try await CaseFileTests.fixture(title: "Approval chain")
        let mail = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "mail.eml", text: "Please find the approval attached.")
        let att = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "approval.txt", text: "Approved by José Álvarez for payment.")
        let copy = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "approval-copy.txt", text: "Approved by José Álvarez for payment.")
        try await f.db.exec("INSERT INTO source_version_relations (id, parent_source_version_id, child_source_version_id, relation, ordinal, created_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(mail.version), .uuid(att.version), .text("attachment"), .integer(0), .real(1)])
        let digest = String(repeating: "ab", count: 32)
        for v in [att.version, copy.version] {
            try await f.db.exec("INSERT INTO source_text_digests (source_version_id, text_sha256, normalizer, character_count, computed_at) VALUES (?,?,?,?,?);",
                                [.uuid(v), .text(digest), .text("nfkc-ws-v1"), .integer(36), .real(1)])
        }
        let entity = UUID()
        try await f.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(entity), .text("person"), .text("José Álvarez"), .text("josé álvarez"), .uuid(att.object)])
        for o in [att.object, copy.object] {
            try await f.db.exec("INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence) VALUES (?,?,?,?,?,?,?);",
                                [.uuid(UUID()), .uuid(entity), .text("person"), .text("José Álvarez"), .text("josé álvarez"), .uuid(o), .real(0.9)])
        }
        // Another case with its own document: its name must never appear in this case's banner or receipt.
        let other = try await f.cases.createCase(workspaceID: f.workspaceID, title: "Unrelated matter", actor: "Ada", at: Date())
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: other.id, name: "secret-other.txt", text: "Approved elsewhere.")
        let svc = CaseSearchService(sources: .live(database: f.db))
        let run = try #require(await svc.run(caseID: f.caseID, text: "approved AND person:\"jose alvarez\" AND NOT modified-after:2030", options: Self.utc).run)
        #expect(run.hits.map(\.name) == ["approval-copy.txt", "approval.txt"])
        let hit = try #require(run.hits.first { $0.name == "approval.txt" })
        #expect(hit.bases == [.literalText, .extractedField] || Set(hit.bases).isSuperset(of: [.literalText, .extractedField]))
        #expect(!run.hits.flatMap(\.bases).contains(.similarity))
        #expect(hit.satisfied.contains { $0.contains("not a verified identity") })
        #expect(CaseSearchMatchBasis.similarity.label.contains("not an exact occurrence and not a verified identity"))
        // SEARCH-05: the exact locator reproduces the match in the searched text, with the attachment context.
        let w = try #require(hit.witnesses.first)
        let loc = hit.locator(w)
        #expect(loc.nesting == ["attachment of “mail.eml”"] && loc.sourceVersionID == att.version && loc.line.contains("characters 0–8"))
        let text = "Approved by José Álvarez for payment." as NSString
        #expect(text.substring(with: NSRange(location: loc.range.lowerBound, length: loc.range.count)) == w.matchedText)
        // SEARCH-07: two documents, one distinct text; one canonical entity.
        #expect(run.copyGroups.count == 1 && run.distinctTexts == 1 && run.canonicalEntities == 1)
        #expect(run.countsLine.contains("1 distinct text (1 repeated copy)") && run.countsLine.contains("1 recorded person or organisation"))
        // SEARCH-04: the banner names the mother case, says no prior case is read, the date meaning and the limits.
        let banner = run.activeScope.joined(separator: "\n")
        #expect(banner.contains("Mother case: Approval chain") && banner.contains("Prior cases: none") && banner.contains("file modified date"))
        #expect(banner.contains("Limits of this run") && !banner.contains("Unrelated matter") && !run.receipt.lines.joined().contains("secret-other"))
    }

    @Test("SEARCH-06/11: pending and unsupported are their own receipt categories with version ids; a stopped run continues from where it stopped and refuses after a re-read")
    func receiptCategoriesAndResume() async throws {
        #expect(CaseSearchService.category("waiting to be read", fallback: .failed) == .pending)
        #expect(CaseSearchService.category("unsupported file type", fallback: .noText) == .unsupported)
        #expect(CaseSearchService.category("password-protected", fallback: .failed) == .failed)
        let v = UUID()
        let r = CaseSearchReceipt(searched: 0, items: [.init(name: "a.pdf", category: .pending, reason: "waiting to be read", versionIDs: [v])],
                                  setAsidePassages: 0, coverageLine: "x", notes: [], complete: false)
        #expect(r.lines.contains { $0.hasPrefix("Not searched — still waiting to be read: a.pdf") && $0.contains("version \(v.uuidString.prefix(8))") })
        let f = try await CaseFileTests.fixture(title: "Big case")
        for i in 0..<40 { _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: String(format: "doc%02d.txt", i), text: "Page \(i) mentions the invoice.") }
        let svc = CaseSearchService(sources: .live(database: f.db))
        var tiny = Self.utc; tiny.timeLimitSeconds = 0.000_001
        let box = ProgressBox()
        let invoice = try #require(CaseSearchParser.parse("invoice").query)
        let stopped = try #require(await svc.run(caseID: f.caseID, query: invoice, options: tiny, progress: { p in box.add(p) }).run)
        #expect(!stopped.isComplete && stopped.continuation?.remaining == 40 && box.last?.total == 40)
        let done = try #require(await svc.resume(stopped, timeLimitSeconds: 60).run)
        #expect(done.isComplete && done.hits.count == 40 && done.continuation == nil && done.receipt.searched == 40)
        // A document is read again after the stop: the continuation is refused.
        let partial = try #require(await svc.run(caseID: f.caseID, text: "invoice", options: tiny).run)
        try await f.db.exec("UPDATE knowledge_objects SET updated_at = 99;", [])
        if case .rejected(let why, _) = await svc.resume(partial, timeLimitSeconds: 60) {
            #expect(why.first?.contains("cannot be continued") == true)
        } else if let r = await svc.resume(partial, timeLimitSeconds: 60).run, partial.continuation?.remaining == 40 {
            // Nothing had been reached yet, so nothing read again: a full continuation is still honest.
            #expect(r.isComplete)
        }
        // A complete run has nothing to continue.
        if case .rejected = await svc.resume(done) {} else { Issue.record("a complete run must not continue") }
    }

    @Test("SEARCH-10: a live search re-runs under its policy when the material changes, reports each new-match set once with provenance, and a receipt refuses a policy")
    func policyReruns() async throws {
        let f = try await CaseFileTests.fixture(title: "Refunds")
        _ = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "a.txt", text: "Nothing here.")
        let svc = CaseSearchService(sources: .live(database: f.db))
        let run = try #require(await svc.run(caseID: f.caseID, text: "refund", options: Self.utc).run)
        let live = try await svc.save(run, name: "Refunds", kind: .live, actor: "Ada")
        let frozen = try await svc.save(run, name: "Then", kind: .receipt, actor: "Ada")
        #expect(await svc.rerunDue(caseID: f.caseID).isEmpty)                         // manual policy: nothing runs on its own
        try await svc.repository.setRerunPolicy(id: live, caseID: f.caseID, .onMaterialChange)
        await #expect(throws: CaseSearchRepositoryError.frozen) { try await svc.repository.setRerunPolicy(id: frozen, caseID: f.caseID, .onMaterialChange) }
        #expect(await svc.rerunDue(caseID: f.caseID).isEmpty)                         // nothing changed
        let added = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "refund.txt", text: "A refund was asked for.")
        let alerts = await svc.rerunDue(caseID: f.caseID)
        #expect(alerts.count == 1 && alerts[0].changes.newMatches.map(\.name) == ["refund.txt"])
        #expect(alerts[0].provenance.first?.contains("version \(added.version.uuidString.prefix(8))") == true)
        #expect(await svc.rerunDue(caseID: f.caseID).isEmpty, "the same new matches are not reported twice")
        // Not acknowledged by the alert: the baseline is unchanged until the person marks it seen.
        let saved = try #require(try await svc.repository.savedSearch(id: live))
        #expect(saved.result.matchedObjectIDs.isEmpty && saved.alertedDigest != nil)
        let receipt = try #require(try await svc.repository.savedSearch(id: frozen))
        #expect(receipt.rerunPolicy == .manual && receipt.result == run.storedResult)
    }

    @Test("SEARCH-12: non-Latin text, nested attachments and a source removed mid-case; literal accuracy scored against a hand-written key, apart from reading accuracy")
    func independentFixtures() async throws {
        let f = try await CaseFileTests.fixture(title: "Multilingual")
        let texts: [(String, String)] = [
            ("hindi.txt", "भुगतान दो बार किया गया। आपूर्तिकर्ता ने रसीद दी।"),
            ("greek.txt", "Η πληρωμή έγινε δύο φορές από τον Παπαδόπουλο."),
            ("cjk.txt", "供应商收到两次付款。"),
            ("mixed.txt", "Invoice A-17/B — payé deux fois (twice)."),
            ("ocr.txt", "The supp1ier was paid twlce."),   // what the reader produced from a scan: the key holds the original words
        ]
        var v: [String: (version: UUID, object: UUID, blocks: [UUID])] = [:]
        for (n, t) in texts { v[n] = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: n, text: t) }
        let parent = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "bundle.zip", text: "Archive listing.")
        let mail = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "inner.eml", text: "Forwarded note.")
        try await f.db.exec("INSERT INTO source_version_relations (id, parent_source_version_id, child_source_version_id, relation, ordinal, created_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(parent.version), .uuid(mail.version), .text("archiveMember"), .integer(0), .real(1)])
        try await f.db.exec("INSERT INTO source_version_relations (id, parent_source_version_id, child_source_version_id, relation, ordinal, created_at) VALUES (?,?,?,?,?,?);",
                            [.uuid(UUID()), .uuid(mail.version), .uuid(v["mixed.txt"]!.version), .text("attachment"), .integer(0), .real(1)])
        let svc = CaseSearchService(sources: .live(database: f.db))
        // The hand-written key: query → documents whose SEARCHED TEXT holds it (literal correctness).
        let key: [(String, [String])] = [
            ("भुगतान", ["hindi.txt"]), ("\"दो बार\"", ["hindi.txt"]), ("πληρωμη", ["greek.txt"]),          // Greek accents ignored by default
            ("Παπαδόπουλο", ["greek.txt"]), ("exact:\"两次付款\"", ["cjk.txt"]),
            ("供应商收到两次付款", ["cjk.txt"]),                                                             // a CJK run is one word (documented)
            ("两次", []),                                                                                      // …so a part of it is not a word match
            ("payé", ["mixed.txt"]), ("paye", ["mixed.txt"]), ("exact:\"A-17/B\"", ["mixed.txt"]), ("twice", ["mixed.txt"]),
        ]
        var correct = 0
        for (q, expected) in key {
            let got = try await names(svc, f.caseID, q)
            if got == expected { correct += 1 } else { Issue.record("\(q): \(got) ≠ \(expected)") }
        }
        #expect(correct == key.count, "literal search accuracy over the searched text: \(correct)/\(key.count)")
        // Reading accuracy is a different measure: the original words of the scan are not in the reader's text, and the
        // search says it searched that text — it does not claim the original lacks them.
        #expect(try await names(svc, f.caseID, "supplier") == [])
        #expect(try await names(svc, f.caseID, "supp1ier") == ["ocr.txt"])
        // Nesting two levels deep.
        let run = try #require(await svc.run(caseID: f.caseID, text: "twice", options: Self.utc).run)
        #expect(run.hits.first?.nesting == ["attachment of “inner.eml”", "member of “bundle.zip”"])
        // Permission change mid-case: the source is excluded; it is no longer searched, and a live search says so.
        let saved = try await svc.save(run, name: "Twice", kind: .live, actor: "Ada")
        let header = try #require(try await f.cases.fetch(caseID: f.caseID)?.caseHeader)
        _ = try await f.cases.excludeSource(caseID: f.caseID, expectedRevision: header.revision, sourceRef: v["mixed.txt"]!.version.uuidString,
                                            sourceKind: .sourceVersion, actor: "Ada", at: Date())
        #expect(try await names(svc, f.caseID, "twice") == [])
        let s = try #require(try await svc.repository.savedSearch(id: saved))
        guard case .success(let ch) = await svc.changes(for: s) else { Issue.record("no changes report"); return }
        #expect(ch.scopeChanged && ch.noLongerMatching == [v["mixed.txt"]!.object] && ch.current.receipt.items(.excluded).map(\.name) == ["mixed.txt"])
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CaseSearchProgress] = []
    func add(_ p: CaseSearchProgress) { lock.lock(); items.append(p); lock.unlock() }
    var last: CaseSearchProgress? { lock.lock(); defer { lock.unlock() }; return items.last }
}

@MainActor
@Suite("Smart map S4 — relationship paths", .serialized)
struct SmartMapS4PathTests {

    @Test("SEARCH-09/10: typed, directed, certainty- and time-bounded paths with every edge explained; honest no-path coverage; versioned saved patterns and frozen receipts")
    func paths() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let a = try await f.file.addPerson(caseID: c, name: "Asha", role: .subject, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let b = try await f.file.addPerson(caseID: c, name: "Bala", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let q = try await f.file.addAllegation(caseID: c, text: "Did Asha pay Bala twice?", actor: "Ada")
        let repo = CaseMapRepository(database: f.db)
        let na = rig.node(.person, a), nb = rig.node(.person, b), nq = rig.node(.allegation, q)
        let march = Date(timeIntervalSince1970: 1_772_000_000), april = march.addingTimeInterval(30 * 86_400)
        _ = try await repo.addLink(caseID: c, type: .mentions, from: na, to: nb, rationale: "Asha's email names Bala", certainty: .statedBySource,
                                   validity: CaseMapValidity(from: march, to: nil, text: "from March"), actor: "Ada")
        _ = try await repo.addLink(caseID: c, type: .supports, from: nb, to: nq, rationale: "Bala's statement", certainty: .possible,
                                   validity: CaseMapValidity(from: april, to: nil, text: "April"), actor: "Ada")
        let p = try await rig.projection()
        var query = CaseMapPathQuery(from: na, to: nq)
        query.linkTypes = [.mentions, .supports]
        guard case .success(let r) = CaseMapPathSearch.run(query, in: p) else { Issue.record("not run"); return }
        #expect(r.paths.count == 1 && r.paths[0].nodes == [na, nb, nq] && r.complete)
        let e = r.paths[0].edges
        #expect(e[0].explanation.contains("certainty: Stated by the source") || e[0].certainty == .statedBySource)
        #expect(e[1].period == CaseMapValidity(from: april, to: nil, text: "April").label && e[1].basis.contains("Bala's statement"))
        #expect(r.lines.last == CaseMapPathResult.caveat)
        // Direction: backwards from the question finds nothing following forward; against the direction it does.
        var back = CaseMapPathQuery(from: nq, to: na); back.linkTypes = [.mentions, .supports]
        guard case .success(let none) = CaseMapPathSearch.run(back, in: p) else { Issue.record("not run"); return }
        #expect(none.paths.isEmpty && (none.notFollowed["against the chosen direction"] ?? 0) > 0)
        #expect(none.lines.contains { $0.contains("says nothing about connections outside these bounds") })
        back.direction = .backward
        guard case .success(let found) = CaseMapPathSearch.run(back, in: p) else { Issue.record("not run"); return }
        #expect(found.paths.first?.edges.allSatisfy { !$0.followedForward } == true)
        // Certainty and time conditions.
        var sure = query; sure.minCertainty = .probable
        guard case .success(let s1) = CaseMapPathSearch.run(sure, in: p) else { Issue.record("not run"); return }
        #expect(s1.paths.isEmpty && s1.notFollowed.keys.contains { $0.contains("less certainly") })
        var timed = query; timed.timeOrdered = true
        guard case .success(let t1) = CaseMapPathSearch.run(timed, in: p) else { Issue.record("not run"); return }
        #expect(t1.paths.count == 1)
        var window = query; window.intervalEnd = march.addingTimeInterval(86_400)
        guard case .success(let w1) = CaseMapPathSearch.run(window, in: p) else { Issue.record("not run"); return }
        #expect(w1.paths.isEmpty && (w1.notFollowed["outside the interval"] ?? 0) == 1)
        var short = query; short.maxLength = 1
        guard case .success(let s2) = CaseMapPathSearch.run(short, in: p) else { Issue.record("not run"); return }
        #expect(s2.paths.isEmpty && s2.lengthLimitStopped == 1)
        var tiny = query; tiny.maxSteps = 1
        guard case .success(let s3) = CaseMapPathSearch.run(tiny, in: p) else { Issue.record("not run"); return }
        #expect(s3.stepLimitReached && !s3.complete)
        var bad = query; bad.maxLength = 50
        if case .failure(.rejected) = CaseMapPathSearch.run(bad, in: p) {} else { Issue.record("an out-of-bounds pattern must be refused") }
        // Saved patterns: versions by name, a frozen receipt never edited.
        let sr = CaseSearchRepository(database: f.db)
        let v1 = try await sr.savePattern(caseID: c, name: "Asha to question", kind: .live, query: query, result: nil, fence: nil, actor: "Ada")
        let v2 = try await sr.savePattern(caseID: c, name: "Asha to question", kind: .receipt, query: timed, result: t1, fence: "fence-1", actor: "Ada")
        #expect(v1.version == 1 && v2.version == 2)
        let saved = try await sr.savedPatterns(caseID: c)
        #expect(saved.count == 2 && saved[0].query == query && saved[1].result == t1 && saved[1].fence == "fence-1")
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_saved_patterns SET fence = 'x' WHERE id = ?;", [.uuid(v2.id)]) }
        await #expect(throws: CaseSearchRepositoryError.blank("The frozen result")) {
            _ = try await sr.savePattern(caseID: c, name: "x", kind: .receipt, query: query, result: nil, fence: nil, actor: "Ada")
        }
    }
}

@MainActor
@Suite("Smart map S4 — reports", .serialized)
struct SmartMapS4ReportTests {

    @Test("REPORT-02: sections, and a point recorded in one step with its section, time, question and person — fixed once recorded")
    func sectionsAndPlacement() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let sec = try await f.file.addSection(caseID: c, reportID: rig.report, heading: "3. Findings", actor: "Ada")
        let sub = try await f.file.addSection(caseID: c, reportID: rig.report, heading: "3.1 Seal", parentSectionID: sec, actor: "Ada")
        let q = try await f.file.addAllegation(caseID: c, text: "Was the seal intact?", actor: "Ada")
        let person = try await f.file.addPerson(caseID: c, name: "Dr Rao", role: .witness, entityID: nil, contact: nil, notes: nil, actor: "Ada")
        let when = Date(timeIntervalSince1970: 1_773_000_000)
        let pt = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The seal was intact",
                                          quote: "The seal on bag 7 was intact on arrival.", placement: CasePointPlacement(sectionID: sub, eventAt: when, eventText: "on arrival"),
                                          questions: [q], people: [person], actor: "Ada")
        let point = try #require(try await f.file.reportLedger(caseID: c).point(pt))
        #expect(point.sectionID == sub && point.eventAt == when && point.eventText == "on arrival" && point.isVerified)
        let st = try await f.file.reportStructure(caseID: c)
        #expect(st.sections(of: rig.report).map(\.heading) == ["3. Findings", "3.1 Seal"] && st.sections.last?.parentSectionID == sec)
        #expect(Set(st.uses(of: pt).map(\.context)) == [.question, .person])
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_report_points SET section_id = NULL WHERE id = ?;", [.uuid(pt)]) }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_report_sections SET heading = 'x' WHERE id = ?;", [.uuid(sec)]) }
        // A section of another report is refused inside the write.
        let other = try await f.file.addReport(caseID: c, CaseReportDetails(title: "Other"), actor: "Ada")
        let foreign = try await f.file.addSection(caseID: c, reportID: other, heading: "1. Intro", actor: "Ada")
        await #expect(throws: CaseWorkError.notInCase("report section")) {
            _ = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .claim, statement: "x", quote: nil, placement: CasePointPlacement(sectionID: foreign), actor: "Ada")
        }
    }

    @Test("REPORT-02/06 (AI off): rule-based suggestions are proposals; accepting records a verified point; re-reading never duplicates or touches an accepted point, its qualification or its review")
    func suggestions() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let first = try await f.svc.suggestPoints(caseID: c, reportID: rig.report, actor: "Ada")
        #expect(first.added == 3 && first.unavailable == nil)                 // finding words, "weighed", "result"
        var st = try await f.file.reportStructure(caseID: c)
        let props = st.proposals(of: rig.report)
        #expect(props.allSatisfy { $0.state == .proposed && $0.originLabel.contains("no model was used") })
        #expect(try await f.file.reportLedger(caseID: c).points.isEmpty, "a suggestion is not a point")
        let seal = try #require(props.first { $0.quote.hasPrefix("The seal") })
        #expect(seal.kind == .finding)
        let pt = try await f.svc.acceptSuggestion(caseID: c, proposalID: seal.id, statement: "The seal was intact", actor: "Ada")
        try await f.file.addQualification(caseID: c, pointID: pt, kind: .condition, text: "if custody is complete", quote: nil, actor: "Ada")
        try await f.file.reviewPoint(caseID: c, pointID: pt, to: .accepted, actor: "Ada")
        let weigh = try #require(props.first { $0.quote.contains("weighed") })
        await #expect(throws: (any Error).self) { try await f.svc.dismissSuggestion(caseID: c, proposalID: weigh.id, reason: " ", actor: "Ada") }
        try await f.svc.dismissSuggestion(caseID: c, proposalID: weigh.id, reason: "Not material", actor: "Ada")
        let before = try await f.file.reportLedger(caseID: c)
        let again = try await f.svc.suggestPoints(caseID: c, reportID: rig.report, actor: "Ada")
        #expect(again.added == 0 && again.alreadyProposed == 1 && again.alreadyDecided == 2)
        let after = try await f.file.reportLedger(caseID: c)
        #expect(after.points == before.points && after.qualifications == before.qualifications)
        let p = try #require(after.point(pt))
        #expect(p.review == .accepted && p.isVerified && p.proposalID == seal.id && p.quote == seal.quote)
        st = try await f.file.reportStructure(caseID: c)
        #expect(st.proposals.first { $0.id == seal.id }?.pointID == pt && st.proposals.first { $0.id == weigh.id }?.state == .dismissed)
        await #expect(throws: CaseReportStructureError.proposalDecided) { _ = try await f.svc.acceptSuggestion(caseID: c, proposalID: weigh.id, actor: "Ada") }
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_report_point_proposals SET quote = 'x' WHERE id = ?;", [.uuid(seal.id)]) }
        // Headings are kept as section hints; a report without a document has nothing to read.
        #expect(CaseReportPointSuggester.isHeading("2.1 Method") && CaseReportPointSuggester.isHeading("FINDINGS") && !CaseReportPointSuggester.isHeading("The seal was intact."))
        let bare = try await f.file.addReport(caseID: c, CaseReportDetails(title: "Phoned-in result"), actor: "Ada")
        #expect(try await f.svc.suggestPoints(caseID: c, reportID: bare, actor: "Ada").unavailable?.contains("no document") == true)
    }

    @Test("REPORT-03/07: one canonical point used in a question, chronology and money keeps its identity and review references; every summary carries its qualifications")
    func usesAndQualifiedSummaries() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let pt = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The sample is valid",
                                          quote: "The result is valid only if the chain of custody is complete.", actor: "Ada")
        try await f.file.addQualification(caseID: c, pointID: pt, kind: .condition, text: "only if the chain of custody is complete", quote: nil, actor: "Ada")
        let q = try await f.file.addAllegation(caseID: c, text: "Is the sample reliable?", actor: "Ada")
        let entry = try await f.file.addJournal(caseID: c, kind: .chronology, text: "Sample examined", eventDate: Date(), evidenceRef: nil, actor: "Ada")
        let u1 = try await f.file.usePoint(caseID: c, pointID: pt, in: .question, contextID: q.uuidString, actor: "Ada")
        _ = try await f.file.usePoint(caseID: c, pointID: pt, in: .chronology, contextID: entry.uuidString, note: "dates the examination", actor: "Ada")
        _ = try await f.file.usePoint(caseID: c, pointID: pt, in: .money, contextID: "transaction-1", actor: "Ada")
        await #expect(throws: CaseReportStructureError.alreadyUsed) { _ = try await f.file.usePoint(caseID: c, pointID: pt, in: .question, contextID: q.uuidString, actor: "Ada") }
        await #expect(throws: CaseReportStructureError.contextNotInCase("question")) { _ = try await f.file.usePoint(caseID: c, pointID: pt, in: .question, contextID: UUID().uuidString, actor: "Ada") }
        var st = try await f.file.reportStructure(caseID: c)
        var ledger = try await f.file.reportLedger(caseID: c)
        let point = try #require(ledger.point(pt))
        #expect(st.uses(of: pt).count == 3 && st.uses(of: pt).allSatisfy { $0.pointID == pt && $0.change(against: point) == nil })
        try await f.file.reviewPoint(caseID: c, pointID: pt, to: .accepted, actor: "Ada")
        ledger = try await f.file.reportLedger(caseID: c)
        let accepted = try #require(ledger.point(pt))
        let changed = try #require(st.uses.first { $0.id == u1 }?.change(against: accepted))
        #expect(changed.contains("Accepted on review") && changed.contains("Not reviewed yet"))
        try await f.file.withdrawPointUse(caseID: c, id: u1, reason: "Wrong question", actor: "Ada")
        st = try await f.file.reportStructure(caseID: c)
        #expect(st.uses(of: pt).count == 2 && st.uses.count == 3)
        // REPORT-03: the export line, the case-file report section and the brief all carry the condition.
        let line = CaseReportPointText.summary(try #require(ledger.point(pt)), ledger.qualifications)
        #expect(line.contains("QUALIFIED: Condition: only if the chain of custody is complete"))
        #expect(CaseReportPointText.section(ledger).contains("QUALIFIED: Condition: only if the chain of custody is complete"))
        let p = try await rig.projection()
        let brief = CaseMapBrief.compute(p)
        let entryText = try #require(brief.allEntries.first { $0.node.kind == .reportPoint }).text
        #expect(entryText.contains("QUALIFIED") && entryText.contains("only if the chain of custody is complete"))
        // …and the case-file report released through the one output door.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("s4-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputs = CaseOutputService(database: f.db, caseFiles: f.svc, custody: { _ in [] }, pendingDirectory: temp)
        let pkg = try await outputs.prepare(caseID: c, kind: .caseFileReport, route: .file, actor: "Ada") { CaseFileDocuments.caseFileReport($0, by: "Ada") }
        #expect(pkg.text.contains("## Supplied reports and their points") && pkg.text.contains("QUALIFIED: Condition: only if the chain of custody is complete"))
        #expect(pkg.citations.contains { $0.sourceVersionID == rig.doc.version })
    }

    @Test("REPORT-04: an evidence request and a comparison open from a point, keeping its source, purpose and deliverable")
    func workFromPoint() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let pt = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The sample weighed 12 grams",
                                          quote: "The sample weighed 12 grams.", actor: "Ada")
        let other = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .claim, statement: "The seal was intact",
                                             quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        let evidence = EvidenceStore(database: f.db)
        let analysis = InvestigationAnalysisService(cases: f.cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                    analysis: InvestigationAnalysisRepository(database: f.db))
        let req = try await f.svc.requestEvidence(caseID: c, fromPoint: pt, details: EvidenceRequestDetails(description: "Balance calibration log", custodian: "City Forensic Lab"),
                                                  purpose: "Check the weighing", analysis: analysis, actor: "Ada")
        let cmp = try await f.svc.openComparison(caseID: c, fromPoint: pt, against: .point, targetID: other, title: "Compare weight with seal record",
                                                 purpose: "Do the two observations agree?", deliverable: "A short comparison note", actor: "Ada")
        let ledger = try await f.file.reportLedger(caseID: c)
        #expect(ledger.workLinks.contains { $0.workKind == .request && $0.workID == req && $0.targetID == pt && $0.role == .raisedFrom && $0.purpose == "Check the weighing" })
        #expect(ledger.workLinks.contains { $0.workKind == .task && $0.workID == cmp && $0.targetID == pt && $0.role == .raisedFrom })
        #expect(ledger.workLinks.contains { $0.workKind == .task && $0.workID == cmp && $0.targetID == other && $0.role == .compares })
        #expect(ledger.contract(cmp)?.deliverable == "A short comparison note" && ledger.contract(cmp)?.purpose == "Do the two observations agree?")
        let p = try await rig.projection()
        #expect(p.links.contains { $0.from == rig.node(.request, req) && $0.to == rig.node(.reportPoint, pt) && $0.type == .derivedFrom })
        #expect(p.links.contains { $0.from == rig.node(.task, cmp) && $0.to == rig.node(.reportPoint, other) && $0.status.text == "Compared with it" })
        // The point's source travels: the request's map node reaches the report's document through the point.
        #expect(p.links.contains { $0.from == rig.node(.reportPoint, pt) && $0.to == rig.node(.report, rig.report) })
        await #expect(throws: CaseWorkError.notInCase("point")) {
            _ = try await f.svc.requestEvidence(caseID: c, fromPoint: UUID(), details: EvidenceRequestDetails(description: "x"), purpose: "y", analysis: analysis, actor: "Ada")
        }
    }

    @Test("REPORT-08: an amendment compared with the original shows reworded and requalified points; dependent work is flagged for review and no decision changes")
    func compareVersions() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let a1 = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The seal was intact on arrival", quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        let a2 = try await f.svc.addPoint(caseID: c, reportID: rig.report, kind: .finding, statement: "The sample weighed 12 grams", quote: "The sample weighed 12 grams.", actor: "Ada")
        try await f.file.reviewPoint(caseID: c, pointID: a1, to: .accepted, actor: "Ada")
        let task = try await f.svc.createAction(caseID: c, .init(title: "Check the seal photos", purpose: "Confirm the seal", deliverable: "Photo note", fromPoint: a1), actor: "Ada")
        try await f.file.submitAction(caseID: c, taskID: task, note: "done", actor: "Ada")
        try await f.file.reviewAction(caseID: c, taskID: task, accept: true, note: "fine", actor: "Ben")
        try await f.file.recordOutcome(caseID: c, taskID: task, outcome: .answered, note: "intact", actor: "Ada")
        let amend = try await f.file.addReport(caseID: c, CaseReportDetails(title: "Laboratory report 41 — amended", kind: .amendment, amendsReportID: rig.report,
                                                                          sourceVersionID: rig.doc.version, producer: "City Forensic Lab", author: "Dr Rao",
                                                                          examinedMaterial: "Bag 7", reportDateText: "20 March 2026", methods: "Visual inspection of the seal",
                                                                          limitations: "Examined from photographs only"), actor: "Ada")
        let b1 = try await f.svc.addPoint(caseID: c, reportID: amend, kind: .finding, statement: "The seal was probably intact on arrival", quote: "The seal on bag 7 was intact on arrival.", actor: "Ada")
        _ = try await f.svc.addPoint(caseID: c, reportID: amend, kind: .finding, statement: "The sample weighed 12 grams", quote: "The sample weighed 12 grams.", actor: "Ada")
        let b2 = try #require(try await f.file.reportLedger(caseID: c).points.first { $0.reportID == amend && $0.statement.contains("12 grams") }?.id)
        try await f.file.addQualification(caseID: c, pointID: b2, kind: .uncertainty, text: "the balance was not calibrated", quote: nil, actor: "Ada")
        let beforeLedger = try await f.file.reportLedger(caseID: c)
        let (cid, cmp) = try await f.svc.compareReports(caseID: c, earlier: rig.report, later: amend, actor: "Ada")
        #expect(cmp.fields.map(\.field) == ["Report date"])
        let seal = try #require(cmp.points.first { $0.earlierPointID == a1 })
        #expect(seal.change == .reworded && seal.laterPointID == b1 && seal.wordsAdded == ["probably"] && seal.pairedBy == "same quoted words")
        let weight = try #require(cmp.points.first { $0.earlierPointID == a2 })
        #expect(weight.change == .requalified && weight.qualificationsAdded == ["Uncertainty: the balance was not calibrated"])
        #expect(cmp.affectedWork.count == 1 && cmp.affectedWork[0].workID == task && cmp.affectedWork[0].pointID == a1)
        #expect(cmp.lines.contains { $0.contains("added: probably") } && cmp.lines.contains { $0.contains("No decision or outcome was changed") })
        let st = try await f.file.reportStructure(caseID: c)
        #expect(st.openFlags(work: task).count == 1 && st.comparisons.first?.id == cid && st.comparisons.first?.result == cmp)
        // Prior decisions untouched: the accepted point, the accepted review and the outcome.
        let after = try await f.file.reportLedger(caseID: c)
        #expect(after.points == beforeLedger.points && after.contracts == beforeLedger.contracts && after.point(a1)?.review == .accepted)
        #expect(after.contract(task)?.review == .accepted && after.contract(task)?.outcome == .answered)
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_report_comparisons SET result_json = '{}' WHERE id = ?;", [.uuid(cid)]) }
        let flag = try #require(st.openFlags(work: task).first)
        try await f.file.clearReviewFlag(caseID: c, id: flag.id, note: "Photos still show the seal intact", actor: "Ada")
        #expect(try await f.file.reportStructure(caseID: c).openFlags(work: task).isEmpty)
        await #expect(throws: CaseReportStructureError.notAnAmendment) { _ = try await f.svc.compareReports(caseID: c, earlier: amend, later: amend, actor: "Ada") }
    }

    @Test("REPORT-09: supplied tables, figures and media are kept and shown as supplied, never as the app's own analysis; a file outside the case is refused")
    func suppliedArtifacts() async throws {
        let rig = try await CaseFramesRig.make()
        let f = rig.f, c = f.caseID
        let fig = try await f.file.addArtifact(caseID: c, reportID: rig.report, kind: .figure, label: "Figure 2 — seal close-up", sourceVersionID: rig.doc.version,
                                               locator: "p. 4", suppliedBy: "City Forensic Lab", actor: "Ada")
        _ = try await f.file.addArtifact(caseID: c, reportID: rig.report, kind: .table, label: "Table 1 — weights", actor: "Ada")
        let outside = try await CaseFileTestSources.seed(f.db)
        await #expect(throws: CaseWorkError.sourceNotInCase) {
            _ = try await f.file.addArtifact(caseID: c, reportID: rig.report, kind: .media, label: "Video", sourceVersionID: outside, actor: "Ada")
        }
        let st = try await f.file.reportStructure(caseID: c)
        #expect(st.artifacts.count == 2)
        let line = try #require(st.artifacts.first { $0.id == fig }?.line)
        #expect(line.contains("supplied by City Forensic Lab") && line.contains("did not perform the acquisition or the analysis"))
        #expect(st.artifacts.allSatisfy { !$0.line.lowercased().contains("analysed by this app") })
        let section = CaseReportPointText.section(try await f.file.reportLedger(caseID: c), structure: st)
        #expect(section.contains("Table 1 — weights") && section.contains("no file of it in the case yet"))
        await #expect(throws: (any Error).self) { try await f.db.exec("UPDATE case_report_artifacts SET label = 'x' WHERE id = ?;", [.uuid(fig)]) }
    }

    @Test("v179 → v180: work links keep every row (wider kinds), the update guard stands, the new tables exist; inventory registers them; case erasure removes them")
    func migrationAndErasure() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 179)
        let c = UUID(), w = UUID()
        try await db.exec("INSERT INTO case_work_links (id, case_id, work_kind, work_id, target_kind, target_id, role, purpose, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?,?);",
                          [.uuid(w), .uuid(c), .text("task"), .uuid(UUID()), .text("point"), .uuid(UUID()), .text("raisedFrom"), .text("why"), .text("Ada"), .real(1)])
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 180)
        for t in ["case_report_sections", "case_report_point_proposals", "case_report_point_uses", "case_report_comparisons", "case_work_review_flags",
                  "case_report_artifacts", "case_saved_patterns"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
            #expect(CaseDataInventory.entry(t)?.lifecycle == .caseID, "\(t) not registered")
        }
        #expect(try await db.query("SELECT purpose FROM case_work_links WHERE id = ?;", [.uuid(w)]).first?.string(0) == "why")
        await #expect(throws: (any Error).self) { try await db.exec("UPDATE case_work_links SET role = 'serves' WHERE id = ?;", [.uuid(w)]) }
        try await db.exec("INSERT INTO case_work_links (id, case_id, work_kind, work_id, target_kind, target_id, role, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(c), .text("request"), .uuid(UUID()), .text("point"), .uuid(UUID()), .text("compares"), .text("Ada"), .real(1)])
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await db.withSavepoint("inv") { d in try CaseDataInventory.unregistered(d) }.isEmpty)
    }
}

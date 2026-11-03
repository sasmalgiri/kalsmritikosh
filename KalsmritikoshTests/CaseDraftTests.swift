//
//  CaseDraftTests.swift
//  KalsmritikoshTests
//
//  P5 — case drafts: the rules draft a chronology of the defendants' dated steps, a cast with officials
//  apart, and leads (a defendant whose outcome no document records) offline; the AI reading's proposals
//  are verified (a fabricated quote, a date not in the quote's sentence, a judge as the actor of a step,
//  a conclusion, a leading or accusatory question are dropped); an accepted chronology item becomes a
//  chronology entry citing its passage and the same passage twice is refused; a document outside the
//  case is never used or sent; nothing is sent without a clearance; a privileged document never is.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P5 — case drafts", .serialized)
struct CaseDraftTests {
    typealias B = CaseDraftBuilder

    static let releaseA = """
    FOR IMMEDIATE RELEASE
    Thursday, September 24, 2015

    Guy R. Miller, 45, of Newark, pleaded guilty on September 22, 2015, before U.S. District Judge John Michael Vazquez to conspiracy to commit wire fraud.
    U.S. Attorney Paul J. Fishman announced the plea.
    Shawn C. Simon, 39, of Edison, was charged on March 3, 2015, in the same scheme.
    """
    static let releaseB = """
    FOR IMMEDIATE RELEASE
    Tuesday, January 12, 2016

    Guy R. Miller was sentenced on January 11, 2016, to 48 months in prison by U.S. District Judge John Michael Vazquez.
    U.S. Attorney Paul J. Fishman announced the sentence.
    Shawn C. Simon remains charged in the scheme.
    """

    static func doc(_ text: String) -> B.Document { B.Document(objectID: UUID(), sourceVersionID: UUID(), text: text) }

    // MARK: - Rules, offline

    @Test("Offline: the cast separates the judge and the prosecutor from the defendants; the chronology holds only defendants' dated steps; a missing outcome is a lead")
    func deterministicDrafts() {
        let a = Self.doc(Self.releaseA), b = Self.doc(Self.releaseB)
        let cast = B.cast([a, b])
        let byName = Dictionary(cast.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        #expect(byName["Guy R. Miller"]?.role == .defendant, "\(cast.map { "\($0.name)=\($0.roleLabel)" })")
        #expect(byName["Guy R. Miller"]?.documentCount == 2)
        #expect(byName["Guy R. Miller"]?.roleQuote.map { a.text.contains($0) || b.text.contains($0) } == true)
        #expect(byName["John Michael Vazquez"]?.role == .judge)
        #expect(byName["John Michael Vazquez"]?.group == .officials)
        #expect(byName["Paul J. Fishman"]?.role == .prosecutor)
        #expect(byName["Shawn C. Simon"]?.group == .defendants)

        let timeline = B.timeline([a, b], cast: cast)
        #expect(timeline.contains { $0.who == "Guy R. Miller" && $0.dateText == "2015-09-22" && $0.what.contains("pleaded guilty") },
                "\(timeline.map { "\($0.dateText) \($0.what)" })")
        #expect(timeline.contains { $0.who == "Guy R. Miller" && $0.dateText == "2016-01-11" && $0.what.contains("sentenced") })
        #expect(timeline.allSatisfy { $0.who != "John Michael Vazquez" && $0.who != "Paul J. Fishman" })
        #expect(timeline.allSatisfy { $0.provenance == .rules && ($0.objectID == a.objectID ? a.text : b.text).contains($0.quote) })
        #expect(timeline.map(\.dateText) == timeline.map(\.dateText).sorted())

        let leads = B.leads([a, b], cast: cast, contradictions: [])
        let simon = leads.first { $0.source == .missingOutcome && $0.notEstablished.contains("Shawn C. Simon") }
        #expect(simon != nil, "\(leads.map(\.notEstablished))")
        #expect(simon.map { a.text.contains($0.quote) || b.text.contains($0.quote) } == true)
        #expect(!leads.contains { $0.source == .missingOutcome && $0.notEstablished.contains("Guy R. Miller") })
        #expect(leads.allSatisfy { B.isNeutral($0.notEstablished) && !B.concludes($0.notEstablished) })

        let questions = B.interviewQuestions(person: "Guy R. Miller", docs: [a, b], contradictions: [], timeline: timeline)
        #expect(!questions.isEmpty)
        #expect(questions.allSatisfy { B.isNeutral($0.question) && $0.question.hasSuffix("?") })
    }

    @Test("A contradiction in the case becomes a lead with both quotes and an interview question for the person it names")
    func contradictionLead() {
        let a = Self.doc(Self.releaseA), b = Self.doc(Self.releaseB)
        let c = Contradiction(kind: .amount, description: "Amount — Guy R. Miller, loss: $1,000 vs $2,000. (case check · rules)",
                              claimA: "Guy R. Miller caused a loss of $1,000.", claimB: "Guy R. Miller caused a loss of $2,000.",
                              evidenceA: a.objectID, evidenceB: b.objectID, severity: .high, detectedAt: Date())
        let leads = B.leads([a, b], cast: B.cast([a, b]), contradictions: [c])
        let lead = leads.first { $0.source == .contradiction }
        #expect(lead?.otherQuote == c.claimB && lead?.quote == c.claimA)
        #expect(lead?.notEstablished.contains("(case check") == false)
        #expect(lead?.records.contains("financial") == true)
        let qs = B.interviewQuestions(person: "Guy R. Miller", docs: [a, b], contradictions: [c], timeline: [])
        #expect(qs.first?.basis == .contradiction && qs.first?.otherQuote == c.claimB)
    }

    // MARK: - Verification of the AI reading

    @Test("Verification drops a fabricated quote, a date not in the quote's sentence, a judge as the actor of a step and a conclusion; keeps a checked event and gap")
    func verifyTimeline() {
        let a = Self.doc(Self.releaseA)
        let cast = B.cast([a, Self.doc(Self.releaseB)])
        let batch = B.Batch(passages: [B.Passage(objectID: a.objectID, sourceVersionID: a.sourceVersionID, text: a.text)])
        let reply = """
        {"events": [
          {"date": "2015-09-22", "what": "Guy R. Miller pleaded guilty to conspiracy to commit wire fraud", "who": "Guy R. Miller",
           "quote": "Guy R. Miller, 45, of Newark, pleaded guilty on September 22, 2015", "passage": 1},
          {"date": "2014-05-01", "what": "Guy R. Miller took $2 million", "who": "Guy R. Miller",
           "quote": "Guy R. Miller admitted taking $2 million on May 1, 2014", "passage": 1},
          {"date": "2015-09-23", "what": "Guy R. Miller pleaded guilty", "who": "Guy R. Miller",
           "quote": "Guy R. Miller, 45, of Newark, pleaded guilty on September 22, 2015", "passage": 1},
          {"date": "2015-09-22", "what": "John Michael Vazquez convicted Guy R. Miller", "who": "John Michael Vazquez",
           "quote": "pleaded guilty on September 22, 2015, before U.S. District Judge John Michael Vazquez", "passage": 1},
          {"date": "2015-09-22", "what": "Guy R. Miller pleaded guilty", "who": "Guy R. Miller",
           "quote": "Guy R. Miller, 45, of Newark, pleaded guilty on September 22, 2015", "passage": 7}
        ],
        "gaps": [
          {"not_established": "The outcome of the charge against Shawn C. Simon is not stated in these passages.",
           "records": "The court docket for Shawn C. Simon.", "quote": "Shawn C. Simon, 39, of Edison, was charged on March 3, 2015", "passage": 1},
          {"not_established": "Shawn C. Simon was clearly guilty of the fraud.", "records": "None.",
           "quote": "Shawn C. Simon, 39, of Edison, was charged on March 3, 2015", "passage": 1},
          {"not_established": "Who paid the bribes.", "records": "Bank records.", "quote": "Simon paid bribes to officials", "passage": 1}
        ]}
        """
        let v = B.verifyTimeline(reply: reply, batch: batch, documents: [a], cast: cast)
        #expect(v.items.count == 1, "\(v.items.map(\.what)) dropped: \(v.dropped)")
        #expect(v.items.first?.dateText == "2015-09-22" && v.items.first?.who == "Guy R. Miller" && v.items.first?.provenance == .aiRead)
        #expect(v.dropped.contains { $0.contains("quote not in its passage") })
        #expect(v.dropped.contains { $0.contains("date is not in the quote") })
        #expect(v.dropped.contains { $0.contains("John Michael Vazquez is the judge") })
        #expect(v.dropped.contains { $0.contains("passage not sent") })
        #expect(v.leads.count == 1 && v.leads.first?.notEstablished.contains("Shawn C. Simon") == true)
        #expect(v.dropped.contains { $0.contains("not neutral or states a conclusion") })
        #expect(B.verifyTimeline(reply: "not json", batch: batch, documents: [a], cast: cast).unreadable)
    }

    @Test("Interview questions: leading or accusatory ones are dropped by the fixed rule list; a neutral grounded one is kept")
    func verifyInterview() {
        let a = Self.doc(Self.releaseA)
        let passages = [B.Passage(objectID: a.objectID, sourceVersionID: a.sourceVersionID, text: a.text)]
        let q = "Guy R. Miller, 45, of Newark, pleaded guilty on September 22, 2015"
        let reply = """
        {"questions": [
          {"question": "What do you recall about the events of September 22, 2015?", "quote": "\(q)", "passage": 1},
          {"question": "Why did you lie about the wire fraud?", "quote": "\(q)", "passage": 1},
          {"question": "Isn't it true that you knew about the scheme?", "quote": "\(q)", "passage": 1},
          {"question": "Will you admit your role in the conspiracy?", "quote": "\(q)", "passage": 1},
          {"question": "Do you confess to the fraud?", "quote": "\(q)", "passage": 1},
          {"question": "What happened on May 1, 2014?", "quote": "\(q)", "passage": 1},
          {"question": "Who else was involved?", "quote": "Miller confessed to everything", "passage": 1}
        ]}
        """
        let v = B.verifyInterview(reply: reply, person: "Guy R. Miller", passages: passages)
        #expect(v.questions.map(\.question) == ["What do you recall about the events of September 22, 2015?"], "dropped: \(v.dropped)")
        #expect(v.dropped.filter { $0 == "leading or accusatory" }.count == 4)
        #expect(v.dropped.contains { $0.contains("date") })
        #expect(v.dropped.contains { $0.contains("quote not in its passage") })
        for bad in ["Why did you lie to the board?", "Isn't it true you were there?", "Didn't you sign it?", "Will you come clean?",
                    "Do you admit it?", "Are you guilty?", "You knew, right?"] {
            #expect(!B.isNeutral(bad), "\(bad)")
        }
        for ok in ["What do you recall about the meeting?", "Who else attended the meeting on March 3?", "When did you plead guilty?"] {
            #expect(B.isNeutral(ok), "\(ok)")
        }
    }

    // MARK: - Accepting a chronology item

    @Test("Accepting a drafted chronology item makes a chronology entry citing its passage; the same item twice is refused")
    func acceptTimelineItem() async throws {
        let f = try await CaseFileTests.fixture()
        let src = try await CaseFileTestSources.seedPassage(f.db, cases: f.cases, caseID: f.caseID, name: "release.txt", text: Self.releaseA)
        let docs = [B.Document(objectID: src.object, sourceVersionID: src.version, text: Self.releaseA)]
        let item = try #require(B.timeline(docs, cast: B.cast(docs)).first { $0.who == "Guy R. Miller" })
        let r = try await PassageChronology.add(caseID: f.caseID, objectID: item.objectID, sourceVersionID: item.sourceVersionID, quote: item.quote,
                                                text: item.what, eventDate: item.localDate, caseFiles: f.svc, actor: "Ada")
        #expect(r.sourceVersionID == src.version)
        #expect(r.support.isDocumentary, "\(r.support.label)")
        let entries = try await f.svc.file.journal(caseID: f.caseID, kind: .chronology)
        let e = try #require(entries.first)
        #expect(entries.count == 1 && e.text == item.what && e.quote == item.quote && e.evidenceRef == src.version.uuidString)
        #expect(e.citations.first?.quote == item.quote && e.citations.first?.objectID == src.object)
        let day = Calendar.current.dateComponents([.year, .month, .day], from: try #require(e.eventDate))
        #expect(day.year == item.year && day.month == item.month && day.day == item.day)
        await #expect(throws: PassageChronologyError.alreadyInChronology) {
            _ = try await PassageChronology.add(caseID: f.caseID, objectID: item.objectID, sourceVersionID: item.sourceVersionID, quote: item.quote,
                                                text: item.what, eventDate: item.localDate, caseFiles: f.svc, actor: "Ada")
        }
        #expect(try await f.svc.file.journal(caseID: f.caseID, kind: .chronology).count == 1)
    }

    // MARK: - Scope and privacy through the case desk

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        private var clearances: [CloudSourceClearance?] = []
        func add(_ p: String, _ c: CloudSourceClearance?) { lock.lock(); prompts.append(p); clearances.append(c); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
        var cleared: [CloudSourceClearance?] { lock.lock(); defer { lock.unlock() }; return clearances }
    }

    private struct Rig { let svc: InvestigationContradictionGapService; let caseID: UUID; let kos: [UUID]; let sent: Sent }

    private let t0 = Date(timeIntervalSince1970: 1_767_500_000)

    /// Three documents; the first two are in the case, the third is not.
    private func rig(_ texts: [String], privileged: Set<Int> = [], gate: Bool = true, reader: Bool = true,
                     reply: String = #"{"events": [], "gaps": []}"#, failure: (any Error & Sendable)? = nil) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        var versions: [UUID] = [], kos: [UUID] = []
        for text in texts {
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
        var c = try await cases.createCase(workspaceID: ws, title: "Miller", actor: "analyst", at: t0)
        for v in versions.prefix(2) {
            c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: v.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        }
        let all = zip(versions, zip(kos, texts)).map { B.Document(objectID: $0.1.0, sourceVersionID: $0.0, text: $0.1.1) }
        let privilegedIDs = Set(privileged.map { kos[$0] })
        let sent = Sent()
        let caseID = c.id
        var pass = CaseContradictionPass(
            // Deliberately returns EVERY document, so the desk's own scope filter is what is tested.
            documents: { _ in all },
            gate: { _ in
                guard gate else { return nil }
                return CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                       legacyPrivileged: { privilegedIDs })
                    .bound(to: CloudScopeBinding(scopeID: caseID) { Dictionary(uniqueKeysWithValues: zip(kos.prefix(2), versions.prefix(2).map { Set([$0]) })) })
            },
            reader: { nil })
        pass.draftReader = { reader ? CaseDraftReader { prompt, clearance in
            sent.add(prompt, clearance); if let failure { throw failure }; return reply } : nil }
        pass.roleReader = { reader ? VerifiedRoleReader { prompt, clearance in
            sent.add(prompt, clearance); if let failure { throw failure }; return #"{"roles": []}"# } : nil }
        let svc = InvestigationContradictionGapService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), evidence: evidence,
                                                       contradictions: ContradictionsRepository(database: db), gaps: GapNodeRepository(database: db),
                                                       reviews: InvestigationDeskReviewRepository(database: db), pass: pass)
        return Rig(svc: svc, caseID: caseID, kos: kos, sent: sent)
    }

    static let outside = """
    FOR IMMEDIATE RELEASE
    Monday, May 2, 2016
    Guy R. Miller was arrested on May 1, 2016, in an unrelated matter involving Zebulon Q. Outsider.
    """

    @Test("Drafts use and send only the case's documents; the AI item that verifies is shown")
    func scope() async throws {
        let reply = """
        {"events": [{"date": "2015-03-03", "what": "Shawn C. Simon was charged in the scheme", "who": "Shawn C. Simon",
          "quote": "Shawn C. Simon, 39, of Edison, was charged on March 3, 2015", "passage": 1}], "gaps": []}
        """
        let r = try await rig([Self.releaseA, Self.releaseB, Self.outside], reply: reply)
        let d = try await r.svc.buildDrafts(caseID: r.caseID, useAI: true)
        #expect(d.documents == 2 && d.readerAvailable)
        #expect(!d.cast.contains { $0.name.contains("Outsider") })
        #expect(d.timeline.allSatisfy { $0.objectID != r.kos[2] && $0.dateText != "2016-05-01" })
        #expect(d.calls >= 1 && !r.sent.all.isEmpty)
        #expect(r.sent.all.allSatisfy { !$0.contains("Outsider") && !$0.contains("unrelated matter") })
        #expect(r.sent.cleared.allSatisfy { $0 != nil && !$0!.clearedObjectIDs.contains(r.kos[2]) })
        // Simon's charge: either the rules had it (agreed) or the verified AI item adds it — once.
        #expect(d.timeline.filter { $0.who == "Shawn C. Simon" && $0.dateText == "2015-03-03" }.count == 1, "\(d.timeline.map { "\($0.dateText) \($0.what)" })")
        #expect(d.verified + d.agreedWithRules >= 1)
        // Rules-only: nothing sent.
        let before = r.sent.all.count
        let offline = try await r.svc.buildDrafts(caseID: r.caseID, useAI: false)
        #expect(r.sent.all.count == before && offline.calls == 0 && !offline.timeline.isEmpty)
        // The interview plan: the document outside the case is neither used nor sent.
        let iv = try await r.svc.draftInterview(caseID: r.caseID, person: "Guy R. Miller", useAI: false)
        #expect(!iv.questions.isEmpty && iv.questions.allSatisfy { $0.objectID != r.kos[2] && B.isNeutral($0.question) })
    }

    @Test("A failed drafting or role call is recorded with its reason, not only counted; role calls are the batches actually sent")
    func failureReasons() async throws {
        let failure = OnlineRequestBuilder.ParseError.cutOff("1500 output tokens, 1500 of them thinking")
        let r = try await rig([Self.releaseA, Self.releaseB, "x"], failure: failure)
        let d = try await r.svc.buildDrafts(caseID: r.caseID, useAI: true)
        #expect(d.readerAvailable && d.calls == 0)
        #expect(d.roleBatches >= 1, "the role batches sent are counted")
        #expect(d.failedCalls == d.failures.count && d.failedCalls >= 2)
        #expect(d.failures.contains { $0.hasPrefix("drafting call:") && $0.contains("cut off at the output limit") && $0.contains("1500 of them thinking") }, "\(d.failures)")
        #expect(d.failures.contains { $0.hasPrefix("role call:") }, "\(d.failures)")
        let iv = try await r.svc.draftInterview(caseID: r.caseID, person: "Guy R. Miller", useAI: true)
        #expect(iv.failedCalls == 1 && iv.failures.first?.contains("cut off") == true, "\(iv.failures)")
        // A reader that answers: the drafting call is made and nothing is recorded as failed.
        let ok = try await rig([Self.releaseA, Self.releaseB, "x"])
        let d2 = try await ok.svc.buildDrafts(caseID: ok.caseID, useAI: true)
        #expect(d2.calls >= 1 && d2.failures.isEmpty && d2.failedCalls == 0)
    }

    @Test("No send without a clearance gate or a reader; a privileged document is never sent; the rules still draft offline")
    func privacy() async throws {
        let noGate = try await rig([Self.releaseA, Self.releaseB, "x"], gate: false)
        let d1 = try await noGate.svc.buildDrafts(caseID: noGate.caseID, useAI: true)
        #expect(noGate.sent.all.isEmpty && d1.calls == 0 && d1.notSentReason != nil && !d1.timeline.isEmpty)
        let iv1 = try await noGate.svc.draftInterview(caseID: noGate.caseID, person: "Guy R. Miller", useAI: true)
        #expect(noGate.sent.all.isEmpty && iv1.calls == 0)

        let priv = try await rig([Self.releaseA, Self.releaseB, "x"], privileged: [0])
        let d2 = try await priv.svc.buildDrafts(caseID: priv.caseID, useAI: true)
        #expect(d2.deniedForCloud == 1)
        #expect(priv.sent.all.allSatisfy { !$0.contains("of Newark, pleaded guilty") && !$0.contains("Shawn C. Simon, 39") })
        #expect(priv.sent.cleared.allSatisfy { $0 != nil && !$0!.clearedObjectIDs.contains(priv.kos[0]) })
        #expect(d2.timeline.contains { $0.objectID == priv.kos[0] })   // the rules still read it on the Mac

        let offline = try await rig([Self.releaseA, Self.releaseB, "x"], reader: false)
        #expect(!(await offline.svc.draftReaderAvailable()))
        let d3 = try await offline.svc.buildDrafts(caseID: offline.caseID, useAI: true)
        #expect(!d3.readerAvailable && offline.sent.all.isEmpty && !d3.timeline.isEmpty && !d3.cast.isEmpty)
    }
}

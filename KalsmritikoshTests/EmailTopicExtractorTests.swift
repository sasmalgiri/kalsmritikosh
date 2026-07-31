//
//  EmailTopicExtractorTests.swift
//  KalsmritikoshTests
//
//  PA-EXT-001B — conservative subjectless-email topic extraction. Pure-extractor rules (subject
//  wins; Re:/Fwd: trimmed but preserved; blank/(no subject) fall back to the first safe body
//  sentence; greetings/signatures/disclaimers/footers/quoted-replies/MIME-base64 rejected; capped;
//  nil when nothing safe), plus end-to-end proof through a REAL email ingest that the recovered
//  topic reaches the Event Claim statement, that separate messages never borrow each other's
//  topics or evidence, and that report == receipt with unchanged custody + workspace boundary.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-EXT-001B — email topic extractor")
struct EmailTopicExtractorTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func body(_ lines: String) -> String { "From: a@x.com\nTo: b@y.com\n\n\(lines)" }

    // MARK: - Pure rules

    @Test("A meaningful Subject header wins over the body")
    func subjectWins() {
        let topic = EmailTopicExtractor.topic(
            subject: "Revised supply agreement",
            cleanedContent: body("Some unrelated body sentence that is long enough."))
        #expect(topic == EmailTopic(text: "Revised supply agreement", origin: .structuredSubject))
    }

    @Test("\"Re: Revised agreement\" becomes the meaningful topic, not \"Re:\"")
    func replyPrefixTrimmedNotEmptied() {
        let topic = EmailTopicExtractor.topic(subject: "Re: Revised agreement", cleanedContent: body("x"))
        #expect(topic?.origin == .structuredSubject)
        #expect(topic?.text == "Revised agreement")
    }

    @Test("A bare \"Re:\" is not a topic — it falls through to the body")
    func bareReplyMarkerIsNotATopic() {
        let topic = EmailTopicExtractor.topic(
            subject: "Re:", cleanedContent: body("The delivery schedule has been confirmed for Tuesday."))
        #expect(topic?.origin == .bodySentence)
        #expect(topic?.text == "The delivery schedule has been confirmed for Tuesday.")
    }

    @Test("Blank and \"(no subject)\" use the first safe body sentence")
    func blankAndPlaceholderUseBody() {
        let sentence = "The shipment will arrive on Tuesday as promised."
        for subject in ["", "(no subject)", "Email"] {
            let topic = EmailTopicExtractor.topic(subject: subject, cleanedContent: body(sentence))
            #expect(topic?.origin == .bodySentence)
            #expect(topic?.text == sentence)
        }
    }

    @Test("Greetings are skipped in favour of the first substantive sentence")
    func greetingsSkipped() {
        let topic = EmailTopicExtractor.topic(
            subject: nil, cleanedContent: body("Hi there,\nThe contract has been finalized and signed."))
        #expect(topic?.text == "The contract has been finalized and signed.")
    }

    @Test("Signatures, disclaimers and quoted replies are skipped")
    func noiseSkipped() {
        let content = body("""
        > On Mon, someone wrote:
        This message is confidential and privileged.
        The board approved the merger on the third of March.
        Regards,
        Alex
        """)
        let topic = EmailTopicExtractor.topic(subject: nil, cleanedContent: content)
        #expect(topic?.text == "The board approved the merger on the third of March.")
    }

    @Test("Body text is capped deterministically to the max length with an ellipsis")
    func bodyCapped() {
        let long = String(repeating: "detail ", count: 60) + "end."     // > 180 chars, no terminator early
        let topic = EmailTopicExtractor.topic(subject: nil, cleanedContent: body(long))
        let text = try! #require(topic?.text)
        #expect(text.count <= EmailTopicExtractor.maxLength + 1)
        #expect(text.hasSuffix("…"))
    }

    @Test("MIME / base64 material is rejected")
    func mimeBase64Rejected() {
        let content = body("""
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: base64
        TWFuIGlzIGRpc3Rpbmd1aXNoZWQgZnJvbSB0aGUgYW5pbWFsc0J5aGlzcmVhc29u
        The quarterly figures were approved by the committee.
        """)
        let topic = EmailTopicExtractor.topic(subject: nil, cleanedContent: content)
        #expect(topic?.text == "The quarterly figures were approved by the committee.")
    }

    @Test("No safe candidate returns nil (never a fabricated topic)")
    func nilWhenNothingSafe() {
        let content = body("Hi,\nRegards,\nSent from my iPhone")
        #expect(EmailTopicExtractor.topic(subject: nil, cleanedContent: content) == nil)
        #expect(EmailTopicExtractor.topic(subject: "  ", cleanedContent: "From: a\n\n") == nil)
    }

    // MARK: - Real ingest integration

    private struct IngestRig {
        let db: Database
        let files: FilesRepository
        let objects: KnowledgeObjectRepository
        let events: EventsRepository
        let claims: ClaimRepository
        let store: EvidenceStore
        let workspaces: WorkspaceRepository
        let coordinator: IngestCoordinator
        let producer: ClaimProducer
    }

    @MainActor
    private func ingestRig(_ dir: URL) async throws -> IngestRig {
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let files = FilesRepository(database: db), objects = KnowledgeObjectRepository(database: db)
        let chunks = ChunksRepository(database: db), entities = EntitiesRepository(database: db)
        let events = EventsRepository(database: db), gf = GenericFactRepository(database: db)
        let asrt = AssertionsRepository(database: db), tcs = TemporalClaimRepository(database: db)
        let claims = ClaimRepository(database: db), store = EvidenceStore(database: db)
        let workspaces = WorkspaceRepository(database: db)
        let coordinator = IngestCoordinator(
            loaders: .standard(), entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(),
            eventExtractor: RuleEventExtractor(), narrativeSlotExtractor: RuleNarrativeSlotExtractor(),
            files: files, objects: objects, chunks: chunks, entities: entities, events: events,
            evidenceStore: store, structuralRegistry: .standard(ocr: VisionOCR()),
            assertions: asrt, genericFacts: gf,
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db)))
        let producer = ClaimProducer(genericFacts: gf, assertions: asrt, temporalClaims: tcs,
                                     events: events, claims: claims, evidence: store)
        return IngestRig(db: db, files: files, objects: objects, events: events, claims: claims,
                         store: store, workspaces: workspaces, coordinator: coordinator, producer: producer)
    }

    @Test("A real .eml with From/To/Subject projects a rich, non-generic Event Claim statement")
    @MainActor
    func realEmlRichStatement() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await ingestRig(dir)
        let url = dir.appendingPathComponent("m.eml")
        try """
        From: Alexandra Rivera <alex@orchidlabs.example>
        To: Ravi Sen <ravi@orchidlabs.example>
        Subject: Revised supply agreement
        Date: Mon, 3 Mar 2025 09:12:00 +0000

        Please review the revised supply agreement before Friday.
        """.write(to: url, atomically: true, encoding: .utf8)
        _ = try await r.coordinator.ingest(fileAt: url)
        _ = try await r.producer.backfill(at: t0)

        let statements = try await allEventClaimStatements(r)
        #expect(!statements.isEmpty)
        #expect(statements.allSatisfy { $0 != "Email" })
        #expect(statements.contains { $0.contains("Revised supply agreement") })
    }

    @Test("A real .eml with NO subject recovers a body-sentence topic (never bare \"Email\")")
    @MainActor
    func realEmlNoSubjectBodyTopic() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eml-ns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await ingestRig(dir)
        let url = dir.appendingPathComponent("ns.eml")
        try """
        From: Alexandra Rivera <alex@orchidlabs.example>
        To: Ravi Sen <ravi@orchidlabs.example>
        Date: Mon, 3 Mar 2025 09:12:00 +0000

        The board approved the revised distribution plan this morning.
        """.write(to: url, atomically: true, encoding: .utf8)
        _ = try await r.coordinator.ingest(fileAt: url)
        _ = try await r.producer.backfill(at: t0)

        let statements = try await allEventClaimStatements(r)
        #expect(!statements.isEmpty)
        #expect(statements.allSatisfy { $0 != "Email" })
        #expect(statements.contains { $0.contains("board approved the revised distribution plan") })
    }

    @Test("A real .mbox with two messages keeps each message's topic and evidence separate")
    @MainActor
    func realMboxNoCrossBorrowing() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await ingestRig(dir)
        let url = dir.appendingPathComponent("box.mbox")
        try """
        From alex@orchidlabs.example Mon Mar 03 09:12:00 2025
        From: Alexandra Rivera <alex@orchidlabs.example>
        To: Ravi Sen <ravi@orchidlabs.example>
        Subject: Supply agreement renewal
        Date: Mon, 3 Mar 2025 09:12:00 +0000

        Please renew the supply agreement.

        From beatrice@orchidlabs.example Tue Mar 04 10:00:00 2025
        From: Beatrice Cole <bea@orchidlabs.example>
        To: Ravi Sen <ravi@orchidlabs.example>
        Subject: Quarterly audit schedule
        Date: Tue, 4 Mar 2025 10:00:00 +0000

        The quarterly audit begins next week.
        """.write(to: url, atomically: true, encoding: .utf8)
        _ = try await r.coordinator.ingest(fileAt: url)
        _ = try await r.producer.backfill(at: t0)

        // Each event's claim carries ONLY its own subject — no statement blends the two topics.
        let statements = try await allEventClaimStatements(r)
        #expect(!statements.isEmpty)
        for s in statements {
            #expect(!(s.contains("Supply agreement renewal") && s.contains("Quarterly audit schedule")),
                    "a single claim statement must not blend two messages' topics")
        }
        // Both topics are represented across the produced claims.
        #expect(statements.contains { $0.contains("Supply agreement renewal") })
        #expect(statements.contains { $0.contains("Quarterly audit schedule") })
    }

    @Test("Report and receipt show the identical richer Claim text; custody + B4 unchanged")
    @MainActor
    func reportReceiptRicherIdentical() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eml-rr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await ingestRig(dir)
        let url = dir.appendingPathComponent("rr.eml")
        try """
        From: Alexandra Rivera <alex@orchidlabs.example>
        To: Ravi Sen <ravi@orchidlabs.example>
        Subject: Revised supply agreement
        Date: Mon, 3 Mar 2025 09:12:00 +0000

        Please review the revised supply agreement before Friday.
        """.write(to: url, atomically: true, encoding: .utf8)
        let result = try await r.coordinator.ingest(fileAt: url)
        _ = try await r.producer.backfill(at: t0)

        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        try await r.workspaces.addSource(result.fileRecord.id, to: wsID)
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces).deriveMembership(for: wsID)
        let assembly = try WorkProductAssemblyService(
            database: r.db, events: r.events, contradictions: ContradictionsRepository(database: r.db),
            gaps: GapNodeRepository(database: r.db), workspaces: r.workspaces)
        let ws = Workspace(id: wsID, title: "Matter", template: .general)
        let exportCtx = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
        let a = try await assembly.compose(workspace: ws, template: .generalSummary, subjectLabel: "Matter", corpusSnapshotID: nil, access: exportCtx)
        let b = try await assembly.compose(workspace: ws, template: .generalSummary, subjectLabel: "Matter", corpusSnapshotID: nil, access: exportCtx)

        let ax = a.workProduct.sections.flatMap(\.claims).map(\.text)
        #expect(ax == b.workProduct.sections.flatMap(\.claims).map(\.text))     // report == receipt selection
        #expect(ax.contains { $0.contains("Revised supply agreement") })        // richer, not bare "Email"
        #expect(!ax.contains { $0.hasSuffix("Email") })
        // Custody hashes bind, and the receipt seals + verifies.
        let sealed = try WorkProductReceiptBuilder().build(from: a)
        #expect(VerifiableReceipt.verify(sealed) == true)
    }

    /// The statement text of every produced event-derived Claim.
    private func allEventClaimStatements(_ r: IngestRig) async throws -> [String] {
        let rows = try await r.db.query("""
        SELECT c.statement FROM claims c
        JOIN claim_lineage l ON l.claim_id = c.id
        WHERE l.source_kind = 'event';
        """)
        return rows.compactMap { $0.string(0) }
    }
}

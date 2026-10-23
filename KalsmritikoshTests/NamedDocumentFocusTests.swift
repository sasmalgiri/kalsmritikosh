//
//  NamedDocumentFocusTests.swift
//  KalsmritikoshTests
//
//  Named-document focus: when the question names ONE document (caption, quoted title, file name,
//  reference number) and exactly one candidate's HEAD carries that naming, the retrieval used for
//  answering is narrowed to that document. Zero or several matches, or no naming → unchanged. A
//  caption cited in the BODY of another document never selects it. Pure — synthetic results, no DB.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Named-document focus — the question names one document")
struct NamedDocumentFocusTests {

    // Three decisions of the same kind, each with a caption head, an author passage and an author fact.
    struct Doc {
        let id = UUID()
        let headBlock = UUID()
        let authorBlock = UUID()
        let head: String
        let author: String
    }

    static func chunk(_ object: UUID, _ ordinal: Int, _ text: String, block: UUID) -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: object, ordinal: ordinal, text: text, characterRange: 0..<text.count,
                                    evidenceBlockID: block), score: 1, viaLayer: .metadata)
    }
    static func fact(_ value: String, block: UUID) -> GenericFact {
        GenericFact(subjectLabel: "decision", field: "opinion_by", value: value,
                    assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                    confidence: 0.9, sourceBlockIDs: [block])
    }

    let pinching = Doc(head: "Pinching v. Wurdeman\n12 F.2d 164\n\nPINCHING v. WURDEMAN.\nNo. 4321.\nCourt of Appeals of District of Columbia.",
                       author: "VAN ORSDEL")
    let hughes = Doc(head: "Hughes v. Life Insurance Co. of North America\n112 F. Supp. 2d 780\n\nRobert HUGHES, Plaintiff, v. LIFE INSURANCE COMPANY OF NORTH AMERICA, Defendant.\nNo. IP 99-1143-C-B/S.\nUnited States District Court, S.D. Indiana.",
                     author: "BARKER")
    let memphis = Doc(head: "Memphis Memorial Park v. McCann\n133 F. Supp. 293\n\nMEMPHIS MEMORIAL PARK v. Early M. McCANN.\nCiv. A. Nos. 1675-1677.\nUnited States District Court M. D. Tennessee.",
                      author: "WILLIAM E. MILLER")

    func result(_ docs: [Doc], extraChunks: [RetrievedChunk] = []) -> RetrievalResult {
        var chunks: [RetrievedChunk] = []
        var facts: [GenericFact] = []
        var events: [Event] = []
        for d in docs {
            chunks.append(Self.chunk(d.id, 0, d.head, block: d.headBlock))
            chunks.append(Self.chunk(d.id, 3, "\(d.author), Judge. The opinion follows.", block: d.authorBlock))
            facts.append(Self.fact(d.author, block: d.authorBlock))
            events.append(Event(kind: .emailSent, date: Date(timeIntervalSinceReferenceDate: 0), title: "decided", sourceObjectID: d.id))
        }
        return RetrievalResult(chunks: chunks + extraChunks, events: events, genericFacts: facts)
    }
    func heads(_ docs: [Doc]) -> [NamedDocumentHead] {
        docs.map { NamedDocumentHead(objectID: $0.id, fileName: "decision.pdf", headText: $0.head) }
    }

    // MARK: - Each naming form

    @Test("Caption \"A v. B\": the decision whose caption it is, and only its facts")
    func captionSelectsTheNamedDecision() throws {
        let docs = [hughes, pinching, memphis]
        let out = try #require(NamedDocumentFocus.focus(question: "Who wrote the opinion in Pinching v. Wurdeman?",
                                                        result: result(docs), heads: heads(docs)))
        #expect(out.naming == .caption)
        #expect(Set(out.result.chunks.map(\.chunk.objectID)) == [pinching.id])
        #expect(out.result.genericFacts.map(\.value) == ["VAN ORSDEL"])
        #expect(out.result.events.allSatisfy { $0.sourceObjectID == pinching.id })
        #expect(out.focusedObjectIDs == [pinching.id])
        #expect(out.note.contains("Pinching v. Wurdeman"))
    }

    @Test("Caption with a long corporate party and a trailing citation, as the case bench asks it")
    func captionWithCorporatePartyAndCitation() throws {
        let docs = [memphis, hughes, pinching]
        let q = "When was Hughes v. Life Insurance Co. of North America, 112 F. Supp. 2d 780 decided?"
        let mentions = NamedDocumentFocus.namings(in: q)
        let caption = try #require(mentions.first { $0.naming == .caption })
        #expect(caption.sideA == ["hughes"])
        #expect(caption.sideB == ["life", "insurance", "north", "america"])
        #expect(mentions.contains { $0.naming == .citation && $0.display == "112 F. Supp. 2d 780" })
        let out = try #require(NamedDocumentFocus.focus(question: q, result: result(docs), heads: heads(docs)))
        #expect(Set(out.result.chunks.map(\.chunk.objectID)) == [hughes.id])
    }

    @Test("Lower-case question still reads the caption")
    func lowercaseCaption() throws {
        let docs = [hughes, pinching, memphis]
        let out = try #require(NamedDocumentFocus.focus(question: "who wrote the opinion in memphis memorial park v. mccann",
                                                        result: result(docs), heads: heads(docs)))
        #expect(Set(out.result.chunks.map(\.chunk.objectID)) == [memphis.id])
    }

    @Test("\"In re A\" selects the matter of that name")
    func inReCaption() throws {
        let kindred = Doc(head: "In re Kindred\n117 Cal. App. 3d 165\n\nIn re JAMES KINDRED on Habeas Corpus.\nCourt of Appeals of California.", author: "BROWN")
        let docs = [kindred, hughes]
        let out = try #require(NamedDocumentFocus.focus(question: "Who wrote the majority opinion in In re Kindred, 117 Cal. App. 3d 165?",
                                                        result: result(docs), heads: heads(docs)))
        #expect(Set(out.result.chunks.map(\.chunk.objectID)) == [kindred.id])
    }

    @Test("Citation / reference number alone selects the one document whose head carries it")
    func citationSelects() throws {
        let docs = [hughes, pinching, memphis]
        let byReporter = try #require(NamedDocumentFocus.focus(question: "When was 133 F. Supp. 293 decided?",
                                                               result: result(docs), heads: heads(docs)))
        #expect(byReporter.naming == .citation)
        #expect(Set(byReporter.result.chunks.map(\.chunk.objectID)) == [memphis.id])
        let byDocket = try #require(NamedDocumentFocus.focus(question: "Who decided docket 99-1143?",
                                                             result: result(docs), heads: heads(docs)))
        #expect(Set(byDocket.result.chunks.map(\.chunk.objectID)) == [hughes.id])
    }

    @Test("Quoted title (straight or curly quotes) selects the release of that title")
    func quotedTitleSelects() throws {
        let fairfield = Doc(head: "U.S. Attorney's Office\nDistrict of Connecticut\nFairfield Man Indicted for Bank Fraud\nTuesday, March 5, 2024", author: "Fairfield man")
        let hartford = Doc(head: "U.S. Attorney's Office\nDistrict of Connecticut\nHartford Woman Sentenced for Wire Fraud\nMonday, March 4, 2024", author: "Hartford woman")
        let docs = [hartford, fairfield]
        for q in ["What happened in \"Fairfield Man Indicted for Bank Fraud\"?", "What happened in “Fairfield Man Indicted for Bank Fraud”?"] {
            let out = try #require(NamedDocumentFocus.focus(question: q, result: result(docs), heads: heads(docs)))
            #expect(out.naming == .quotedTitle)
            #expect(Set(out.result.chunks.map(\.chunk.objectID)) == [fairfield.id])
        }
    }

    @Test("File name with an extension selects that file; a shared file name is ambiguous")
    func fileNameSelects() throws {
        let a = Doc(head: "INVOICE 401\nTotal due: $1,200", author: "Acme")
        let b = Doc(head: "INVOICE 402\nTotal due: $9,900", author: "Beta")
        let docs = [a, b]
        let h = [NamedDocumentHead(objectID: a.id, fileName: "invoice-401.pdf", headText: a.head),
                 NamedDocumentHead(objectID: b.id, fileName: "invoice-402.pdf", headText: b.head)]
        let out = try #require(NamedDocumentFocus.focus(question: "What is the total in invoice-401.pdf?", result: result(docs), heads: h))
        #expect(out.naming == .fileName)
        #expect(Set(out.result.chunks.map(\.chunk.objectID)) == [a.id])
        // Twelve decisions all called decision.pdf: naming the file name picks none.
        #expect(NamedDocumentFocus.focus(question: "Who wrote decision.pdf?", result: result([hughes, pinching]),
                                         heads: heads([hughes, pinching])).isNil)
    }

    // MARK: - Never guess

    @Test("Two documents with the same caption (trial and appeal) → unchanged")
    func ambiguityUnchanged() {
        let trial = Doc(head: "Smith v. Jones\nNo. 10-200\nDistrict Court.", author: "ADAMS")
        let appeal = Doc(head: "Smith v. Jones\nNo. 11-300\nCourt of Appeals.", author: "BAKER")
        let docs = [trial, appeal]
        #expect(NamedDocumentFocus.focus(question: "Who wrote the opinion in Smith v. Jones?", result: result(docs), heads: heads(docs)).isNil)
    }

    @Test("No naming in the question → unchanged")
    func noNamingUnchanged() {
        let docs = [hughes, pinching]
        #expect(NamedDocumentFocus.focus(question: "Who wrote the opinion?", result: result(docs), heads: heads(docs)).isNil)
        #expect(NamedDocumentFocus.focus(question: "What happened in 2024?", result: result(docs), heads: heads(docs)).isNil)
        #expect(NamedDocumentFocus.namings(in: "What was decided on 2024-03-05 about the $1,200,000 claim?").isEmpty)
    }

    @Test("A caption cited only in another document's BODY never selects that document")
    func bodyCitationDoesNotSelect() throws {
        // Memphis's own body (a later passage) cites "Pinching v. Wurdeman"; its head does not.
        let citing = Self.chunk(memphis.id, 6, "See Pinching v. Wurdeman, 12 F.2d 164, for the rule.", block: UUID())
        let without = [hughes, memphis]
        #expect(NamedDocumentFocus.focus(question: "Who wrote the opinion in Pinching v. Wurdeman?",
                                         result: result(without, extraChunks: [citing]), heads: heads(without)).isNil)
        // A long head whose citation lies beyond the caption window is not a match either.
        let longHead = memphis.head + "\n" + String(repeating: "The facts are stipulated. ", count: 40)
            + "Compare Pinching v. Wurdeman, 12 F.2d 164."
        let h = [NamedDocumentHead(objectID: hughes.id, headText: hughes.head),
                 NamedDocumentHead(objectID: memphis.id, headText: longHead)]
        #expect(NamedDocumentFocus.focus(question: "Who wrote the opinion in Pinching v. Wurdeman?",
                                         result: result(without), heads: h).isNil)
        // With the named decision present, it — not the citing one — is chosen.
        let all = [hughes, memphis, pinching]
        let out = try #require(NamedDocumentFocus.focus(question: "Who wrote the opinion in Pinching v. Wurdeman?",
                                                        result: result(all, extraChunks: [citing]), heads: heads(all)))
        #expect(Set(out.result.chunks.map(\.chunk.objectID)) == [pinching.id])
    }

    @Test("A question that asks across documents is not focused")
    func acrossDocumentsUnchanged() {
        let docs = [hughes, pinching, memphis]
        #expect(NamedDocumentFocus.focus(question: "Which decisions cite Pinching v. Wurdeman?", result: result(docs), heads: heads(docs)).isNil)
    }

    @Test("An email and its attachment are one document: both kept")
    func attachmentFamilyKept() throws {
        let email = Doc(head: "From: Records <r@x.example>\nSubject: Records: Hughes v. Life Insurance Co. of North America\n\nPlease find attached.", author: "—")
        let attachment = hughes
        let docs = [email, attachment, pinching]
        let family = UUID()
        let h = [NamedDocumentHead(objectID: email.id, familyKey: family, fileName: "records.eml", headText: email.head),
                 NamedDocumentHead(objectID: attachment.id, familyKey: family, fileName: "decision.pdf", headText: attachment.head),
                 NamedDocumentHead(objectID: pinching.id, fileName: "decision.pdf", headText: pinching.head)]
        let out = try #require(NamedDocumentFocus.focus(question: "Who wrote the opinion in Hughes v. Life Insurance Co. of North America?",
                                                        result: result(docs), heads: h))
        #expect(Set(out.result.chunks.map(\.chunk.objectID)) == [email.id, attachment.id])
        // Family keys: an attachment of a one-object file joins it; mailbox messages stay apart.
        let file = UUID(), parent = UUID(), object = UUID()
        #expect(NamedDocumentFocus.familyKey(objectID: object, fileID: file, fileObjectCount: 1, parentFileID: parent, parentFileObjectCount: 1) == parent)
        #expect(NamedDocumentFocus.familyKey(objectID: object, fileID: file, fileObjectCount: 1, parentFileID: nil, parentFileObjectCount: 0) == file)
        #expect(NamedDocumentFocus.familyKey(objectID: object, fileID: file, fileObjectCount: 40, parentFileID: nil, parentFileObjectCount: 0) == object)
    }

    @Test("Narrowing keeps facts by their blocks and drops cross-document summaries")
    func narrowingRules() {
        let docs = [hughes, pinching]
        let base = result(docs)
        let withSummaries = RetrievalResult(
            chunks: base.chunks, events: base.events,
            summaries: [Summary(level: .document, length: .short, scope: .document(pinching.id), body: "p"),
                        Summary(level: .document, length: .short, scope: .document(hughes.id), body: "h"),
                        Summary(level: .knowledgeBase, length: .short, scope: .knowledgeBase, body: "kb")],
            genericFacts: base.genericFacts, authorityObjectIDs: [hughes.id, pinching.id])
        let n = NamedDocumentFocus.narrow(withSummaries, to: [pinching.id])
        #expect(n.summaries.map(\.body) == ["p"])
        #expect(n.authorityObjectIDs == [pinching.id])
        #expect(n.genericFacts.map(\.value) == ["VAN ORSDEL"])
    }
}

extension Optional where Wrapped == NamedDocumentFocusOutcome {
    var isNil: Bool { self == nil }
}

/// End to end: three short decisions in a throwaway ledger; the question names one; the answer
/// names that decision's author, not a sibling's — and does not report a cross-decision conflict.
@Suite("Named-document focus — through the real answer path", .serialized)
struct NamedDocumentFocusLedgerTests {

    static let decisions: [(file: String, text: String)] = [
        ("goudeau.txt", """
        Goudeau v. Daigle
        124 F.2d 656

        GOUDEAU v. DAIGLE et al.
        No. 9941.
        Circuit Court of Appeals, Fifth Circuit.
        January 6, 1942.

        HOLMES, Circuit Judge.
        This appeal is from a judgment dismissing appellant's suit to enforce specific performance of a contract for the sale of land, on the ground that the complaint failed to state a cause of action.
        The sales agreement was a commutative contract imposing reciprocal obligations, and the appellant never tendered the purchase price within the time fixed by the contract.
        Neither may the denial of specific performance be reversed. The judgment appealed from is affirmed. We note that Pinching v. Wurdeman, 12 F.2d 164, states a different rule for leases, and that Hughes v. Life Insurance Co. of North America, No. IP 99-1143-C-B/S, is not to the contrary.
        """),
        ("pinching.txt", """
        Pinching v. Wurdeman
        12 F.2d 164

        PINCHING v. WURDEMAN.
        No. 4321.
        Court of Appeals of District of Columbia.
        April 5, 1926.

        VAN ORSDEL, Circuit Judge.
        This is an appeal from a decree of the Supreme Court of the District of Columbia dismissing a bill to cancel a lease of real property.
        The lessee entered into possession and paid rent for several years before the bill was filed, and the lessor accepted the payments.
        The decree is affirmed.
        """),
        ("hughes.txt", """
        Hughes v. Life Insurance Co. of North America
        112 F. Supp. 2d 780

        Robert HUGHES, Plaintiff, v. LIFE INSURANCE COMPANY OF NORTH AMERICA, Defendant.
        No. IP 99-1143-C-B/S.
        United States District Court, S.D. Indiana.
        September 5, 2000.

        BARKER, District Judge.
        Plaintiff seeks long-term disability benefits under an employee welfare benefit plan administered by the defendant insurer.
        The administrator's denial of benefits was not arbitrary and capricious on this record.
        The defendant's motion for summary judgment is granted.
        """),
    ]

    @Test("\"Who wrote the opinion in Pinching v. Wurdeman?\" → Van Orsdel, not Holmes or Barker")
    func authorOfTheNamedDecision() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var settings = previous
        settings["kalsmritikosh.privacy.offlineNoLLM"] = true   // evidence path: deterministic
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pj-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = await AppState(bookmarks: BookmarkStore())
        await state.boot(databaseURL: temp.appendingPathComponent("focus.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest else {
            Issue.record("ledger did not boot"); return
        }
        for d in Self.decisions {
            let url = temp.appendingPathComponent(d.file)
            try d.text.write(to: url, atomically: true, encoding: .utf8)
            _ = try await ingest.ingest(fileAt: url)
        }

        let question = "Who wrote the opinion in Pinching v. Wurdeman?"
        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
        // What retrieval hands the answer path, before focus: which documents it surfaced.
        var diagnostic: [String] = []
        if let detector = await state.intentDetector, let router = await state.router, let retriever = await state.retriever,
           let intent = try? await detector.detect(question: question), let route = try? await router.route(intent: intent),
           let retrieved = try? await retriever.retrieve(for: intent, layers: route.retrievalLayers, access: access) {
            let r = retrieved.result
            let ids = NamedDocumentFocus.candidateObjectIDs(in: r)
            diagnostic.append("candidates: \(ids.count), chunks \(r.chunks.count), facts \(r.genericFacts.map { "\($0.field)=\($0.value)" })")
            if let objects = await state.objects {
                let rows = (try? await objects.documentHeads(for: Set(ids))) ?? []
                let heads = rows.map { NamedDocumentHead(objectID: $0.objectID, familyKey: NamedDocumentFocus.familyKey(
                    objectID: $0.objectID, fileID: $0.fileID, fileObjectCount: $0.fileObjectCount,
                    parentFileID: $0.parentFileID, parentFileObjectCount: $0.parentFileObjectCount),
                    title: $0.title, fileName: $0.fileName, headText: $0.head) }
                diagnostic += rows.map { "head \($0.fileName ?? "-") files=\($0.fileObjectCount) title=\($0.title ?? "-"): \($0.head.prefix(60))" }
                let focus = NamedDocumentFocus.focus(question: question, result: r, heads: heads)
                diagnostic.append("focus: \(focus?.note ?? "none") chunks→\(focus?.result.chunks.count ?? -1)")
                // The ledger heads identify the named decision on their own.
                #expect(focus?.focusedObjectIDs.count == 1, "focus picks exactly the named decision")
                #expect(focus?.result.genericFacts.contains { $0.value == "Holmes" || $0.value == "Barker" } == false)
            }
        }
        let brain = await state.brain
        // The bare caption, and the case bench's form with the reporter citation — which the
        // identifier anchor resolves to EVERY document containing it, the citing decision too.
        // The third names Hughes with its docket number, which the citing decision (Goudeau) also
        // carries in its body: the identifier anchor admits BOTH documents, and the focus step is
        // what narrows the answer to the decision whose caption it is.
        let asks: [(q: String, author: String, focused: Bool)] = [
            (question, "orsdel", false),
            ("Who wrote the majority opinion in Pinching v. Wurdeman, 12 F.2d 164?", "orsdel", false),
            ("Who wrote the opinion in Hughes v. Life Insurance Co. of North America, No. IP 99-1143-C-B/S?", "barker", true),
        ]
        for (q, author, mustFocus) in asks {
            let a = await brain.answer(question: q, access: access)
            let body = a.body.lowercased()
            Attachment.record(([q, a.body, "trace: \(a.reasoningTrace?.assumptions ?? [])"] + diagnostic).joined(separator: "\n"),
                              named: "focus-answer.txt")
            #expect(!a.refused, "answered: \(a.refusalReason ?? "")")
            #expect(body.contains(author), "the named decision's author: \(a.body)")
            let siblings = ["orsdel", "holmes", "barker"].filter { $0 != author }
            #expect(!siblings.contains { body.contains($0) }, "no sibling decision's author: \(a.body)")
            if mustFocus {
                #expect(a.reasoningTrace?.assumptions.contains { $0.hasPrefix("Focused on") } == true,
                        "the answer path records the focus: \(a.reasoningTrace?.assumptions ?? [])")
            }
            #expect(!body.contains("conflict"), "no cross-decision conflict: \(a.body)")
        }
    }
}

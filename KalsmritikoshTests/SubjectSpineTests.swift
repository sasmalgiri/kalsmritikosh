//
//  SubjectSpineTests.swift
//  KalsmritikoshTests
//
//  The trunk of the upside-down tree, pinned against the shapes the owner's
//  real ledger showed (2026-09-25): one patent under four anchors, a mailbox
//  whose facts all took its file name, thread KOs that owned no evidence.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Subject spine — anchors reach documents, one matter one family")
struct SubjectSpineTests {

    private func anchor(_ field: String, _ canon: String, source: UUID = UUID()) -> SubjectSpine.Anchor {
        SubjectSpine.Anchor(id: UUID(), field: field, canon: canon, value: "\(field) \(canon)", sourceObjectID: source)
    }

    @Test("Whole-token match: a truncated number never matches inside the full one")
    func tokenBoundaries() {
        #expect(SubjectSpine.containsToken("202331019665", in: "Hearing Notice of Patent Application-202331019665 Date"))
        #expect(SubjectSpine.containsToken("555489", in: "Patent No. 555489."))
        #expect(!SubjectSpine.containsToken("2023310", in: "Application-202331019665"))
        #expect(SubjectSpine.containsToken("2023310", in: "Patent Application-2023310 Date:"))
        #expect(!SubjectSpine.containsToken("555489", in: "ref 15554890"))
    }

    @Test("One patent: same value under two field names, the grant letter's pair, and a truncated copy form ONE family")
    func patentFamily() {
        let app = anchor("applicationnumber", "202331019665")
        let patSameValue = anchor("patentnumber", "202331019665")
        let granted = anchor("patentnumber", "555489")
        let truncated = anchor("applicationnumber", "2023310")
        let other = anchor("patentnumber", "777001")
        let fam = SubjectSpine.families(
            anchors: [app, patSameValue, granted, truncated, other],
            coChunk: [[granted.id, app.id]])
        let root = fam[app.id]
        #expect(fam[patSameValue.id] == root, "R1 — one value, two names")
        #expect(fam[granted.id] == root, "R2 — named together in one chunk")
        #expect(fam[truncated.id] == root, "R3 — strict prefix of exactly one sibling")
        #expect(fam[other.id] != root, "an unrelated patent stays its own matter")
    }

    @Test("Attribute identifiers never join matters, and a list chunk naming many matters joins none")
    func noFalseJoins() {
        let patA = anchor("patentnumber", "111111")
        let patB = anchor("patentnumber", "222222")
        let patC = anchor("patentnumber", "333333")
        let patD = anchor("patentnumber", "444444")
        let account = anchor("accountnumber", "03201050025348")
        let fam = SubjectSpine.families(
            anchors: [patA, patB, patC, patD, account],
            coChunk: [[patA.id, account.id], [patA.id, patB.id, patC.id, patD.id]])
        #expect(fam[account.id] == account.id, "a bank account on a letterhead is not a matter")
        #expect(fam[patA.id] != fam[patB.id], "a report listing four matters does not make them one")
    }

    @Test("A document goes to the family it names most; a tie stays unresolved")
    func documentResolution() {
        let a = anchor("patentnumber", "111111"), b = anchor("casenumber", "c-9")
        let fam = [a.id: a.id, b.id: b.id]
        let byID = [a.id: a, b.id: b]
        let clear = UUID(), tie = UUID()
        let out = SubjectSpine.resolveObjects(
            reach: [.init(anchorID: a.id, objectID: clear, hits: 3),
                    .init(anchorID: b.id, objectID: clear, hits: 1),
                    .init(anchorID: a.id, objectID: tie, hits: 2),
                    .init(anchorID: b.id, objectID: tie, hits: 2)],
            familyOf: fam, anchors: byID)
        #expect(out[clear] == a.id)
        #expect(out[tie] == nil, "never guess between two matters")
    }

    @Test("Family label: patent number first, the application alongside, truncated copies hidden")
    func familyLabel() {
        let label = SubjectSpine.label(for: [
            anchor("applicationnumber", "202331019665"),
            anchor("patentnumber", "555489"),
            anchor("applicationnumber", "2023310"),
            anchor("patentnumber", "202331019665"),
        ])
        #expect(label == "Patent No. 555489 (Application 202331019665)", "got \(label)")
    }

    @Test("A report that LISTS messages is not about the matters in their subjects")
    func listingsAreNotAboutness() {
        let listing = "1. [MED] Suspicious language From: Shabana Khan <s@k.com> Subject: Re: [Our Ref: TIN23/2367] Hearing Notice of Patent Application-202331019665 Date: Tue, 6 Aug 2024"
        #expect(SubjectSpine.containsToken("202331019665", in: listing), "the mention still counts")
        #expect(!SubjectSpine.containsToken("202331019665", in: SubjectSpine.withoutQuotedSubjects(listing)),
                "but not as what the report is about")
        let inline = "Credit Card Pattern in Plain Body of 'RE: [Our Ref: TIN23/2367] Hearing Notice of Patent Application-202331019665' and 'Wish you'"
        #expect(!SubjectSpine.containsToken("202331019665", in: SubjectSpine.withoutQuotedSubjects(inline)),
                "an inline-quoted reply subject is a listing too")
        let petition = "Application No. 202331019665 filed on 22/03/2023 by the applicant"
        #expect(SubjectSpine.containsToken("202331019665", in: SubjectSpine.withoutQuotedSubjects(petition)))
    }

    @Test("A fact whose label names exactly one matter joins it; naming two joins neither")
    func labelNamesMatter() {
        var r = SubjectSpine.Resolution()
        let a = UUID(), b = UUID()
        r.label = [a: "Patent No. 555489 (Application 202331019665)", b: "Case c-777777"]
        r.canonFamily = [("202331019665", a), ("2023310", a), ("c-777777", b)]
        #expect(r.subjectLabel(anchorID: nil, currentLabel: "[Our Ref: TIN23/2367] Hearing Notice of Patent Application-202331019665",
                               objectIDs: []) == "Patent No. 555489 (Application 202331019665)")
        #expect(r.subjectLabel(anchorID: nil, currentLabel: "202331019665 and c-777777", objectIDs: []) == nil)
        #expect(r.subjectLabel(anchorID: nil, currentLabel: "Invoice for your internet", objectIDs: []) == nil)
    }

    @Test("Mention ids are deterministic so a rerun writes nothing new")
    func deterministicMentionID() {
        let a = UUID(), o = UUID()
        #expect(SubjectSpine.mentionID(anchorID: a, objectID: o) == SubjectSpine.mentionID(anchorID: a, objectID: o))
        #expect(SubjectSpine.mentionID(anchorID: a, objectID: o) != SubjectSpine.mentionID(anchorID: o, objectID: a))
    }
}

@Suite("Fact subject partitioning — a mailbox is not one document")
struct FactSubjectPartitionerTests {

    private func block(_ kind: EvidenceBlockKind, _ text: String, message: Int?, header: String? = nil) -> EvidenceBlock {
        EvidenceBlock(documentID: UUID(), ordinal: 0, kind: kind, rawText: text,
                      locator: SourceLocator(emailHeaderField: header),
                      attributes: message.map { ["messageIndex": AnyCodable(.int(Int64($0)))] } ?? [:])
    }

    @Test("Each message's facts take its normalized Subject, not the mailbox file name")
    func perMessageSubjects() {
        let blocks = [
            block(.emailHeader, "Re: RE: [Our Ref: TIN23/2367] Hearing Notice of Patent Application-202331019665", message: 0, header: "subject"),
            block(.emailBody, "Status: amendment filed", message: 0),
            block(.emailHeader, "Fwd: YOUR CV HAS BEEN SHORTLISTED", message: 1, header: "subject"),
            block(.emailBody, "Employer: Movers Limited", message: 1),
        ]
        let parts = FactSubjectPartitioner.partitions(blocks: blocks, fallbackLabel: "Sent")
        #expect(parts.map(\.subjectLabel) == [
            "[Our Ref: TIN23/2367] Hearing Notice of Patent Application-202331019665",
            "YOUR CV HAS BEEN SHORTLISTED",
        ])
        #expect(parts.allSatisfy { $0.blocks.count == 2 }, "no block crosses into another message")
    }

    @Test("A single document stays one partition under its own label — unchanged behaviour")
    func singleDocumentUnchanged() {
        let blocks = [block(.paragraph, "Applicant: Jane Roe", message: nil),
                      block(.paragraph, "Application No: 1234", message: nil)]
        let parts = FactSubjectPartitioner.partitions(blocks: blocks, fallbackLabel: "Form 5")
        #expect(parts.count == 1)
        #expect(parts.first?.subjectLabel == "Form 5")
        #expect(parts.first?.blocks.count == 2)
    }

    @Test("A message with no Subject line falls back to the file label")
    func missingSubject() {
        let parts = FactSubjectPartitioner.partitions(
            blocks: [block(.emailBody, "Amount: Rs.1500", message: 4)], fallbackLabel: "Sent")
        #expect(parts.first?.subjectLabel == "Sent")
        #expect(FactSubjectPartitioner.normalizedSubject("Subject: Re:  ") == nil)
    }

    @Test("A thread KO owns the blocks of every message it lists — it used to own none")
    func threadKOOwnsItsBlocks() {
        let bag = #"[{"messageIndex":3,"subject":"a"},{"messageIndex":7,"subject":"a"}]"#
        let ko = KnowledgeObject(sourceFile: URL(fileURLWithPath: "/tmp/Sent.mbox"), sourceType: .mbox,
                                 content: "thread", metadata: [EmailLoader.threadMessagesMetaKey: AnyCodable(.string(bag))])
        let blocks = [3, 5, 7].map { (n: Int) in block(.emailBody, "body \(n)", message: n) }
        let own = IngestCoordinator.blocks(for: ko, from: blocks, singleKO: false)
        #expect(own.map(\.rawText) == ["body 3", "body 7"])
        #expect(EmailLoader.threadMessageIndices(fromBag: bag) == [3, 7])
    }
}

@Suite("Subject spine — over a real ledger", .serialized)
@MainActor
struct SubjectSpineLedgerTests {

    @Test("Anchors reach every document naming them; the matter's documents resolve to one family; reruns write nothing")
    func runOverLedger() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        func ko(_ name: String) async throws -> UUID {
            let fileID = UUID(), id = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, 'pdf');",
                              [.uuid(fileID), .text("file:///tmp/\(name).pdf")])
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?, ?, 'pdf', ?, 0, 0);
            """, [.uuid(id), .uuid(fileID), .text(name)])
            return id
        }
        func chunk(_ text: String, _ object: UUID) async throws {
            try await db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at)
            VALUES (?, ?, 0, ?, 0, ?, 0);
            """, [.uuid(UUID()), .uuid(object), .text(text), .integer(Int64(text.count))])
        }
        func anchor(_ key: String, value: String, source: UUID) async throws -> UUID {
            let id = UUID()
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
            VALUES (?, 'identifierAnchor', ?, ?, ?, 0.9);
            """, [.uuid(id), .text(value), .text(key), .uuid(source)])
            return id
        }

        let form5 = try await ko("Form 5")
        let grant = try await ko("Grant Certificate")
        let hearing = try await ko("Hearing Notice_202331019665")   // named for the matter, no number in text
        let unrelated = try await ko("Recipe")
        try await chunk("Application No: 202331019665 Applicant: Jane Roe", form5)
        try await chunk("Patent No. 555489 granted on Application No. 202331019665", grant)
        try await chunk("You are requested to attend the hearing", hearing)
        try await chunk("sourdough starter hydration 2023310", unrelated)

        let app = try await anchor("applicationnumber|202331019665", value: "Application No. 202331019665", source: form5)
        let pat = try await anchor("patentnumber|555489", value: "Patent No. 555489", source: grant)

        let spine = SubjectSpine(database: db)
        let (resolution, receipt) = try await spine.run()
        #expect(receipt.mentionsWritten >= 4, "form 5, grant (both anchors), and the file named for the matter")
        #expect(resolution.familyOf[app] == resolution.familyOf[pat], "the grant letter names both numbers")
        let family = try #require(resolution.familyOf[app])
        #expect(resolution.subjectOfObject[form5] == family)
        #expect(resolution.subjectOfObject[grant] == family)
        #expect(resolution.subjectOfObject[hearing] == family, "the file name carries the matter")
        #expect(resolution.subjectOfObject[unrelated] == nil)
        #expect(resolution.label[family] == "Patent No. 555489 (Application 202331019665)")
        #expect(resolution.subjectLabel(anchorID: nil, objectIDs: [hearing]) == "Patent No. 555489 (Application 202331019665)")

        let (_, rerun) = try await spine.run()
        #expect(rerun.mentionsWritten == 0, "idempotent — same world, no new rows")
    }
}

//
//  CommunityDetectorKindTests.swift
//  KalsmritikoshTests
//
//  P1.14 — attributes (dates, money, phone numbers) are never community
//  members, even when an older co-occurrence graph still carries their edges.
//  On the owner's copy 88 of ~350 level-0 members were email date headers.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P1.14 — community detection ignores attribute entities", .serialized)
struct CommunityDetectorKindTests {

    @Test("A stale date edge cannot pull a date header into a community; people still cluster")
    func datesNeverJoinCommunities() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("comm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///x.eml"), .text("eml")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, 'eml', 'body', 0, 0);
        """, [.uuid(ko), .uuid(fileID)])
        let alice = UUID(), bob = UUID(), stamp = UUID()
        for (id, kind, value) in [(alice, "person", "Alice Rao"), (bob, "person", "Bob Sen"),
                                  (stamp, "date", "Mon, 26 Jul 2021 20:02:20")] {
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
            VALUES (?, ?, ?, ?, ?, 0.9);
            """, [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(ko)])
        }
        // A graph built before the builder excluded dates: the date is the
        // strongest edge of all.
        for (a, b, w) in [(alice, bob, 3), (alice, stamp, 9), (bob, stamp, 9)] {
            let (x, y) = a.uuidString < b.uuidString ? (a, b) : (b, a)
            try await db.exec("""
            INSERT INTO entity_cooccurrences (entity_a, entity_b, weight, computed_at) VALUES (?, ?, ?, 0);
            """, [.uuid(x), .uuid(y), .integer(Int64(w))])
        }

        _ = await AgglomerativeCommunityDetector(database: db).runOnce()
        let members = Set(try await db.query(
            "SELECT entity_id FROM entity_communities WHERE level = 0;", []).compactMap { $0.uuid(0) })
        #expect(!members.contains(stamp), "a date header is an attribute, never a community member")
        #expect(members.isSuperset(of: [alice, bob]), "the people still form their community")
    }
}

@Suite("P1.18 — matter communities hold real parties", .serialized)
struct MatterCommunityHygieneTests {

    @Test("A name the ledger also holds as a place bridges nothing; a retired entity joins nothing")
    func placesAndRetiredStayOut() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("comm18-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///x.eml"), .text("eml")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, 'eml', 'body', 0, 0);
        """, [.uuid(ko), .uuid(fileID)])
        let alice = UUID(), bob = UUID(), cityOrg = UUID(), cityPlace = UUID(), mr = UUID()
        for (id, kind, value) in [(alice, "person", "Alice Rao"), (bob, "person", "Bob Sen"),
                                  (cityOrg, "organization", "Chennai"), (cityPlace, "location", "Chennai"),
                                  (mr, "person", "Mr")] {
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
            VALUES (?, ?, ?, ?, ?, 0.9);
            """, [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(ko)])
        }
        try await db.exec("UPDATE entities SET review_status = 'rejected' WHERE id = ?;", [.uuid(mr)])
        for (a, b, w) in [(alice, bob, 3), (alice, cityOrg, 9), (bob, cityOrg, 9), (alice, mr, 9)] {
            let (x, y) = a.uuidString < b.uuidString ? (a, b) : (b, a)
            try await db.exec("""
            INSERT INTO entity_cooccurrences (entity_a, entity_b, weight, computed_at) VALUES (?, ?, ?, 0);
            """, [.uuid(x), .uuid(y), .integer(Int64(w))])
        }
        _ = await AgglomerativeCommunityDetector(database: db).runOnce()
        let members = Set(try await db.query(
            "SELECT entity_id FROM entity_communities WHERE level = 0;", []).compactMap { $0.uuid(0) })
        #expect(!members.contains(cityOrg), "Chennai-as-organisation is the place, mistyped")
        #expect(!members.contains(mr), "a retired entity is no community member")
        #expect(members.isSuperset(of: [alice, bob]))
    }

    @Test("Association bar: co-mentioned in most of the rarer entity's documents merges; a few report listings do not")
    func associationBar() {
        #expect(AgglomerativeCommunityDetector.associated(weight: 12, documentsA: 12, documentsB: 40), "letterhead partner: always beside the firm")
        #expect(!AgglomerativeCommunityDetector.associated(weight: 3, documentsA: 10, documentsB: 40), "3 archive-wide reports of 10 documents")
        #expect(AgglomerativeCommunityDetector.associated(weight: 3, documentsA: 4, documentsB: 40))
        #expect(AgglomerativeCommunityDetector.associated(weight: 3, documentsA: nil, documentsB: 40), "no counts: no refusal")
    }

    @Test("Forms of address and bare initials are no person; real names with them pass")
    func addressForms() {
        let gate = EntityQualityGate()
        for v in ["Mr", "Mam", "Shri", "H.S", "S.C", "Mr. K."] {
            #expect(gate.classify(Entity(kind: .person, value: v, sourceObjectID: UUID())) == "address-form-only", "\(v)")
        }
        for v in ["Sri Lanka", "Dr. Hyacintha Lobo", "A. R. Rahman", "Li Na", "Mr. Tarun Khurana", "Shabana Khan"] {
            #expect(gate.classify(Entity(kind: .person, value: v, sourceObjectID: UUID())) != "address-form-only", "\(v)")
        }
    }

    @Test("Address lines, document furniture and digitless invoice numbers are retired; real parties pass")
    func furnitureAndStreets() {
        let gate = EntityQualityGate()
        func cls(_ k: Entity.Kind, _ v: String) -> String? { gate.classify(Entity(kind: k, value: v, sourceObjectID: UUID())) }
        for v in ["Senapati Bapat Road", "Shanthi Colony", "Sampada Apartment"] { #expect(cls(.person, v) == "street-shaped", "\(v)") }
        for v in ["Page", "FIG.", "Claims", "OBJECTION", "Invoice"] { #expect(cls(.organization, v) == "document-furniture", "\(v)") }
        #expect(cls(.invoiceNumber, "for") == "identifier-without-digit")
        #expect(cls(.invoiceNumber, "Serial") == "identifier-without-digit")
        #expect(cls(.invoiceNumber, "INV-2024-07") == nil)
        #expect(cls(.person, "Mail Delivery Subsystem") == "automated-sender")
        for (k, v) in [(Entity.Kind.person, "Lois Lane"), (.person, "Picabo Street"), (.person, "Tarun Khurana"),
                       (.organization, "Page Industries"), (.organization, "Controller of Patents"),
                       (.organization, "Table Bay Hotels")] {
            #expect(cls(k, v) == nil, "\(v) is a real party")
        }
    }
}

@Suite("P1.18b — a message listing relates nobody", .serialized)
struct ListingDocumentEdgeTests {

    @Test("People named side by side only in report listings get no edge; the same pair in real documents does; mail is exempt")
    func listingsContributeNoEdge() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("list18-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let listing = (1...3).map { "\($0). From: a\($0)@x.com Subject: Matter \($0) Date: 2024" }.joined(separator: "\n")
        let quotedMail = (1...3).map { "> From: a\($0)@x.com\n> Subject: Re: plan" }.joined(separator: "\n")
        func ko(_ type: String, _ content: String) async throws -> UUID {
            let file = UUID(), id = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                              [.uuid(file), .text("file:///\(id).\(type)"), .text(type)])
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, ?, ?, 0, 0);
            """, [.uuid(id), .uuid(file), .text(type), .text(content)])
            return id
        }
        let reports = [try await ko("pdf", listing), try await ko("pdf", listing)]
        let letters = [try await ko("pdf", "Dear Alice, Bob will call."), try await ko("pdf", "Alice and Bob met.")]
        let mails = [try await ko("eml", quotedMail), try await ko("eml", quotedMail)]
        let alice = UUID(), bob = UUID(), carol = UUID(), dan = UUID(), erin = UUID(), frank = UUID()
        for (id, v) in [(alice, "Alice Rao"), (bob, "Bob Sen"), (carol, "Carol Das"), (dan, "Dan Roy"), (erin, "Erin Paul"), (frank, "Frank Lee")] {
            try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?, 'person', ?, ?, ?);",
                              [.uuid(id), .text(v), .text(v.lowercased()), .uuid(reports[0])])
        }
        func mention(_ e: UUID, _ k: UUID) async throws {
            try await db.exec("""
            INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, confidence)
            VALUES (?, ?, 'person', 's', ?, ?, 1.0);
            """, [.uuid(UUID()), .uuid(e), .text(UUID().uuidString), .uuid(k)])
        }
        for k in reports { try await mention(carol, k); try await mention(dan, k) }
        for k in letters { try await mention(alice, k); try await mention(bob, k) }
        for k in mails { try await mention(erin, k); try await mention(frank, k) }

        _ = await CooccurrenceGraphBuilder(database: db).runOnce()
        let pairs = Set(try await db.query("SELECT entity_a, entity_b FROM entity_cooccurrences;", []).compactMap { r -> Set<UUID>? in
            guard let a = r.uuid(0), let b = r.uuid(1) else { return nil }
            return [a, b]
        })
        #expect(pairs.contains([alice, bob]), "two real documents relate them")
        #expect(pairs.contains([erin, frank]), "a mail thread's quoted headers are conversation, not a listing")
        #expect(!pairs.contains([carol, dan]), "named side by side only in message listings")
    }
}

@Suite("P1.17 — topic labels are words, not fragments")
struct TopicLabelHygieneTests {
    @Test("Encoded fragments and truncated identifiers never label a node; real words and full identifiers do")
    func labelWorthy() {
        let canons: Set<String> = ["202331019665"]
        #expect(!TopicTreeBuilder.isLabelWorthy("capuxmjoemkzvp", anchorCanons: canons))
        #expect(!TopicTreeBuilder.isLabelWorthy("2023310", anchorCanons: canons))
        #expect(TopicTreeBuilder.isLabelWorthy("202331019665", anchorCanons: canons))
        for word in ["pharmaceuticals", "strengths", "attorney", "investigation", "khurana"] {
            #expect(TopicTreeBuilder.isLabelWorthy(word, anchorCanons: canons), "\(word)")
        }
    }
}

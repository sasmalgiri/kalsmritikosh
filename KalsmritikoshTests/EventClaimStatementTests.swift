//
//  EventClaimStatementTests.swift
//  KalsmritikoshTests
//
//  PA-EXT-001A — deterministic, evidence-aware Event Claim statements. Two layers:
//   • Pure renderer unit tests (EventClaimStatementRenderer): the statement rules, honesty
//     guarantees (no invented email role, no fabricated topic), and length cap.
//   • Producer integration tests (claim-producer-3): projection hydrates attributes + narrative
//     slots + participant labels; subjectLabel is the participant's entity label (not the event
//     title); exact Event block evidence is preferred over object-only; Claim ids stay stable and
//     reviews / usage / createdAt survive reprojection; participant-less events still project.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-EXT-001A — Event Claim statements")
struct EventClaimStatementTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Pure renderer helpers

    private func who(_ text: String, entity: UUID? = nil) -> NarrativeSlotValue {
        NarrativeSlotValue(text: text, confidence: 0.95, provenance: .structuredHeader, entityID: entity)
    }
    private func headerWhat(_ text: String) -> NarrativeSlotValue {
        NarrativeSlotValue(text: text, confidence: 0.95, provenance: .structuredHeader)
    }
    private func emailEvent(title: String, blocks: [UUID] = []) -> Event {
        var attrs: [String: AnyCodable] = [:]
        if !blocks.isEmpty { attrs["sourceBlockIDs"] = AnyCodable(.array(blocks.map { .string($0.uuidString) })) }
        return Event(kind: .emailReceived, date: t0, title: title, entityIDs: [],
                     sourceObjectID: UUID(), attributes: attrs, status: .asserted)
    }
    private func participant(_ label: String) -> EventClaimParticipant {
        EventClaimParticipant(entityID: UUID(), displayLabel: label, kind: .person)
    }

    // MARK: - Email statements

    @Test("An email with From/To/Subject renders a rich statement naming participants + topic")
    func richEmailStatement() {
        let slots = EventNarrativeSlots(
            who: [who("Alexandra Rivera <a@x.com>"), who("Ravi Sen <r@y.com>")],
            what: [headerWhat("Revised supply agreement")])
        let s = EventClaimStatementRenderer.render(
            event: emailEvent(title: "Revised supply agreement"),
            narrativeSlots: slots, participant: participant("Alexandra Rivera"))
        #expect(s.text == "Email correspondence involving Alexandra Rivera and Ravi Sen about “Revised supply agreement”.")
        #expect(s.subjectLabel == "Alexandra Rivera")            // participant label, not the title
        #expect(s.text != "Email")
    }

    @Test("An email with no subject but known participants never renders bare \"Email\"")
    func emailNoSubjectNamesParticipants() {
        let slots = EventNarrativeSlots(who: [who("Alexandra Rivera <a@x.com>"), who("Ravi Sen <r@y.com>")])
        let s = EventClaimStatementRenderer.render(
            event: emailEvent(title: "Email"), narrativeSlots: slots, participant: participant("Ravi Sen"))
        #expect(s.text == "Email correspondence involving Alexandra Rivera and Ravi Sen.")
        #expect(s.text != "Email")
        #expect(!s.text.contains("about"))                       // no fabricated topic
    }

    @Test("No email participant role is ever invented (never \"X emailed Y\" / \"sent by\")")
    func noRoleInvented() {
        let slots = EventNarrativeSlots(
            who: [who("Alexandra Rivera <a@x.com>"), who("Ravi Sen <r@y.com>")],
            what: [headerWhat("Revised supply agreement")])
        let s = EventClaimStatementRenderer.render(
            event: emailEvent(title: "Revised supply agreement"), narrativeSlots: slots, participant: nil)
        let lower = s.text.lowercased()
        #expect(!lower.contains("emailed"))
        #expect(!lower.contains("sent by"))
        #expect(!lower.contains("sent to"))
        #expect(!lower.contains(" from "))
    }

    @Test("An email with neither topic nor participants falls back to a neutral correspondence line")
    func emailNeither() {
        let s = EventClaimStatementRenderer.render(
            event: emailEvent(title: "Email"), narrativeSlots: .empty, participant: nil)
        #expect(s.text == "Email correspondence recorded in the source.")
    }

    @Test("Re:/Fwd: prefixes are trimmed for the topic while the meaningful subject is preserved")
    func replyPrefixesTrimmed() {
        let slots = EventNarrativeSlots(who: [who("A <a@x>")], what: [headerWhat("Re: Revised agreement")])
        let s = EventClaimStatementRenderer.render(
            event: emailEvent(title: "Re: Revised agreement"), narrativeSlots: slots, participant: participant("A"))
        #expect(s.text.contains("“Revised agreement”"))
        #expect(!s.text.contains("Re:"))
    }

    // MARK: - Domain events (only-when-persisted)

    @Test("A signatory renders only when the attribute is persisted")
    func signatoryOnlyWhenPersisted() {
        var signed = Event(kind: .contractSigned, date: t0, title: "Contract signed",
                           sourceObjectID: UUID(), status: .asserted)
        #expect(!EventClaimStatementRenderer.render(event: signed, narrativeSlots: .empty, participant: nil).text.contains("by "))
        signed = signed.addingAttributes(["signatory": AnyCodable(.string("Alice Martin"))])
        #expect(EventClaimStatementRenderer.render(event: signed, narrativeSlots: .empty, participant: nil).text
                == "Contract signed by Alice Martin.")
    }

    @Test("An invoice amount renders as a grouped currency phrase only when persisted")
    func invoiceAmount() {
        let event = Event(kind: .invoicePaid, date: t0, title: "Invoice paid", sourceObjectID: UUID(),
                          attributes: ["amount": AnyCodable(.double(3800)), "currency": AnyCodable(.string("INR"))],
                          status: .asserted)
        #expect(EventClaimStatementRenderer.render(event: event, narrativeSlots: .empty, participant: nil).text
                == "Invoice paid: INR 3,800.")
    }

    @Test("Meeting location, delivery reason and task commitment render from persisted attributes/slots")
    func domainDetails() {
        let meeting = Event(kind: .meetingHeld, date: t0, title: "Meeting held", sourceObjectID: UUID(),
                            attributes: ["location": AnyCodable(.string("Kolkata office"))], status: .asserted)
        #expect(EventClaimStatementRenderer.render(event: meeting, narrativeSlots: .empty, participant: nil).text
                == "Meeting held at Kolkata office.")

        let delayed = Event(kind: .deliveryDelayed, date: t0, title: "Delivery delayed",
                            summary: "a shipment delay", sourceObjectID: UUID(), status: .asserted)
        #expect(EventClaimStatementRenderer.render(event: delayed, narrativeSlots: .empty, participant: nil).text
                == "Delivery was delayed because of a shipment delay.")

        let task = Event(kind: .taskAssigned, date: t0, title: "Task assigned",
                         summary: "send the revised draft", sourceObjectID: UUID(), status: .asserted)
        #expect(EventClaimStatementRenderer.render(event: task, narrativeSlots: .empty, participant: nil).text
                == "A commitment was recorded to send the revised draft.")
    }

    // MARK: - Evidence + cap

    @Test("Preferred block ids are read from the event's persisted sourceBlockIDs attribute")
    func preferredBlockIDsRead() {
        let b1 = UUID(), b2 = UUID()
        let s = EventClaimStatementRenderer.render(
            event: emailEvent(title: "Subject", blocks: [b1, b2]), narrativeSlots: .empty, participant: nil)
        #expect(s.preferredBlockIDs == [b1, b2])
    }

    @Test("A very long statement is capped deterministically with an ellipsis")
    func lengthCap() {
        // A long non-email title becomes the statement verbatim, so the STATEMENT-level cap fires.
        let longTitle = String(repeating: "word ", count: 200)
        let event = Event(kind: .other, date: t0, title: longTitle, sourceObjectID: UUID(), status: .asserted)
        let s = EventClaimStatementRenderer.render(event: event, narrativeSlots: .empty, participant: nil)
        #expect(s.text.count <= EventClaimStatementRenderer.maxStatementLength + 1)   // + the ellipsis char
        #expect(s.text.hasSuffix("…"))
    }

    // MARK: - Producer integration rig

    private struct Rig {
        let db: Database
        let events: EventsRepository
        let claims: ClaimRepository
        let producer: ClaimProducer
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("evc-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let events = EventsRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let producer = ClaimProducer(
            genericFacts: GenericFactRepository(database: db), assertions: AssertionsRepository(database: db),
            temporalClaims: TemporalClaimRepository(database: db), events: events, claims: claims, evidence: store)
        return Rig(db: db, events: events, claims: claims, producer: producer)
    }

    private func seedFileKO(_ r: Rig) async throws -> (file: UUID, ko: UUID) {
        let f = UUID(), ko = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(f), .text("file://\(f)"), .text("eml")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(ko), .uuid(f), .text("eml"), .text("c"), .real(0), .real(0)])
        return (f, ko)
    }

    private func seedEntity(_ r: Rig, id: UUID, value: String, ko: UUID) async throws {
        try await r.db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);",
                            [.uuid(id), .text("person"), .text(value), .text(id.uuidString.lowercased()), .uuid(ko)])
    }

    @discardableResult
    private func seedReopenableBlock(_ r: Rig, file: UUID, ko: UUID) async throws -> UUID {
        let sv = UUID(), block = UUID(), doc = UUID()
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(sv), .uuid(file), .uuid(doc), .text("h"), .real(0), .real(0)])
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(block), .uuid(doc), .uuid(sv), .integer(0), .text("text"), .text("t"), .text("t"), .text("test"), .real(1.0)])
        try await r.db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);
        """, [.uuid(block), .uuid(ko), .real(0)])
        return block
    }

    /// Insert an email event with its WHO/WHAT narrative slots populated the way ingestion would:
    /// each WHO carries the participant's header display name (as `"Name <addr>"`), the WHAT carries
    /// the subject — both structured-header provenance.
    private func insertEmailEvent(_ r: Rig, id: UUID = UUID(), ko: UUID, participants: [(id: UUID, label: String)],
                                  subject: String, blocks: [UUID] = []) async throws -> UUID {
        var attrs: [String: AnyCodable] = [:]
        if !blocks.isEmpty { attrs["sourceBlockIDs"] = AnyCodable(.array(blocks.map { .string($0.uuidString) })) }
        let e = Event(id: id, kind: .emailReceived, date: t0, title: subject, entityIDs: participants.map(\.id),
                      sourceObjectID: ko, confidence: .high, attributes: attrs, status: .asserted)
        try await r.events.insertBatch([e])
        var slots = EventNarrativeSlots.empty
        for p in participants {
            slots.add(NarrativeSlotValue(text: "\(p.label) <\(p.id.uuidString.prefix(6))@x.com>", confidence: 0.95,
                                         provenance: .structuredHeader, entityID: p.id), to: .who)
        }
        slots.add(NarrativeSlotValue(text: subject, confidence: 0.95, provenance: .structuredHeader), to: .what)
        try await r.events.setNarrativeSlots(slots, forEventID: id)
        return id
    }

    // MARK: - Integration tests

    @Test("Projection hydrates attributes, slots and participant labels into a rich Claim statement")
    func projectionHydratesRichStatement() async throws {
        let r = try await rig()
        let (file, ko) = try await seedFileKO(r)
        let block = try await seedReopenableBlock(r, file: file, ko: ko)
        let alice = UUID(), ravi = UUID()
        try await seedEntity(r, id: alice, value: "Alexandra Rivera", ko: ko)
        try await seedEntity(r, id: ravi, value: "Ravi Sen", ko: ko)
        _ = try await insertEmailEvent(r, ko: ko, participants: [(alice, "Alexandra Rivera"), (ravi, "Ravi Sen")],
                                       subject: "Revised supply agreement", blocks: [block])
        _ = try await r.producer.backfill(at: t0)

        let claim = try #require(try await r.claims.claims(subjectID: alice).first)
        #expect(claim.statement.contains("Alexandra Rivera"))
        #expect(claim.statement.contains("Ravi Sen"))
        #expect(claim.statement.contains("“Revised supply agreement”"))
        #expect(claim.statement != "Revised supply agreement")   // not the bare event title
        #expect(claim.subjectLabel == "Alexandra Rivera")        // participant entity label, not the title
    }

    @Test("An email with no subject but known participants never projects the bare word \"Email\"")
    func emailNoSubjectNotBare() async throws {
        let r = try await rig()
        let (_, ko) = try await seedFileKO(r)
        let a = UUID()
        try await seedEntity(r, id: a, value: "Alexandra Rivera", ko: ko)
        _ = try await insertEmailEvent(r, ko: ko, participants: [(a, "Alexandra Rivera")], subject: "Email")
        _ = try await r.producer.backfill(at: t0)
        let claim = try #require(try await r.claims.claims(subjectID: a).first)
        #expect(claim.statement != "Email")
        #expect(claim.statement.contains("Alexandra Rivera"))
    }

    @Test("Exact Event block evidence is preferred over object-only evidence")
    func exactBlockPreferred() async throws {
        let r = try await rig()
        let (file, ko) = try await seedFileKO(r)
        let block = try await seedReopenableBlock(r, file: file, ko: ko)
        let a = UUID()
        try await seedEntity(r, id: a, value: "Alice", ko: ko)
        _ = try await insertEmailEvent(r, ko: ko, participants: [(a, "Alice")], subject: "Subject", blocks: [block])
        _ = try await r.producer.backfill(at: t0)
        let claim = try #require(try await r.claims.claims(subjectID: a).first)
        #expect(claim.evidence.contains { $0.blockID == block })   // exact block, not object-only
    }

    @Test("A missing/ambiguous block falls back conservatively to object-level evidence")
    func ambiguousBlockFallsBack() async throws {
        let r = try await rig()
        let (file, ko) = try await seedFileKO(r)
        _ = try await seedReopenableBlock(r, file: file, ko: ko)   // makes the object reopenable
        let a = UUID()
        try await seedEntity(r, id: a, value: "Alice", ko: ko)
        // Reference a block id that has NO evidence_block_objects link → unresolved → drop it.
        _ = try await insertEmailEvent(r, ko: ko, participants: [(a, "Alice")], subject: "Subject", blocks: [UUID()])
        _ = try await r.producer.backfill(at: t0)
        let claim = try #require(try await r.claims.claims(subjectID: a).first)
        #expect(!claim.evidence.isEmpty)                            // still produced …
        #expect(claim.evidence.allSatisfy { $0.blockID == nil })    // … via object-level fallback
    }

    @Test("Event Claim ids remain stable (the event|eventID|participantID fingerprint is unchanged)")
    func claimIDsStable() async throws {
        let r = try await rig()
        let (_, ko) = try await seedFileKO(r)
        let a = UUID()
        try await seedEntity(r, id: a, value: "Alice", ko: ko)
        let eventID = try await insertEmailEvent(r, ko: ko, participants: [(a, "Alice")], subject: "Subject")
        _ = try await r.producer.backfill(at: t0)
        let claim = try #require(try await r.claims.claims(subjectID: a).first)
        #expect(claim.id == ClaimProducer.claimID(kind: "event", sourceID: eventID, subjectID: a))
    }

    @Test("Reviews, usage and createdAt survive a producer-v3 reprojection")
    func reprojectionPreservesReviewUsageCreatedAt() async throws {
        let r = try await rig()
        let (_, ko) = try await seedFileKO(r)
        let a = UUID()
        try await seedEntity(r, id: a, value: "Alice", ko: ko)
        _ = try await insertEmailEvent(r, ko: ko, participants: [(a, "Alice")], subject: "Subject")
        _ = try await r.producer.backfill(at: t0)
        let id = try #require(try await r.claims.claims(subjectID: a).first).id
        let reviews = ClaimReviewRepository(database: r.db), usage = ClaimUsageRepository(database: r.db)
        try await reviews.record(ClaimReview(claimID: id, disposition: .confirmed, reviewer: "u", reviewedAt: t0))
        try await usage.record(ClaimUsage(claimID: id, context: .workProduct, usedAt: t0))

        _ = try await r.producer.backfill(at: t0.addingTimeInterval(999))   // reproject later
        #expect(try await reviews.currentDisposition(claimID: id) == .confirmed)
        #expect(try await usage.usageCount(claimID: id) == 1)
        #expect(try await r.claims.claim(id: id)?.createdAt == t0)          // original createdAt preserved
    }

    @Test("A participant-less event still projects a source-scoped Claim")
    func participantlessSourceScoped() async throws {
        let r = try await rig()
        let (file, ko) = try await seedFileKO(r)
        let block = try await seedReopenableBlock(r, file: file, ko: ko)
        _ = try await insertEmailEvent(r, ko: ko, participants: [], subject: "Standalone", blocks: [block])
        _ = try await r.producer.backfill(at: t0)
        let scoped = try await r.claims.claims(inKnowledgeObjectScopes: [ko])
        let claim = try #require(scoped.first)
        #expect(claim.subjectID == nil)
        #expect(claim.scope == .knowledgeObject(ko))
        #expect(claim.statement.contains("Standalone"))
    }
}

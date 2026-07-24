//
//  ClaimProducer.swift
//  Kalsmritikosh
//
//  PA-PROD — the deterministic, LLM-FREE producer that projects existing ledger objects
//  (GenericFact, TemporalClaim, Event, Assertion) into canonical Claims with REOPENABLE
//  evidence. This is the missing production path that lets the persona-v2 registry composers
//  see real data.
//
//  Guarantees:
//   • Deterministic: no model is consulted; the same ledger produces the same Claims.
//   • Reopenable evidence only: every EvidenceReference resolves to a source-version id (via
//     EvidenceStore) — a reference that cannot reopen its exact source is dropped, never
//     fabricated.
//   • Idempotent: a Claim's id is a canonical fingerprint (SHA-256 of source-kind | source-id
//     | subject), so re-producing UPDATES the same row (INSERT OR REPLACE) instead of
//     duplicating it.
//   • Subject identity preserved from the source object; workspace membership is NOT set here
//     (that is WorkspaceMembershipDeriver, through the membership layer).
//   • Failure-isolated: one bad source object is logged and skipped; the batch continues.
//

import Foundation
import CryptoKit
import os

/// Why a single source object was skipped (vs an infrastructure failure, which THROWS).
public enum ClaimProjectionSkipReason: String, Sendable, Equatable {
    case malformedSource      // the source cannot form a usable claim (e.g. empty field/value)
    case unsupportedSource    // a source kind the producer does not (yet) project
}

/// The explicit result boundary the durable coordinator needs: `produced`/`skipped` are safe
/// to advance the cursor past; an INFRASTRUCTURE failure (db / evidence-store / query) is a
/// thrown error instead — the coordinator must NOT advance on a throw, or it could mark a
/// source complete without persisting its Claims.
public enum ClaimProjectionOutcome: Sendable, Equatable {
    case produced(Int)
    case skipped(ClaimProjectionSkipReason)
}

public actor ClaimProducer {
    // v2 (PA-DOC-001): claims now carry an explicit scope (entity | knowledgeObject) and a
    // source-scoped fallback is produced for subject-less facts. Bumping the version makes the
    // durable backfill run a fresh pass that re-saves every claim with its scope populated
    // (same fingerprint id → UPSERT in place; reviews/usage preserved).
    public nonisolated static let producerVersion = "claim-producer-2"

    private let genericFacts: GenericFactRepository
    private let assertions: AssertionsRepository
    private let temporalClaims: TemporalClaimRepository
    private let events: EventsRepository
    private let claims: ClaimRepository
    private let evidence: EvidenceStore

    public init(genericFacts: GenericFactRepository, assertions: AssertionsRepository,
                temporalClaims: TemporalClaimRepository, events: EventsRepository,
                claims: ClaimRepository, evidence: EvidenceStore) {
        self.genericFacts = genericFacts; self.assertions = assertions
        self.temporalClaims = temporalClaims; self.events = events
        self.claims = claims; self.evidence = evidence
    }

    // MARK: - Backfill (all source types, paged, failure-isolated)

    /// Produce Claims for the entire existing ledger. Returns the number of Claims written.
    /// Idempotent: re-running updates the same Claims rather than duplicating them.
    @discardableResult
    public func backfill(at now: Date) async throws -> Int {
        var produced = 0
        produced += try await pageThrough { try await self.genericFacts.all(offset: $0, pageSize: 500) } each: { f in
            await self.persist(kind: "genericFact", sourceID: f.id) { try await self.claim(from: f, at: now) }
        }
        produced += try await pageThrough { try await self.temporalClaims.allClaims(offset: $0, pageSize: 500) } each: { t in
            await self.persist(kind: "temporalClaim", sourceID: t.id) { try await self.claim(from: t, at: now) }
        }
        produced += try await pageThrough { try await self.assertions.all(offset: $0, pageSize: 500) } each: { a in
            await self.persist(kind: "assertion", sourceID: a.id) { try await self.claim(from: a, at: now) }
        }
        produced += try await pageThrough { try await self.events.allWithParticipants(offset: $0, pageSize: 500) } each: { pair in
            var n = 0
            let built = (try? await self.claims(from: pair.0, participants: pair.1, at: now)) ?? []
            for c in built { n += await self.persist(kind: "event", sourceID: pair.0.id) { c } }
            return n
        }
        return produced
    }

    /// Incremental production for a single subject's claim-bearing objects (used by the ingest
    /// hook in Commit B). Deterministic + idempotent, same as backfill.
    @discardableResult
    public func produce(forSubjectID subjectID: Entity.ID, at now: Date) async throws -> Int {
        var produced = 0
        for f in try await genericFacts.facts(subjectID: subjectID) {
            produced += await persist(kind: "genericFact", sourceID: f.id) { try await self.claim(from: f, at: now) }
        }
        var off = 0
        while true {
            let batch = try await temporalClaims.claims(subjectID: subjectID, offset: off, pageSize: 500)
            if batch.isEmpty { break }
            for t in batch { produced += await persist(kind: "temporalClaim", sourceID: t.id) { try await self.claim(from: t, at: now) } }
            if batch.count < 500 { break }; off += 500
        }
        off = 0
        while true {
            let batch = try await assertions.assertions(subjectKind: .entity, subjectID: subjectID, offset: off, pageSize: 500)
            if batch.isEmpty { break }
            for a in batch { produced += await persist(kind: "assertion", sourceID: a.id) { try await self.claim(from: a, at: now) } }
            if batch.count < 500 { break }; off += 500
        }
        off = 0
        while true {
            let batch = try await events.allForEntity(subjectID, offset: off, pageSize: 500)
            if batch.isEmpty { break }
            for e in batch {
                let built = (try? await self.claims(from: e, participants: [subjectID], at: now)) ?? []
                for c in built { produced += await persist(kind: "event", sourceID: e.id) { c } }
            }
            if batch.count < 500 { break }; off += 500
        }
        return produced
    }

    // MARK: - Durable-projection boundary (one source → produced / skipped; infra errors THROW)

    public func project(genericFact f: GenericFact, at now: Date) async throws -> ClaimProjectionOutcome {
        guard !f.field.isEmpty, !f.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .skipped(.malformedSource) }
        // A subject-less fact with no single owning source is skipped conservatively (no scope).
        guard let c = try await claim(from: f, at: now) else { return .skipped(.unsupportedSource) }
        try await store(c, kind: "genericFact", sourceID: f.id)
        return .produced(1)
    }

    public func project(temporalClaim tc: TemporalClaim, at now: Date) async throws -> ClaimProjectionOutcome {
        guard !tc.predicate.isEmpty else { return .skipped(.malformedSource) }
        guard let c = try await claim(from: tc, at: now) else { return .skipped(.unsupportedSource) }
        try await store(c, kind: "temporalClaim", sourceID: tc.id)
        return .produced(1)
    }

    public func project(assertion a: Assertion, at now: Date) async throws -> ClaimProjectionOutcome {
        guard !a.predicate.isEmpty else { return .skipped(.malformedSource) }
        guard let c = try await claim(from: a, at: now) else { return .skipped(.unsupportedSource) }
        try await store(c, kind: "assertion", sourceID: a.id)
        return .produced(1)
    }

    /// Advance the event cursor only after EVERY participant claim has been persisted.
    public func project(event e: Event, participants: [Entity.ID], at now: Date) async throws -> ClaimProjectionOutcome {
        guard !e.title.isEmpty else { return .skipped(.malformedSource) }
        let built = try await claims(from: e, participants: participants, at: now)
        guard !built.isEmpty else { return .skipped(.unsupportedSource) }
        for c in built { try await store(c, kind: "event", sourceID: e.id) }
        return .produced(built.count)
    }

    // MARK: - Paging + failure isolation

    private func pageThrough<Element>(_ page: (Int) async throws -> [Element],
                                      each: (Element) async -> Int) async throws -> Int {
        var produced = 0
        var offset = 0
        let size = 500
        while true {
            let batch = try await page(offset)
            if batch.isEmpty { break }
            for element in batch { produced += await each(element) }
            if batch.count < size { break }
            offset += size
        }
        return produced
    }

    /// Save a claim and, when it is ENTITY-scoped, SUPERSEDE any source-scoped fallback for the
    /// SAME source object (the (kind, sourceID, nil-subject) fingerprint) so a fact that later
    /// gains an entity subject never leaves both a source-scoped and an entity-scoped copy active.
    private func store(_ claim: Claim, kind: String, sourceID: UUID) async throws {
        try await claims.save(claim)
        if case .entity = claim.scope {
            let sibling = Self.claimID(kind: kind, sourceID: sourceID, subjectID: nil)
            if sibling != claim.id { try await claims.deleteClaim(id: sibling) }
        }
    }

    /// Save one Claim (with supersede), isolating any per-object failure (logged, skipped).
    private func persist(kind: String, sourceID: UUID, _ make: () async throws -> Claim?) async -> Int {
        do {
            guard let claim = try await make() else { return 0 }
            try await store(claim, kind: kind, sourceID: sourceID)
            return 1
        } catch {
            KalsmritikoshLog.storage.error("Claim production skipped one source object: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    // MARK: - Deterministic fingerprint id

    /// A stable Claim id per (source kind, source id, subject). Re-production yields the same
    /// id → the row is updated in place, never duplicated.
    nonisolated static func claimID(kind: String, sourceID: UUID, subjectID: Entity.ID?) -> UUID {
        let fingerprint = "kalsmritikosh.claim.v1|\(kind)|\(sourceID.uuidString)|\(subjectID?.uuidString ?? "-")"
        let d = Array(SHA256.hash(data: Data(fingerprint.utf8)).prefix(16))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    // MARK: - Reopenable evidence resolution

    /// Build EvidenceReferences that can REOPEN their exact source, each carrying a CANONICAL
    /// KnowledgeObject id (PA-PROD B6). Block-derived refs resolve the block's real KnowledgeObject
    /// owner + reopenable version via EvidenceStore; unresolved/ambiguous blocks are dropped.
    /// Object-only refs are accepted only when the object id is a REAL `knowledge_objects` row whose
    /// current source version resolves. A `logical_source_id` (file id) is NEVER stored as objectID.
    private func reopenableRefs(blockIDs: [EvidenceBlock.ID], objectIDs: [KnowledgeObject.ID],
                                assertionID: Assertion.ID? = nil, genericFactID: GenericFact.ID? = nil,
                                eventID: Event.ID? = nil) async throws -> [EvidenceReference] {
        var refs: [EvidenceReference] = []
        var coveredObjects: Set<KnowledgeObject.ID> = []
        if !blockIDs.isEmpty {
            for resolution in try await evidence.resolveCanonicalBlocks(blockIDs) {
                guard case .resolved(let rb) = resolution else { continue }  // drop unresolved/ambiguous
                refs.append(EvidenceReference(objectID: rb.knowledgeObjectID, blockID: rb.blockID,
                                              assertionID: assertionID, genericFactID: genericFactID,
                                              eventID: eventID, sourceVersionID: rb.sourceVersionID, role: .supports))
                coveredObjects.insert(rb.knowledgeObjectID)
            }
        }
        for obj in objectIDs where !coveredObjects.contains(obj) {
            // The object id must be a genuine KnowledgeObject AND resolve to a reopenable version
            // via its file — otherwise skip conservatively (never store a file id).
            guard try await evidence.knowledgeObjectExists(obj),
                  let sv = try await evidence.currentVersionID(forObject: obj) else { continue }
            refs.append(EvidenceReference(objectID: obj, blockID: nil, assertionID: assertionID,
                                          genericFactID: genericFactID, eventID: eventID,
                                          sourceVersionID: sv, role: .supports))
        }
        return refs
    }

    // MARK: - Scope (PA-DOC-001)

    /// The explicit scope for a projected claim: entity when a persisted subject exists; otherwise
    /// the SOURCE-scoped fallback anchored to the single owning KnowledgeObject of its evidence.
    /// A subject-less fact backed by zero or MORE-THAN-ONE distinct objects has no unambiguous
    /// source anchor → `nil` (the caller skips it conservatively; nothing is guessed).
    private nonisolated static func scope(subjectID: Entity.ID?, evidence refs: [EvidenceReference]) -> ClaimScope? {
        if let s = subjectID { return .entity(s) }
        let objects = Set(refs.map(\.objectID))
        return objects.count == 1 ? .knowledgeObject(objects.first!) : nil
    }

    // MARK: - Source projections

    private func claim(from fact: GenericFact, at now: Date) async throws -> Claim? {
        let refs = try await reopenableRefs(blockIDs: fact.sourceBlockIDs, objectIDs: [], genericFactID: fact.id)
        guard let scope = Self.scope(subjectID: fact.subjectID, evidence: refs) else { return nil }
        let statement = fact.unit.map { "\(fact.field): \(fact.value) \($0)" } ?? "\(fact.field): \(fact.value)"
        return Claim(id: Self.claimID(kind: "genericFact", sourceID: fact.id, subjectID: fact.subjectID),
                     subjectID: fact.subjectID, subjectLabel: fact.subjectLabel, statement: statement,
                     assessment: fact.assessment, confidence: fact.confidence, evidence: refs,
                     derivedFrom: [DerivedReference(kind: .genericFact, id: fact.id)], scope: scope, createdAt: now)
    }

    private func claim(from tc: TemporalClaim, at now: Date) async throws -> Claim? {
        let refs = try await reopenableRefs(blockIDs: tc.sourceBlockIDs, objectIDs: tc.sourceObjectIDs)
        // TemporalClaims are always subject-scoped (subjectID is non-optional) → .entity.
        guard let scope = Self.scope(subjectID: tc.subjectID, evidence: refs) else { return nil }
        let statement = "\(tc.predicate.replacingOccurrences(of: "_", with: " ")) \(tc.object.displayText)"
        return Claim(id: Self.claimID(kind: "temporalClaim", sourceID: tc.id, subjectID: tc.subjectID),
                     subjectID: tc.subjectID, subjectLabel: tc.subjectID.uuidString, statement: statement,
                     assessment: tc.assessment, confidence: tc.confidence, evidence: refs,
                     derivedFrom: [DerivedReference(kind: .temporalClaim, id: tc.id)], scope: scope, createdAt: now)
    }

    private func claim(from a: Assertion, at now: Date) async throws -> Claim? {
        // Entity-subject assertions are entity-scoped; event/claim-subject ones fall back to a
        // single owning source object (or are skipped when the anchor is ambiguous).
        let subject: Entity.ID? = a.subjectKind == .entity ? a.subjectID : nil
        let refs = try await reopenableRefs(blockIDs: a.evidenceBlockIDs, objectIDs: a.evidenceObjectIDs, assertionID: a.id)
        guard let scope = Self.scope(subjectID: subject, evidence: refs) else { return nil }
        let objText: String
        switch a.object {
        case .literal(let s): objText = s
        case .entity(let id): objText = id.uuidString
        case .event(let id):  objText = id.uuidString
        }
        let statement = "\(a.predicate.replacingOccurrences(of: "_", with: " ")) \(objText)"
        return Claim(id: Self.claimID(kind: "assertion", sourceID: a.id, subjectID: subject),
                     subjectID: subject, subjectLabel: subject?.uuidString ?? a.predicate, statement: statement,
                     assessment: Self.assessment(forProvenance: a.provenance, agent: a.agent),
                     confidence: a.confidence, evidence: refs,
                     derivedFrom: [DerivedReference(kind: .assertion, id: a.id)], scope: scope, createdAt: now)
    }

    private func claims(from event: Event, participants: [Entity.ID], at now: Date) async throws -> [Claim] {
        let refs = try await reopenableRefs(blockIDs: [], objectIDs: [event.sourceObjectID], eventID: event.id)
        let assessment = Self.assessment(forEventStatus: event.status)
        // One claim per participant (entity-scoped); none → a single source-scoped claim anchored
        // to the event's owning object, or nothing when that object doesn't resolve.
        let subjects: [Entity.ID?] = participants.isEmpty ? [nil] : participants.map { $0 }
        return subjects.compactMap { subject -> Claim? in
            guard let scope = Self.scope(subjectID: subject, evidence: refs) else { return nil }
            return Claim(id: Self.claimID(kind: "event", sourceID: event.id, subjectID: subject),
                         subjectID: subject, subjectLabel: event.title, statement: event.title,
                         assessment: assessment, confidence: event.confidence.value, evidence: refs,
                         derivedFrom: [DerivedReference(kind: .event, id: event.id)], scope: scope, createdAt: now)
        }
    }

    // MARK: - Deterministic assessment mappings (no LLM)

    nonisolated static func assessment(forProvenance p: Assertion.Provenance, agent: String) -> EvidenceAssessment {
        let basis: EvidenceBasis
        switch p {
        case .sourceAsserted:           basis = .sourceAsserted
        case .directlyObserved:         basis = .directlyObserved
        case .deterministicallyDerived: basis = .deterministicallyDerived
        case .inferred:                 basis = .inferred
        }
        let origin: ProposalOrigin = agent == "user" ? .userCreated
            : (agent == "system.llm" ? .modelProposed : .sourceExtraction)
        return EvidenceAssessment(basis: basis, origin: origin)
    }

    nonisolated static func assessment(forEventStatus status: EventStatus) -> EvidenceAssessment {
        switch status {
        case .observed:     return EvidenceAssessment(basis: .directlyObserved, origin: .sourceExtraction)
        case .asserted:     return EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction)
        case .derived:      return EvidenceAssessment(basis: .deterministicallyDerived, origin: .deterministicRule)
        case .inferred:     return EvidenceAssessment(basis: .inferred, origin: .sourceExtraction)
        case .contradicted: return EvidenceAssessment(basis: .unknownLegacy, origin: .sourceExtraction, conflict: .contradicted)
        case .unsupported:  return EvidenceAssessment(basis: .unknownLegacy, origin: .sourceExtraction, availability: .unsupported)
        case .reviewed:     return EvidenceAssessment(basis: .unknownLegacy, review: .confirmed, origin: .sourceExtraction)
        case .rejected:     return EvidenceAssessment(basis: .unknownLegacy, review: .rejected, origin: .sourceExtraction)
        }
    }
}

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

public actor ClaimProducer {
    public nonisolated static let producerVersion = "claim-producer-1"

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
            await self.persist { try await self.claim(from: f, at: now) }
        }
        produced += try await pageThrough { try await self.temporalClaims.allClaims(offset: $0, pageSize: 500) } each: { t in
            await self.persist { try await self.claim(from: t, at: now) }
        }
        produced += try await pageThrough { try await self.assertions.all(offset: $0, pageSize: 500) } each: { a in
            await self.persist { try await self.claim(from: a, at: now) }
        }
        produced += try await pageThrough { try await self.events.allWithParticipants(offset: $0, pageSize: 500) } each: { pair in
            var n = 0
            let built = (try? await self.claims(from: pair.0, participants: pair.1, at: now)) ?? []
            for c in built { n += await self.persist { c } }
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
            produced += await persist { try await self.claim(from: f, at: now) }
        }
        var off = 0
        while true {
            let batch = try await temporalClaims.claims(subjectID: subjectID, offset: off, pageSize: 500)
            if batch.isEmpty { break }
            for t in batch { produced += await persist { try await self.claim(from: t, at: now) } }
            if batch.count < 500 { break }; off += 500
        }
        for a in try await assertions.assertions(subjectKind: .entity, subjectID: subjectID, limit: 1000) {
            produced += await persist { try await self.claim(from: a, at: now) }
        }
        off = 0
        while true {
            let batch = try await events.allForEntity(subjectID, offset: off, pageSize: 500)
            if batch.isEmpty { break }
            for e in batch {
                let built = (try? await self.claims(from: e, participants: [subjectID], at: now)) ?? []
                for c in built { produced += await persist { c } }
            }
            if batch.count < 500 { break }; off += 500
        }
        return produced
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

    /// Save one Claim, isolating any per-object failure (logged, skipped).
    private func persist(_ make: () async throws -> Claim?) async -> Int {
        do {
            guard let claim = try await make() else { return 0 }
            try await claims.save(claim)
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

    /// Build EvidenceReferences that can REOPEN their exact source. Blocks resolve via
    /// EvidenceStore (objectID + sourceVersionID + locator); object-only sources resolve to the
    /// current source version. Any reference without a source-version id is DROPPED.
    private func reopenableRefs(blockIDs: [EvidenceBlock.ID], objectIDs: [KnowledgeObject.ID],
                                assertionID: Assertion.ID? = nil, genericFactID: GenericFact.ID? = nil,
                                eventID: Event.ID? = nil) async throws -> [EvidenceReference] {
        var refs: [EvidenceReference] = []
        var coveredObjects: Set<KnowledgeObject.ID> = []
        if !blockIDs.isEmpty {
            for r in try await evidence.resolveEvidenceBlocks(blockIDs) {
                guard let sv = r.sourceVersionID else { continue }        // must reopen
                refs.append(EvidenceReference(objectID: r.objectID, blockID: r.blockID,
                                              assertionID: assertionID, genericFactID: genericFactID,
                                              eventID: eventID, sourceVersionID: sv, role: .supports))
                coveredObjects.insert(r.objectID)
            }
        }
        for obj in objectIDs where !coveredObjects.contains(obj) {
            guard let sv = try await evidence.currentVersionID(forLogicalSource: obj) else { continue }
            refs.append(EvidenceReference(objectID: obj, blockID: nil, assertionID: assertionID,
                                          genericFactID: genericFactID, eventID: eventID,
                                          sourceVersionID: sv, role: .supports))
        }
        return refs
    }

    // MARK: - Source projections

    private func claim(from fact: GenericFact, at now: Date) async throws -> Claim {
        let refs = try await reopenableRefs(blockIDs: fact.sourceBlockIDs, objectIDs: [], genericFactID: fact.id)
        let statement = fact.unit.map { "\(fact.field): \(fact.value) \($0)" } ?? "\(fact.field): \(fact.value)"
        return Claim(id: Self.claimID(kind: "genericFact", sourceID: fact.id, subjectID: fact.subjectID),
                     subjectID: fact.subjectID, subjectLabel: fact.subjectLabel, statement: statement,
                     assessment: fact.assessment, confidence: fact.confidence, evidence: refs,
                     derivedFrom: [DerivedReference(kind: .genericFact, id: fact.id)], createdAt: now)
    }

    private func claim(from tc: TemporalClaim, at now: Date) async throws -> Claim {
        let refs = try await reopenableRefs(blockIDs: tc.sourceBlockIDs, objectIDs: tc.sourceObjectIDs)
        let statement = "\(tc.predicate.replacingOccurrences(of: "_", with: " ")) \(tc.object.displayText)"
        return Claim(id: Self.claimID(kind: "temporalClaim", sourceID: tc.id, subjectID: tc.subjectID),
                     subjectID: tc.subjectID, subjectLabel: tc.subjectID.uuidString, statement: statement,
                     assessment: tc.assessment, confidence: tc.confidence, evidence: refs,
                     derivedFrom: [DerivedReference(kind: .temporalClaim, id: tc.id)], createdAt: now)
    }

    private func claim(from a: Assertion, at now: Date) async throws -> Claim {
        // Only entity-subject assertions are subject-scoped; event/claim-subject ones stay corpus-level.
        let subject: Entity.ID? = a.subjectKind == .entity ? a.subjectID : nil
        let refs = try await reopenableRefs(blockIDs: a.evidenceBlockIDs, objectIDs: a.evidenceObjectIDs, assertionID: a.id)
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
                     derivedFrom: [DerivedReference(kind: .assertion, id: a.id)], createdAt: now)
    }

    private func claims(from event: Event, participants: [Entity.ID], at now: Date) async throws -> [Claim] {
        let refs = try await reopenableRefs(blockIDs: [], objectIDs: [event.sourceObjectID], eventID: event.id)
        let assessment = Self.assessment(forEventStatus: event.status)
        // One claim per participant (distinct subjects, never duplicates); none → corpus-level.
        let subjects: [Entity.ID?] = participants.isEmpty ? [nil] : participants.map { $0 }
        return subjects.map { subject in
            Claim(id: Self.claimID(kind: "event", sourceID: event.id, subjectID: subject),
                  subjectID: subject, subjectLabel: event.title, statement: event.title,
                  assessment: assessment, confidence: event.confidence.value, evidence: refs,
                  derivedFrom: [DerivedReference(kind: .event, id: event.id)], createdAt: now)
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

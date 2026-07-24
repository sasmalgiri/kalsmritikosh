//
//  ClaimRepository.swift
//  Kalsmritikosh
//
//  PA-009 (persona-v2 Stage 1). Persistence for the shared Claim engine. Raw sqlite3 C-API
//  style, matching HistoryArtifactRepository. Four cohesive actors over the v63 tables:
//
//   • ClaimRepository            — claims (+ their evidence + lineage), written atomically.
//   • ClaimContradictionRepository — the claim ↔ Contradiction link table.
//   • ClaimReviewRepository      — append-only human review actions; current disposition.
//   • ClaimUsageRepository       — append-only usage ledger (which outputs used a claim).
//
//  Claims REFERENCE source truth by id; nothing here copies an Event/Assertion/GenericFact.
//  Trust is the canonical five-dimension EvidenceAssessment — never a forked EvidenceStatus.
//

import Foundation

public actor ClaimRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    // MARK: - Save (claim + evidence + lineage, ATOMIC per claim)

    /// Test-only seam: force a throw at a point inside the SAVEPOINT so the atomicity test
    /// can prove ROLLBACK leaves the prior claim + evidence + lineage unchanged.
    enum SaveFailurePoint: Sendable { case afterEvidence, afterLineage }
    struct InjectedSaveFailure: Error {}

    /// Persist a claim and (idempotently) its evidence + lineage as ONE atomic unit. The
    /// whole write runs inside a uniquely-named SAVEPOINT: on any failure it ROLLBACKs to
    /// the savepoint (undoing the claim upsert AND the child-row rewrite) and rethrows, so a
    /// partial claim can never be left behind.
    @discardableResult
    public func save(_ claim: Claim) async throws -> Claim.ID {
        try await performSave(claim, injectFailure: nil)
        return claim.id
    }

    /// Internal variant used only by the atomicity test.
    func save(_ claim: Claim, injectFailureAt point: SaveFailurePoint) async throws {
        try await performSave(claim, injectFailure: point)
    }

    private func performSave(_ claim: Claim, injectFailure: SaveFailurePoint?) async throws {
        // A per-claim savepoint name (valid identifier: letters + hex, no dashes).
        let savepoint = "claim_save_\(claim.id.uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            try await database.exec("SAVEPOINT \(savepoint);", [])

            let a = claim.assessment
            // True UPSERT: re-production UPDATES the row in place and PRESERVES created_at (the
            // original projection time), never rewriting it to the latest backfill time.
            try await database.exec("""
            INSERT INTO claims
                (id, subject_id, subject_label, statement, confidence, contradiction_group_id, created_at,
                 evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                subject_id             = excluded.subject_id,
                subject_label          = excluded.subject_label,
                statement              = excluded.statement,
                confidence             = excluded.confidence,
                contradiction_group_id = excluded.contradiction_group_id,
                evidence_basis         = excluded.evidence_basis,
                review_disposition     = excluded.review_disposition,
                proposal_origin        = excluded.proposal_origin,
                availability_status    = excluded.availability_status,
                conflict_status        = excluded.conflict_status,
                legacy_status          = excluded.legacy_status;
            """, [.uuid(claim.id),
                  claim.subjectID.map { SQLValue.uuid($0) } ?? .null,
                  .text(claim.subjectLabel), .text(claim.statement), .real(claim.confidence),
                  claim.contradictionGroupID.map { SQLValue.uuid($0) } ?? .null,
                  .real(claim.createdAt.timeIntervalSince1970),
                  .text(a.basis.rawValue), .text(a.review.rawValue), .text(a.origin.rawValue),
                  .text(a.availability.rawValue), .text(a.conflict.rawValue),
                  a.legacyStatus.map { SQLValue.text($0.rawValue) } ?? .null])

            // Evidence: rewrite with a stable ordinal identity so distinct references that
            // share object/block but differ in role or linked source ids all persist.
            try await database.exec("DELETE FROM claim_evidence_ref WHERE claim_id = ?;", [.uuid(claim.id)])
            for (ordinal, ev) in claim.evidence.enumerated() {
                try await database.exec("""
                INSERT INTO claim_evidence_ref
                    (claim_id, ordinal, knowledge_object_id, evidence_block_id, assertion_id,
                     generic_fact_id, event_id, source_version_id, evidence_role)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(claim.id), .integer(Int64(ordinal)), .uuid(ev.objectID),
                      ev.blockID.map { SQLValue.uuid($0) } ?? .null,
                      ev.assertionID.map { SQLValue.uuid($0) } ?? .null,
                      ev.genericFactID.map { SQLValue.uuid($0) } ?? .null,
                      ev.eventID.map { SQLValue.uuid($0) } ?? .null,
                      ev.sourceVersionID.map { SQLValue.uuid($0) } ?? .null,
                      .text(ev.role.rawValue)])
            }
            if injectFailure == .afterEvidence { throw InjectedSaveFailure() }

            try await database.exec("DELETE FROM claim_lineage WHERE claim_id = ?;", [.uuid(claim.id)])
            for ref in claim.derivedFrom {
                try await database.exec("""
                INSERT OR IGNORE INTO claim_lineage (claim_id, source_kind, source_id) VALUES (?,?,?);
                """, [.uuid(claim.id), .text(ref.kind.rawValue), .uuid(ref.id)])
            }
            if injectFailure == .afterLineage { throw InjectedSaveFailure() }

            try await database.exec("RELEASE SAVEPOINT \(savepoint);", [])
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);", [])
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);", [])
            throw error
        }
    }

    // MARK: - Load / query

    public func claim(id: Claim.ID) async throws -> Claim? {
        let rows = try await database.query("\(Self.claimColumns) WHERE id = ?;", [.uuid(id)])
        guard let base = rows.first.flatMap(Self.decodeClaimBase) else { return nil }
        return try await hydrate(base)
    }

    /// All claims about a subject, newest first. Scoping is by subject only — a claim carries
    /// no persona ownership, so this can never return another persona's claims.
    public func claims(subjectID: Entity.ID) async throws -> [Claim] {
        let rows = try await database.query(
            "\(Self.claimColumns) WHERE subject_id = ? ORDER BY created_at DESC;", [.uuid(subjectID)])
        return try await hydrateAll(rows)
    }

    public func claims(inContradictionGroup groupID: UUID) async throws -> [Claim] {
        let rows = try await database.query(
            "\(Self.claimColumns) WHERE contradiction_group_id = ? ORDER BY created_at DESC;", [.uuid(groupID)])
        return try await hydrateAll(rows)
    }

    public func count() async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM claims;", [])).first?.int(0) ?? 0)
    }

    // MARK: - Evidence reverse index (which claims cite a given source object)

    /// The ids of every claim whose evidence cites `objectID`. Lets a source change fan out
    /// to the affected claims (impact analysis) without duplicating evidence anywhere.
    public func claimIDs(citingObject objectID: KnowledgeObject.ID) async throws -> [Claim.ID] {
        let rows = try await database.query(
            "SELECT DISTINCT claim_id FROM claim_evidence_ref WHERE knowledge_object_id = ?;", [.uuid(objectID)])
        return rows.compactMap { $0.uuid(0) }
    }

    // MARK: - Hydration

    private func hydrateAll(_ rows: [SQLRow]) async throws -> [Claim] {
        var out: [Claim] = []
        for r in rows { if let base = Self.decodeClaimBase(r) { out.append(try await hydrate(base)) } }
        return out
    }

    private func hydrate(_ base: ClaimBase) async throws -> Claim {
        Claim(id: base.id, subjectID: base.subjectID, subjectLabel: base.subjectLabel,
              statement: base.statement, assessment: base.assessment, confidence: base.confidence,
              evidence: try await evidence(claimID: base.id),
              derivedFrom: try await lineage(claimID: base.id),
              contradictionGroupID: base.contradictionGroupID, createdAt: base.createdAt)
    }

    private func evidence(claimID: Claim.ID) async throws -> [EvidenceReference] {
        let rows = try await database.query("""
        SELECT knowledge_object_id, evidence_block_id, assertion_id, generic_fact_id,
               event_id, source_version_id, evidence_role
        FROM claim_evidence_ref WHERE claim_id = ? ORDER BY ordinal;
        """, [.uuid(claimID)])
        return rows.compactMap { r in
            guard let obj = r.uuid(0) else { return nil }
            let role = r.string(6).flatMap { EvidenceReference.Role(rawValue: $0) } ?? .supports
            return EvidenceReference(objectID: obj, blockID: r.uuid(1), assertionID: r.uuid(2),
                                     genericFactID: r.uuid(3), eventID: r.uuid(4),
                                     sourceVersionID: r.uuid(5), role: role)
        }
    }

    private func lineage(claimID: Claim.ID) async throws -> [DerivedReference] {
        let rows = try await database.query(
            "SELECT source_kind, source_id FROM claim_lineage WHERE claim_id = ?;", [.uuid(claimID)])
        return rows.compactMap { r in
            guard let kindRaw = r.string(0), let kind = DerivedReference.Kind(rawValue: kindRaw),
                  let sid = r.uuid(1) else { return nil }
            return DerivedReference(kind: kind, id: sid)
        }
    }

    // MARK: - Coding

    private struct ClaimBase {
        let id: UUID; let subjectID: UUID?; let subjectLabel: String; let statement: String
        let assessment: EvidenceAssessment; let confidence: Double
        let contradictionGroupID: UUID?; let createdAt: Date
    }

    private static let claimColumns = """
    SELECT id, subject_id, subject_label, statement, confidence, contradiction_group_id, created_at,
           evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status, legacy_status
    FROM claims
    """

    private nonisolated static func decodeClaimBase(_ r: SQLRow) -> ClaimBase? {
        guard let id = r.uuid(0), let label = r.string(2), let statement = r.string(3),
              let basis = r.string(7).flatMap(EvidenceBasis.init(rawValue:)),
              let review = r.string(8).flatMap(ReviewDisposition.init(rawValue:)),
              let origin = r.string(9).flatMap(ProposalOrigin.init(rawValue:)),
              let availability = r.string(10).flatMap(AvailabilityStatus.init(rawValue:)),
              let conflict = r.string(11).flatMap(ConflictStatus.init(rawValue:))
        else { return nil }
        let legacy = r.string(12).flatMap(EvidenceStatus.init(rawValue:))
        let assessment = EvidenceAssessment(basis: basis, review: review, origin: origin,
                                            availability: availability, conflict: conflict, legacyStatus: legacy)
        return ClaimBase(id: id, subjectID: r.uuid(1), subjectLabel: label, statement: statement,
                         assessment: assessment, confidence: r.double(4) ?? 0,
                         contradictionGroupID: r.uuid(5),
                         createdAt: Date(timeIntervalSince1970: r.double(6) ?? 0))
    }
}

// MARK: - Claim ↔ Contradiction links

public actor ClaimContradictionRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    public func link(claimID: Claim.ID, contradictionID: Contradiction.ID) async throws {
        try await database.exec(
            "INSERT OR IGNORE INTO claim_contradictions (claim_id, contradiction_id) VALUES (?,?);",
            [.uuid(claimID), .uuid(contradictionID)])
    }

    public func unlink(claimID: Claim.ID, contradictionID: Contradiction.ID) async throws {
        try await database.exec(
            "DELETE FROM claim_contradictions WHERE claim_id = ? AND contradiction_id = ?;",
            [.uuid(claimID), .uuid(contradictionID)])
    }

    public func contradictionIDs(claimID: Claim.ID) async throws -> [Contradiction.ID] {
        (try await database.query(
            "SELECT contradiction_id FROM claim_contradictions WHERE claim_id = ?;", [.uuid(claimID)]))
            .compactMap { $0.uuid(0) }
    }

    public func claimIDs(contradictionID: Contradiction.ID) async throws -> [Claim.ID] {
        (try await database.query(
            "SELECT claim_id FROM claim_contradictions WHERE contradiction_id = ?;", [.uuid(contradictionID)]))
            .compactMap { $0.uuid(0) }
    }
}

// MARK: - Append-only claim reviews

public actor ClaimReviewRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    @discardableResult
    public func record(_ review: ClaimReview) async throws -> ClaimReview.ID {
        try await database.exec("""
        INSERT INTO claim_reviews (id, claim_id, disposition, prior_value, new_value, reviewer, reason, reviewed_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(review.id), .uuid(review.claimID), .text(review.disposition.rawValue),
              review.priorValue.map { SQLValue.text($0) } ?? .null,
              review.newValue.map { SQLValue.text($0) } ?? .null,
              .text(review.reviewer),
              review.reason.map { SQLValue.text($0) } ?? .null,
              .real(review.reviewedAt.timeIntervalSince1970)])
        return review.id
    }

    /// The full append-only review history for a claim, newest first.
    public func reviews(claimID: Claim.ID) async throws -> [ClaimReview] {
        let rows = try await database.query("""
        SELECT id, claim_id, disposition, prior_value, new_value, reviewer, reason, reviewed_at
        FROM claim_reviews WHERE claim_id = ? ORDER BY reviewed_at DESC, rowid DESC;
        """, [.uuid(claimID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1),
                  let disp = r.string(2).flatMap(ReviewDisposition.init(rawValue:)),
                  let reviewer = r.string(5) else { return nil }
            return ClaimReview(id: id, claimID: cid, disposition: disp,
                               priorValue: r.string(3), newValue: r.string(4),
                               reviewer: reviewer, reason: r.string(6),
                               reviewedAt: Date(timeIntervalSince1970: r.double(7) ?? 0))
        }
    }

    /// The claim's CURRENT disposition — the latest recorded review, else `.unreviewed`.
    public func currentDisposition(claimID: Claim.ID) async throws -> ReviewDisposition {
        (try await database.query("""
        SELECT disposition FROM claim_reviews WHERE claim_id = ?
        ORDER BY reviewed_at DESC, rowid DESC LIMIT 1;
        """, [.uuid(claimID)]))
            .first?.string(0).flatMap(ReviewDisposition.init(rawValue:)) ?? .unreviewed
    }

    /// The latest recorded review for a claim, or `nil` when the claim has never been
    /// reviewed. Distinguishes "no review" from "reviewed as unreviewed" — the effective-
    /// assessment resolver needs that distinction (never-reviewed keeps the stored review).
    public func latestReview(claimID: Claim.ID) async throws -> ClaimReview? {
        try await reviews(claimID: claimID).first
    }
}

// MARK: - Effective (review-applied) claim resolution

/// A claim paired with its EFFECTIVE assessment: the stored assessment with its `review`
/// dimension replaced by the latest recorded `ClaimReview` disposition when one exists. All
/// Claim policy evaluation (composers, export) must use `effectiveAssessment` — never the
/// raw stored assessment — so a later rejection / correction / confirmation is honoured and
/// a stale claim re-save cannot silently erase it.
public struct ResolvedClaim: Sendable, Hashable {
    public let claim: Claim
    public let effectiveAssessment: EvidenceAssessment
    public nonisolated init(claim: Claim, effectiveAssessment: EvidenceAssessment) {
        self.claim = claim; self.effectiveAssessment = effectiveAssessment
    }
}

public actor ClaimResolver {
    private let claims: ClaimRepository
    private let reviews: ClaimReviewRepository
    public init(claims: ClaimRepository, reviews: ClaimReviewRepository) {
        self.claims = claims; self.reviews = reviews
    }

    /// Resolve a loaded claim to its effective assessment. Human review is applied to the
    /// `review` dimension ONLY — the evidence basis (and every other dimension) is preserved.
    public func resolve(_ claim: Claim) async throws -> ResolvedClaim {
        let latest = try await reviews.latestReview(claimID: claim.id)
        let effective = latest.map { claim.assessment.with(review: $0.disposition) } ?? claim.assessment
        return ResolvedClaim(claim: claim, effectiveAssessment: effective)
    }

    /// Load a claim by id and resolve it, or `nil` when the claim does not exist.
    public func resolve(id: Claim.ID) async throws -> ResolvedClaim? {
        guard let claim = try await claims.claim(id: id) else { return nil }
        return try await resolve(claim)
    }
}

// MARK: - Append-only claim usage ledger

public actor ClaimUsageRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    @discardableResult
    public func record(_ usage: ClaimUsage) async throws -> ClaimUsage.ID {
        try await database.exec("""
        INSERT INTO claim_usage (id, claim_id, context, reference_id, note, used_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(usage.id), .uuid(usage.claimID), .text(usage.context.rawValue),
              usage.referenceID.map { SQLValue.uuid($0) } ?? .null,
              usage.note.map { SQLValue.text($0) } ?? .null,
              .real(usage.usedAt.timeIntervalSince1970)])
        return usage.id
    }

    public func usage(claimID: Claim.ID) async throws -> [ClaimUsage] {
        let rows = try await database.query("""
        SELECT id, claim_id, context, reference_id, note, used_at
        FROM claim_usage WHERE claim_id = ? ORDER BY used_at DESC, rowid DESC;
        """, [.uuid(claimID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1),
                  let ctx = r.string(2).flatMap(ClaimUsageContext.init(rawValue:)) else { return nil }
            return ClaimUsage(id: id, claimID: cid, context: ctx, referenceID: r.uuid(3),
                              note: r.string(4), usedAt: Date(timeIntervalSince1970: r.double(5) ?? 0))
        }
    }

    public func usageCount(claimID: Claim.ID) async throws -> Int {
        Int((try await database.query(
            "SELECT COUNT(*) FROM claim_usage WHERE claim_id = ?;", [.uuid(claimID)])).first?.int(0) ?? 0)
    }
}

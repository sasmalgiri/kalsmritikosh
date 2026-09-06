//
//  DerivedProducerVersions.swift
//  Kalsmritikosh
//
//  V1 (v1.1 Stage 1) — the derived producers' declared versions, registered
//  in one place so the staleness predicate has a single authority.
//
//  THE TRAP THIS FILE DEFUSES (owner binding 2026-09-01): initial declared
//  versions are 0, and NULL ≡ 0 ≡ current — nothing in the archive reads as
//  stale until a LOGIC CHANGE bumps a version (V2's patent-pack capture
//  groups are the first). If these had started at 1 over a NULL archive, the
//  staleness predicate would have marked all sources stale on day one, the
//  honest "older rules" line would have invited a full drain that rewrites
//  the archive with UNCHANGED logic, and V5's one-rewrite discipline would
//  have broken before V2 opened. The "N sources processed with older rules —
//  refresh" line must be able to read ZERO the day it lands.
//
//  Staleness predicate (per table): COALESCE(producer_version, 0) != current.
//

public nonisolated enum DerivedProducerVersions {
    /// DomainFactExtractor + its packs (generic_facts.producer_version).
    /// Bump when extraction LOGIC changes what a stored fact would contain.
    ///   0→1 (V2): capture-group extraction — identifiers store the bare
    ///        normalized atom, dates store precision-aware ISO.
    ///   1→2 (V3 3c): the WRITER BINDING — an identifier fact now carries a
    ///        canonical subject (subjectID → its anchor entity). A v2 fact
    ///        contains the anchor link a v1 fact lacks, so the stored
    ///        representation changed and the era advances. The V5 drain rewrites
    ///        v1 rows to bind their subjects.
    /// v3 — W-4 (owner witness): the patent pack's prefix law + canon
    /// validity gate; the drain re-extracts every document's facts and the
    /// register re-mints its anchors. No re-ingest.
    /// v4 — A1.1: the role table (applicant/inventor extraction); the drain
    /// re-extracts and the register carries the roles. No re-ingest.
    public static let facts = 4

    /// Entity extraction + EntityQualityGate (entities.producer_version).
    /// First bump 0→1 (V3 3c): the gate hardening (3b) plus the new anchor
    /// entities — the entity population a v1 producer emits differs from v0
    /// (junk classes gated out; identifier anchors added), so the era advances.
    ///   1→2 (GO2R U0-b): email display names now come from the RFC 2822
    ///        address-list parser with edge punctuation stripped — a v1
    ///        producer emitted ", Akhilesh Sharma" and "'Arindam Das'" person
    ///        entities from To: lists (witnessed live on the owner's archive);
    ///        a v2 producer cannot. The targeted register refresh rewrites
    ///        v1 person values in place (strip + collision-merge, never
    ///        delete) and stamps them v2.
    public static let entities = 2

    /// Event extraction (events.producer_version).
    /// First bump 0→1 (V3 3c): milestone events now thread onto the identifier
    /// ANCHOR (backfillLegalMilestones passes anchor ids), so a v1 event's
    /// participant set can contain the anchor a v0 event never referenced. The
    /// V5 drain rebuilds milestones to apply the threading to the live archive.
    public static let events = 1
}

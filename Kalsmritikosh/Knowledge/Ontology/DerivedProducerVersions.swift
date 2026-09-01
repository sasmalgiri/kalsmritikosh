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

public enum DerivedProducerVersions {
    /// DomainFactExtractor + its packs (generic_facts.producer_version).
    /// Bump when extraction LOGIC changes what a stored fact would contain
    /// (first bump: V2 capture-group extraction).
    public static let facts = 0

    /// Entity extraction + EntityQualityGate (entities.producer_version).
    /// First bump: V3's gate hardening + anchor entities.
    public static let entities = 0

    /// Event extraction (events.producer_version).
    /// First bump: V4's class-gated event scoping.
    public static let events = 0
}

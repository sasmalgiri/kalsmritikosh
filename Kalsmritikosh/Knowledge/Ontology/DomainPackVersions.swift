//
//  DomainPackVersions.swift
//  Kalsmritikosh
//
//  Unified path IN-25 (owner 2026-11-22) — not tested yet.
//
//  C-2 — ONE version per domain rule pack. `DerivedProducerVersions.facts` is the producer-wide era:
//  bumping it re-derives EVERY document's facts. A pack's own version lets a change to (say) the
//  patent pack re-extract only the documents that hold facts the patent pack wrote at an older
//  version — the drain treats those documents as stale and leaves the rest alone.
//
//  Rule: bump a pack's number when its extraction LOGIC changes what a stored fact would contain.
//  Facts written before v201 carry no pack stamp (NULL) and are governed only by the producer era.
//

import Foundation

public nonisolated enum DomainPackVersions {

    /// The current version of each pack, keyed by its stable id (stored in generic_facts.pack_id).
    /// Unified path IN-27 (owner 2026-11-22, round 2) — not tested yet. Every pack at 2: C-7 value tidying and C-9 strict
    /// packs changed what each pack's stored fact holds.
    public static let current: [String: Int] = [
        "employment": 2, "transaction": 2, "contract": 2, "patent": 2, "research": 2,
        "medical": 2, "legalCase": 2, "vitalRecords": 2, "financialStatement": 2,
        "property": 2, "identityDocument": 2,
    ]

    /// The version a pack id is at now (0 for an id this build no longer knows — never stale-looping).
    public static func current(_ packID: String) -> Int { current[packID] ?? 0 }

    /// True when a fact was written by a known pack at an older (or newer) version than now.
    public static func isStale(packID: String?, packVersion: Int?) -> Bool {
        guard let packID, let now = current[packID] else { return false }
        return (packVersion ?? 0) != now
    }

    /// SQL predicate over generic_facts selecting rows a pack change made stale. Constants only
    /// (no user input), so it is safe to interpolate.
    public static var staleSQLPredicate: String {
        let clauses = current.keys.sorted().map { id in
            "(pack_id = '\(id)' AND COALESCE(pack_version, 0) != \(current[id] ?? 0))"
        }
        return "(" + clauses.joined(separator: " OR ") + ")"
    }

    static func id(of root: DomainFactExtractor.PackRoot) -> String {
        switch root {
        case .employment: return "employment"
        case .transaction: return "transaction"
        case .contract: return "contract"
        case .patent: return "patent"
        case .research: return "research"
        case .medical: return "medical"
        case .legalCase: return "legalCase"
        case .vitalRecords: return "vitalRecords"
        case .financialStatement: return "financialStatement"
        case .property: return "property"
        case .identityDocument: return "identityDocument"
        }
    }
}

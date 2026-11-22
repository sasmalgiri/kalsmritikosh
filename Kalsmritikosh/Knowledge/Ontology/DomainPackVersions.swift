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
    public static let current: [String: Int] = [
        "employment": 1, "transaction": 1, "contract": 1, "patent": 1, "research": 1,
        "medical": 1, "legalCase": 1, "vitalRecords": 1, "financialStatement": 1,
        "property": 1, "identityDocument": 1,
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

//
//  AlternativeAccounts.swift
//  Kalsmritikosh
//
//  REC-002 — when sources genuinely conflict on a fact, the reconstruction must present the
//  BALANCED alternative accounts (each version with its own evidence), unresolved — never
//  average them away or silently pick one. This composes CLM-003 (canonical comparison) so a
//  mere format difference is not treated as a conflict.
//
//  Deterministic, offline. Groups facts by subject+field; a field with >1 distinct canonical
//  value becomes an AlternativeAccount holding each version + its supporting evidence.
//

import Foundation

public struct AccountVersion: Sendable, Hashable {
    public let value: String
    public let sourceBlockIDs: [UUID]
    public let status: EvidenceStatus
}

public struct AlternativeAccount: Sendable, Hashable {
    public let subjectLabel: String
    public let field: String
    public let versions: [AccountVersion]   // >= 2 conflicting versions
    public var isUnresolved: Bool { versions.count >= 2 }
}

public struct AlternativeAccountsBuilder: Sendable {
    public nonisolated init() {}
    private let comparator = CanonicalFactComparator()

    /// Build alternative accounts for every subject+field with a genuine conflict.
    public nonisolated func build(from facts: [GenericFact]) -> [AlternativeAccount] {
        // Group by subject label + normalized field.
        var groups: [String: [GenericFact]] = [:]
        for f in facts {
            groups["\(f.subjectLabel.lowercased())|\(f.field)", default: []].append(f)
        }

        var accounts: [AlternativeAccount] = []
        for (_, group) in groups where group.count >= 2 {
            // Cluster by canonical equivalence — same canonical value = one version.
            var versions: [AccountVersion] = []
            var usedValues: [String] = []   // canonical keys already represented
            for fact in group {
                let isNew = !usedValues.contains { key in
                    // reuse comparator: two facts equivalent iff same subject+field+canonical
                    comparator.compare(fact, GenericFact(subjectLabel: fact.subjectLabel, field: fact.field,
                        value: key, status: fact.status, confidence: 1, sourceBlockIDs: [])) == .equivalent
                }
                if isNew {
                    usedValues.append(fact.value)
                    versions.append(AccountVersion(value: fact.value, sourceBlockIDs: fact.sourceBlockIDs, status: fact.status))
                } else if let idx = versions.firstIndex(where: {
                    comparator.compare(fact, GenericFact(subjectLabel: fact.subjectLabel, field: fact.field,
                        value: $0.value, status: fact.status, confidence: 1, sourceBlockIDs: [])) == .equivalent
                }) {
                    // Merge evidence into the existing version (corroboration, not a new account).
                    let merged = Array(Set(versions[idx].sourceBlockIDs + fact.sourceBlockIDs))
                    versions[idx] = AccountVersion(value: versions[idx].value, sourceBlockIDs: merged, status: versions[idx].status)
                }
            }
            if versions.count >= 2 {
                accounts.append(AlternativeAccount(subjectLabel: group[0].subjectLabel, field: group[0].field, versions: versions))
            }
        }
        return accounts
    }

    /// Render an account as a balanced, non-resolving statement.
    public nonisolated func render(_ account: AlternativeAccount) -> String {
        let lines = account.versions.enumerated().map { i, v in
            "  (\(i + 1)) \(v.value)  [\(v.sourceBlockIDs.count) source(s)]"
        }
        return "\(account.subjectLabel) — \(account.field): sources disagree (shown, not resolved):\n"
            + lines.joined(separator: "\n")
    }
}

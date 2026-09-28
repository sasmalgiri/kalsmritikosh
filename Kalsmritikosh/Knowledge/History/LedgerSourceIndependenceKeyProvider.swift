//
//  LedgerSourceIndependenceKeyProvider.swift
//  Kalsmritikosh
//
//  W-5.4 (implement-all U-2) — the CONCRETE independence-key provider,
//  wired into retrieval so corroboration finally collapses copies on the
//  live archive. The law extends HIST-035 to THREAD COPIES: Fwd/Re/quoted
//  copies of one message are ONE independent source — two intimation
//  emails of the same grant letter corroborate nothing by themselves.
//
//  Key preference per object:
//    1. email subject present  → "thread:" + the normalized subject
//       (fwd:/fw:/re: chains and routing tags stripped, lowercased,
//       whitespace collapsed) — every copy in a thread shares it;
//    2. else file content hash → "hash:" + hash (exact duplicates);
//    3. else nil — the object stays its own group (conservative).
//

import Foundation

public struct LedgerSourceIndependenceKeyProvider: SourceIndependenceKeyProvider {
    private let objects: KnowledgeObjectRepository

    public init(objects: KnowledgeObjectRepository) {
        self.objects = objects
    }

    public func keys(for objectIDs: Set<KnowledgeObject.ID>) async throws -> [KnowledgeObject.ID: String] {
        let identities = try await objects.independenceIdentities(for: objectIDs)
        var out: [KnowledgeObject.ID: String] = [:]
        for (id, identity) in identities {
            if let subject = identity.emailSubject {
                let normalized = Self.threadKey(subject: subject)
                if !normalized.isEmpty {
                    out[id] = "thread:" + normalized
                    continue
                }
            }
            if let hash = identity.contentHash, !hash.isEmpty {
                out[id] = "hash:" + hash
            }
            // No reliable identity → omit (own group), never guess.
        }
        return out
    }

    /// The thread key: the subject with routing prefixes stripped (same
    /// normalizer the event titles use), lowercased, inner whitespace
    /// collapsed. Pure — CI proves the intimation pair collapses.
    public nonisolated static func threadKey(subject: String) -> String {
        RuleEventExtractor.normalizeEventTitle(subject)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

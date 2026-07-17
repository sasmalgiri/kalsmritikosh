//
//  EntityOverlap.swift
//  Kalsmritikosh
//
//  "Where do these two both appear?" — the shared-evidence overlap between two
//  entities: the documents that mention BOTH, plus a per-entity footprint
//  (mentions, distinct documents). Complements the connection path-finder: one
//  shows HOW two entities link, this shows WHERE they co-appear. Deterministic
//  set intersection over the mention ledger; no model.
//

import Foundation

/// One document that mentions both entities.
public struct SharedDoc: Sendable, Hashable, Identifiable {
    public var id: KnowledgeObject.ID { objectID }
    public let objectID: KnowledgeObject.ID
    public let filename: String
    public let date: Date?
    public let url: URL?
    public init(objectID: KnowledgeObject.ID, filename: String, date: Date?, url: URL?) {
        self.objectID = objectID; self.filename = filename; self.date = date; self.url = url
    }
}

/// A per-entity footprint used on either side of the comparison.
public struct EntityFootprint: Sendable, Hashable {
    public let name: String
    public let mentionCount: Int
    public let documentCount: Int
    public init(name: String, mentionCount: Int, documentCount: Int) {
        self.name = name; self.mentionCount = mentionCount; self.documentCount = documentCount
    }
}

public struct EntityComparison: Sendable {
    public let a: EntityFootprint
    public let b: EntityFootprint
    public let shared: [SharedDoc]     // documents mentioning BOTH, newest first
    public init(a: EntityFootprint, b: EntityFootprint, shared: [SharedDoc]) {
        self.a = a; self.b = b; self.shared = shared
    }
}

public enum EntityOverlap {
    /// A document seen for an entity: id → (filename, date, url). Deduped per doc.
    public typealias DocMap = [KnowledgeObject.ID: (filename: String, date: Date?, url: URL?)]

    /// Documents present in BOTH maps, newest first (nil dates sort last), then
    /// by filename for stable ordering.
    public static func shared(_ a: DocMap, _ b: DocMap) -> [SharedDoc] {
        let common = Set(a.keys).intersection(b.keys)
        let rows = common.map { id -> SharedDoc in
            let v = a[id] ?? b[id]!
            return SharedDoc(objectID: id, filename: v.filename, date: v.date, url: v.url)
        }
        return rows.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?): return l == r ? lhs.filename < rhs.filename : l > r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return lhs.filename < rhs.filename
            }
        }
    }
}

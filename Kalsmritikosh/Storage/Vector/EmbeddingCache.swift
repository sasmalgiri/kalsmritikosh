//
//  EmbeddingCache.swift
//  Kalsmritikosh
//
//  Tiny in-memory LRU around expensive Embedder calls so the
//  HybridRetriever doesn't re-embed the same questions in a session.
//

import Foundation

public actor EmbeddingCache {
    private var entries: [String: [Float]] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 256) {
        self.capacity = max(8, capacity)
    }

    public func value(for key: String) -> [Float]? {
        guard let v = entries[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return v
    }

    public func set(_ key: String, _ vector: [Float]) {
        if entries[key] != nil {
            order.removeAll { $0 == key }
        }
        entries[key] = vector
        order.append(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

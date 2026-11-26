//
//  ResolvedProviderCache.swift
//  Kalsmritikosh
//
//  Speed PERF-22 (owner 2026-11-23) — not tested yet. A loop that asks the registry for the same capability once per item
//  (per chunk, per document) resolves it ONCE and reuses it for a short while: resolution ranks every provider and probes
//  availability, which costs more than the item itself for small items. The PrivacyGate is not bypassed: the cached
//  provider was resolved through it, every use re-checks `isAvailable()` (Online checks the person's mode again at the
//  send), and the entry expires after `ttl`, so a changed setting is picked up within seconds.
//

import Foundation
import os

public actor ResolvedProviderCache {
    private let registry: CapabilityRegistry
    private let ttl: TimeInterval
    private var entries: [CapabilitySpec: (provider: any ModelProvider, at: Date)] = [:]

    public init(registry: CapabilityRegistry, ttl: TimeInterval = 15) {
        self.registry = registry
        self.ttl = ttl
    }

    /// The provider for `spec` (resolved at most once per `ttl`), or nil when none is available now.
    public func provider(for spec: CapabilitySpec) async -> (any ModelProvider)? {
        if let e = entries[spec], Date().timeIntervalSince(e.at) < ttl, await e.provider.isAvailable() { return e.provider }
        do {
            let p = try await registry.resolve(spec)
            guard await p.isAvailable() else { entries[spec] = nil; return nil }
            entries[spec] = (p, Date())
            return p
        } catch {
            KalsmritikoshLog.routing.debug("ResolvedProviderCache: no provider for \(spec.purpose, privacy: .public): \(String(describing: error), privacy: .public)")
            entries[spec] = nil
            return nil
        }
    }
}

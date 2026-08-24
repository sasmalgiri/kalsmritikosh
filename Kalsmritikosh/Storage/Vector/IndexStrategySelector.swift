//
//  IndexStrategySelector.swift
//  Kalsmritikosh
//
//  P9.3 step 6 (GOV-005) — the pure index-strategy decision. One source of
//  truth for the RAM ceiling (HNSWVectorIndex.maxInMemoryVectors) and a 20%
//  hysteresis band so the strategy cannot flap while the background embedding
//  drain walks the corpus across the threshold. The DECISION is persisted in
//  ann_index_meta.strategy (boot serves the persisted strategy immediately —
//  no boot-time recount race); re-evaluation happens only in the background
//  maintenance job (ANNIndexCoordinator.maintain).
//

import Foundation

public enum IndexStrategySelector {

    /// Fraction of the in-memory cap below which a disk index switches back
    /// to in-memory HNSW. The 20% band prevents flapping at the boundary.
    public nonisolated static let hysteresisFactor = 0.8

    /// Pure decision: given the current persisted strategy, the corpus size
    /// and the machine's RAM, which strategy should serve?
    public nonisolated static func decide(
        current: ANNStrategy,
        vectorCount: Int,
        physicalMemoryBytes: UInt64
    ) -> ANNStrategy {
        decide(current: current, vectorCount: vectorCount,
               cap: HNSWVectorIndex.maxInMemoryVectors(physicalMemoryBytes: physicalMemoryBytes))
    }

    /// Cap-explicit core (the RAM wrapper above is the production entry;
    /// the coordinator injects a cap directly so integration tests can
    /// exercise real strategy switches without a 250k-vector corpus).
    public nonisolated static func decide(
        current: ANNStrategy,
        vectorCount: Int,
        cap: Int
    ) -> ANNStrategy {
        switch current {
        case .inMemoryHNSW:
            return vectorCount > cap ? .diskIVF : .inMemoryHNSW
        case .diskIVF:
            return vectorCount < Int(hysteresisFactor * Double(cap)) ? .inMemoryHNSW : .diskIVF
        }
    }
}

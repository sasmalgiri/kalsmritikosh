//
//  ExtractionTelemetryRepository.swift
//  Kalsmritikosh
//
//  Unified path IN-27 (owner 2026-11-22, round 2) — not tested yet. Keeps the C-5 extraction counters (counts only,
//  never content) across launches in v203 `extraction_telemetry_totals`: the totals saved earlier are added into the
//  process counters once per launch, before the first save, so a save never overwrites what earlier launches counted.
//

import Foundation
import os

public actor ExtractionTelemetryRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// 0 = saved totals not yet added this launch, 1 = being added (others skip their save), 2 = added.
    private static let restored = OSAllocatedUnfairLock(initialState: 0)

    /// Add the saved totals once (first call per launch), then save the combined totals.
    public func persist() async {
        do {
            let state = Self.restored.withLock { st -> Int in
                let was = st
                if st == 0 { st = 1 }
                return was
            }
            if state == 1 { return }   // another save is adding the saved totals right now
            if state == 0 {
                do {
                    if let json = try await database.query("SELECT snapshot_json FROM extraction_telemetry_totals WHERE id = 1;", []).first?.string(0) {
                        ExtractionTelemetry.shared.seed(try JSONDecoder().decode(ExtractionTelemetry.Snapshot.self, from: Data(json.utf8)))
                    }
                } catch {
                    // Not read: try again next time and never overwrite the saved totals meanwhile.
                    Self.restored.withLock { $0 = 0 }
                    throw error
                }
                Self.restored.withLock { $0 = 2 }
            }
            let json = String(decoding: try JSONEncoder().encode(ExtractionTelemetry.shared.snapshot()), as: UTF8.self)
            try await database.exec("""
                INSERT INTO extraction_telemetry_totals (id, snapshot_json, updated_at) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET snapshot_json = excluded.snapshot_json, updated_at = excluded.updated_at;
                """, [.text(json), .date(Date())])
        } catch {
            KalsmritikoshLog.storage.error("Extraction counters not kept: \(String(describing: error), privacy: .public)")
        }
    }
}

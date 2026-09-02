//
//  DiagnosticLedger.swift
//  KalsmritikoshTests
//
//  Canonical ledger guard for diagnostic tooling (owner 2026-09-02). The Q2-gate
//  false alarm came from a query hitting an EMPTY legacy container (there are
//  three candidate DBs on the machine: real 716, legacy 0, stale dup 667). The
//  in-process probes resolve via DatabaseLocations.defaultDatabaseURL correctly,
//  but they must still ASSERT the booted ledger is populated before treating its
//  answers as evidence — no probe may ever grade a phantom container again.
//

import Foundation
import Testing
@testable import Kalsmritikosh

enum DiagnosticLedger {
    /// Assert the booted ledger has rows. Records an Issue and returns false when
    /// empty, so the caller can abort before grading a phantom container.
    @MainActor
    static func assertPopulated(_ db: Database?, label: String) async -> Bool {
        guard let db else { Issue.record("\(label): no database on the booted state"); return false }
        let rows = (try? await db.query("SELECT COUNT(*) FROM knowledge_objects", [])) ?? []
        let ko = Int(rows.first?.int(0) ?? 0)
        print("\(label) LEDGER GUARD: knowledge_objects=\(ko)")
        if ko == 0 { Issue.record("\(label): empty ledger (ko=0) — refusing to grade a phantom container") }
        return ko > 0
    }
}

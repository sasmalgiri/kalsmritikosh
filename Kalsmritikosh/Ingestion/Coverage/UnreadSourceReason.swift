//
//  UnreadSourceReason.swift
//  Kalsmritikosh
//
//  Smart-map S14 (QA-15) — why a source version the app holds produced no readable text (a failed scan, an
//  unsupported or damaged file), in the words the case intake list uses. One place, so the workspace picker, the
//  case map and the brief name the same reason. Reads only; never empty (an unknown reason is said as such).
//

import Foundation
import os

public nonisolated enum UnreadSourceReason {

    /// Said when the version has no readiness record to explain it.
    public static let noRecord = "no text could be read from it (no reading record says why)"

    /// The reason for each version, from its readiness record (the intake list's stage and detail).
    public static func reasons(for versions: Set<UUID>, database: Database) async -> [UUID: String] {
        guard !versions.isEmpty else { return [:] }
        let readiness = SourceReadinessRepository(database: database)
        var out: [UUID: String] = [:]
        for v in versions.sorted(by: { $0.uuidString < $1.uuidString }) {
            let snapshot: SourceReadinessSnapshot?
            do {
                snapshot = try await readiness.snapshot(sourceVersionID: v)
            } catch let e as SourceReadinessError {
                if case .aggregateNotFound(_) = e { snapshot = nil } else {
                    KalsmritikoshLog.app.error("Unread source reason: readiness unreadable: \(String(describing: e), privacy: .public)")
                    snapshot = nil
                }
            } catch {
                KalsmritikoshLog.app.error("Unread source reason: readiness unreadable: \(error.localizedDescription, privacy: .public)")
                snapshot = nil
            }
            out[v] = text(snapshot: snapshot)
        }
        return out
    }

    /// The reason for one readiness snapshot of a version that holds no text.
    public static func text(snapshot: SourceReadinessSnapshot?) -> String {
        guard snapshot != nil else { return noRecord }
        let (stage, detail) = CaseIntakeStages.stage(snapshot: snapshot, hasLedgerText: false)
        let head = stage.label.prefix(1).lowercased() + stage.label.dropFirst()
        return detail.map { "\(head) (\($0))" } ?? head
    }
}

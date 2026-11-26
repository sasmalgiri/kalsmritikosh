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

    // MARK: GUI walk 2026-11-13 D5 — one plain-words reason for a failed reading, on every screen

    /// Said when the reading failed and nothing more specific is known: the parser produced no text.
    public static let noTextRead = "no text could be read from it"

    /// The plain words for the reading step that failed (a readiness limitation). Internal step names such as
    /// "metadataExtraction" are never shown: anything but text recognition or transcription is "no text could be read".
    public static func failureDetail(dimension: SourceReadinessDimension?) -> String {
        switch dimension {
        case .ocr?: return "text recognition (OCR) failed"
        case .transcription?: return "transcription failed"
        default: return noTextRead
        }
    }

    /// The same reason, from a failed reading attempt's technical stage and detail (the Evidence screen's list). The
    /// stage and detail stay available as technical details; the label is this sentence, so the Evidence screen, the
    /// Add-sources sheet and the case overview say the same thing for the same file.
    public static func failureReason(stage: String?, detail: String?) -> String {
        "reading failed (\(failureDetail(stage: stage, detail: detail)))"
    }

    static func failureDetail(stage: String?, detail: String?) -> String {
        let text = (detail ?? "").lowercased()
        let step = (stage ?? "").lowercased()
        if text.contains("timeout") || text.contains("timed out") { return "it took longer than the time allowed" }
        if text.contains("password") || text.contains("encrypted") { return "it needs a password" }
        if text.contains("corrupt") || text.contains("damaged") { return "the file is damaged" }
        if step == "router" || text.contains("unsupported") { return "this kind of file is not supported" }
        if text.contains("ocr") || text.contains("vision") || text.contains("recogni") { return failureDetail(dimension: .ocr) }
        if text.contains("transcri") { return failureDetail(dimension: .transcription) }
        return noTextRead
    }
}

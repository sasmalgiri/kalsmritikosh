//
//  PlacementTwin.swift
//  Kalsmritikosh
//
//  P4-U2 (Amendment A1 rider) — the PLACEMENT TWIN: an independent check of a
//  story outline against the placement laws, in the same fence as every twin:
//
//    · CHECKER, NEVER WRITER — the outline and its persisted artifact are
//      untouched, always; the twin's only output is advisory review rows
//    · the laws it re-derives independently:
//        H-1 use-once   — no item appears in two chapters
//        completeness   — every item appears in some chapter (nothing dropped)
//        chronology     — dated items inside a chapter are date-ordered, and
//                         structural chapters are date-ordered between
//                         themselves (Undated/Unplaced ride last, by design)
//    · agreement → one accept row; a violation → flag rows naming the law in
//      plain language (a rule-defect signal, never auto-tuning)
//

import Foundation
import os

public enum PlacementTwin {
    private static let logger = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "knowledge")

    /// Pure re-derivation of the placement laws. Empty = the outline obeys.
    public nonisolated static func check(outline: HistoryOutline) -> [String] {
        var findings: [String] = []
        let itemsByID = Dictionary(uniqueKeysWithValues: outline.items.map { ($0.id, $0) })

        // H-1 use-once + completeness.
        var seen = Set<UUID>()
        for chapter in outline.chapters {
            for id in chapter.itemIDs {
                if !seen.insert(id).inserted {
                    findings.append("an item appears in more than one chapter (\u{201C}\(itemsByID[id]?.title ?? id.uuidString)\u{201D})")
                }
            }
        }
        for item in outline.items where !seen.contains(item.id) {
            findings.append("an item was dropped from every chapter (\u{201C}\(item.title)\u{201D})")
        }

        // Within-chapter chronology (dated items only).
        for chapter in outline.chapters {
            let dates = chapter.itemIDs.compactMap { itemsByID[$0]?.start?.start }
            if dates != dates.sorted() {
                findings.append("chapter \u{201C}\(chapter.title)\u{201D} lists items out of date order")
            }
        }

        // Structural chapters date-ordered between themselves.
        let structural = outline.chapters.filter {
            $0.title != HistoryOutlineBuilder.undatedChapterTitle
                && $0.title != HistoryOutlineBuilder.unplacedChapterTitle
        }
        let earliest = structural.compactMap { ch in
            ch.itemIDs.compactMap { itemsByID[$0]?.start?.start }.min()
        }
        if earliest != earliest.sorted() {
            findings.append("chapters are not in chronological order")
        }
        return findings
    }

    /// Record the verdict as advisory review rows against the persisted
    /// artifact. Never touches history tables — fact_reviews only.
    public static func record(findings: [String], artifactID: UUID, database: Database) async {
        do {
            if findings.isEmpty {
                try await database.exec("""
                INSERT INTO fact_reviews (id, subject_kind, subject_id, action, reviewer, reason, reviewed_at)
                VALUES (?, 'story-placement', ?, 'accept', 'twin.placement', 'the outline obeys the placement laws', ?);
                """, [.uuid(UUID()), .uuid(artifactID), .real(Date().timeIntervalSince1970)])
            } else {
                for finding in findings {
                    try await database.exec("""
                    INSERT INTO fact_reviews (id, subject_kind, subject_id, action, reviewer, reason, reviewed_at)
                    VALUES (?, 'story-placement', ?, 'flag', 'twin.placement', ?, ?);
                    """, [.uuid(UUID()), .uuid(artifactID), .text(finding), .real(Date().timeIntervalSince1970)])
                    logger.info("twin.placement: FLAG \(artifactID.uuidString.prefix(8), privacy: .public) — \(finding, privacy: .public)")
                }
            }
        } catch {
            KalsmritikoshLog.knowledge.error("twin.placement: recording failed: \(error)")
        }
    }
}

//
//  TopicScoreboard.swift
//  Kalsmritikosh
//
//  M4 — an objective, deterministic read of topic-layer quality so the owner can
//  judge whether AI subject-resolution (M2) + prose polish (M3) actually improved
//  the database, not just eyeball it. Pure classification + a small stats struct;
//  the live query lives in AppState.
//
//  "Document-shaped" = the topic is keyed by a file/artifact label (a hash suffix
//  like `-9309f15b`, an underscore/extension file name, or an ALL-CAPS doc word)
//  rather than a real-world subject (a person/org/patent). Fewer document-shaped
//  topics after AI subject resolution = the leap working.
//

import Foundation

public struct TopicScoreboard: Sendable, Equatable {
    public let total: Int
    public let documentShaped: Int
    public let aiPolished: Int
    public var subjectShaped: Int { max(0, total - documentShaped) }
    public var subjectShapedFraction: Double { total == 0 ? 0 : Double(subjectShaped) / Double(total) }
    public var polishedFraction: Double { total == 0 ? 0 : Double(aiPolished) / Double(total) }

    public init(total: Int, documentShaped: Int, aiPolished: Int) {
        self.total = total; self.documentShaped = documentShaped; self.aiPolished = aiPolished
    }

    /// True when a topic identifier looks like a document/artifact label rather
    /// than a real-world subject. Deterministic and dependency-free.
    public nonisolated static func isDocumentShaped(_ identifier: String) -> Bool {
        let s = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        // 1 — a trailing `-<hex>` id suffix (e.g. "RESUME_2-9309f15b").
        if s.range(of: #"-[0-9a-fA-F]{6,}$"#, options: .regularExpression) != nil { return true }
        // 2 — a file extension.
        if s.range(of: #"\.(pdf|docx?|xlsx?|pptx?|txt|md|eml|msg|csv|rtf|html?)$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // 3 — file-name shape: underscores, or an ALL-CAPS document word.
        let docWords = ["resume", "report", "gdpr", "invoice", "convert", "scan", "export", "attachment", "copy"]
        let lower = s.lowercased()
        if s.contains("_") && docWords.contains(where: { lower.contains($0) }) { return true }
        // 4 — a lone ALL-CAPS token ≥ 4 chars with a digit or underscore (RESUME_2).
        if s.range(of: #"^[A-Z0-9_]{4,}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Build the scoreboard from the topic identifiers + the last build's polish count.
    public nonisolated static func from(identifiers: [String], aiPolished: Int) -> TopicScoreboard {
        let doc = identifiers.filter { isDocumentShaped($0) }.count
        return TopicScoreboard(total: identifiers.count, documentShaped: doc, aiPolished: aiPolished)
    }
}

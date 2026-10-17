//
//  CommunicationAnalysis.swift
//  Kalsmritikosh
//
//  N-2 — who talks to whom (Intella/Nuix style), from the ledger's per-email
//  participant rows: sender → recipient pairs with counts, monthly volume by each
//  email's own Date header, and replies whose original message is not in the
//  archive (In-Reply-To pointing at a Message-ID we do not hold).
//

import Foundation
import os

public struct CommunicationPair: Sendable, Identifiable, Hashable {
    public var id: String { from + "→" + to }
    public let from: String
    public let to: String
    public let count: Int
}

public struct MissingOriginal: Sendable, Identifiable, Hashable {
    public var id: String { replyMessageID + "|" + missingID }
    public let document: String
    public let replyMessageID: String
    public let missingID: String
}

public struct CommunicationReport: Sendable {
    public let pairs: [CommunicationPair]
    public let monthly: [(month: String, count: Int)]
    public let missingOriginals: [MissingOriginal]
}

extension AppState {

    public func communicationReport() async -> CommunicationReport? {
        guard ProductModuleFlags.isEnabled(.communicationAnalysis), let database else { return nil }
        do {
            let pairRows = try await database.query("""
                SELECT ef.value, et.value, COUNT(DISTINCT f.source_ko_id) AS n
                FROM email_participant_occurrences f
                JOIN email_participant_occurrences t ON t.source_ko_id = f.source_ko_id AND t.role IN ('to','cc')
                JOIN entities ef ON ef.id = f.entity_id
                JOIN entities et ON et.id = t.entity_id
                WHERE f.role = 'from' AND f.entity_id != t.entity_id
                GROUP BY f.entity_id, t.entity_id ORDER BY n DESC LIMIT 60;
                """, [])
            let pairs = pairRows.compactMap { r -> CommunicationPair? in
                guard let a = r.string(0), let b = r.string(1) else { return nil }
                return CommunicationPair(from: a, to: b, count: Int(r.int(2) ?? 0))
            }

            // Monthly volume from each email's Date header (mbox members share one file date).
            let dateRows = try await database.query("""
                SELECT DISTINCT ko.id, json_extract(ko.metadata_json, '$.date') FROM knowledge_objects ko
                JOIN email_participant_occurrences p ON p.source_ko_id = ko.id;
                """, [])
            var byMonth: [String: Int] = [:]
            let rfc = DateFormatter()
            rfc.locale = Locale(identifier: "en_US_POSIX")
            for r in dateRows {
                guard let raw = r.string(1) else { continue }
                var parsed: Date?
                for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
                    rfc.dateFormat = fmt
                    if let d = rfc.date(from: raw.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)) { parsed = d; break }
                }
                guard let d = parsed else { continue }
                let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: d)
                byMonth[String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0), default: 0] += 1
            }

            // Replies whose original is not in the archive.
            let headerRows = try await database.query("""
                SELECT b.document_id, b.raw_text FROM evidence_blocks b
                WHERE b.superseded_by_run IS NULL
                  AND (LOWER(b.raw_text) LIKE 'message-id:%' OR LOWER(b.raw_text) LIKE 'in-reply-to:%');
                """, [])
            var held = Set<String>()
            var replies: [(doc: UUID, own: String?, parent: String)] = []
            var ownByDoc: [UUID: String] = [:]
            func angle(_ s: String) -> String? {
                s.range(of: #"<[^>]+>"#, options: .regularExpression).map { String(s[$0]).lowercased() }
            }
            for r in headerRows {
                guard let doc = r.uuid(0), let text = r.string(1) else { continue }
                if text.lowercased().hasPrefix("message-id:"), let id = angle(text) { held.insert(id); ownByDoc[doc] = id }
                else if let id = angle(text) { replies.append((doc, nil, id)) }
            }
            var missing: [MissingOriginal] = []
            for rep in replies where !held.contains(rep.parent) {
                let name = try await database.query("""
                    SELECT f.url FROM chunks c JOIN evidence_blocks b ON b.id = c.evidence_block_id
                    JOIN knowledge_objects ko ON ko.id = c.object_id JOIN files f ON f.id = ko.file_id
                    WHERE b.document_id = ? LIMIT 1;
                    """, [.uuid(rep.doc)]).first?.string(0).flatMap { URL(string: $0)?.lastPathComponent } ?? "An email"
                missing.append(MissingOriginal(document: name, replyMessageID: ownByDoc[rep.doc] ?? "", missingID: rep.parent))
                if missing.count >= 200 { break }
            }
            return CommunicationReport(pairs: pairs,
                                       monthly: byMonth.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                                       missingOriginals: missing)
        } catch {
            KalsmritikoshLog.app.error("Communication report failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

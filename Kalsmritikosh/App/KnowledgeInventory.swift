//
//  KnowledgeInventory.swift
//  Kalsmritikosh
//
//  Read-only per-file dump of EVERYTHING the system extracted from
//  each ingested file: source URL, KO content summary, chunks count,
//  full entity + event lists with values, fact_bonds touching this
//  KO, and a content preview.
//
//  Why this exists: DataHealthCheck reports aggregate counts ("16
//  files, 1699 entities, 15 events") — useful for engine health but
//  doesn't tell you whether the extraction got the RIGHT entities
//  from each file. This dump pairs source vs. extracted side-by-side
//  so you can hand the originals + the inventory back and we can
//  spot ingest-fidelity regressions.
//
//  Pure read-only on the database. Writes one markdown file to
//  ~/Documents/EvalBaselines/knowledge-inventory.md.
//

import Foundation
import OSLog

public enum KnowledgeInventory {

    public struct Result: Sendable {
        public let reportURL: URL
        public let filesAudited: Int
        public let totalEntities: Int
        public let totalEvents: Int
        public let totalBonds: Int
    }

    @MainActor
    public static func generate(_ state: AppState, koLimit: Int = 200) async throws -> Result {
        guard let database = state.database,
              let filesRepo = state.files,
              let objects = state.objects,
              let entitiesRepo = state.entities,
              let eventsRepo = state.events
        else {
            throw NSError(
                domain: "KnowledgeInventory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AppState not booted."]
            )
        }
        let started = Date()

        // Page through every KO in created_at order so the inventory
        // is stable across runs.
        var allKOIDs: [KnowledgeObject.ID] = []
        var offset = 0
        let pageSize = 200
        while allKOIDs.count < koLimit {
            let page = (try? await objects.allIDs(offset: offset, pageSize: pageSize)) ?? []
            if page.isEmpty { break }
            allKOIDs.append(contentsOf: page)
            offset += page.count
            if page.count < pageSize { break }
        }

        var md = "# Kalsmritikosh — Knowledge Inventory\n\n"
        md += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n"
        md += "Database: `\(database.url.path)`\n"
        md += "KOs audited: \(allKOIDs.count)\n\n"
        md += "_This file pairs each ingested source against what Atlas extracted from it. Use it to compare against your original files and spot ingest gaps._\n\n"

        // ── Per-file sections ────────────────────────────────────────
        var totalEnts = 0
        var totalEvts = 0
        var totalBonds = 0

        for (i, koID) in allKOIDs.enumerated() {
            // Source URL via files join
            let urlRow = (try? await database.query("""
            SELECT f.url, f.source_type, f.size_bytes, k.source_type, k.confidence, k.created_at
            FROM knowledge_objects k JOIN files f ON f.id = k.file_id
            WHERE k.id = ? LIMIT 1;
            """, [.uuid(koID)]))?.first
            let sourceURL = urlRow?.string(0) ?? "(unknown)"
            let sourceTypeRaw = urlRow?.string(3) ?? "?"
            let sizeBytes = urlRow?.int(2) ?? 0
            let confidence = urlRow?.double(4) ?? 0
            let fileName = URL(string: sourceURL)?.lastPathComponent
                ?? URL(fileURLWithPath: sourceURL).lastPathComponent

            md += "---\n\n"
            md += "## \(i + 1). \(fileName)\n\n"
            md += "- **Source path:** `\(sourceURL)`\n"
            md += "- **Source type:** `\(sourceTypeRaw)`\n"
            md += "- **Size:** \(sizeBytes) bytes\n"
            md += "- **KO id:** `\(koID.uuidString.prefix(8))…`\n"
            md += "- **Ingest confidence:** \(String(format: "%.2f", confidence))\n\n"

            // Content preview (first 400 chars)
            if let content = try? await objects.fetchContent(id: koID) {
                let preview = content
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(400)
                md += "**Content preview** (first 400 chars):\n\n> \(preview)\(content.count > 400 ? " …" : "")\n\n"
            } else {
                md += "**Content preview:** _(could not read)_\n\n"
            }

            // Chunks count
            let chunkCount = await scalar(database, "SELECT COUNT(*) FROM chunks WHERE object_id = ?;", [.uuid(koID)])
            let vectorCount = await scalar(database, """
            SELECT COUNT(*) FROM vectors v
            JOIN chunks c ON c.id = v.chunk_id
            WHERE c.object_id = ?;
            """, [.uuid(koID)])
            let synthQCount = await scalar(database, "SELECT COUNT(*) FROM synthetic_questions WHERE object_id = ?;", [.uuid(koID)])
            md += "**Extracted shape:** \(chunkCount) chunks · \(vectorCount) vector embeddings · \(synthQCount) synthetic questions\n\n"

            // Entities extracted from this KO (via mentions join)
            let entities = (try? await entitiesRepo.findByMentionSource(koID)) ?? []
            totalEnts += entities.count
            if entities.isEmpty {
                md += "**Entities:** _(none extracted — possible NER miss)_\n\n"
            } else {
                md += "**Entities (\(entities.count)):**\n\n"
                let grouped = Dictionary(grouping: entities, by: \.kind)
                for kind in grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let group = grouped[kind] ?? []
                    let values = group.map(\.value).sorted().joined(separator: ", ")
                    md += "- **\(kind.rawValue)** (\(group.count)): \(String(values.prefix(800)))\n"
                }
                md += "\n"
            }

            // Events extracted from this KO
            let events = (try? await eventsRepo.findBySourceObject(koID)) ?? []
            totalEvts += events.count
            if events.isEmpty {
                md += "**Events:** _(none extracted)_\n\n"
            } else {
                md += "**Events (\(events.count)):**\n\n"
                for event in events {
                    let dateStr = event.date.formatted(date: .abbreviated, time: .omitted)
                    let summary = event.summary?.prefix(160).description.replacingOccurrences(of: "\n", with: " ") ?? ""
                    md += "- `\(event.kind.rawValue)` on \(dateStr): \(event.title) \(summary.isEmpty ? "" : "— \(summary)")\n"
                }
                md += "\n"
            }

            // fact_bonds where this KO is the source
            let bondRows = (try? await database.query("""
            SELECT bond_name, COUNT(*) FROM fact_bonds
            WHERE source_object_id = ? GROUP BY bond_name ORDER BY COUNT(*) DESC;
            """, [.uuid(koID)])) ?? []
            let bondsHere = bondRows.reduce(0) { $0 + Int($1.int(1) ?? 0) }
            totalBonds += bondsHere
            if bondsHere > 0 {
                md += "**Typed bonds (G3) emitted from this KO (\(bondsHere)):**\n\n"
                for row in bondRows {
                    if let name = row.string(0) {
                        md += "- `\(name)` × \(row.int(1) ?? 0)\n"
                    }
                }
                md += "\n"
            }
        }

        // ── Global cross-cuts ────────────────────────────────────────
        md += "---\n\n## Cross-file rollups\n\n"

        // Top entities by mention frequency
        let topEntities = (try? await database.query("""
        SELECT e.kind, e.value, COUNT(m.id) AS mentions
        FROM entities e
        JOIN entity_mentions m ON m.entity_id = e.id
        GROUP BY e.id
        ORDER BY mentions DESC
        LIMIT 30;
        """)) ?? []
        md += "### Top 30 entities by mention count (across all KOs)\n\n"
        md += "| Kind | Value | Mentions |\n|---|---|---:|\n"
        for row in topEntities {
            guard let kind = row.string(0), let value = row.string(1) else { continue }
            md += "| `\(kind)` | \(value) | \(row.int(2) ?? 0) |\n"
        }
        md += "\n"

        // Events by year
        let yearRows = (try? await database.query("""
        SELECT strftime('%Y', date, 'unixepoch') AS yr, COUNT(*)
        FROM events GROUP BY yr ORDER BY yr DESC LIMIT 20;
        """)) ?? []
        md += "### Events by year\n\n"
        if yearRows.isEmpty {
            md += "_(no events)_\n\n"
        } else {
            md += "| Year | Events |\n|---|---:|\n"
            for row in yearRows {
                if let yr = row.string(0) {
                    md += "| \(yr) | \(row.int(1) ?? 0) |\n"
                }
            }
            md += "\n"
        }

        // ── Write to disk ────────────────────────────────────────────
        let documentsDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let reportDir = documentsDir.appendingPathComponent("EvalBaselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("knowledge-inventory.md", isDirectory: false)
        try md.data(using: .utf8)?.write(to: url, options: .atomic)

        let elapsed = Date().timeIntervalSince(started)
        AtlasLog.app.info("KnowledgeInventory: wrote \(allKOIDs.count, privacy: .public) KOs to \(url.path, privacy: .public) in \(String(format: "%.1f", elapsed), privacy: .public)s")
        _ = filesRepo // suppress unused warning if we don't fan out further
        return Result(
            reportURL: url,
            filesAudited: allKOIDs.count,
            totalEntities: totalEnts,
            totalEvents: totalEvts,
            totalBonds: totalBonds
        )
    }

    private static func scalar(_ db: Database, _ sql: String, _ bindings: [SQLValue]) async -> Int {
        guard let rows = try? await db.query(sql, bindings) else { return 0 }
        return Int(rows.first?.int(0) ?? 0)
    }
}

//
//  CommunitySummarizer.swift
//  Kalsmritikosh
//
//  HISTORY Phase B.3 — produces one short LLM-generated narrative
//  per community detected in B.2. Persisted in `community_summaries`.
//
//  Why: the Narrative Composer (Phase D) needs a topic-level
//  paragraph to anchor a chapter ("This chapter covers the
//  patent-correspondence cluster: Khurana & Khurana, IIPRD,
//  Shabana Khan…"). Without a per-community summary, the composer
//  would have to hit the LLM at query time for every chapter,
//  exploding latency.
//
//  Pipeline:
//    1. Read all communities from `entity_communities` (B.2).
//    2. For each: list members (entity values), filter to top-N.
//    3. LLM call: "Given these entities, produce a 1-line title
//       and 2-3 sentence summary describing the topic."
//    4. Persist into `community_summaries`.
//
//  Quality-or-nothing rule: if the LLM returns nil or empty, we
//  leave the row blank rather than fabricating one.
//

import Foundation
import OSLog

public actor CommunitySummarizer: BackgroundService {
    public let id = "atlas.community.summarize"

    private let database: Database
    private let entities: EntitiesRepository
    private let capabilities: CapabilityRegistry
    private let intervalSeconds: TimeInterval
    private let topEntityCount: Int
    private var runTask: Task<Void, Never>?

    public init(
        database: Database,
        entities: EntitiesRepository,
        capabilities: CapabilityRegistry,
        intervalSeconds: TimeInterval = 24 * 3_600, // 1× per day
        topEntityCount: Int = 12
    ) {
        self.database = database
        self.entities = entities
        self.capabilities = capabilities
        self.intervalSeconds = intervalSeconds
        self.topEntityCount = topEntityCount
    }

    public func start() async {
        guard runTask == nil else { return }
        AtlasLog.knowledge.info("CommunitySummarizer: starting (interval=\(self.intervalSeconds, privacy: .public)s, topN=\(self.topEntityCount, privacy: .public))")
        runTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runOnce()
                let ns = await UInt64(self.intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
    }

    /// One full pass — picks communities that don't have a summary
    /// yet (or whose membership has changed since the last
    /// summary). Returns the number of communities summarized.
    @discardableResult
    public func runOnce() async -> Int {
        let spec = CapabilitySpec.summarization(contextTokens: 2_000, purpose: "history.community.summary")
        let provider: any ModelProvider
        do {
            provider = try await capabilities.resolve(spec)
        } catch {
            AtlasLog.knowledge.info("CommunitySummarizer: no summarization provider; skipping pass")
            return 0
        }
        guard await provider.isAvailable() else {
            AtlasLog.knowledge.info("CommunitySummarizer: provider \(provider.id, privacy: .public) unavailable; skipping pass")
            return 0
        }

        // 1. List communities ordered by member count desc.
        let communities: [(id: UUID, count: Int)]
        do {
            let rows = try await database.query("""
            SELECT community_id, COUNT(*) AS member_count
            FROM entity_communities
            WHERE level = 0
            GROUP BY community_id
            HAVING member_count >= 3
            ORDER BY member_count DESC
            LIMIT 500;
            """, [])
            communities = rows.compactMap { row -> (UUID, Int)? in
                guard let id = row.uuid(0),
                      let c = row.int(1) else { return nil }
                return (id, Int(c))
            }
        } catch {
            AtlasLog.knowledge.error("CommunitySummarizer: list failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard !communities.isEmpty else {
            AtlasLog.knowledge.info("CommunitySummarizer: no eligible communities")
            return 0
        }

        var produced = 0
        for community in communities {
            // 2. Decide whether to (re)summarize.
            let already = (try? await database.query(
                "SELECT member_count FROM community_summaries WHERE community_id = ? AND level = 0 LIMIT 1;",
                [.uuid(community.id)]
            ).first?.int(0)) ?? -1
            if already == Int64(community.count) {
                // Membership stable; skip.
                continue
            }

            // 3. Pull top entities for this community.
            let memberRows = (try? await database.query("""
            SELECT e.id, e.value, e.kind FROM entity_communities ec
            JOIN entities e ON e.id = ec.entity_id
            WHERE ec.community_id = ? AND ec.level = 0
            ORDER BY e.confidence DESC
            LIMIT ?;
            """, [.uuid(community.id), .integer(Int64(topEntityCount))])) ?? []
            let members: [(id: UUID, value: String, kind: String)] = memberRows.compactMap { row in
                guard let id = row.uuid(0),
                      let value = row.string(1),
                      let kind = row.string(2) else { return nil }
                return (id, value, kind)
            }
            guard members.count >= 3 else { continue }

            // 4. LLM call.
            let summary = await summarize(members: members, provider: provider)
            guard let summary, !summary.text.isEmpty else {
                AtlasLog.knowledge.info("CommunitySummarizer: provider returned empty for community \(community.id.uuidString.prefix(8), privacy: .public); leaving blank")
                continue
            }

            // 5. Persist.
            let topIDsJSON = (try? JSONEncoder().encode(members.map(\.id))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            do {
                try await database.exec("""
                INSERT INTO community_summaries (community_id, level, title, summary, member_count, top_entity_ids_json, computed_at)
                VALUES (?, 0, ?, ?, ?, ?, ?)
                ON CONFLICT(community_id, level) DO UPDATE SET
                    title = excluded.title,
                    summary = excluded.summary,
                    member_count = excluded.member_count,
                    top_entity_ids_json = excluded.top_entity_ids_json,
                    computed_at = excluded.computed_at;
                """, [
                    .uuid(community.id),
                    .text(summary.title),
                    .text(summary.text),
                    .integer(Int64(community.count)),
                    .text(topIDsJSON),
                    .real(Date().timeIntervalSince1970)
                ])
                produced += 1
            } catch {
                AtlasLog.knowledge.error("CommunitySummarizer: write failed for \(community.id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
        AtlasLog.knowledge.info("CommunitySummarizer: produced \(produced, privacy: .public) summaries of \(communities.count, privacy: .public) communities")
        return produced
    }

    private struct Summary {
        let title: String
        let text: String
    }

    private func summarize(
        members: [(id: UUID, value: String, kind: String)],
        provider: any ModelProvider
    ) async -> Summary? {
        let bullets = members
            .prefix(topEntityCount)
            .map { "  - \($0.value) (\($0.kind))" }
            .joined(separator: "\n")
        let prompt = """
        These entities cluster together in the user's archive. Give the cluster a short title (max 6 words) and a 2-3 sentence summary describing what topic or relationship they share.

        Entities:
        \(bullets)

        Reply with exactly two lines:
        TITLE: <the title>
        SUMMARY: <2-3 sentence summary>
        """
        let options = GenerationOptions(
            maxTokens: 200,
            temperature: 0.2,
            systemPrompt: "You are a precise topic-labeling assistant. Output exactly two lines: TITLE and SUMMARY."
        )
        let response: String
        do {
            response = try await provider.generate(prompt: prompt, options: options)
        } catch {
            return nil
        }
        // Parse "TITLE:" and "SUMMARY:" out of the response.
        var title = ""
        var summary = ""
        for line in response.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("title:") {
                title = String(trimmed.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("summary:") {
                summary = String(trimmed.dropFirst("summary:".count)).trimmingCharacters(in: .whitespaces)
            } else if !summary.isEmpty {
                summary += " " + trimmed
            }
        }
        guard !title.isEmpty, !summary.isEmpty else { return nil }
        return Summary(title: title, text: summary)
    }
}

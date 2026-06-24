//
//  SyntheticQuestionsBackfill.swift
//  Kalsmritikosh
//
//  Re-runs the heuristic synthetic-question generator over chunks that
//  were ingested BEFORE G2-SYNTHETIC-QUESTIONS landed. DataHealthCheck
//  caught this on 2026-06-24: 16 of 16 production KOs had 0 synthetic
//  questions because they were chunked + embedded before the generator
//  was wired into IngestCoordinator.
//
//  Read-only on the ingestion side — never re-extracts entities,
//  events, or vectors. Only writes new rows into `synthetic_questions`
//  + its FTS5 index. Heuristic generator (NLTagger-based) means no
//  LLM round-trips — runs in seconds for thousands of chunks.
//
//  Idempotent: skips KOs that already have synthetic_questions rows
//  so re-running the backfill doesn't double-write.
//

import Foundation
import OSLog

public actor SyntheticQuestionsBackfill {
    public struct Stats: Sendable {
        public var knowledgeObjects = 0
        public var skipped = 0
        public var questionsWritten = 0
        public var failed = 0
    }

    private let knowledgeObjects: KnowledgeObjectRepository
    private let chunks: ChunksRepository
    private let syntheticQuestions: SyntheticQuestionsRepository
    private let generator: any SyntheticQuestionGenerator
    private let pageSize: Int

    public init(
        knowledgeObjects: KnowledgeObjectRepository,
        chunks: ChunksRepository,
        syntheticQuestions: SyntheticQuestionsRepository,
        generator: any SyntheticQuestionGenerator = HeuristicSyntheticQuestionGenerator(),
        pageSize: Int = 200
    ) {
        self.knowledgeObjects = knowledgeObjects
        self.chunks = chunks
        self.syntheticQuestions = syntheticQuestions
        self.generator = generator
        self.pageSize = pageSize
    }

    /// Walk every KO in the ledger and emit synthetic questions for
    /// chunks that don't already have any. Returns counts. Safe to
    /// re-run — KOs whose synthetic_questions table already has rows
    /// are skipped without regenerating.
    public func run() async -> Stats {
        var stats = Stats()
        var offset = 0
        let started = Date()
        AtlasLog.knowledge.info("SyntheticQuestionsBackfill: starting run")
        while true {
            let page: [KnowledgeObject.ID]
            do {
                page = try await knowledgeObjects.allIDs(offset: offset, pageSize: pageSize)
            } catch {
                AtlasLog.knowledge.error("SyntheticQuestionsBackfill: enumerate failed at offset \(offset, privacy: .public) — \(String(describing: error), privacy: .public)")
                stats.failed += 1
                break
            }
            if page.isEmpty { break }
            for koID in page {
                stats.knowledgeObjects += 1
                let existing = (try? await syntheticQuestions.countForObject(koID)) ?? 0
                if existing > 0 {
                    stats.skipped += 1
                    continue
                }
                let chunkList = (try? await chunks.findByObjectID(koID)) ?? []
                guard !chunkList.isEmpty else {
                    stats.skipped += 1
                    continue
                }
                var rows: [SyntheticQuestionsRepository.Row] = []
                for chunk in chunkList {
                    let questions = await generator.generate(
                        for: chunk,
                        documentContext: "",
                        topK: 4
                    )
                    for q in questions {
                        rows.append(SyntheticQuestionsRepository.Row(
                            chunkID: chunk.id,
                            objectID: koID,
                            text: q.text,
                            confidence: q.confidence,
                            producedBy: generator.id
                        ))
                    }
                }
                if rows.isEmpty {
                    stats.skipped += 1
                    continue
                }
                do {
                    try await syntheticQuestions.insertBatch(rows)
                    stats.questionsWritten += rows.count
                } catch {
                    AtlasLog.knowledge.error("SyntheticQuestionsBackfill: insert failed for KO \(koID.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                    stats.failed += 1
                }
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        AtlasLog.knowledge.info("SyntheticQuestionsBackfill: complete — KOs=\(stats.knowledgeObjects, privacy: .public) skipped=\(stats.skipped, privacy: .public) questionsWritten=\(stats.questionsWritten, privacy: .public) failed=\(stats.failed, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s")
        return stats
    }
}

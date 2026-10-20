//
//  CaseBenchRunner.swift
//  KalsmritikoshTests
//
//  The case bench (docs/CASE_BENCH_PLAN.md): real, public investigation records run through the
//  app's own pipeline — ingest, extraction, Ask — one isolated ledger per shard of cases. The
//  runner only records what the app did (answers, citations, extracted dates and names, timing)
//  as JSON lines; scripts/casebench/score.py compares that with each case's answer key, so the
//  scoring can change without re-running the app.
//
//  Owner-run, never in CI: it does nothing unless CASEBENCH_DIR is set (pass it as
//  TEST_RUNNER_CASEBENCH_DIR to xcodebuild). Every shard gets a fresh ledger in a temp folder;
//  the owner's archive is never opened. Shards that already have a result file are skipped, so
//  a stopped run resumes where it left off.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Case bench — real cases through the real pipeline", .serialized)
struct CaseBenchRunner {

    struct Question: Decodable { let id: String; let q: String }
    struct TruthLine: Decodable { let `case`: String; let source: String; let questions: [Question]; let control: String? }

    struct DocResult: Encodable {
        let doc: String; let chunks: Int; let entities: Int; let events: Int; let seconds: Double
        let error: String?
    }
    struct AnswerResult: Encodable {
        let id: String; let q: String; let body: String; let refused: Bool; let refusal: String?
        let cited: [String]; let snippets: [String]; let confidence: String; let seconds: Double
        /// Generations that returned text while this question was answered, per provider ID —
        /// the proof of which model (if any) wrote the answer.
        let aiCalls: [String: Int]
    }
    struct CaseResult: Encodable {
        let `case`: String; let source: String
        let docs: [DocResult]
        let eventDates: [String]; let entities: [String]
        /// field=value of every fact the ledger holds from this case's documents (the
        /// open-field and domain-pack extractors write facts, not entities).
        let facts: [String]
        let answers: [AnswerResult]
    }
    struct ShardSummary: Encodable {
        let shard: String; let cases: Int; let ingestSeconds: Double; let embedSeconds: Double
        let askSeconds: Double; let control: AnswerResult?
        /// The on-device model the run used ("AFM 3 Core Advanced"), nil in evidence-only mode.
        let aiModel: String?
    }

    static var env: [String: String] { ProcessInfo.processInfo.environment }

    @Test("Run every shard under CASEBENCH_DIR")
    func runShards() async throws {
        guard let root = Self.env["CASEBENCH_DIR"] else { return }   // owner-run only
        let out = URL(fileURLWithPath: Self.env["CASEBENCH_OUT"] ?? root + "/../results", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let maxShards = Int(Self.env["CASEBENCH_MAX_SHARDS"] ?? "") ?? .max
        let embed = Self.env["CASEBENCH_EMBED"] != "0"
        let askEvery = max(1, Int(Self.env["CASEBENCH_ASK_EVERY"] ?? "") ?? 1)
        // Tier A runs the evidence-only answer path ("Fully private (no AI)"). The switch goes
        // into the argument domain, which lives in memory for this process only, so the owner's
        // saved preference is never written.
        // Tier B (CASEBENCH_NOAI=0) answers with Apple's on-device model. The switch is forced
        // off the same way, so an owner preference of "Fully private" cannot silently turn the
        // run into an evidence-only one, and the run stops unless the model is really there.
        let noAI = Self.env["CASEBENCH_NOAI"] == "1"
        UserDefaults.standard.setVolatileDomain(["kalsmritikosh.privacy.offlineNoLLM": noAI],
                                                forName: UserDefaults.argumentDomain)
        if !noAI {
            guard await FoundationModelsProvider().isAvailable() else {
                Issue.record("AI run requested but Apple's on-device model is unavailable: \(FoundationModelsProvider.unavailabilityHint() ?? "unknown")")
                return
            }
        }
        let aiModel = noAI ? nil : FoundationModelsProvider.installedModelName()
        var done = 0
        for shard in Self.shards(under: URL(fileURLWithPath: root, isDirectory: true)) {
            guard done < maxShards else { break }
            let name = shard.deletingLastPathComponent().lastPathComponent + "-" + shard.lastPathComponent
            let target = out.appendingPathComponent(name + ".jsonl")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            try await run(shard: shard, name: name, into: target, embed: embed, askEvery: askEvery, aiModel: aiModel)
            done += 1
        }
    }

    /// Shard folders (those holding a truth.jsonl), in name order. Walks folders by hand so the
    /// orchestrator's symlinked shards are followed (FileManager's enumerator does not).
    static func shards(under root: URL, depth: Int = 0) -> [URL] {
        let fm = FileManager.default
        let dir = root.resolvingSymlinksInPath()
        if fm.fileExists(atPath: dir.appendingPathComponent("truth.jsonl").path) { return [dir] }
        guard depth < 4, let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return kids.filter { !$0.lastPathComponent.hasPrefix(".") }
            .flatMap { shards(under: $0, depth: depth + 1) }
            .sorted { $0.path < $1.path }
    }

    private func run(shard: URL, name: String, into target: URL, embed: Bool, askEvery: Int, aiModel: String?) async throws {
        let truth = try String(contentsOf: shard.appendingPathComponent("truth.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(TruthLine.self, from: Data($0.utf8)) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("casebench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = await AppState(bookmarks: BookmarkStore())
        await state.boot(databaseURL: temp.appendingPathComponent("bench.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database else {
            Issue.record("ledger did not boot for \(name)"); return
        }

        // 1. Ingest every case's documents.
        var docsByCase: [String: [DocResult]] = [:]
        var objectsByCase: [String: [UUID]] = [:]
        var caseOfObject: [UUID: String] = [:]
        var versionsByCase: [String: [UUID]] = [:]
        let t0 = Date()
        for line in truth {
            let folder = shard.appendingPathComponent(line.case, isDirectory: true)
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let s = Date()
                do {
                    let r = try await ingest.ingest(fileAt: file)
                    objectsByCase[line.case, default: []].append(r.object.id)
                    caseOfObject[r.object.id] = line.case + "/" + file.lastPathComponent
                    if let v = r.sourceVersionID { versionsByCase[line.case, default: []].append(v) }
                    docsByCase[line.case, default: []].append(.init(doc: file.lastPathComponent, chunks: r.chunkCount,
                        entities: r.entityCount, events: r.eventCount, seconds: Date().timeIntervalSince(s), error: nil))
                } catch {
                    docsByCase[line.case, default: []].append(.init(doc: file.lastPathComponent, chunks: 0, entities: 0,
                        events: 0, seconds: Date().timeIntervalSince(s), error: String(describing: error)))
                }
            }
        }
        let ingestSeconds = Date().timeIntervalSince(t0)
        let t1 = Date()
        if embed { await ingest.drainEmbeddingsNow() }
        let embedSeconds = Date().timeIntervalSince(t1)

        // 2. Ask each case's questions over the whole shard's ledger (an archive holds many cases).
        let brain = await state.brain
        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
        func ask(_ id: String, _ q: String) async -> AnswerResult {
            let s = Date()
            let before = await LLMCallCounters.shared.snapshot().completedByProvider
            let a = await brain.answer(question: q, access: access)
            let after = await LLMCallCounters.shared.snapshot().completedByProvider
            let calls = after.compactMapValues { $0 }.reduce(into: [String: Int]()) { out, kv in
                let d = kv.value - (before[kv.key] ?? 0)
                if d > 0 { out[kv.key] = d }
            }
            return AnswerResult(id: id, q: q, body: a.body, refused: a.refused, refusal: a.refusalReason,
                                cited: a.citations.map { caseOfObject[$0.objectID] ?? "?" },
                                snippets: a.citations.prefix(5).map { String($0.snippet.prefix(300)) },
                                confidence: String(describing: a.confidence), seconds: Date().timeIntervalSince(s),
                                aiCalls: calls)
        }
        var lines: [String] = []
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let progress = target.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: progress.path, contents: nil)
        let progressHandle = try FileHandle(forWritingTo: progress)
        defer { try? progressHandle.close(); try? FileManager.default.removeItem(at: progress) }
        let t2 = Date()
        for (index, line) in truth.enumerated() {
            let ids = objectsByCase[line.case] ?? []
            let marks = ids.map { _ in "?" }.joined(separator: ",")
            var dates: [String] = [], names: [String] = [], facts: [String] = []
            let versions = versionsByCase[line.case] ?? []
            if !versions.isEmpty {
                let vmarks = versions.map { _ in "?" }.joined(separator: ",")
                facts = ((try? await db.query("""
                    SELECT DISTINCT gf.field || '=' || gf.value FROM generic_facts gf, json_each(gf.source_blocks_json) j
                    JOIN evidence_blocks eb ON eb.id = j.value WHERE eb.source_version_id IN (\(vmarks))
                    """, versions.map { .uuid($0) })) ?? []).compactMap { $0.string(0) }
            }
            if !ids.isEmpty {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
                dates = ((try? await db.query("SELECT date FROM events WHERE source_object_id IN (\(marks))", ids.map { .uuid($0) })) ?? [])
                    .compactMap { $0.date(0) }.map { f.string(from: $0) }
                names = ((try? await db.query("SELECT DISTINCT kind || ':' || value FROM entities WHERE source_object_id IN (\(marks))", ids.map { .uuid($0) })) ?? [])
                    .compactMap { $0.string(0) }
            }
            var answers: [AnswerResult] = []
            // Every case is checked for extraction; questions go to every askEvery-th case.
            if index % askEvery == 0 { for q in line.questions { answers.append(await ask(q.id, q.q)) } }
            let r = CaseResult(case: line.case, source: line.source, docs: docsByCase[line.case] ?? [],
                               eventDates: Array(Set(dates)).sorted(), entities: names.sorted(),
                               facts: facts.sorted(), answers: answers)
            lines.append(String(decoding: try enc.encode(r), as: UTF8.self))
            try progressHandle.write(contentsOf: Data((lines.last! + "\n").utf8))   // visible while the shard runs
        }
        // A case that is not in the archive: the honest answer is a refusal.
        let control: AnswerResult? = if let q = truth.first?.control { await ask("control", q) } else { nil }
        let summary = ShardSummary(shard: name, cases: truth.count, ingestSeconds: ingestSeconds, embedSeconds: embedSeconds,
                                   askSeconds: Date().timeIntervalSince(t2), control: control, aiModel: aiModel)
        lines.append(String(decoding: try enc.encode(["summary": summary]), as: UTF8.self))
        try (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
    }
}

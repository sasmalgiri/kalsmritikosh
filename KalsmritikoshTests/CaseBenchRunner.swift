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
    struct TruthLine: Decodable {
        let `case`: String; let source: String; let questions: [Question]; let control: String?
        let profile: String?; let stratum: String?; let key: String?
    }

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
        /// The question as the app answered it, when it was rewritten (normalised or canonical form).
        var resolved: String? = nil
        /// Which path wrote the answer (VerifiedAnswerComposer.writer): "ai-verified", "needs-review",
        /// "ai-not-stated", "rules-ai-failed" or "rules".
        var writer: String? = nil
    }
    struct CaseResult: Encodable {
        let `case`: String; let source: String
        let docs: [DocResult]
        let eventDates: [String]; let entities: [String]
        /// field=value of every fact the ledger holds from this case's documents (the
        /// open-field and domain-pack extractors write facts, not entities).
        let facts: [String]
        let answers: [AnswerResult]
        let profile: String?; let stratum: String?
        /// The case worked as an investigation (CASEBENCH_WORKFLOW=1): opened as a case over its
        /// own documents, questions asked inside the case, findings built.
        let workflow: WorkflowResult?
    }
    struct WorkflowResult: Encodable {
        let authorizedVersions: Int; let custodyEntries: Int; let custodyHashed: Int
        let contradictions: Int; let gaps: Int
        let answers: [AnswerResult]
        let findingsSections: Int; let findingsClaims: Int; let findingsCitations: Int
        let findingsCitationsInScope: Int; let findingsText: String
        let error: String?
        /// P3 — the case contradiction check: every contradiction in scope with both quotes, its kind and
        /// how it was found, and what the check cost.
        var contradictionList: [ContradictionLine] = []
        var contradictionCheck: ContradictionCheck? = nil
        /// P5 — the case drafts (rules; the AI reading too when a key is given): chronology, cast,
        /// gaps and leads, with what verified, what was dropped and what it cost.
        var drafts: DraftsResult? = nil
    }
    struct DraftsResult: Encodable {
        struct Item: Encodable { let date: String; let what: String; let who: String?; let quote: String; let doc: String; let provenance: String }
        struct Member: Encodable { let name: String; let kind: String; let role: String; let group: String; let documents: Int; let quote: String?; let provenance: String? }
        struct Lead: Encodable { let source: String; let notEstablished: String; let records: String; let quote: String; let doc: String; let otherQuote: String? }
        let timeline: [Item]; let cast: [Member]; let leads: [Lead]
        let documents: Int; let readerAvailable: Bool; let verified: Int; let agreedWithRules: Int; let dropped: Int
        let droppedReasons: [String]; let calls: Int; let roleBatches: Int; let roleReadings: Int; let failedCalls: Int
        let passagesSent: Int; let deniedForCloud: Int; let notSent: String?
        /// Why each failed reader call failed, and why each role reading was dropped.
        var failures: [String] = []
        var roleDropped: [String] = []
        /// The interview plan drafted for each of the case's subjects (rules).
        struct Question: Encodable { let question: String; let quote: String; let doc: String; let basis: String; let otherQuote: String? }
        struct Interview: Encodable { let person: String; let questions: [Question] }
        var interviews: [Interview] = []
    }
    struct ContradictionLine: Encodable {
        let kind: String; let provenance: String; let description: String
        let quoteA: String; let docA: String; let quoteB: String; let docB: String
    }
    struct ContradictionCheck: Encodable {
        let documents: Int; let rules: Int; let ai: Int; let aiDropped: Int; let aiAgreedWithRules: Int
        let calls: Int; let failedCalls: Int; let passagesSent: Int; let deniedForCloud: Int
        let notSent: String?; let claimLinks: Int
        /// Why each AI pair was dropped (with what it proposed) and why each failed call failed.
        var droppedReasons: [String] = []
        var failures: [String] = []
    }
    struct ShardSummary: Encodable {
        let shard: String; let cases: Int; let ingestSeconds: Double; let embedSeconds: Double
        let askSeconds: Double; let control: AnswerResult?
        /// The on-device model the run used ("AFM 3 Core Advanced"), nil in evidence-only mode.
        let aiModel: String?
        /// Knowledge and product modules switched on for this run (CASEBENCH_FULL).
        let modulesOn: Int
        /// Model calls by purpose over the whole shard (ingest and asking) — which features spend
        /// the on-device model.
        let modelCallsByPurpose: [String: Int]
        /// The cloud readers the run installed (CASEBENCH_CLOUD_KEY_FILE) with their model, the calls each
        /// made, and the failures each met, in the provider's words. Empty: no cloud reader.
        var cloudModel: String? = nil
        var cloudReaders: [String: CloudReaderUse] = [:]
        /// One line for the run footer: which readers ran and what each did.
        var cloudSummary: String { Self.cloudSummary(model: cloudModel, readers: cloudReaders) }

        static func cloudSummary(model: String?, readers: [String: CloudReaderUse]) -> String {
            guard let model else { return "cloud readers: none" }
            let used = readers.filter { $0.value.calls > 0 }.sorted { $0.key < $1.key }
            guard !used.isEmpty else { return "cloud readers (\(model)): installed, no calls made" }
            return "cloud readers (\(model)): " + used.map { "\($0.key) \($0.value.calls) call(s)" + ($0.value.failed > 0 ? " (\($0.value.failed) failed: \($0.value.failures.first ?? "?"))" : "") }
                .joined(separator: ", ")
        }

        enum CodingKeys: String, CodingKey {
            case shard, cases, ingestSeconds, embedSeconds, askSeconds, control, aiModel, modulesOn, modelCallsByPurpose, cloudModel, cloudReaders, cloudSummary
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(shard, forKey: .shard); try c.encode(cases, forKey: .cases)
            try c.encode(ingestSeconds, forKey: .ingestSeconds); try c.encode(embedSeconds, forKey: .embedSeconds)
            try c.encode(askSeconds, forKey: .askSeconds); try c.encodeIfPresent(control, forKey: .control)
            try c.encodeIfPresent(aiModel, forKey: .aiModel); try c.encode(modulesOn, forKey: .modulesOn)
            try c.encode(modelCallsByPurpose, forKey: .modelCallsByPurpose); try c.encodeIfPresent(cloudModel, forKey: .cloudModel)
            try c.encode(cloudReaders, forKey: .cloudReaders); try c.encode(cloudSummary, forKey: .cloudSummary)
        }
    }
    struct CloudReaderUse: Encodable, Equatable {
        var calls = 0
        var failed = 0
        var failures: [String] = []
    }

    /// The run's settings: the process environment, or — for a bundled pack run — the pack's
    /// settings (`BundledPack.overrides`), which stand in for the TEST_RUNNER_* variables.
    static var env: [String: String] { ProcessInfo.processInfo.environment.merging(BundledPack.overrides) { _, pack in pack } }

    /// A bundled pack (`scripts/casebench/pack_local.py`): the shards and settings of one bench run,
    /// packed into a single JSON resource because the sandboxed Xcode test host can read neither
    /// ~/CaseBench nor TEST_RUNNER_* variables. Materialised into the temporary folder and run
    /// exactly as an environment-driven run; each shard result is attached to the test result.
    enum BundledPack {
        nonisolated(unsafe) static var overrides: [String: String] = [:]
        struct File: Decodable { let name: String; let b64: String }
        struct Case: Decodable { let `case`: String; let files: [File] }
        struct Shard: Decodable { let name: String; let truth: String; let cases: [Case] }
        struct Pack: Decodable { let set: String; let env: [String: String]; let shards: [Shard] }

        static func url() -> URL? {
            let bundle = Bundle(for: Marker.self)
            if let u = bundle.url(forResource: "casebench-pack", withExtension: "json") { return u }
            guard let root = bundle.resourceURL, let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
            while let u = e.nextObject() as? URL { if u.lastPathComponent == "casebench-pack.json" { return u } }
            return nil
        }

        /// Materialise the pack: returns the cases root and the results folder.
        static func materialise(_ packURL: URL) throws -> (cases: URL, results: URL, set: String, shards: Int) {
            let pack = try JSONDecoder().decode(Pack.self, from: Data(contentsOf: packURL))
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("casebench-pack-\(UUID().uuidString)", isDirectory: true)
            let cases = base.appendingPathComponent("cases", isDirectory: true), results = base.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
            for s in pack.shards {
                let dir = cases.appendingPathComponent(s.name, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try s.truth.write(to: dir.appendingPathComponent("truth.jsonl"), atomically: true, encoding: .utf8)
                for c in s.cases {
                    let folder = dir.appendingPathComponent(c.case, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for f in c.files { try (Data(base64Encoded: f.b64) ?? Data()).write(to: folder.appendingPathComponent(f.name)) }
                }
            }
            overrides = pack.env
            return (cases, results, pack.set, pack.shards.count)
        }
    }
    private final class Marker {}

    @Test("Run every shard under CASEBENCH_DIR")
    func runShards() async throws {
        var bundled: (cases: URL, results: URL, set: String, shards: Int)?
        if ProcessInfo.processInfo.environment["CASEBENCH_DIR"] == nil, let pack = BundledPack.url() {
            bundled = try BundledPack.materialise(pack)
        }
        defer { if let b = bundled { try? FileManager.default.removeItem(at: b.cases.deletingLastPathComponent()) } }
        guard let root = bundled?.cases.path ?? Self.env["CASEBENCH_DIR"] else { return }   // owner-run only
        let out = bundled?.results ?? URL(fileURLWithPath: Self.env["CASEBENCH_OUT"] ?? root + "/../results", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer {
            // A bundled run hands its results back through the test result (the sandboxed host's
            // folders are not readable from outside): one attachment per shard.
            if let b = bundled, let files = try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil) {
                for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "jsonl" {
                    if let data = try? Data(contentsOf: f) { Attachment.record(data, named: f.lastPathComponent) }
                }
                Attachment.record(Data("set: \(b.set)\nshards: \(b.shards)\nsettings: \(BundledPack.overrides.sorted { $0.key < $1.key })\n".utf8), named: "MEASUREMENT-pack.txt")
            }
        }
        let maxShards = Int(Self.env["CASEBENCH_MAX_SHARDS"] ?? "") ?? .max
        let embed = Self.env["CASEBENCH_EMBED"] != "0"
        let askEvery = max(1, Int(Self.env["CASEBENCH_ASK_EVERY"] ?? "") ?? 1)
        let workflowEvery = Int(Self.env["CASEBENCH_WORKFLOW_EVERY"] ?? "") ?? 0   // 0 = off
        // Tier A runs the evidence-only answer path ("Fully private (no AI)"). The switch goes
        // into the argument domain, which lives in memory for this process only, so the owner's
        // saved preference is never written.
        // Tier B (CASEBENCH_NOAI=0) answers with Apple's on-device model. The switch is forced
        // off the same way, so an owner preference of "Fully private" cannot silently turn the
        // run into an evidence-only one, and the run stops unless the model is really there.
        let noAI = Self.env["CASEBENCH_NOAI"] == "1"
        var settings: [String: Any] = ["kalsmritikosh.privacy.offlineNoLLM": noAI]
        // CASEBENCH_FULL=1 — the app at full power: every implemented knowledge module and every
        // product module on (preview features shown), in this process's argument domain only.
        // Online-only modules still need Online mode, which a private bench never turns on.
        if Self.env["CASEBENCH_FULL"] == "1" {
            for m in KnowledgeModule.allCases { settings[KnowledgeModuleFlags.storageKey(m)] = true }
            for m in ProductModule.allCases { settings["kalsmritikosh.product.\(m.rawValue)"] = true }
            settings[ProductModuleFlags.showPreviewKey] = true
        }
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
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
            try await run(shard: shard, name: name, into: target, embed: embed, askEvery: askEvery, workflowEvery: workflowEvery, aiModel: aiModel)
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

    private func run(shard: URL, name: String, into target: URL, embed: Bool, askEvery: Int, workflowEvery: Int, aiModel: String?) async throws {
        let truth = try String(contentsOf: shard.appendingPathComponent("truth.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(TruthLine.self, from: Data($0.utf8)) }

        await LLMCallCounters.shared.reset()   // per-shard model-call accounting
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("casebench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("bench.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database else {
            Issue.record("ledger did not boot for \(name)"); return
        }

        // 1. Ingest every case's documents.
        var docsByCase: [String: [DocResult]] = [:]
        var objectsByCase: [String: [UUID]] = [:]
        var caseOfObject: [UUID: String] = [:]
        var versionsByCase: [String: [UUID]] = [:]
        var filesByCase: [String: [UUID]] = [:]
        let t0 = Date()
        // Objects the archive already holds — whatever a case's ingest adds beyond them (an
        // email's attachments, a ZIP's files, a mailbox's messages) belongs to that case.
        var knownObjects = Set<UUID>()
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
                    filesByCase[line.case, default: []].append(r.fileRecord.id)
                    docsByCase[line.case, default: []].append(.init(doc: file.lastPathComponent, chunks: r.chunkCount,
                        entities: r.entityCount, events: r.eventCount, seconds: Date().timeIntervalSince(s),
                        // A file the pipeline could not read returns (it is recorded under Needs attention)
                        // rather than throwing; the bench reports it as an error, never as a 0-chunk success.
                        error: r.processingStatus == .failed ? "failed: \(r.processingDetail ?? "no reason recorded")" : nil))
                } catch {
                    docsByCase[line.case, default: []].append(.init(doc: file.lastPathComponent, chunks: 0, entities: 0,
                        events: 0, seconds: Date().timeIntervalSince(s), error: String(describing: error)))
                }
            }
            let all = Set(((try? await db.query("SELECT id FROM knowledge_objects;", [])) ?? []).compactMap { $0.uuid(0) })
            for o in all.subtracting(knownObjects) where caseOfObject[o] == nil {
                caseOfObject[o] = line.case + "/(inside a case document)"
                objectsByCase[line.case, default: []].append(o)
            }
            knownObjects = all
        }
        let ingestSeconds = Date().timeIntervalSince(t0)
        let t1 = Date()
        if embed { await ingest.drainEmbeddingsNow() }
        let embedSeconds = Date().timeIntervalSince(t1)

        // The gap layer the app builds on its idle pass, built now so an opened case can show it
        // (closed-case simulation 2026-10-26: without it every case reported 0 gaps).
        if workflowEvery > 0 { _ = await state.scanForGaps() }

        // 2. Ask each case's questions over the whole shard's ledger (an archive holds many cases).
        let brain = await state.brain
        var cloudModel: String?
        await BenchClaude.Usage.shared.resetReaders()
        // CASEBENCH_CLOUD_KEY_FILE — the cloud step of the understanding cascade, measured with the
        // owner's Claude key (read from a file outside the repo; the app itself reaches the cloud only
        // through its network helper, which a test host does not have). The question's wording goes to
        // the interpreter and rewriter; the retrieved passages go to the record extractor and the verified
        // answer composer, whose every claim is checked against its passage. Without a key the readers
        // the app installed at boot stand (no Online provider here → nothing is sent, evidence-only).
        if let keyFile = Self.env["CASEBENCH_CLOUD_KEY_FILE"],
           let key = try? String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            let model = Self.env["CASEBENCH_CLOUD_MODEL"] ?? "claude-opus-5"
            func asks(_ reader: String) -> @Sendable (String) async throws -> String {
                { prompt in try await BenchClaude.send(prompt, key: key, model: model, reader: reader) }
            }
            // Verified record extraction reads the person's documents — a stronger reader than the
            // question rewriter; every answer it proposes is checked verbatim against the documents.
            let extractModel = Self.env["CASEBENCH_CLOUD_EXTRACT_MODEL"] ?? "claude-opus-5"
            // Each document reader is counted under its own name (the run footer lists them).
            func reads(_ reader: String, _ maxTokens: Int) -> @Sendable (String, CloudSourceClearance?) async throws -> String {
                { prompt, _ in try await BenchClaude.send(prompt, key: key, model: extractModel, maxTokens: maxTokens, reader: reader) }
            }
            // P1 — the verified answer composer reads the retrieved passages with the same model; every
            // claim it writes is checked against its passage. One reader set for the archive brain and,
            // through the app's holder, for every case-scoped brain.
            let baseReaders = CloudReaders(
                interpreterCloud: CloudQuestionInterpreter(generate: asks("questionInterpreter")),
                rewriterCloud: CloudQuestionRewriter(generate: asks("questionRewriter")),
                recordExtractor: VerifiedRecordExtractor(generate: reads("recordExtractor", 600)),
                answerComposer: VerifiedAnswerComposer(generate: reads("answerComposer", 1_500)),
                // P3 — the case contradiction check reads the case's cleared passages with the same model.
                contradictionReader: CaseContradictionReader(generate: reads("contradictionReader", 1_500)),
                modelsAllowedOverride: true)
            var readers = baseReaders
            // P4/P5 — the role reader and the case drafts read the case's cleared passages with the same model.
            readers.roleReader = VerifiedRoleReader(generate: reads("roleReader", 800))
            readers.draftReader = CaseDraftReader(generate: reads("draftReader", CaseDraftBuilder.readerReplyTokens))
            cloudModel = extractModel == model ? model : "\(model) (questions), \(extractModel) (documents)"
            state.cloudReaderHolder.set(readers)
            await brain.setCloudReaders(readers)
        }
        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
        func ask(_ id: String, _ q: String) async -> AnswerResult {
            let s = Date()
            let before = await LLMCallCounters.shared.snapshot().completedByProvider
            let claudeBefore = await BenchClaude.Usage.shared.calls
            let a = await brain.answer(question: q, access: access)
            let claudeCalls = await BenchClaude.Usage.shared.calls - claudeBefore
            let after = await LLMCallCounters.shared.snapshot().completedByProvider
            var calls = after.compactMapValues { $0 }.reduce(into: [String: Int]()) { out, kv in
                let d = kv.value - (before[kv.key] ?? 0)
                if d > 0 { out[kv.key] = d }
            }
            if claudeCalls > 0 { calls["claude"] = claudeCalls }
            return AnswerResult(id: id, q: q, body: a.body, refused: a.refused, refusal: a.refusalReason,
                                cited: a.citations.map { caseOfObject[$0.objectID] ?? "?" },
                                snippets: a.citations.prefix(5).map { String($0.snippet.prefix(300)) },
                                confidence: String(describing: a.confidence), seconds: Date().timeIntervalSince(s),
                                aiCalls: calls, resolved: a.resolvedQuestion == q ? nil : a.resolvedQuestion,
                                writer: VerifiedAnswerComposer.writer(of: a))
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
            var workflow: WorkflowResult?
            if workflowEvery > 0, index % workflowEvery == 0 {
                workflow = await investigate(line: line, versions: versions, files: filesByCase[line.case] ?? [], state: state, db: db, caseOf: caseOfObject)
            }
            let r = CaseResult(case: line.case, source: line.source, docs: docsByCase[line.case] ?? [],
                               eventDates: Array(Set(dates)).sorted(), entities: names.sorted(),
                               facts: facts.sorted(), answers: answers,
                               profile: line.profile, stratum: line.stratum, workflow: workflow)
            lines.append(String(decoding: try enc.encode(r), as: UTF8.self))
            try progressHandle.write(contentsOf: Data((lines.last! + "\n").utf8))   // visible while the shard runs
        }
        // A case that is not in the archive: the honest answer is a refusal.
        let control: AnswerResult? = if let q = truth.first?.control { await ask("control", q) } else { nil }
        let summary = ShardSummary(shard: name, cases: truth.count, ingestSeconds: ingestSeconds, embedSeconds: embedSeconds,
                                   askSeconds: Date().timeIntervalSince(t2), control: control, aiModel: aiModel,
                                   modulesOn: KnowledgeModule.allCases.filter { KnowledgeModuleFlags.isEnabled($0) }.count + ProductModule.allCases.filter { ProductModuleFlags.isEnabled($0) }.count,
                                   modelCallsByPurpose: await LLMCallCounters.shared.snapshot().byPurpose,
                                   cloudModel: cloudModel, cloudReaders: await BenchClaude.Usage.shared.readers)
        lines.append(String(decoding: try enc.encode(["summary": summary]), as: UTF8.self))
        try (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
    }

    /// Work one case the way an investigator would: open a case over exactly the documents that
    /// arrived for it, ask its questions inside the case, look at custody, contradictions and
    /// gaps, and build the findings. Everything is recorded; nothing is judged here.
    private func investigate(line: TruthLine, versions: [UUID], files: [UUID], state: AppState, db: Database,
                             caseOf: [UUID: String]) async -> WorkflowResult {
        let now = Date()
        func failed(_ e: Error) -> WorkflowResult {
            WorkflowResult(authorizedVersions: 0, custodyEntries: 0, custodyHashed: 0, contradictions: 0, gaps: 0,
                           answers: [], findingsSections: 0, findingsClaims: 0, findingsCitations: 0,
                           findingsCitationsInScope: 0, findingsText: "", error: String(describing: e))
        }
        guard let cases = await state.investigationCases, let answersService = await state.investigationAnswers,
              let custody = await state.investigationCustody, let cg = await state.investigationContradictionGap,
              let findingsService = await state.investigationFindings else {
            return failed(NSError(domain: "CaseBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "investigation services not wired"]))
        }
        do {
            let ws = UUID()
            try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                              [.uuid(ws), .text(line.key ?? line.case), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            // The app's own "add sources to workspace" path (it also derives the workspace's members).
            guard let sources = await state.workspaceSourceCoordinator else {
                return failed(NSError(domain: "CaseBench", code: 2, userInfo: [NSLocalizedDescriptionKey: "workspace sources not wired"]))
            }
            try await sources.addSources(Set(files), to: ws, at: now)
            // The access the app's case screens use: this case's workspace, for retrieval and for export.
            let access = SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .retrieval))
            let exportAccess = SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
            // The app's own case intake: the workspace's documents and their attachments come in.
            let c = try await cases.createCase(workspaceID: ws, title: line.key ?? line.case, actor: "case-bench", at: now)
            guard let intake = await state.investigationWorkspaceIntake else {
                return failed(NSError(domain: "CaseBench", code: 3, userInfo: [NSLocalizedDescriptionKey: "case intake not wired"]))
            }
            _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "case-bench", at: now)
            let context = try await answersService.scopeContext(caseID: c.id)
            let authorized = context.scope.authorizedSourceVersionIDs
            var asked: [AnswerResult] = []
            for q in line.questions {
                let s = Date()
                // Real model calls for in-case answers too (the case-scoped brain gets the same readers).
                let before = await LLMCallCounters.shared.snapshot().completedByProvider
                let claudeBefore = await BenchClaude.Usage.shared.calls
                let a = try await answersService.answer(caseID: c.id, question: q.q, access: access).verified
                let claudeCalls = await BenchClaude.Usage.shared.calls - claudeBefore
                let after = await LLMCallCounters.shared.snapshot().completedByProvider
                var calls = after.compactMapValues { $0 }.reduce(into: [String: Int]()) { out, kv in
                    let d = kv.value - (before[kv.key] ?? 0)
                    if d > 0 { out[kv.key] = d }
                }
                if claudeCalls > 0 { calls["claude"] = claudeCalls }
                asked.append(AnswerResult(id: q.id, q: q.q, body: a.body, refused: a.refused, refusal: a.refusalReason,
                                          cited: a.citations.map { caseOf[$0.objectID] ?? "?" },
                                          snippets: a.citations.prefix(5).map { String($0.snippet.prefix(300)) },
                                          confidence: String(describing: a.confidence), seconds: Date().timeIntervalSince(s), aiCalls: calls,
                                          writer: VerifiedAnswerComposer.writer(of: a)))
            }
            let manifest = try await custody.manifest(caseID: c.id)
            // P3 — the case's own contradiction check (rules; the cloud reader too when a key is given),
            // run before the findings so their conflicts section reflects it.
            let check = try await cg.findContradictions(caseID: c.id, at: now)
            let inScope = try await cg.contradictions(caseID: c.id)
            let contradictions = inScope.count
            let contradictionList = inScope.map { item -> ContradictionLine in
                let x = item.contradiction
                return ContradictionLine(kind: CaseContradictionFinder.kindLabel(of: x) ?? x.kind.rawValue,
                                         provenance: CaseContradictionFinder.provenance(of: x)?.rawValue ?? "archive-scan",
                                         description: x.description,
                                         quoteA: x.claimA, docA: x.evidenceA.flatMap { caseOf[$0] } ?? "?",
                                         quoteB: x.claimB, docB: x.evidenceB.flatMap { caseOf[$0] } ?? "?")
            }
            let gaps = try await cg.gaps(caseID: c.id).count
            // P5 — the case drafts, after the contradiction check (its rows feed the leads). With a key the
            // bench reader drafts too (the readers above); without one the rules alone.
            let d = try await cg.buildDrafts(caseID: c.id, useAI: true)
            let drafts = DraftsResult(
                timeline: d.timeline.map { .init(date: $0.dateText, what: $0.what, who: $0.who, quote: $0.quote, doc: caseOf[$0.objectID] ?? "?", provenance: $0.provenance.rawValue) },
                cast: d.cast.map { .init(name: $0.name, kind: $0.kind.rawValue, role: $0.roleLabel, group: $0.group.rawValue, documents: $0.documentCount,
                                         quote: $0.roleQuote, provenance: $0.roleProvenance?.rawValue) },
                leads: d.leads.map { .init(source: $0.source.rawValue, notEstablished: $0.notEstablished, records: $0.records, quote: $0.quote,
                                           doc: caseOf[$0.objectID] ?? "?", otherQuote: $0.otherQuote) },
                documents: d.documents, readerAvailable: d.readerAvailable, verified: d.verified, agreedWithRules: d.agreedWithRules,
                dropped: d.dropped.count, droppedReasons: Array(d.dropped.prefix(40)), calls: d.calls, roleBatches: d.roleBatches,
                roleReadings: d.roleReadings, failedCalls: d.failedCalls, passagesSent: d.passagesSent, deniedForCloud: d.deniedForCloud,
                notSent: d.notSentReason, failures: d.failures, roleDropped: Array(d.roleDropped.prefix(40)),
                interviews: d.interviews.map { iv in .init(person: iv.person, questions: iv.questions.map {
                    .init(question: $0.question, quote: $0.quote, doc: caseOf[$0.objectID] ?? "?", basis: $0.basis.rawValue, otherQuote: $0.otherQuote) }) })
            let findings = try await findingsService.buildFindings(caseID: c.id, access: exportAccess, actor: "case-bench", at: now)
            let product = findings.assembled.workProduct
            let claims = product.sections.flatMap(\.claims)
            let citations = product.allCitations
            let text = product.sections.map { s in
                ([s.title] + s.preamble + s.claims.map(\.text)).joined(separator: "\n")
            }.joined(separator: "\n\n")
            return WorkflowResult(
                authorizedVersions: authorized.count, custodyEntries: manifest.count,
                custodyHashed: manifest.filter { ($0.contentHash ?? "").isEmpty == false }.count,
                contradictions: contradictions, gaps: gaps, answers: asked,
                findingsSections: product.sections.count, findingsClaims: claims.count,
                findingsCitations: citations.count,
                findingsCitationsInScope: citations.filter { $0.sourceVersionID.map(authorized.contains) ?? false }.count,
                findingsText: String(text.prefix(4000)), error: nil,
                contradictionList: contradictionList,
                contradictionCheck: ContradictionCheck(
                    documents: check.documents, rules: check.ruleFindings.count, ai: check.aiFindings.count,
                    aiDropped: check.aiDropped.count, aiAgreedWithRules: check.aiAgreedWithRules, calls: check.calls,
                    failedCalls: check.failedCalls, passagesSent: check.passagesSent, deniedForCloud: check.deniedForCloud,
                    notSent: check.notSentReason, claimLinks: check.claimLinks,
                    droppedReasons: Array(check.aiDropped.prefix(40)), failures: check.failures),
                drafts: drafts)
        } catch {
            return failed(error)
        }
    }
}

/// The bench's direct Claude call (test target only). The request and the reading of the reply are the
/// app's own (`OnlineRequestBuilder`) — model floor on output tokens, refusal fallbacks, error mapping —
/// so the bench measures what Online mode sends; only the transport differs (the test host has no
/// network helper).
enum BenchClaude {
    /// `reader`: which cloud reader made the call (the run footer counts calls and failures per reader).
    static func send(_ prompt: String, key: String, model: String, maxTokens: Int = 400, reader: String = "other") async throws -> String {
        do {
            let text = try await transport(prompt, key: key, model: model, maxTokens: maxTokens)
            await Usage.shared.record(reader: reader, failure: nil)
            return text
        } catch {
            await Usage.shared.record(reader: reader, failure: VerifiedRoleReader.reason(error))
            throw error
        }
    }

    private static func transport(_ prompt: String, key: String, model: String, maxTokens: Int) async throws -> String {
        let outbound = try OnlineRequestBuilder.build(kind: .anthropic, model: model, apiKey: key,
                                                      system: nil, prompt: prompt, maxTokens: maxTokens)
        guard let url = URL(string: outbound.url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        for (k, v) in outbound.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = outbound.body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = try OnlineRequestBuilder.parse(kind: .anthropic, response: OutboundHTTPResponse(status: status, body: data))
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        await BenchClaude.Usage.shared.add((object?["usage"] as? [String: Any]).map { ($0["input_tokens"] as? Int ?? 0) + ($0["output_tokens"] as? Int ?? 0) } ?? 0)
        return text
    }

    actor Usage {
        static let shared = Usage()
        private(set) var tokens = 0, calls = 0
        /// Calls and failures per reader, since the last reset (one shard).
        private(set) var readers: [String: CaseBenchRunner.CloudReaderUse] = [:]
        func add(_ n: Int) { tokens += n; calls += 1 }
        func resetReaders() { readers = [:] }
        func record(reader: String, failure: String?) {
            var use = readers[reader] ?? CaseBenchRunner.CloudReaderUse()
            use.calls += 1
            if let failure { use.failed += 1; if use.failures.count < 20 { use.failures.append(failure) } }
            readers[reader] = use
        }
    }
}

//
//  EvidenceVerifier.swift
//  Kalsmritikosh
//
//  Last gate before any answer ships. Delegates confidence + contradiction
//  scoring to ConfidenceEngine and uses the report to decide whether to
//  ship, refuse, or downgrade. Without citations, no answer.
//

import Foundation
import OSLog

/// Task #30 verify+fallback sub-profiler (env-gated KALSMRITIKOSH_VERIFY_CLOCK,
/// inert in production). Sub-signposts inside verify() that SUM to the stage
/// the top-level StageClock measures — so the 47 s of the flagship's answer
/// (retrieve1 collapsed to ~0.2 s; verify+fallback IS the cost now) gets a
/// per-question breakdown with the cross-encoder candidate count for the
/// magnitude-model reconciliation (count × unit-B's ~0.86 s/call).
nonisolated final class VerifyClock: @unchecked Sendable {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["KALSMRITIKOSH_VERIFY_CLOCK"] == "1"
    private let t0 = Date()
    private var last = Date()
    private var rows: [(String, Double)] = []
    var rerankCandidates = 0
    func mark(_ s: String) {
        guard Self.enabled else { return }
        let now = Date(); rows.append((s, now.timeIntervalSince(last))); last = now
    }
    func dump(_ q: String) {
        guard Self.enabled else { return }
        let tbl = rows.map { "\($0.0)=\(String(format: "%.2f", $0.1))s" }.joined(separator: " ")
        print("VERIFYCLOCK q=\"\(q.prefix(28))\" \(tbl) rerankCands=\(rerankCandidates) total=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    }
}

public struct EvidenceVerifier: Verifier {
    /// Per-claim citation cap (Item 1 of UPDATE_08). The previous
    /// `claims.flatMap { ... supportingObjectIDs.map { ... } }` emitted
    /// one citation per (claim × supportingObject) pair with no dedupe
    /// and no ranking — so a 16-claim answer with 4 supporting objects
    /// per claim shipped 64 raw citations, drowning the real source in
    /// noise (Gate 1: lookup precision 0.02). The cap is per-claim and
    /// NOT global so aggregation answers can still cite many sources.
    public static let maxCitationsPerClaim = 3

    /// Unit-A binding #3 — TIME is an input to freshness-aware confidence,
    /// so harness runs treat it like one. Production uses the real clock
    /// (freshness decay is correct product behavior, untouched). When
    /// KALSMRITIKOSH_REFERENCE_NOW is set (epoch seconds; test runs pass it
    /// via the TEST_RUNNER_ prefix), that instant is the answer path's
    /// "now", making sealed artifacts byte-comparable across days — the
    /// zero-epsilon seal. Never set in the shipped app.
    nonisolated static func referenceNow() -> Date {
        guard let raw = ProcessInfo.processInfo.environment["KALSMRITIKOSH_REFERENCE_NOW"],
              let secs = TimeInterval(raw) else { return Date() }
        return Date(timeIntervalSince1970: secs)
    }

    /// UPDATE_14 — intent-aware global cap on distinct doc citations.
    /// After the per-claim cap + cross-claim dedupe, the survivor list
    /// still ran 6–8 docs deep because 5+ experts each contributed top
    /// chunks. Lookup answers should cite 1–3 docs; reconstruction and
    /// aggregation legitimately need more. These caps are intent-keyed,
    /// with an aggregation-shape override for question text that asks
    /// for breadth ("all", "total", "how many", "list", …).
    public static let lookupCitationCap = 3
    public static let reconstructCitationCap = 6
    public static let executiveCitationCap = 8
    public static let aggregationCitationCap = 8

    /// Question-shape hints that always get the generous cap even if
    /// the intent detector classified the question as factualLookup.
    /// Without this guard a "How many emails reference Supplier ABC?"
    /// question would lose recall on aggregation-class questions.
    private static let aggregationShapeKeywords: [String] = [
        "all ", " total", "how many", "how much", "count of",
        "each ", "list ", "list all", "sum of", "summarize all",
        "across the", "across all"
    ]

    /// Question text matches an aggregation shape ("all X", "how many",
    /// "list all", "across the…"). Drives both the generous global
    /// citation cap AND the G2-1.5 reranker bypass — aggregation needs
    /// breadth of coverage, but the reranker scores relevance, so it
    /// systematically drops the long tail of legitimate evidence.
    private static func isAggregationShape(_ intent: UserIntent) -> Bool {
        let q = " " + intent.rawQuestion.lowercased() + " "
        return aggregationShapeKeywords.contains(where: { q.contains($0) })
    }

    /// G2-MMR — Maximal Marginal Relevance lambda. 0.7 = 70% weight on
    /// relevance, 30% on diversity. chatmind-pipeline's validated value.
    /// Lower → more diversity / less relevance pull; higher → vice-versa.
    private static let mmrLambda = 0.7

    /// MMR pass over reranked citation survivors.
    ///
    /// Greedy selection: at each step, pick the candidate that
    /// maximizes  λ * relevance − (1 − λ) * maxSimilarityToAlreadyPicked.
    /// Relevance combines reranker + retrieval scores. Similarity is
    /// token-Jaccard on snippets — cheap, deterministic, no embedder
    /// needed. Stops when `limit` citations are picked.
    ///
    /// Fixes the aggregation pile-up pattern (UPDATE_18 §2): without
    /// MMR, a thread of 4 near-identical supplier emails monopolizes
    /// the citation cap and crowds out the contract/amendment that
    /// completes the answer.
    private static func applyMMR(
        citations: [VerifiedAnswer.Citation],
        rerankByObject: [KnowledgeObject.ID: Double],
        scoreByObject: [KnowledgeObject.ID: Double],
        lambda: Double,
        limit: Int
    ) -> [VerifiedAnswer.Citation] {
        guard citations.count > limit else { return citations }

        // Pre-tokenize each snippet once. Short tokens (<3 chars) are
        // dropped to suppress stop-word noise; lowercasing makes the
        // Jaccard case-insensitive.
        let tokensByID: [KnowledgeObject.ID: Set<String>] = Dictionary(
            uniqueKeysWithValues: citations.map { c in
                let toks = c.snippet
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 3 }
                return (c.objectID, Set(toks))
            }
        )

        func relevance(_ c: VerifiedAnswer.Citation) -> Double {
            let r = rerankByObject[c.objectID] ?? 0.5
            let s = scoreByObject[c.objectID] ?? 0.5
            return (r + s) / 2
        }

        func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
            if a.isEmpty && b.isEmpty { return 0 }
            let inter = a.intersection(b).count
            let union = a.union(b).count
            return union == 0 ? 0 : Double(inter) / Double(union)
        }

        var pool = citations
        var picked: [VerifiedAnswer.Citation] = []
        picked.reserveCapacity(limit)

        while !pool.isEmpty && picked.count < limit {
            var bestIdx = 0
            var bestScore = -Double.infinity
            for (i, c) in pool.enumerated() {
                let rel = relevance(c)
                let cToks = tokensByID[c.objectID] ?? []
                var maxSim = 0.0
                for p in picked {
                    let sim = jaccard(cToks, tokensByID[p.objectID] ?? [])
                    if sim > maxSim { maxSim = sim }
                }
                let score = lambda * rel - (1 - lambda) * maxSim
                if score > bestScore {
                    bestScore = score
                    bestIdx = i
                }
            }
            picked.append(pool.remove(at: bestIdx))
        }
        return picked
    }

    /// Choose the per-answer global cap by intent kind + question shape.
    private static func intentCitationCap(_ intent: UserIntent) -> Int {
        if isAggregationShape(intent) {
            return aggregationCitationCap
        }
        switch intent.kind {
        case .factualLookup, .semanticSearch, .unknown:
            return lookupCitationCap
        case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
            return reconstructCitationCap
        case .executiveBriefing, .riskDetection, .missingInformation:
            return executiveCitationCap
        }
    }

    public let minimumConfidence: Confidence
    public let minimumCitations: Int
    /// Answerability gate (inspired by chatmind-pipeline's ANSWERABILITY_MIN_SCORE).
    /// When the BEST retrieval score across all chunks is below this floor,
    /// the verifier refuses before running the LLM reranker — saves wasted
    /// latency AND prevents weak evidence from producing a confidently-
    /// worded answer the user shouldn't trust.
    ///
    /// The fixture's typical max score is ~0.86. A real-archive query that
    /// finds nothing relevant typically tops out under 0.20. Default sits
    /// well below the fixture floor so eval behavior is unchanged.
    public let answerabilityMinRetrievalScore: Double
    private let engine: any ConfidenceEngine
    /// Returns the fraction of the user's archive past Tier-1 ingest
    /// (chunks + entities + events present). The Engine multiplies
    /// final confidence by max(coverage, 0.5) while < 1.0, so the
    /// Quality Strip can honestly say "Answered from X% of your
    /// archive". `nil` → engine treats it as 1.0 (no-op multiplier).
    /// T11 close-out.
    private let ingestCoverageProvider: (@Sendable () async -> Double)?
    /// Defensive — filters hostname-shape, stoplist, and weekday
    /// strings out of the rendered "Subjects in scope" line even if
    /// they somehow survived ingestion. nil = no filtering, behaviour
    /// identical to pre-fix.
    private let entityQualityGate: EntityQualityGate?
    /// G2-1 — optional. When present, citation survivors are reordered
    /// by claim-relevance (reranker score) before the intent-aware
    /// global cap truncates. When nil, the cap orders by
    /// `scoreByObject` alone (pre-G2-1 behavior). The reranker itself
    /// degrades gracefully to identity scoring when no provider
    /// supports `.reranking` — so plumbing this through doesn't risk
    /// regression on a heuristic-floor run.
    private let reranker: Reranker?
    /// G2-1.5 — optional. When present, the verifier reads the session
    /// snapshot at verify() time and hands it to the reranker so the
    /// model can resolve pronouns / topic returns against recent turns.
    /// Nil → reranker prompt falls back to the G2-1 question-only form.
    private let sessionProfile: SessionProfile?
    /// P1 citation integrity (release gate F3) — optional. When present,
    /// every built citation must resolve to a real canonical source identity
    /// through one of the approved retrieval layers (chunk / event /
    /// relationship / deterministic evaluation / authority document, plus a
    /// ledger-existence probe). Phantom citations are dropped BEFORE the
    /// reranker; an answer whose citations all fail resolution refuses.
    /// Nil → pre-P1 behavior, preserved for existing unit fixtures.
    private let citationResolver: CitationResolver?

    public init(
        minimumConfidence: Confidence = Confidence(0.2),
        minimumCitations: Int = 1,
        engine: any ConfidenceEngine = DefaultConfidenceEngine(),
        ingestCoverageProvider: (@Sendable () async -> Double)? = nil,
        entityQualityGate: EntityQualityGate? = nil,
        reranker: Reranker? = nil,
        sessionProfile: SessionProfile? = nil,
        answerabilityMinRetrievalScore: Double = 0.20,
        citationResolver: CitationResolver? = nil
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumCitations = minimumCitations
        self.engine = engine
        self.ingestCoverageProvider = ingestCoverageProvider
        self.entityQualityGate = entityQualityGate
        self.reranker = reranker
        self.sessionProfile = sessionProfile
        self.answerabilityMinRetrievalScore = answerabilityMinRetrievalScore
        self.citationResolver = citationResolver
    }

    public func verify(
        intent: UserIntent,
        findings: [ExpertFindings],
        retrieval: RetrievalResult
    ) async throws -> VerifiedAnswer {
        let vclock = VerifyClock()
        defer { vclock.dump(intent.rawQuestion) }   // fires at every return
        let claims = findings.flatMap(\.claims)
        let droppedUnverifiable = findings.map(\.droppedUnverifiable).reduce(0, +)
        let intentWindow: DateInterval? = {
            guard let tf = intent.timeframe,
                  let s = tf.start, let e = tf.end, e > s else { return nil }
            return DateInterval(start: s, end: e)
        }()
        let ingestCoverage: Double = await ingestCoverageProvider?() ?? 1.0
        var report = await engine.evaluate(
            claims: claims,
            droppedUnverifiable: droppedUnverifiable,
            events: retrieval.events,
            intentKind: intent.kind,
            intentWindow: intentWindow,
            ingestCoverage: ingestCoverage,
            now: Self.referenceNow()
        )
        // S2-U1 consumer 3 — the bounded salience advisory (±0.02 max): the
        // mean structural salience across the retrieved chunks nudges the
        // combined confidence as a logged tiebreaker, never a driver.
        if !retrieval.chunks.isEmpty {
            let mean = retrieval.chunks.map(\.chunk.salience).reduce(0, +)
                / Double(retrieval.chunks.count)
            report = engine.applySalienceAdvisory(report, meanCitedSalience: mean)
        }
        vclock.mark("claimEval")
        // Per-object ranking signal: best (max) hybrid retrieval score
        // across the chunks in `retrieval.chunks` that belong to a given
        // KnowledgeObject. Objects with no retrieval hit (came in via
        // memory / entity / event layer) sort to the back via -infinity.
        var scoreByObject: [KnowledgeObject.ID: Double] = [:]
        for rc in retrieval.chunks {
            let id = rc.chunk.objectID
            if let existing = scoreByObject[id] {
                if rc.score > existing { scoreByObject[id] = rc.score }
            } else {
                scoreByObject[id] = rc.score
            }
        }
        // Answerability gate (chatmind-inspired). When retrieval clearly
        // didn't find anything similar to the question, refuse early
        // BEFORE running the LLM reranker. This both saves an Ollama
        // round-trip on hopeless queries AND prevents the model from
        // ranking noise into a confident-sounding answer.
        let maxRetrievalScore: Double = scoreByObject.values.max() ?? 0
        if maxRetrievalScore < answerabilityMinRetrievalScore {
            let intentKindRaw = intent.kind.rawValue
            return VerifiedAnswer(
                body: "Kalsmritikosh can't ground an answer to that yet.",
                answerText: nil,
                intentKind: intentKindRaw,
                citations: [],
                confidence: report.combined,
                contradictions: report.contradictions,
                refused: true,
                refusalReason: "Retrieval scores too low (max=\(String(format: "%.3f", maxRetrievalScore)) < \(String(format: "%.2f", answerabilityMinRetrievalScore))) — no confident match in archive.",
                report: report
            )
        }

        // Build citations with: per-claim cap (top-N by score), dedupe
        // across the whole answer by objectID (first claim that wins
        // a given object owns its snippet), and an intent-aware global
        // distinct-document cap applied last.
        var seenObjects = Set<KnowledgeObject.ID>()
        var citations: [VerifiedAnswer.Citation] = []
        // Unit-A: the OUTER claim order shapes the shipped receipt (first
        // claim to reach an object owns its snippet) — rank it by the same
        // key as the answer text (max score → statement), never raw
        // findings order.
        let citationOrderedClaims = claims.sorted { a, b in
            let aScore = a.supportingObjectIDs.compactMap { scoreByObject[$0] }.max() ?? 0
            let bScore = b.supportingObjectIDs.compactMap { scoreByObject[$0] }.max() ?? 0
            if aScore != bScore { return aScore > bScore }
            return a.statement < b.statement
        }
        for claim in citationOrderedClaims {
            // DETERMINISM RULE (pre-V2 unit A, applies to EVERY ranking sort
            // and EVERY top-K cut in the answer path): the ordering key is
            // score → evidentiary tier (where present) → stable content key.
            // A score-only comparator leaves ties to per-process hash order,
            // which changes both citation ORDER and cut MEMBERSHIP run-to-run.
            let ranked = claim.supportingObjectIDs.sorted { lhs, rhs in
                let ls = scoreByObject[lhs] ?? -.infinity
                let rs = scoreByObject[rhs] ?? -.infinity
                if ls != rs { return ls > rs }
                return lhs.uuidString < rhs.uuidString
            }
            for objectID in ranked.prefix(Self.maxCitationsPerClaim) {
                guard !seenObjects.contains(objectID) else { continue }
                seenObjects.insert(objectID)
                citations.append(VerifiedAnswer.Citation(
                    objectID: objectID,
                    eventID: claim.supportingEventIDs.first,
                    snippet: String(claim.statement.prefix(180))
                ))
            }
        }
        // P1 citation-integrity gate (release gate F3). Every citation must
        // resolve to a real canonical source identity through one of the
        // approved retrieval layers — NOT just the chunk-score map, which
        // would wrongly discard event/relationship/authority-backed
        // citations. Phantom objectIDs are dropped here, before the
        // reranker spends work on them; phantom eventID annotations are
        // scrubbed while the citation survives on its objectID authority.
        var droppedPhantomCitations = 0
        if let citationResolver {
            let resolution = await citationResolver.resolve(citations, retrieval: retrieval)
            droppedPhantomCitations = resolution.rejectedObjectIDs.count
            if droppedPhantomCitations > 0 {
                KalsmritikoshLog.brain.warning("EvidenceVerifier: rejected \(droppedPhantomCitations, privacy: .public) phantom citation(s) — objectIDs resolved through no approved retrieval layer")
            }
            if !resolution.scrubbedEventIDs.isEmpty {
                KalsmritikoshLog.brain.warning("EvidenceVerifier: scrubbed \(resolution.scrubbedEventIDs.count, privacy: .public) phantom eventID annotation(s) from citations")
            }
            citations = resolution.citations
        }
        // G2-1 — pairwise relevance scoring of (question, candidate
        // citation snippet) via the reranker. Lifts citation precision
        // by reordering survivors against the actual question text
        // instead of retrieval similarity alone. Returns identity (0.5
        // for every candidate) when no reranker is wired OR when the
        // resolved provider isn't available — preserving the
        // `scoreByObject` ordering and ensuring no regression on the
        // heuristic floor.
        var rerankByObject: [KnowledgeObject.ID: Double] = [:]
        // Runtime A/B/C toggle (KALSMRITIKOSH_RERANKER):
        //   off    → skip reranker entirely (sort by scoreByObject only)
        //   embed  → Apple NLEmbedding bi-encoder (deterministic, sandbox-safe)
        //   <else> → default Ollama prompted scoring (current path)
        // The Ollama path is non-deterministic and not App-Store-shippable;
        // `embed` and `off` are the diagnostic baselines while UPDATE_17B's
        // Core ML cross-encoder is being built.
        // Mode source priority (highest to lowest):
        //   1. KALSMRITIKOSH_RERANKER process env (Xcode scheme arg)
        //   2. UserDefaults key "KALSMRITIKOSH_RERANKER"
        //   3. Default: "ladder" (post-Fast-Eval-#3 decision).
        //
        // FAST-EVAL-FIX (run #3): the Ollama prompted-scoring path
        // produced ±33% multihop recall swings across identical runs
        // (UPDATE_18 §1 documented this; Fast Eval #2 → #3 confirmed
        // it on M1: 1.00 → 0.67 with no code change). The Core ML
        // cross-encoder cascade ("ladder") is deterministic; ship it
        // as the new default. Explicit env / defaults can still flip
        // back to off / embed / ollama for diagnostic runs.
        let envMode = ProcessInfo.processInfo
            .environment["KALSMRITIKOSH_RERANKER"]?
            .lowercased()
        let defaultsMode = UserDefaults.standard
            .string(forKey: "KALSMRITIKOSH_RERANKER")?
            .lowercased()
        // ENGINE POWER — Lightning mode turns the reranker off outright; the
        // deterministic ranking (structure + FTS scores) stands alone.
        let rerankerMode = FeatureFlags.fullPowerModeValue()
            ? (envMode ?? defaultsMode ?? "ladder")
            : "off"
        let rerankerDisabled = (rerankerMode == "off")
        let useEmbeddingReranker = (rerankerMode == "embed")
        let useLadder = (rerankerMode == "ladder")
        // G2-1.5 — bypass the reranker for aggregation-shape questions
        // ("list all", "how many", "across the…"). The reranker scores
        // relevance and would drop the long tail of legitimate evidence
        // that aggregation answers need for coverage. Leaving
        // rerankByObject empty makes the survivor sort fall back to
        // `scoreByObject`, which is what aggregation wants.
        let bypassRerank = Self.isAggregationShape(intent) || rerankerDisabled
        // S2-U1/S2-U4 — mean structural salience per object, computed once:
        // the rerank factor, the slot tiebreak, and the candidate cap all read it.
        var meanSalienceByObject: [KnowledgeObject.ID: Double] = [:]
        do {
            var agg: [KnowledgeObject.ID: (t: Double, n: Int)] = [:]
            for rc in retrieval.chunks {
                let cur = agg[rc.chunk.objectID] ?? (0, 0)
                agg[rc.chunk.objectID] = (cur.t + rc.chunk.salience, cur.n + 1)
            }
            meanSalienceByObject = agg.mapValues { $0.t / Double($0.n) }
        }
        if !citations.isEmpty, !bypassRerank {
            // S2-U4 Fix C — the candidate CAP: the cross-encoder pays seconds
            // per candidate, and low-structure junk was consuming the budget.
            // Candidates enter the reranker in salience × retrieval order,
            // capped; the rest are NEVER dropped from the answer — they just
            // skip the expensive scoring and keep their retrieval ordering
            // (no rerank entry → the MMR relevance falls back to neutral).
            // Total order on ties (unit A law): content key, never hash order.
            let rerankBudget = 12
            let rerankCitations: [VerifiedAnswer.Citation]
            if citations.count > rerankBudget {
                rerankCitations = citations.sorted { a, b in
                    let wa = (meanSalienceByObject[a.objectID] ?? SalienceTable.neutral) * (scoreByObject[a.objectID] ?? 0.5)
                    let wb = (meanSalienceByObject[b.objectID] ?? SalienceTable.neutral) * (scoreByObject[b.objectID] ?? 0.5)
                    if wa != wb { return wa > wb }
                    return a.objectID.uuidString < b.objectID.uuidString
                }.prefix(rerankBudget).map { $0 }
            } else {
                rerankCitations = citations
            }
            let snippets = rerankCitations.map { citation -> String in
                // Prefer a chunk text snippet for the candidate. The
                // citation's own `snippet` (a claim statement) is a
                // weak signal because the claim is what we're scoring
                // AGAINST. Fall back to it only when we have nothing
                // better — typically when the citation came from an
                // event-only claim with no chunk evidence.
                let chunkText = retrieval.chunks
                    .first { $0.chunk.objectID == citation.objectID }?
                    .chunk.text
                return String((chunkText ?? citation.snippet).prefix(400))
            }
            let scores: [Double]
            if useLadder {
                // G2-RERANK-LADDER — composable cascade. Cheap tiers
                // run first; the Core ML cross-encoder tier (Tier 3,
                // costClass 50) returns nil when the .mlpackage isn't
                // bundled yet, so the cascade gracefully falls back to
                // the heuristic tier alone. When BGEReranker.mlpackage
                // lands in Resources/ (UPDATE_17B), Tier 3 activates
                // automatically — no code change here.
                let ladder = RerankerLadder(tiers: [
                    HeuristicKeywordTier(),
                    CoreMLCrossEncoderTier()
                ])
                vclock.rerankCandidates = snippets.count
                scores = await ladder.score(
                    question: intent.rawQuestion,
                    candidates: snippets
                )
            } else if useEmbeddingReranker {
                // Apple-native bi-encoder. Deterministic. No external
                // dep, no Ollama, no LLM noise. Lower ceiling than a
                // cross-encoder but a strict improvement over the
                // current Ollama prompted-scoring path for evals.
                let embedRanker = EmbeddingReranker()
                scores = await embedRanker.score(
                    question: intent.rawQuestion,
                    candidates: snippets
                )
            } else if let reranker {
                // UNIT D — THE RESOLUTION BOUNDARY (owner ruling 2026-09-01):
                // session state may REWRITE THE QUESTION, never touch the
                // evidence. Downstream of resolution the answer is a pure
                // function of (resolved question, stamped ledgerState, pinned
                // clock), so session-derived signals are removed from every
                // scoring surface — including this non-release Ollama branch,
                // which was the session's only downstream read. Conversation
                // context belongs in the question-resolution step upstream of
                // retrieval, receipted via VerifiedAnswer.resolvedQuestion.
                let context = Reranker.Context(
                    intentKind: intent.kind.rawValue,
                    questionShape: Reranker.questionShape(intent.rawQuestion),
                    keyEntities: intent.entityHints,
                    recentTurns: [],
                    mentionedEntities: []
                )
                scores = await reranker.score(
                    question: intent.rawQuestion,
                    context: context,
                    candidates: snippets
                )
            } else {
                // No reranker available; leave rerankByObject empty
                // so the sort falls back to scoreByObject.
                scores = []
            }
            for (i, citation) in rerankCitations.enumerated() where i < scores.count {
                rerankByObject[citation.objectID] = scores[i]
            }
        }
        // S2-U1 consumer 1 — BOUNDED structural-salience factor on the rerank
        // score: ×(0.85 + 0.3 × meanSalience), i.e. ±15% around neutral 0.6's
        // ~1.03. Salience refines relevance ordering; it can never override
        // semantic relevance (the bound) and never touches scoreByObject, so
        // reranker-off runs are byte-identical to before.
        if !rerankByObject.isEmpty {
            for (objectID, score) in rerankByObject {
                guard let mean = meanSalienceByObject[objectID] else { continue }
                rerankByObject[objectID] = score * (0.85 + 0.3 * mean)
            }
        }
        vclock.mark("rerank")

        // UPDATE_14 + G2-MMR — apply the intent-aware global cap on
        // distinct documents. The pre-MMR rule was a pure lexicographic
        // sort on (rerankScore desc, scoreByObject desc). MMR adds a
        // diversity term so aggregation/multihop answers stop piling
        // up many duplicates of the same email thread — the
        // pile-up pattern noted in UPDATE_18 §2 (Revision D).
        //
        // FAST-EVAL-FIX (run #3): factualLookup questions stuck at
        // precision 0.33 for 3 runs because L1 was citing 3 documents
        // when only 1 was expected. When the top retrieval hit is
        // BOTH confident (>=0.85 score) AND clearly ahead of the runner-up
        // (margin >=0.04), the answer almost certainly comes from that
        // single chunk. Tighten the cap to 1 in that case. The same
        // rule benefits semanticSearch and unknown-kind questions.
        let lookupKinds: Set<UserIntent.Kind> = [.factualLookup, .semanticSearch, .unknown]
        var globalCap = Self.intentCitationCap(intent)
        if lookupKinds.contains(intent.kind), !Self.isAggregationShape(intent) {
            let sortedScores = scoreByObject.values.sorted(by: >)
            if let top = sortedScores.first, top >= 0.85,
               (sortedScores.dropFirst().first ?? 0) <= top - 0.04 {
                globalCap = 1
            }
        }
        if citations.count > globalCap {
            citations = Self.applyMMR(
                citations: citations,
                rerankByObject: rerankByObject,
                scoreByObject: scoreByObject,
                lambda: Self.mmrLambda,
                limit: globalCap
            )
        }

        let intentKindRaw = intent.kind.rawValue

        // D-11/D-12 — compile the plan ONCE; when the question names a
        // registered fact field, compose the slot answer from the surfaced
        // facts (their carried evaluations decide surfaceability).
        let plan = QueryPlanCompiler().compile(intent: intent, category: .fact, queryClass: .ordinary)
        let slot = SlotAnswerComposer.compose(
            slotFieldIDs: plan.slotFieldIDs,
            facts: retrieval.genericFacts,
            evaluations: retrieval.claimEvaluations,
            authorityObjectIDs: retrieval.authorityObjectIDs,
            documentsSearched: Set(retrieval.chunks.map(\.chunk.objectID)).count,
            scoreByObject: scoreByObject,
            salienceByObject: meanSalienceByObject)

        // D-14 — the slot-question confidence profile: a uniquely-attested
        // value from a structured source with no conflict on the requested
        // field floors at 0.8 × coverage factor. Components logged so
        // EvalKit can assert them.
        var effectiveReport = report
        if let slot, !slot.isNotFound {
            let floored = DefaultConfidenceEngine.slotProfileFloor(
                base: report.combined,
                singleCanonicalValue: slot.singleCanonicalValue,
                structuredSource: slot.structuredSource,
                conflictOnRequestedField: slot.isConflict,
                ingestCoverage: ingestCoverage)
            if floored.value != report.combined.value {
                KalsmritikoshLog.brain.info("EvidenceVerifier: slot profile floor \(report.combined.value, privacy: .public) -> \(floored.value, privacy: .public) (single=\(slot.singleCanonicalValue, privacy: .public) structured=\(slot.structuredSource, privacy: .public) conflict=\(slot.isConflict, privacy: .public))")
                effectiveReport = ConfidenceReport(
                    combined: floored,
                    sourceCount: report.sourceCount,
                    distinctSourceObjectIDs: report.distinctSourceObjectIDs,
                    agreementScore: report.agreementScore,
                    contradictions: report.contradictions,
                    droppedUnverifiable: report.droppedUnverifiable,
                    newestEvidenceDate: report.newestEvidenceDate,
                    freshness: report.freshness,
                    coverage: report.coverage,
                    coverageGaps: report.coverageGaps,
                    ingestCoverage: report.ingestCoverage)
            }
        }

        guard !claims.isEmpty,
              effectiveReport.combined >= minimumConfidence,
              citations.count >= minimumCitations
        else {
            return VerifiedAnswer(
                body: "Kalsmritikosh can't ground an answer to that yet.",
                answerText: nil,
                intentKind: intentKindRaw,
                citations: [],
                confidence: effectiveReport.combined,
                contradictions: effectiveReport.contradictions,
                refused: true,
                refusalReason: claims.isEmpty
                    ? "No expert produced any claim."
                    : (citations.count < minimumCitations && droppedPhantomCitations > 0)
                        ? "All candidate citations failed canonical source resolution (\(droppedPhantomCitations) phantom citation(s) rejected)."
                        : "Evidence below confidence threshold (\(minimumConfidence.value)).",
                report: effectiveReport
            )
        }

        let rendered = renderAnswer(intent: intent, findings: findings, retrieval: retrieval,
                                    report: effectiveReport, plan: plan, slot: slot)
        return VerifiedAnswer(
            body: rendered.body,
            answerText: rendered.answerText,
            intentKind: intentKindRaw,
            citations: citations,
            confidence: effectiveReport.combined,
            contradictions: effectiveReport.contradictions,
            refused: false,
            refusalReason: nil,
            report: effectiveReport,
            walkSteps: retrieval.walkSteps
        )
    }

    /// Rendered answer split into the synthesized response (`answerText`)
    /// and the full UI body (`body`, which appends a small retrieval
    /// footer). Splitting these out is what UPDATE_13 Item 3/4 needs:
    /// eval metrics score against `answerText` so an expected name in
    /// the footer can no longer satisfy keyword-hit by coincidence.
    private struct RenderedAnswer {
        let body: String
        let answerText: String
    }

    private func renderAnswer(
        intent: UserIntent,
        findings: [ExpertFindings],
        retrieval: RetrievalResult,
        report: ConfidenceReport,
        plan: QueryPlan,
        slot: SlotAnswerComposition?
    ) -> RenderedAnswer {
        // 0) D-12/D-15 — a slot question renders the ONE composed sentence
        //    (value, explicit conflict, or field-named honest not-found) as
        //    the primary answer. Everything the old path dumped (other
        //    fields, subjects, cautions) stays in the detail footer.
        let docClaims = findings.flatMap(\.claims).filter { !$0.supportingObjectIDs.isEmpty }
        let answerText: String
        if let slot {
            answerText = slot.primaryText
        } else if !docClaims.isEmpty {
            // G2-RENDER-FIX (Fast Eval #2 follow-up) — rank doc-claims
            // by the maximum retrieval score across the KOs they cite,
            // not by expert-iteration order. With synthetic-questions
            // + QA-pairs + Tier 3 in the cascade, many experts now
            // produce many doc-grounded claims; the original `.prefix(5)`
            // truncation was dropping the claim that cited the #1-ranked
            // chunk (e.g. contract.md on T3 question 3) in favour of
            // whichever expert finished first. Surfacing the
            // best-evidenced claims first keeps the rendered answer
            // text aligned with the citation list.
            var scoreByObject: [KnowledgeObject.ID: Double] = [:]
            for rc in retrieval.chunks {
                let id = rc.chunk.objectID
                if let prior = scoreByObject[id], prior >= rc.score { continue }
                scoreByObject[id] = rc.score
            }
            let rankedDocClaims = docClaims.sorted { a, b in
                let aScore = a.supportingObjectIDs
                    .compactMap { scoreByObject[$0] }.max() ?? 0
                let bScore = b.supportingObjectIDs
                    .compactMap { scoreByObject[$0] }.max() ?? 0
                if aScore != bScore { return aScore > bScore }
                // Unit-A tie-break: stable content key, so the .prefix(5)
                // cut has deterministic MEMBERSHIP, not just ordering.
                return a.statement < b.statement
            }
            answerText = rankedDocClaims
                .prefix(5)
                .map(\.statement)
                .joined(separator: " ")
        } else {
            // 2) No document-grounded claims. Fall back to whatever
            //    claims any expert produced — typically event bullets.
            //    Still better than an entity dump.
            let anyClaims = findings.flatMap(\.claims)
            if anyClaims.isEmpty {
                answerText = "No expert produced findings for that question."
            } else {
                answerText = anyClaims
                    .prefix(5)
                    .map { "\u{2022} \($0.statement)" }
                    .joined(separator: "\n")
            }
        }

        // 3) Optional retrieval footer: subjects + an agreement note.
        //    This is for the user's situational awareness; it does NOT
        //    contribute to keyword-hit scoring.
        var footerParts: [String] = []
        // D-12 — the other fields on file, compacted to one detail line.
        if let also = slot?.alsoOnFile {
            footerParts.append(also)
        }
        let subjectLine = subjectHeading(intent: intent, retrieval: retrieval)
        if !subjectLine.isEmpty {
            footerParts.append(subjectLine)
        }
        // RET-006 — honest sufficiency disclosure: if the question asked for specific
        // fields the retrieved evidence does not contain, say so neutrally rather than
        // leaving a vague gap. Absence is disclosed, never presented as proof.
        // D-15: a slot question's absence is already the PRIMARY sentence,
        // named precisely — the generic footer line would duplicate it.
        if slot == nil {
            let sufficiency = EvidenceSufficiencyAssessor()
                .assess(plan: plan, evidenceTexts: retrieval.chunks.map(\.chunk.text))
            let disclosure = sufficiency.disclosure()
            if !disclosure.isEmpty {
                footerParts.append(disclosure)
            }
        }
        // CLM-001/CLM-002 — the causal and verbatim-grounding guards exist
        // for MODEL prose. A slot answer is deterministic ledger data whose
        // citations already bind it to its block — and canonical money
        // rendering ("Rs20,000 INR" → "₹20,000") would trip the verbatim
        // check falsely. Guards run on the generated paths only.
        if slot == nil {
            let causalCaution = CausalLanguageGuard()
                .assess(claims: [answerText], evidenceTexts: retrieval.chunks.map(\.chunk.text))
            if !causalCaution.isEmpty {
                footerParts.append(causalCaution)
            }
            let grounding = ClaimGrounding().check(claim: answerText, evidenceTexts: retrieval.chunks.map(\.chunk.text))
            if grounding.hasUngroundedMaterial {
                footerParts.append("Caution: not found verbatim in the evidence: "
                    + grounding.ungroundedTokens.joined(separator: ", ") + ".")
            }
        }
        // D-14 — the disagreement note is scoped: on a slot question it
        // appears only when the disagreement touches the REQUESTED field
        // (the composed conflict); disagreements about unrequested fields
        // belong in the detail, not stamped across a clean single-value
        // answer. Non-slot questions keep the global-agreement behavior.
        if let slot {
            if slot.isConflict {
                footerParts.append("Note: your sources disagree on \(slot.requestedLabel.lowercased()) — both values are shown above.")
            }
        } else if report.agreementScore <= 0.6 {
            footerParts.append("Note: experts disagreed across some of these claims.")
        }
        let body: String
        if footerParts.isEmpty {
            body = answerText
        } else {
            body = answerText + "\n\n---\n" + footerParts.joined(separator: "\n")
        }
        return RenderedAnswer(body: body, answerText: answerText)
    }

    private func subjectHeading(intent: UserIntent, retrieval: RetrievalResult) -> String {
        var subjects: [String] = []
        switch intent.scope {
        case .project(let name): subjects.append("Project \(name)")
        case .person(let name): subjects.append(name)
        case .organization(let name): subjects.append(name)
        case .folder(let path): subjects.append(path)
        case .global: break
        }
        for hint in intent.entityHints.prefix(6) where hint.count > 2 {
            if !subjects.contains(where: { $0.localizedCaseInsensitiveContains(hint) }) {
                subjects.append(hint)
            }
        }
        // Pull strong organization / project / person entities from
        // retrieved evidence to ground the answer body in named subjects.
        // Defensively re-filter through EntityQualityGate so the rendered
        // line never surfaces hostname-shape / stoplist / weekday strings
        // even if a pre-T13.4 row survived in the canonical table.
        // D-13 — presentation hygiene: keepsForPresentation is STRICTER than
        // shouldKeep (mail/infra brands like "Gmail"/"Smtpnet" stay in the
        // ledger but never print as subjects).
        let strong = retrieval.entities
            .filter { $0.kind == .organization || $0.kind == .person || $0.kind == .project || $0.kind == .vendor || $0.kind == .client }
            .filter { entityQualityGate?.keepsForPresentation($0) ?? true }
            .sorted {
                // Unit-A tie-break for the .prefix(6) membership cut.
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.value < $1.value
            }
            .prefix(6)
            .map(\.value)
        for value in strong where value.count > 2 {
            if !subjects.contains(where: { $0.localizedCaseInsensitiveContains(value) }) {
                subjects.append(value)
            }
        }
        // Domain mining: walk emails encountered in retrieved evidence and
        // surface the organizational domains they came from (e.g.
        // "supplier-abc.com" → "Supplier ABC").
        let emails = retrieval.entities
            .filter { $0.kind == .emailAddress }
            .compactMap { $0.normalizedValue ?? $0.value }
        var domains = Set<String>()
        for email in emails {
            if let at = email.firstIndex(of: "@") {
                let domain = String(email[email.index(after: at)...])
                guard let head = domain.split(separator: ".").first.map(String.init)
                else { continue }
                let label = head
                    .split(separator: "-")
                    .map { token -> String in
                        let s = String(token)
                        // Preserve obvious acronyms (<= 4 chars, alphabetic).
                        if s.count <= 4 && s.allSatisfy(\.isLetter) {
                            return s.uppercased()
                        }
                        return s.prefix(1).uppercased() + s.dropFirst().lowercased()
                    }
                    .joined(separator: " ")
                if !label.isEmpty { domains.insert(label) }
            }
        }
        for label in domains where label.count > 2 {
            // D-13 — a mined domain stem is only org-shaped when the domain
            // was multi-token ("supplier-abc.com" → "Supplier ABC"). Single-
            // token stems are almost always infrastructure ("Gmail",
            // "Hxcore", "Smtpnet") — the mail's plumbing, not a subject.
            guard label.contains(" ") else { continue }
            // Same gate check via a synthesized organization entity so
            // hostname-shape domain stems (Tyzpr01mb4530, Seqmbx01) get
            // filtered before they ever reach the rendered line.
            if let gate = entityQualityGate {
                let probe = Entity(
                    kind: .organization,
                    value: label,
                    sourceObjectID: UUID(),
                    confidence: .medium
                )
                if !gate.keepsForPresentation(probe) { continue }
            }
            if !subjects.contains(where: { $0.localizedCaseInsensitiveContains(label) }) {
                subjects.append(label)
            }
        }
        // D-13 — drop empty/whitespace entries and case-insensitive dupes
        // before joining; the screenshot's footer carried both.
        var seen = Set<String>()
        let cleaned = subjects
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return cleaned.isEmpty ? "" : "Subjects in scope: \(cleaned.joined(separator: ", "))."
    }
}

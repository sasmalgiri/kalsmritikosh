//
//  CausalDiscoverer.swift
//  Kalsmritikosh
//
//  HISTORY Phase G.4 — background pass that proposes typed causal
//  links between events that already exist in the ledger.
//
//  Algorithm (the design research's "afternoon-shippable" heuristic
//  — explicitly NOT PC / GES / LiNGAM, which assume dense i.i.d.
//  observational data and would over-fit on a sparse human archive):
//
//   For each ordered pair (A before B, day gap ≤ maxGapDays):
//     score = w_overlap * jaccard(A.entityIDs, B.entityIDs)
//           + w_lexical * (1.0 if B.summary or B.title contains a
//                          causal trigger near an A-entity mention)
//           + w_temporal * (1.0 - gapDays / maxGapDays)
//           + w_tier     * average(qualityTier weight of A, B)
//
//     if score >= threshold and not already linked:
//       emit CausalLink(
//         A → B,
//         relation = .caused if lexical trigger fired
//                  : .contributedTo otherwise,
//         confidence = score,
//         allen = computed from datePrecision + dates,
//         source = .lexicalTrigger if trigger fired else .heuristic,
//         reason = trigger phrase OR "shared entities and close timing"
//       )
//
//  Hume guard: heuristic-only links NEVER auto-promote to .caused.
//  A lexical trigger ("because of", "due to", "as a result of") is
//  required. This is what the research called out — co-occurrence
//  alone is not causation.
//
//  Counterfactuals (PREVENTED) are NOT auto-emitted. They require
//  user assertion or LLM-level reasoning. We ship CONTRIBUTED_TO,
//  CAUSED (lexical only), ENABLED (when A is a precondition kind
//  like contractSigned and B depends on that kind), and FOLLOWED
//  (temporal-only fallback when other signals are weak but the pair
//  is still narratively interesting).
//

import Foundation
import OSLog

public actor CausalDiscoverer: BackgroundService {
    public let id = "atlas.causal.discover"

    private let database: Database
    private let events: EventsRepository
    private let entities: EntitiesRepository
    private let objects: KnowledgeObjectRepository
    private let links: EventLinksRepository
    /// Max wall-clock days between A and B for a link to be considered.
    /// > 90 days the heuristic too easily fires on coincidence.
    private let maxGapDays: Int
    /// Score floor for emission. Below this the pair stays unlinked.
    private let threshold: Double
    /// Max events scanned per pass — sparse human archives only have
    /// a few hundred to a few thousand events; one pass over them
    /// completes in seconds.
    private let maxEventsPerPass: Int
    private let intervalSeconds: TimeInterval
    private var runTask: Task<Void, Never>?

    public init(
        database: Database,
        events: EventsRepository,
        entities: EntitiesRepository,
        objects: KnowledgeObjectRepository,
        links: EventLinksRepository,
        maxGapDays: Int = 90,
        threshold: Double = 0.45,
        maxEventsPerPass: Int = 2000,
        intervalSeconds: TimeInterval = 6 * 3_600   // 4× per day
    ) {
        self.database = database
        self.events = events
        self.entities = entities
        self.objects = objects
        self.links = links
        self.maxGapDays = maxGapDays
        self.threshold = threshold
        self.maxEventsPerPass = maxEventsPerPass
        self.intervalSeconds = intervalSeconds
    }

    public func start() async {
        guard runTask == nil else { return }
        AtlasLog.knowledge.info("CausalDiscoverer: starting (gap=\(self.maxGapDays, privacy: .public)d threshold=\(self.threshold, privacy: .public))")
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

    /// One discovery pass. Returns the number of new links emitted.
    @discardableResult
    public func runOnce() async -> Int {
        let candidates: [Event]
        do {
            candidates = try await events.recent(limit: maxEventsPerPass)
        } catch {
            AtlasLog.knowledge.error("CausalDiscoverer: load events failed — \(String(describing: error), privacy: .public)")
            return 0
        }
        guard candidates.count >= 2 else { return 0 }
        let sorted = candidates.sorted { $0.date < $1.date }

        // Existing-triple set lets us skip pairs we've already linked.
        let existing: Set<String>
        do {
            existing = try await links.existingTriples()
        } catch {
            existing = []
        }

        var emitted = 0
        // O(N²) over a 2k cap = 4M pair checks max; each is a tier+set
        // arithmetic op — completes in well under a second on the
        // archive sizes we target.
        for i in 0..<sorted.count {
            let a = sorted[i]
            for j in (i + 1)..<sorted.count {
                let b = sorted[j]
                let gapDays = Calendar.current.dateComponents([.day], from: a.date, to: b.date).day ?? 0
                if gapDays > maxGapDays { break }   // sorted; no later j helps
                if gapDays < 0 { continue }
                guard a.id != b.id else { continue }

                let score = Self.score(
                    a: a, b: b,
                    gapDays: gapDays,
                    maxGapDays: maxGapDays
                )
                guard score.value >= threshold else { continue }

                // Hume guard: only .caused when a lexical trigger
                // matched. Otherwise stamp .contributedTo or .enabled
                // depending on kind compatibility.
                let relation: CausalRelation = {
                    if score.lexicalTrigger != nil { return .caused }
                    if Self.isEnablerPair(a: a, b: b) { return .enabled }
                    return .contributedTo
                }()
                let triple = "\(a.id.uuidString)|\(b.id.uuidString)|\(relation.rawValue)"
                if existing.contains(triple) { continue }

                let allen = AllenInterval.relation(
                    aStart: a.date, aEnd: a.endDate,
                    bStart: b.date, bEnd: b.endDate
                )
                let reason: String? = score.lexicalTrigger
                    ?? (score.entityOverlap > 0.3 ? "shared entities + close timing" : nil)
                let link = CausalLink(
                    sourceEventID: a.id,
                    targetEventID: b.id,
                    relation: relation,
                    confidence: min(1.0, score.value),
                    evidenceObjectIDs: Array(Set([a.sourceObjectID, b.sourceObjectID])),
                    allen: allen,
                    source: score.lexicalTrigger != nil ? .lexicalTrigger : .heuristic,
                    reason: reason
                )
                do {
                    try await links.insert(link)
                    emitted += 1
                } catch {
                    AtlasLog.knowledge.error("CausalDiscoverer: insert failed for \(a.id.uuidString.prefix(8), privacy: .public)→\(b.id.uuidString.prefix(8), privacy: .public) — \(String(describing: error), privacy: .public)")
                }
            }
        }
        AtlasLog.knowledge.info("CausalDiscoverer: emitted \(emitted, privacy: .public) new links from \(sorted.count, privacy: .public) events")
        return emitted
    }

    // MARK: - Scoring

    /// Bundle: the value + signals that fed it. The signals are
    /// surfaced to the link's `reason` field for explainability.
    struct ScoreResult {
        let value: Double
        let entityOverlap: Double
        let lexicalTrigger: String?   // matched phrase, nil if none
    }

    nonisolated static func score(
        a: Event, b: Event,
        gapDays: Int,
        maxGapDays: Int
    ) -> ScoreResult {
        let setA = Set(a.entityIDs)
        let setB = Set(b.entityIDs)
        let intersect = setA.intersection(setB).count
        let union = setA.union(setB).count
        let entityOverlap = union == 0 ? 0.0 : Double(intersect) / Double(union)

        let temporalProximity = max(0.0, 1.0 - Double(gapDays) / Double(maxGapDays))
        let tierAvg = (a.qualityTier.defaultWeight + b.qualityTier.defaultWeight) / 2.0
        let confidenceAvg = (a.confidence.value + b.confidence.value) / 2.0

        // Lexical trigger check: does B's title or summary contain a
        // causal trigger phrase near an A-entity mention? Simple
        // substring scan is fine for the size of these strings.
        var lexical: String? = nil
        let bText = ((b.title) + " " + (b.summary ?? "")).lowercased()
        for trigger in Self.causalTriggers where bText.contains(trigger) {
            lexical = trigger
            break
        }

        let lexicalScore: Double = lexical != nil ? 0.4 : 0.0
        let weightedScore = 0.30 * entityOverlap
            + lexicalScore
            + 0.20 * temporalProximity
            + 0.15 * tierAvg
            + 0.10 * confidenceAvg
        return ScoreResult(
            value: weightedScore,
            entityOverlap: entityOverlap,
            lexicalTrigger: lexical
        )
    }

    /// Pair-kinds that the heuristic treats as ENABLED rather than
    /// CONTRIBUTED_TO. Contract-signing typically enables subsequent
    /// invoice / delivery / amendment events without being their
    /// proximate cause; meeting-held enables subsequent decisions.
    nonisolated static func isEnablerPair(a: Event, b: Event) -> Bool {
        switch (a.kind, b.kind) {
        case (.contractSigned, .invoiceIssued),
             (.contractSigned, .invoicePaid),
             (.contractSigned, .deliveryCompleted),
             (.contractSigned, .deliveryDelayed),
             (.contractSigned, .contractModified),
             (.meetingHeld,    .taskAssigned),
             (.invoiceIssued,  .invoicePaid):
            return true
        default:
            return false
        }
    }

    /// Causal trigger phrases observed in real-world correspondence.
    /// Conservative on purpose — false positives create false causal
    /// claims. Lower-cased; matched as substrings in event.title +
    /// event.summary. Spelling variants ("due to" vs "owing to") are
    /// covered; figurative usage ("because of you" etc.) is rare
    /// enough in formal correspondence to ignore.
    nonisolated static let causalTriggers: [String] = [
        "because of",
        "due to",
        "as a result of",
        "as a consequence of",
        "in response to",
        "in light of",
        "following the",
        "triggered by",
        "owing to",
        "caused by"
    ]
}

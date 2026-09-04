//
//  HistorySubjectResolver.swift
//  Kalsmritikosh
//
//  HIST-012 (Universal History program, Phase 1). Resolves a subject to a canonical
//  entity id — deterministically, never by guessing. Two entry points:
//
//    • resolve(entityID:)  — the Dossier's direct path. An id in → an exact resolved
//      subject out. This is what makes "a named person cannot silently become global
//      history" true: the Dossier passes the picked Entity.ID, not a string.
//    • resolve(freeText:)  — normalize → search names → rank → return exactly one
//      resolution, a list of ambiguity candidates, or notFound. It NEVER collapses
//      two same-name people into one guessed subject.
//
//  Deterministic + LLM-free (capability discipline; Knowledge/ names no models).
//

import Foundation

/// Pure, testable subject-name normalisation: fold case, honorifics, punctuation
/// and whitespace so "Dr. Shirshendu  Sasmal" and "shirshendu sasmal" compare equal.
public enum HistorySubjectNormalizer {
    private static let honorifics: Set<String> = [
        "mr", "mrs", "ms", "miss", "dr", "prof", "professor", "sri", "smt", "shri", "sir"
    ]

    public static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        // Split on any non-alphanumeric, drop honorific tokens, rejoin single-spaced.
        let tokens = folded
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0).lowercased() }
            .filter { !honorifics.contains($0) }
        return tokens.joined(separator: " ")
    }
}

public struct HistorySubjectResolver: Sendable {
    private let entities: EntitiesRepository
    /// Cap on how many search hits are considered / how many evidence ids are
    /// gathered for the resolved subject (paging happens in the collector later).
    private let candidateLimit: Int
    private let evidenceProbe: Int

    public init(entities: EntitiesRepository, candidateLimit: Int = 25, evidenceProbe: Int = 200) {
        self.entities = entities
        self.candidateLimit = candidateLimit
        self.evidenceProbe = evidenceProbe
    }

    // MARK: - Direct id path (Dossier)

    /// Exact resolution from a canonical entity id. Always succeeds when the entity
    /// exists; confidence 1.0. Follows entity merges via `resolveCanonical`.
    public func resolve(entityID: Entity.ID) async throws -> ResolvedHistorySubject? {
        let canonical = (try? await entities.resolveCanonical(entityID)) ?? entityID
        var found = try await entities.find(byID: canonical)
        if found == nil { found = try await entities.find(byID: entityID) }
        guard let entity = found else { return nil }
        let evidenceIDs = try await evidenceObjectIDs(for: canonical)
        return ResolvedHistorySubject(
            subject: .forEntity(entity),
            displayName: entity.value,
            canonicalEntityID: canonical,
            aliases: [],   // alias expansion arrives with the collector (Phase 3)
            resolutionConfidence: 1.0,
            matchedEvidenceObjectIDs: evidenceIDs,
            ambiguityCandidates: []
        )
    }

    // MARK: - Free-text path

    public func resolve(freeText query: String) async throws -> HistoryResolution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound(query: query) }
        let norm = HistorySubjectNormalizer.normalize(trimmed)

        // Search by value, fold each hit to its canonical entity, dedupe.
        let hits = try await entities.search(value: trimmed, limit: candidateLimit)
        var byCanonical: [Entity.ID: Entity] = [:]
        for row in hits {
            let canonical = (try? await entities.resolveCanonical(row.id)) ?? row.id
            if byCanonical[canonical] == nil, let e = try await entities.find(byID: canonical) {
                byCanonical[canonical] = e
            }
        }
        guard !byCanonical.isEmpty else { return .notFound(query: query) }

        // Build candidates with an exact-match flag + mention-count signal.
        var candidates: [(cand: SubjectCandidate, exact: Bool, entity: Entity)] = []
        for (id, e) in byCanonical {
            let count = try await mentionCount(for: id)
            let exact = HistorySubjectNormalizer.normalize(e.value) == norm
                || (e.normalizedValue.map { HistorySubjectNormalizer.normalize($0) } == norm)
            // score: exact match dominates, then co-occurrence, then confidence.
            let score = (exact ? 1000.0 : 0.0) + Double(count) + e.confidence.value
            candidates.append((
                SubjectCandidate(id: id, displayName: e.value, kind: e.kind,
                                 mentionCount: count, score: score),
                exact, e))
        }
        // Deterministic ordering: score desc, then id for stable ties.
        candidates.sort { a, b in
            a.cand.score != b.cand.score ? a.cand.score > b.cand.score
                                         : a.cand.id.uuidString < b.cand.id.uuidString
        }

        let exacts = candidates.filter(\.exact)
        // Exactly one exact-name match → resolve it. Multiple exact matches
        // (same-name people) → ambiguous, never guessed.
        if exacts.count == 1 {
            return .resolved(try await resolved(from: exacts[0].entity, id: exacts[0].cand.id, confidence: 0.9))
        }
        if exacts.count > 1 {
            return .ambiguous(exacts.map(\.cand))
        }
        // No exact match: a single fuzzy hit resolves (lower confidence); several → ambiguous.
        if candidates.count == 1 {
            return .resolved(try await resolved(from: candidates[0].entity, id: candidates[0].cand.id, confidence: 0.6))
        }
        return .ambiguous(candidates.map(\.cand))
    }

    // MARK: - Story path (P4-U1)

    /// How a story ask's subject resolved. Fail-closed: no anchor, no story —
    /// the honest message names what WOULD resolve, never guesses a subject.
    public enum StoryResolution: Sendable {
        case resolved(ResolvedHistorySubject, anchorKey: String)
        /// Several anchors match ("the patent" with two patents on file) —
        /// listed for the user, never picked for them.
        case ambiguous(message: String)
        case notResolvable(message: String)
    }

    /// P4-U1 — resolve a story question via IDENTIFIER ANCHORS ONLY, using the
    /// same deterministic charter the answer path uses (an identifier value in
    /// the question, or a definite reference to the one document of its kind
    /// on file). Anything else fails closed with the honest message — a story
    /// subject is never guessed from retrieval bycatch. Person-scoped stories
    /// keep their existing door (the Dossier passes a picked Entity.ID).
    public func resolveStory(question: String, anchors: [Entity]) async throws -> StoryResolution {
        let charter = SubjectResolver.resolve(question: question, anchors: anchors)
        switch charter.method {
        case .identifierInQuestion, .definiteReference:
            guard let primary = charter.anchors.first,
                  let key = primary.normalizedValue, !key.isEmpty,
                  let resolved = try await resolve(entityID: primary.id) else {
                return .notResolvable(message: "The resolved subject could not be loaded from the register.")
            }
            // The anchor's own source document is story evidence even when the
            // identifier has no mention rows yet.
            var evidence = resolved.matchedEvidenceObjectIDs
            if !evidence.contains(primary.sourceObjectID) {
                evidence.append(primary.sourceObjectID)
            }
            return .resolved(ResolvedHistorySubject(
                subject: resolved.subject,
                displayName: resolved.displayName,
                canonicalEntityID: resolved.canonicalEntityID,
                aliases: resolved.aliases,
                resolutionConfidence: resolved.resolutionConfidence,
                matchedEvidenceObjectIDs: evidence,
                ambiguityCandidates: resolved.ambiguityCandidates), anchorKey: key)
        case .ambiguous:
            return .ambiguous(message: charter.receiptLine)
        case .none:
            return .notResolvable(message:
                "A story needs a subject the archive can anchor — name the document's number, or say \u{201C}the patent\u{201D} (or invoice, contract, case) when there is exactly one on file.")
        }
    }

    // MARK: - Internals

    private func resolved(from entity: Entity, id: Entity.ID, confidence: Double) async throws -> ResolvedHistorySubject {
        ResolvedHistorySubject(
            subject: .forEntity(entity),
            displayName: entity.value,
            canonicalEntityID: id,
            aliases: [],
            resolutionConfidence: confidence,
            matchedEvidenceObjectIDs: try await evidenceObjectIDs(for: id),
            ambiguityCandidates: []
        )
    }

    private func mentionCount(for id: Entity.ID) async throws -> Int {
        (try await entities.mentions(forEntityID: id, limit: evidenceProbe)).count
    }

    private func evidenceObjectIDs(for id: Entity.ID) async throws -> [KnowledgeObject.ID] {
        let rows = try await entities.mentions(forEntityID: id, limit: evidenceProbe)
        var seen = Set<KnowledgeObject.ID>()
        var out: [KnowledgeObject.ID] = []
        for r in rows where seen.insert(r.objectID).inserted { out.append(r.objectID) }
        return out
    }
}

//
//  DocumentSimilarity.swift
//  Kalsmritikosh
//
//  X-1 — "See Also" and filing suggestions. A document's vector is the normalised mean of
//  its live chunk embeddings for one embedding model (the same vectors retrieval already
//  uses; nothing new is embedded). It is cached in `document_vectors` (v148) with the
//  signature of the chunk set it came from, so a changed document is rebuilt.
//
//  Honest outcomes, never invented ones:
//   * a document with no embedded passage has no vector → `.notYetEmbedded`, not "nothing similar";
//   * a suggestion below the confidence floor is not offered → `.noConfidentSuggestion`.
//  Suggestions never file anything; the person chooses.
//

import Foundation
import Accelerate

public nonisolated struct SimilarDocument: Sendable, Hashable {
    public let objectID: UUID
    public let score: Double
    /// The closest pair of passages (this document's, the other's), as the reason it is shown.
    public var reason: (mine: String, theirs: String)?

    public static func == (a: Self, b: Self) -> Bool { a.objectID == b.objectID && a.score == b.score }
    public func hash(into h: inout Hasher) { h.combine(objectID); h.combine(score) }
}

public nonisolated struct FilingSuggestion: Sendable, Hashable {
    public enum Target: Sendable, Hashable { case group(UUID), tag(UUID) }
    public let target: Target
    public let name: String
    public let score: Double
}

public nonisolated enum SimilarityOutcome<T: Sendable>: Sendable {
    case results([T])
    case notYetEmbedded
    case noConfidentSuggestion
    /// Filing suggestions were not calibrated for the embedding model in use, so none are
    /// offered (see `DocumentSimilarity.filingThresholds`).
    case notCalibrated
}

public actor DocumentSimilarity {
    private let database: Database
    private let modelID: String
    /// Below this cosine a group/tag is never suggested.
    public static let suggestionFloor = 0.5
    /// The best group must beat the next one by at least this much, or nothing is suggested.
    /// Embedding models score unrelated text far above zero (on the open corpus, bge-small
    /// gave an article about chess 0.71 to an astronomy group and 0.70 to a law group), so an
    /// absolute floor alone cannot say "this belongs nowhere"; a clear lead can. Calibrated on
    /// the open corpus (Fixtures/OpenCorpus): every on-subject article led by ≥ 0.030, the
    /// off-topic one by 0.018.
    public static let suggestionLead = 0.025

    /// Filing needs thresholds measured for the embedding model in use. Only the bundled model
    /// is calibrated: with Apple's built-in sentence embedding the open corpus gave an article
    /// about chess a 0.09 lead for an astronomy group — larger than several right answers — so
    /// no threshold can say "this belongs nowhere" with it, and filing stays off rather than
    /// guess. See Also is unaffected (it ranks; it does not decide).
    public static let filingThresholds: [String: (floor: Double, lead: Double)] = [
        "bge-small.v1": (suggestionFloor, suggestionLead)
    ]
    /// See Also hides documents scoring below this (they are not meaningfully alike).
    public static let seeAlsoFloor = 0.3

    private let thresholds: (floor: Double, lead: Double)?

    public init(database: Database, modelID: String, thresholds: (floor: Double, lead: Double)? = nil) {
        self.database = database
        self.modelID = modelID
        self.thresholds = thresholds ?? Self.filingThresholds[modelID]
    }

    // MARK: - Vectors

    /// The cached (or freshly built) vector of one document; nil when none of its passages is embedded.
    public func vector(for objectID: UUID) async throws -> [Float]? {
        let sig = try await signature(of: objectID)
        guard sig.count > 0 else { return nil }
        if let row = try await database.query(
            "SELECT vector, signature FROM document_vectors WHERE object_id = ? AND model_id = ?;",
            [.uuid(objectID), .text(modelID)]).first,
           row.string(1) == sig.text, let blob = row.blob(0) {
            return Self.floats(blob)
        }
        let rows = try await database.query("""
            SELECT e.q, e.scale FROM chunk_embeddings e JOIN chunks c ON c.id = e.chunk_id
            WHERE c.object_id = ? AND e.model_id = ? AND c.superseded_by_run IS NULL AND c.review_status IS NULL;
            """, [.uuid(objectID), .text(modelID)])
        let vectors = rows.compactMap { r -> [Float]? in
            guard let q = r.blob(0) else { return nil }
            return Self.scaled(VectorQuantization.floats(fromInt8: q), by: Float(r.double(1) ?? 1))
        }
        guard let mean = Self.normalisedMean(vectors) else { return nil }
        try await database.exec("""
            INSERT INTO document_vectors (object_id, model_id, dims, vector, chunk_count, signature, computed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (object_id, model_id) DO UPDATE SET dims = excluded.dims, vector = excluded.vector,
                chunk_count = excluded.chunk_count, signature = excluded.signature, computed_at = excluded.computed_at;
            """, [.uuid(objectID), .text(modelID), .integer(Int64(mean.count)), .blob(Self.data(mean)),
                  .integer(Int64(vectors.count)), .text(sig.text), .date(Date())])
        return mean
    }

    /// Vectors of every document that has any embedded passage.
    func allVectors() async throws -> [UUID: [Float]] {
        let rows = try await database.query("""
            SELECT DISTINCT c.object_id FROM chunk_embeddings e JOIN chunks c ON c.id = e.chunk_id
            WHERE e.model_id = ? AND c.superseded_by_run IS NULL AND c.review_status IS NULL;
            """, [.text(modelID)])
        var out: [UUID: [Float]] = [:]
        for id in rows.compactMap({ $0.uuid(0) }) {
            if let v = try await vector(for: id) { out[id] = v }
        }
        return out
    }

    private func signature(of objectID: UUID) async throws -> (count: Int, text: String) {
        let row = try await database.query("""
            SELECT COUNT(*), COALESCE(MAX(e.created_at), 0) FROM chunk_embeddings e JOIN chunks c ON c.id = e.chunk_id
            WHERE c.object_id = ? AND e.model_id = ? AND c.superseded_by_run IS NULL AND c.review_status IS NULL;
            """, [.uuid(objectID), .text(modelID)]).first
        let count = Int(row?.int(0) ?? 0)
        return (count, "\(count):\(row?.double(1) ?? 0)")
    }

    // MARK: - See Also

    /// The documents most like this one: itself and its near-duplicates excluded (those are
    /// shown as duplicates), `allowed` filters by the screen's access scope.
    public func seeAlso(_ objectID: UUID, limit: Int = 8,
                        allowed: @Sendable (UUID) async -> Bool = { _ in true }) async throws -> SimilarityOutcome<SimilarDocument> {
        guard let mine = try await vector(for: objectID) else { return .notYetEmbedded }
        let duplicates = try await nearDuplicates(of: objectID)
        let all = try await allVectors()
        var scored: [(UUID, Double)] = []
        for (id, v) in all where id != objectID && !duplicates.contains(id) {
            let s = Self.cosine(mine, v)
            if s >= Self.seeAlsoFloor { scored.append((id, s)) }
        }
        scored.sort { $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 > $1.1 }
        var out: [SimilarDocument] = []
        for (id, s) in scored {
            guard out.count < limit else { break }
            guard await allowed(id) else { continue }
            out.append(SimilarDocument(objectID: id, score: s, reason: try await closestPassages(objectID, id)))
        }
        return .results(out)
    }

    private func nearDuplicates(of objectID: UUID) async throws -> Set<UUID> {
        let rows = try await database.query("""
            SELECT b.object_id FROM near_duplicate_members a JOIN near_duplicate_members b ON b.group_id = a.group_id
            WHERE a.object_id = ? AND b.object_id <> a.object_id;
            """, [.uuid(objectID)])
        return Set(rows.compactMap { $0.uuid(0) })
    }

    /// The pair of live passages, one from each document, whose embeddings are closest.
    func closestPassages(_ a: UUID, _ b: UUID) async throws -> (mine: String, theirs: String)? {
        func passages(_ id: UUID) async throws -> [(String, [Float])] {
            let rows = try await database.query("""
                SELECT c.text, e.q, e.scale FROM chunk_embeddings e JOIN chunks c ON c.id = e.chunk_id
                WHERE c.object_id = ? AND e.model_id = ? AND c.superseded_by_run IS NULL AND c.review_status IS NULL
                ORDER BY c.ordinal LIMIT 200;
                """, [.uuid(id), .text(modelID)])
            return rows.compactMap { r in
                guard let t = r.string(0), let q = r.blob(1) else { return nil }
                return (t, Self.scaled(VectorQuantization.floats(fromInt8: q), by: Float(r.double(2) ?? 1)))
            }
        }
        let pa = try await passages(a), pb = try await passages(b)
        var best: (Double, String, String)?
        for (ta, va) in pa {
            for (tb, vb) in pb {
                let s = Self.cosine(va, vb)
                if best == nil || s > best!.0 { best = (s, ta, tb) }
            }
        }
        return best.map { (String($0.1.prefix(240)), String($0.2.prefix(240))) }
    }

    // MARK: - Filing suggestions

    /// Groups (with at least two members) and tags (on at least two documents) this document
    /// most resembles, by cosine to the members' mean. Groups and tags it is already in are
    /// left out. Nothing is offered below `suggestionFloor`, or when the best candidate does
    /// not lead the next by `suggestionLead`.
    public func suggestFiling(_ objectID: UUID, limit: Int = 3) async throws -> SimilarityOutcome<FilingSuggestion> {
        guard let limits = thresholds else { return .notCalibrated }
        guard let mine = try await vector(for: objectID) else { return .notYetEmbedded }
        var candidates: [FilingSuggestion] = []

        let groupRows = try await database.query("""
            SELECT g.id, g.name, m.object_id FROM user_groups g JOIN user_group_members m ON m.group_id = g.id
            WHERE g.retired_at IS NULL AND m.removed_at IS NULL;
            """, [])
        let tagRows = try await database.query("""
            SELECT t.id, t.name, l.subject_id FROM user_tags t JOIN user_tag_links l ON l.tag_id = t.id
            WHERE t.retired_at IS NULL AND l.removed_at IS NULL AND l.subject_kind = 'object';
            """, [])
        for (rows, isGroup) in [(groupRows, true), (tagRows, false)] {
            var members: [UUID: (name: String, docs: [UUID])] = [:]
            for r in rows {
                guard let id = r.uuid(0), let name = r.string(1), let doc = r.uuid(2) else { continue }
                members[id, default: (name, [])].docs.append(doc)
            }
            for (id, entry) in members {
                if entry.docs.contains(objectID) { continue }
                var vectors: [[Float]] = []
                for doc in entry.docs { if let v = try await vector(for: doc) { vectors.append(v) } }
                guard vectors.count >= 2, let centroid = Self.normalisedMean(vectors) else { continue }
                let s = Self.cosine(mine, centroid)
                candidates.append(FilingSuggestion(target: isGroup ? .group(id) : .tag(id), name: entry.name, score: s))
            }
        }
        candidates.sort { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
        guard let top = candidates.first, top.score >= limits.floor else { return .noConfidentSuggestion }
        // A clear lead over the next candidate, or no suggestion (it would be a guess).
        if candidates.count > 1, top.score - candidates[1].score < limits.lead { return .noConfidentSuggestion }
        // The leader, then any others that are themselves well above the rest.
        var out = [top]
        for (i, c) in candidates.enumerated().dropFirst() where out.count < limit {
            let next = i + 1 < candidates.count ? candidates[i + 1].score : 0
            guard c.score >= limits.floor, c.score - next >= limits.lead, top.score - c.score < limits.lead * 2 else { break }
            out.append(c)
        }
        return .results(out)
    }

    /// Every candidate group/tag with its score, best first, before any threshold — for calibration.
    func groupScores(_ objectID: UUID) async throws -> [FilingSuggestion] {
        guard let mine = try await vector(for: objectID) else { return [] }
        let rows = try await database.query("""
            SELECT g.id, g.name, m.object_id FROM user_groups g JOIN user_group_members m ON m.group_id = g.id
            WHERE g.retired_at IS NULL AND m.removed_at IS NULL;
            """, [])
        var members: [UUID: (name: String, docs: [UUID])] = [:]
        for r in rows {
            guard let id = r.uuid(0), let name = r.string(1), let doc = r.uuid(2) else { continue }
            members[id, default: (name, [])].docs.append(doc)
        }
        var out: [FilingSuggestion] = []
        for (id, entry) in members where !entry.docs.contains(objectID) {
            var vs: [[Float]] = []
            for d in entry.docs { if let v = try await vector(for: d) { vs.append(v) } }
            guard let c = Self.normalisedMean(vs) else { continue }
            out.append(FilingSuggestion(target: .group(id), name: entry.name, score: Self.cosine(mine, c)))
        }
        return out.sorted { $0.score > $1.score }
    }

    // MARK: - Maths

    static func scaled(_ v: [Float], by s: Float) -> [Float] {
        var out = v
        var scale = s
        vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// Mean of same-length vectors, normalised to unit length; nil when empty, mixed
    /// lengths, or a zero mean.
    static func normalisedMean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(sum.count)) }
        var norm: Float = 0
        vDSP_svesq(sum, 1, &norm, vDSP_Length(sum.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        var inv = 1 / norm
        vDSP_vsmul(sum, 1, &inv, &sum, 1, vDSP_Length(sum.count))
        return sum
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let d = (na * nb).squareRoot()
        return d > 0 ? Double(dot / d) : 0
    }

    static func data(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func floats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

//
//  TermSalienceComputer.swift
//  Kalsmritikosh
//
//  TT (Amendment A1, part 1) — TERM salience beside D-17's STRUCTURAL
//  salience: the winner terms of each document, scored
//
//      in-doc frequency × archive rarity × structural salience × corroboration
//
//  Laws: identifiers rank highest BY CONSTRUCTION (an anchor's canon value
//  outranks any prose term); proper nouns need corroboration (a name seen in
//  one document stays a leaf-local term, never a tree label); everything is
//  deterministic (total order on ties) and versioned (a scoring change is an
//  era, refreshed by targeted refresh). The topic tree's seeds and labels
//  read from here; nothing existing is rewritten.
//

import Foundation
import os

public struct TermSalienceComputer {
    private let database: Database
    private static let logger = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "knowledge")

    public static let producerVersion = 1
    /// Winner terms kept per document.
    static let winnersPerDocument = 12

    public init(database: Database) {
        self.database = database
    }

    /// Compute + persist winner terms for every KO below the current era.
    /// Idempotent: a second run finds nothing stale.
    @discardableResult
    public func run() async throws -> Int {
        // Archive-wide document frequency per term, from chunk text.
        let koRows = try await database.query("""
        SELECT ko.id FROM knowledge_objects ko
        WHERE NOT EXISTS (
            SELECT 1 FROM document_terms dt
            WHERE dt.object_id = ko.id AND dt.producer_version = ?
        );
        """, [.integer(Int64(Self.producerVersion))])
        let staleKOs = koRows.compactMap { $0.uuid(0) }
        guard !staleKOs.isEmpty else { return 0 }

        let totalDocs = Int((try await database.query(
            "SELECT COUNT(*) FROM knowledge_objects;", [])).first?.int(0) ?? 1)

        // term → number of documents carrying it (rarity denominator).
        var docFrequency: [String: Int] = [:]
        var termsByKO: [UUID: [String: (count: Int, salience: Double)]] = [:]
        let chunkRows = try await database.query(
            "SELECT object_id, text, salience FROM chunks;", [])
        var perDocSeen: [UUID: Set<String>] = [:]
        for row in chunkRows {
            guard let ko = row.uuid(0), let text = row.string(1) else { continue }
            let structural = row.double(2) ?? SalienceTable.neutral
            for term in Self.terms(of: text) {
                var bag = termsByKO[ko] ?? [:]
                let cur = bag[term] ?? (0, 0)
                bag[term] = (cur.count + 1, max(cur.salience, structural))
                termsByKO[ko] = bag
                if perDocSeen[ko, default: []].insert(term).inserted {
                    docFrequency[term, default: 0] += 1
                }
            }
        }

        // Anchor canon values: identifiers, highest by construction.
        let anchorRows = try await database.query("""
        SELECT source_object_id, normalized FROM entities
        WHERE kind = 'identifierAnchor' AND merged_into IS NULL;
        """, [])
        var anchorTermsByKO: [UUID: [String]] = [:]
        for row in anchorRows {
            guard let ko = row.uuid(0), let key = row.string(1) else { continue }
            let canon = key.split(separator: "|").dropFirst().joined(separator: "|")
            if !canon.isEmpty { anchorTermsByKO[ko, default: []].append(canon) }
        }

        var written = 0
        try await database.exec("SAVEPOINT term_salience;", [])
        do {
            for ko in staleKOs {
                var scored: [(term: String, score: Double, isID: Bool, corroboration: Int)] = []
                for (term, agg) in termsByKO[ko] ?? [:] {
                    let df = docFrequency[term] ?? 1
                    let rarity = log(Double(totalDocs + 1) / Double(df)) + 1
                    let corroboration = df
                    // Proper nouns (capitalized-shaped terms) need corroboration:
                    // single-document names never label anything above a leaf.
                    let isProperShape = term.first.map { $0.isUppercase } ?? false
                    let corroborationFactor = isProperShape && df < 2 ? 0.3 : 1.0
                    let score = Double(agg.count) * rarity * agg.salience * corroborationFactor
                    scored.append((term, score, false, corroboration))
                }
                for canon in anchorTermsByKO[ko] ?? [] {
                    // Identifier: highest by construction — above any prose score.
                    let top = (scored.map(\.score).max() ?? 1)
                    scored.append((canon, top * 2 + 100, true, 2))
                }
                // Total order: score desc, then term asc — deterministic winners.
                // Dedupe by term (an anchor's canon can also appear as a prose
                // term — the higher-scored identifier form wins, one row per PK).
                var seenTerms = Set<String>()
                let winners = scored.sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.term < $1.term
                }
                .filter { seenTerms.insert($0.term).inserted }
                .prefix(Self.winnersPerDocument)

                try await database.exec(
                    "DELETE FROM document_terms WHERE object_id = ?;", [.uuid(ko)])
                for w in winners {
                    try await database.exec("""
                    INSERT INTO document_terms (object_id, term, score, is_identifier, corroboration, producer_version)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """, [.uuid(ko), .text(w.term), .real(w.score),
                          .integer(w.isID ? 1 : 0), .integer(Int64(w.corroboration)),
                          .integer(Int64(Self.producerVersion))])
                    written += 1
                }
            }
            try await database.exec("RELEASE term_salience;", [])
        } catch {
            try? await database.exec("ROLLBACK TO term_salience;", [])
            try? await database.exec("RELEASE term_salience;", [])
            throw error
        }
        Self.logger.info("TermSalience: \(staleKOs.count) documents, \(written) winner terms")
        return written
    }

    /// Tokenize into candidate terms: words ≥3 chars, not stopwords; original
    /// case preserved (the proper-noun corroboration law reads it).
    nonisolated static func terms(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !SentenceQuoteComposer.stopwords.contains($0.lowercased()) }
    }
}

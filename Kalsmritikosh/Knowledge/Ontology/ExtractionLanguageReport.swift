//
//  ExtractionLanguageReport.swift
//  Kalsmritikosh
//
//  P3.6 — LANGUAGE HONESTY. The other axis of universality, and the one where
//  silence is most misleading.
//
//  WHAT WAS ALREADY TRUE. `Cleaner.detectLanguage` runs `NLLanguageRecognizer`
//  on every document and stores the result in the KnowledgeObject's metadata as
//  `meta["language"]`. So the app has ALWAYS known what language each document
//  is in.
//
//  WHAT WAS MISSING. Nothing ever said so. Extraction is English-only — the
//  domain packs' patterns, the open-field extractor's prose gates, the role
//  stopwords, the date parsers are all English — and multilingual is v2. A Hindi
//  or Marathi document therefore produces chunks and almost no facts, and that
//  outcome is INDISTINGUISHABLE from an English document that genuinely
//  contained no facts.
//
//  That is the exact failure this program keeps closing, in its most consequential
//  form yet: an archive could be 40% non-English, the ledger could be near-empty
//  for all of it, every count would look merely "low", and nobody would learn
//  the reason. A user would conclude the product does not work rather than that
//  it does not yet speak their language.
//
//  WHAT THIS DOES, AND DELIBERATELY DOES NOT DO. It does not translate, and it
//  does not attempt non-English extraction — that is v2 and pretending otherwise
//  would be worse than the silence. It makes the LIMIT VISIBLE: which languages
//  the archive holds, how many documents in each, and what the app can and
//  cannot do with them. Stating a limit plainly is the honest version of not
//  having built something yet.
//
//  No new schema: the language is already in KO metadata. Read-only, offline.
//

import Foundation
import os

public enum ExtractionLanguageReport {

    /// Languages whose extraction is genuinely supported today. English only —
    /// every pattern in the eleven domain packs, the open-field extractor's
    /// prose heads and tails, `roleStopwords`, and the date normalizers are
    /// English. Adding a code here without adding those is how a limit becomes
    /// a false claim.
    public nonisolated static let extractionSupported: Set<String> = ["en"]

    /// Languages that SEARCH still works for, even where extraction does not.
    /// FTS5 with `unicode61` tokenizes any script, and the embedder is
    /// multilingual-ish by accident of training — so a non-English document is
    /// still findable by its own words. That distinction matters to a user:
    /// "cannot extract structured facts" is a much smaller loss than "cannot
    /// find it at all", and reporting only the first would overstate the damage.
    public nonisolated static let searchSupportedForAnyScript = true

    public struct LanguageCoverage: Sendable, Equatable {
        public let languageCode: String
        public let documentCount: Int
        public let extractionSupported: Bool
        /// The display name, via the OS rather than a hand-kept table — so a
        /// language nobody anticipated still renders as a name, not a code.
        public var displayName: String {
            Locale.current.localizedString(forLanguageCode: languageCode)
                ?? languageCode.uppercased()
            }
    }

    public struct Report: Sendable {
        public let coverage: [LanguageCoverage]
        /// Documents whose language could not be detected. NOT counted as
        /// non-English: an undetected language is unknown, and guessing either
        /// way would be the same absence-as-fact error.
        public let undetectedCount: Int
        public let totalDocuments: Int

        public var supportedDocuments: Int {
            coverage.filter(\.extractionSupported).reduce(0) { $0 + $1.documentCount }
        }
        public var unsupportedDocuments: Int {
            coverage.filter { !$0.extractionSupported }.reduce(0) { $0 + $1.documentCount }
        }

        /// The honest paragraph for the Ingestion Report. Returns nil when the
        /// archive is entirely in a supported language AND every document's
        /// language was detected — in that case there is no limit to state, and
        /// printing a reassurance nobody needs is its own kind of noise.
        public func limitationStatement() -> String? {
            guard totalDocuments > 0 else { return nil }
            let unsupported = coverage.filter { !$0.extractionSupported }
                .sorted { $0.documentCount > $1.documentCount }
            guard !unsupported.isEmpty || undetectedCount > 0 else { return nil }

            var lines: [String] = []
            if !unsupported.isEmpty {
                let total = unsupported.reduce(0) { $0 + $1.documentCount }
                let pct = Int((Double(total) / Double(totalDocuments) * 100).rounded())
                lines.append(
                    "\(total) of \(totalDocuments) documents (\(pct)%) are not in English. "
                    + "Structured extraction — dates, identifiers, names, labelled fields — "
                    + "is English-only in this version, so these documents will yield FEW OR NO "
                    + "FACTS. That is a limitation of the app, not a property of your documents.")
                lines.append(
                    "They ARE still fully searchable by their own words, and their text is "
                    + "preserved verbatim, so nothing is lost — only the structured layer is "
                    + "missing.")
                let listed = unsupported.prefix(6)
                    .map { "\($0.displayName) (\($0.documentCount))" }
                    .joined(separator: " · ")
                lines.append("By language: \(listed)"
                             + (unsupported.count > 6 ? " · and \(unsupported.count - 6) more" : ""))
            }
            if undetectedCount > 0 {
                lines.append(
                    "\(undetectedCount) document(s) had no detectable language — usually very "
                    + "short text, tables of numbers, or scans with little recognised text. "
                    + "These are counted separately rather than assumed to be English.")
            }
            return lines.joined(separator: "\n\n")
        }
    }

    /// Build the report from the ledger's KnowledgeObject metadata.
    ///
    /// Reads `meta.language`, which `Cleaner` has been writing all along. The
    /// JSON path is queried in SQL rather than decoding every KO in Swift,
    /// because on a large archive that decode is the whole cost of the report.
    public nonisolated static func build(database: Database) async -> Report? {
        guard KnowledgeModuleFlags.isEnabled(.languageHonesty) else { return nil }
        do {
            let total = Int((try await database.query(
                "SELECT COUNT(*) FROM knowledge_objects;", [])).first?.int(0) ?? 0)
            guard total > 0 else {
                return Report(coverage: [], undetectedCount: 0, totalDocuments: 0)
            }
            // json_extract is available in SQLite's JSON1, which this schema
            // already relies on elsewhere. A NULL result means either no
            // metadata or no language key — both are "undetected", which is
            // why they are counted together and NOT as English.
            let rows = try await database.query("""
            SELECT json_extract(metadata, '$.language') AS lang, COUNT(*) AS n
            FROM knowledge_objects
            GROUP BY lang
            ORDER BY n DESC;
            """, [])
            var coverage: [LanguageCoverage] = []
            var undetected = 0
            for r in rows {
                let n = Int(r.int(1) ?? 0)
                guard let raw = r.string(0), !raw.isEmpty else { undetected += n; continue }
                // NLLanguageRecognizer returns BCP-47 ("en", "hi", "zh-Hans").
                // Compare on the primary subtag so "en-GB" is supported too.
                let primary = raw.split(separator: "-").first.map(String.init) ?? raw
                coverage.append(LanguageCoverage(
                    languageCode: raw,
                    documentCount: n,
                    extractionSupported: extractionSupported.contains(primary.lowercased())))
            }
            return Report(coverage: coverage, undetectedCount: undetected, totalDocuments: total)
        } catch {
            // A report that cannot be built must say so rather than returning
            // an empty one — an empty report reads as "no non-English
            // documents", which is a claim this failed to check.
            KalsmritikoshLog.knowledge.error(
                "ExtractionLanguageReport failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

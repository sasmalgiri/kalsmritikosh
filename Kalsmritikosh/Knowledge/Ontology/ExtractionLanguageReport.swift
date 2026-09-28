//
//  ExtractionLanguageReport.swift
//  Kalsmritikosh
//
//  P3.6 — LANGUAGE HONESTY. The other axis of universality, and the one where
//  silence is most misleading.
//
//  A CLAIM I MADE HERE WAS FALSE, and the owner's own archive disproved it.
//  This header used to say: "`Cleaner.detectLanguage` runs `NLLanguageRecognizer`
//  on every document and stores the result in `meta["language"]`, so the app has
//  ALWAYS known what language each document is in."
//
//  It does run. It does not store. `IngestCoordinator` computes
//  `cleaned = ContentDecoder().decode(cleaner.clean(perFileKOs.first ?? …))`,
//  uses it for `classifier.classify(cleaned)`, and then PERSISTS `perFileKOs` —
//  the uncleaned originals. The detected language is computed on every ingest
//  and thrown away. On a 19-document real archive this report therefore said
//  "19 documents had no detectable language", which was true of the ledger and
//  false about the documents: every one of them is English.
//
//  I asserted the claim from reading that the code EXISTS, without checking that
//  its OUTPUT is kept — the same mistake as grepping a name to prove a call.
//
//  So this now DETECTS the language itself, from stored content, at report time.
//  Read-only and off the ingest path on purpose: `Cleaner.clean` also collapses
//  whitespace and repairs encoding, so persisting its output would change the
//  stored text of every document, and it only cleans `perFileKOs.first`, so a
//  multi-message mbox would get its first message's language applied to all. That
//  is a pipeline decision for the owner, not a repair to smuggle into a report.
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
import NaturalLanguage
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

    /// Identify a language from a text sample. nil when the recogniser has no
    /// confident answer — a table of figures or a two-word note genuinely has
    /// no language, and guessing "en" would manufacture the very certainty this
    /// report exists to avoid.
    nonisolated static func detect(_ sample: String) -> String? {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        // Below this, identification is noise. Measured floor, not a guess: the
        // recogniser will happily label a single word.
        guard trimmed.count >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        // A low-confidence hypothesis is not a detection.
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        guard confidence >= 0.5 else { return nil }
        return language.rawValue
    }

    /// Build the report from the ledger.
    ///
    /// Uses a stored `meta.language` when present and detects from content
    /// otherwise — see the header for why nothing stores it today.
    public nonisolated static func build(database: Database) async -> Report? {
        guard KnowledgeModuleFlags.isEnabled(.languageHonesty) else { return nil }
        do {
            let total = Int((try await database.query(
                "SELECT COUNT(*) FROM knowledge_objects;", [])).first?.int(0) ?? 0)
            guard total > 0 else {
                return Report(coverage: [], undetectedCount: 0, totalDocuments: 0)
            }
            // The column is `metadata_json`, NOT `metadata`. The first version
            // of this query named the wrong column, so it threw, returned nil,
            // and the Ingestion Report omitted the language section entirely —
            // an English-only limit rendered as no limit at all. Exactly the
            // failure this file exists to prevent, committed inside it.
            //
            // json_extract is available in SQLite's JSON1, which this schema
            // already relies on elsewhere. A NULL result means either no
            // metadata or no language key — both are "undetected", which is
            // why they are counted together and NOT as English.
            // Prefer a stored language when one exists (a future ingest may
            // persist it); otherwise detect from the content that IS stored.
            // `substr` bounds the read: language identification needs a sample,
            // not a whole book, and pulling every document's full text through
            // SQLite would make this report the most expensive thing in the app.
            let rows = try await database.query("""
            SELECT json_extract(metadata_json, '$.language') AS lang,
                   substr(content, 1, 2000) AS sample
            FROM knowledge_objects;
            """, [])
            var tally: [String: Int] = [:]
            var undetected = 0
            for r in rows {
                let stored = r.string(0)
                let detected = (stored?.isEmpty == false)
                    ? stored
                    : Self.detect(r.string(1) ?? "")
                guard let code = detected, !code.isEmpty else { undetected += 1; continue }
                tally[code, default: 0] += 1
            }
            var coverage: [LanguageCoverage] = []
            for (raw, n) in tally {
                // NLLanguageRecognizer returns BCP-47 ("en", "hi", "zh-Hans").
                // Compare on the primary subtag so "en-GB" is supported too.
                let primary = raw.split(separator: "-").first.map(String.init) ?? raw
                coverage.append(LanguageCoverage(
                    languageCode: raw,
                    documentCount: n,
                    extractionSupported: extractionSupported.contains(primary.lowercased())))
            }
            coverage.sort { $0.documentCount > $1.documentCount }
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

//
//  CaseSearchService.swift
//  Kalsmritikosh
//
//  Living case map M5 (plan 2026-11-06 §8) — "Search case evidence": an explicit, deterministic search of
//  ONE case's authorised documents. The case's scope is resolved first; candidates, matching, counts,
//  witnesses and pages are all taken from the documents that scope resolves to — nothing outside the case is
//  read. Every match is enumerated (no top-N): pages are slices of the complete, stably ordered match list,
//  and a run that hits a document cap or its time limit says so and lists what it did not reach.
//
//  • Counts are kept apart: matching documents, occurrences (places in the text; overlapping matches count
//    once) and passages (the document's chunks that hold a match).
//  • Each hit carries a witness: the matched passages with the words highlighted, and the clauses it
//    satisfied (and those it lacked as required).
//  • Each run carries a receipt over the case scope it actually searched: searched, partly searched, not
//    searched (could not be read, no text, beyond a limit), excluded from the case, set-aside passages — from
//    Package B's CaseCoverageReadout. A zero-match result never implies that unsearched sources were searched.
//  • Saved searches: a live search (query + options + baseline) and a frozen receipt (one run as it was), in
//    the encrypted ledger. A live search reports new matches when the case's material changes; it never adds
//    a document to the case.
//  No model is called; nothing is sent anywhere.
//

import CryptoKit
import Foundation
import os

// MARK: - Scope and sources

/// The case scope a search runs over.
public nonisolated struct CaseSearchScope: Sendable, Equatable {
    public let caseID: UUID
    /// The case's authorised source versions (the only material searched).
    public let versionIDs: Set<UUID>
    /// Names of the sources the case explicitly excluded (never searched; listed in the receipt).
    public let excludedNames: [String]
    /// CaseScopeFingerprinter over the case revision and its authorised versions.
    public let fingerprint: String
    /// S4 (SEARCH-04) — the mother case's title, shown in the active-scope banner.
    public var caseTitle: String? = nil
    /// Prior cases whose material this search may read: always empty (a case search never reads another case).
    public var historicalSelection: [String] = []

    public init(caseID: UUID, versionIDs: Set<UUID>, excludedNames: [String], fingerprint: String) {
        self.caseID = caseID; self.versionIDs = versionIDs; self.excludedNames = excludedNames; self.fingerprint = fingerprint
    }
}

/// Where a case search reads from (the app passes its live services; tests pass fixtures).
public nonisolated struct CaseSearchSources: Sendable {
    /// The case's scope; throws when the case cannot be read (it may have been erased).
    public var scope: @Sendable (UUID) async throws -> CaseSearchScope
    /// Package B's reading coverage of the scope's versions (nil: not available).
    public var coverage: @Sendable (UUID, Set<UUID>) async -> CaseCoverageReadout?
    /// A name per source version (the same labels the coverage readout uses).
    public var labels: @Sendable ([UUID]) async -> [UUID: String]
    public var repository: CaseSearchRepository
    /// S4 (SEARCH-01) — the case's own records (the case map's projection); nil: not available here, said in the result.
    public var records: (@Sendable (UUID) async -> CaseMapProjection?)? = nil

    public init(scope: @escaping @Sendable (UUID) async throws -> CaseSearchScope,
                coverage: @escaping @Sendable (UUID, Set<UUID>) async -> CaseCoverageReadout?,
                labels: @escaping @Sendable ([UUID]) async -> [UUID: String],
                repository: CaseSearchRepository) {
        self.scope = scope; self.coverage = coverage; self.labels = labels; self.repository = repository
    }
}

// MARK: - Results

/// One matched passage, shown as the witness of a hit.
public nonisolated struct CaseSearchWitness: Sendable, Equatable, Hashable {
    /// The words around the match.
    public let snippet: String
    /// The matched words inside `snippet` (UTF-16 offsets).
    public let highlights: [Range<Int>]
    /// The exact matched words (for a citation or the chronology).
    public let matchedText: String
    /// The UTF-16 range of the match in the document's text.
    public let range: Range<Int>
    public let passageID: UUID?
    public let passageOrdinal: Int?
    public let page: Int?
    /// The match runs across a passage boundary (found because the whole document is searched).
    public let crossesPassageBoundary: Bool
}

public nonisolated struct CaseSearchHit: Identifiable, Sendable, Equatable {
    public var id: UUID { objectID }
    public let objectID: UUID
    public let versionIDs: [UUID]
    public let name: String
    public let sourceType: String
    public let occurrences: Int
    public let passages: Int
    public let crossBoundaryOccurrences: Int
    /// The clauses this document satisfied, as the explanation words them (with the field that matched).
    public let satisfied: [String]
    /// The NOT clauses it lacks, as required.
    public let absentAsRequired: [String]
    public let witnesses: [CaseSearchWitness]
    /// Searched, but only part of it could be read or searched (the reason).
    public let partly: String?
    /// Matched on recorded fields alone; its text could not be searched.
    public let textNotSearched: Bool
    /// S4 (SEARCH-03) — what the satisfied clauses matched against (exact text, an extracted value, a recorded field).
    public var bases: [CaseSearchMatchBasis] = []
    /// S4 (SEARCH-05) — where the document sits: attachment of / member of … (nearest first).
    public var nesting: [String] = []
    /// S4 (SEARCH-07) — the canonical entities a person clause matched, and the other matching documents that hold the
    /// same text (repeated copies, by the normalised-text digest).
    public var entities: [UUID] = []
    public var copies: [UUID] = []

    /// The exact locator of a witness: the version, the passage and page, the UTF-16 characters, and the attachment
    /// context — enough to find the same words in the searched representation again.
    public func locator(_ w: CaseSearchWitness) -> CaseSearchLocator {
        CaseSearchLocator(objectID: objectID, sourceVersionID: versionIDs.first, passageID: w.passageID, page: w.page, range: w.range, nesting: nesting)
    }
}

/// S4 (SEARCH-05) — where a match is, in the representation that was searched (the reader's text of the document).
public nonisolated struct CaseSearchLocator: Sendable, Equatable, Hashable {
    public let objectID: UUID
    public let sourceVersionID: UUID?
    public let passageID: UUID?
    public let page: Int?
    /// UTF-16 offsets in the document's text as the ledger holds it.
    public let range: Range<Int>
    public let nesting: [String]
    public var line: String {
        var parts = [sourceVersionID.map { "version \($0.uuidString.prefix(8))" } ?? "no source version"]
        if let passageID { parts.append("passage \(passageID.uuidString.prefix(8))") }
        if let page { parts.append("page \(page)") }
        parts.append("characters \(range.lowerBound)–\(range.upperBound) of the searched text")
        parts += nesting
        return parts.joined(separator: " · ")
    }
}

/// What the search covered — over the case scope it actually ran on.
public nonisolated struct CaseSearchReceipt: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case partlySearched, failed, unavailable, noText, notReached, excluded
        /// S4 (SEARCH-06): in the case but still waiting to be read; a file type the app cannot read.
        case pending, unsupported

        public var label: String {
            switch self {
            case .pending: return "Not searched — still waiting to be read"
            case .unsupported: return "Not searched — a file type this app cannot read"
            case .partlySearched: return "Partly searched"
            case .failed: return "Not searched — could not be read"
            case .unavailable: return "Not searched — no text in this Mac's ledger"
            case .noText: return "Not searched — no readable text"
            case .notReached: return "Not searched — beyond a limit of this run"
            case .excluded: return "Excluded from the case"
            }
        }
    }

    public struct Item: Codable, Sendable, Equatable, Hashable {
        public let name: String
        public let category: Category
        public let reason: String
        /// S4 (SEARCH-06) — the source versions this line is about.
        public var versionIDs: [UUID]? = nil
        public init(name: String, category: Category, reason: String, versionIDs: [UUID]? = nil) {
            self.name = name; self.category = category; self.reason = reason; self.versionIDs = versionIDs
        }
        var versionText: String { (versionIDs ?? []).isEmpty ? "" : " [" + (versionIDs ?? []).map { "version \($0.uuidString.prefix(8))" }.joined(separator: ", ") + "]" }
    }

    /// Documents whose text (and fields) were searched in full.
    public let searched: Int
    public let items: [Item]
    /// Passages the person set aside, blanked out before matching.
    public let setAsidePassages: Int
    /// Package B's reading coverage line for the case (nil: the reading record could not be read).
    public let coverageLine: String?
    public let notes: [String]
    public let complete: Bool

    public func items(_ c: Category) -> [Item] { items.filter { $0.category == c } }
    public var partlySearched: Int { items(.partlySearched).count }
    public var notSearched: Int { items.filter { $0.category != .partlySearched && $0.category != .excluded }.count }
    public var excluded: Int { items(.excluded).count }

    public var headline: String {
        var s = "Searched \(searched) document\(searched == 1 ? "" : "s") of this case in full"
        if partlySearched > 0 { s += ", \(partlySearched) in part" }
        s += "."
        if notSearched > 0 { s += " \(notSearched) not searched." }
        if excluded > 0 { s += " \(excluded) excluded from the case." }
        if setAsidePassages > 0 { s += " \(setAsidePassages) passage\(setAsidePassages == 1 ? "" : "s") you set aside not searched." }
        return s
    }

    /// The receipt as lines (for a saved receipt and an export).
    public var lines: [String] {
        var out = [headline]
        for c in Category.allCases {
            for i in items(c) { out.append("\(c.label): \(i.name) — \(i.reason)\(i.versionText)") }
        }
        if let coverageLine { out.append("What the app could read: \(coverageLine)") } else {
            out.append("The case's reading record could not be read; what was searched is counted from the ledger alone.")
        }
        out += notes
        return out
    }
}

/// A complete run of a case search.
public nonisolated struct CaseSearchRun: Sendable, Equatable {
    public let caseID: UUID
    public let query: CaseSearchQuery
    public let options: CaseSearchOptions
    public let executedAt: Date
    public let scopeFingerprint: String
    public let scopeVersionIDs: [UUID]
    public let indexRevision: String
    /// Every matching document, in the stable order (name, then document id).
    public let hits: [CaseSearchHit]
    public let receipt: CaseSearchReceipt
    /// Why the run stopped early (a cap, the time limit, cancellation); nil when it searched everything.
    public let stoppedEarly: String?
    /// S4 (SEARCH-04) — the active scope and every constraint that ran, one line each.
    public var activeScope: [String] = []
    /// S4 (SEARCH-01) — the case's own records searched with the same query (nil: not searched in this run, and why).
    public var records: CaseRecordSearchResult? = nil
    public var recordsNotSearched: String? = nil
    /// S4 (SEARCH-07) — canonical entities matched by person clauses, and the matching documents that are copies of the
    /// same text (each group listed once).
    public var canonicalEntities: Int = 0
    public var copyGroups: [[UUID]] = []
    /// S4 (SEARCH-11) — how to continue a run that stopped early (nil: nothing left, or it cannot be continued).
    public var continuation: CaseSearchContinuation? = nil
    public var distinctTexts: Int { documentCount - copyGroups.reduce(0) { $0 + $1.count - 1 } }

    public var documentCount: Int { hits.count }
    public var occurrenceCount: Int { hits.reduce(0) { $0 + $1.occurrences } }
    public var passageCount: Int { hits.reduce(0) { $0 + $1.passages } }
    public var explanation: [String] { query.explanation }
    public var isComplete: Bool { stoppedEarly == nil && receipt.complete }

    public var pageCount: Int { max(1, (hits.count + options.pageSize - 1) / options.pageSize) }

    /// Page `index` (from 0) of the complete match list.
    public func page(_ index: Int) -> CaseSearchPage {
        let size = options.pageSize
        let start = min(max(0, index) * size, hits.count)
        let end = min(start + size, hits.count)
        return CaseSearchPage(index: max(0, index), pageCount: pageCount, total: hits.count, firstNumber: start + 1, hits: Array(hits[start..<end]))
    }

    /// The counts line: documents, occurrences and passages kept apart, and whether the list is complete.
    public var countsLine: String {
        let d = "\(documentCount) matching document\(documentCount == 1 ? "" : "s")"
        let o = "\(occurrenceCount) occurrence\(occurrenceCount == 1 ? "" : "s")"
        let p = "\(passageCount) passage\(passageCount == 1 ? "" : "s")"
        var extra = ""
        if !copyGroups.isEmpty { extra += " · \(distinctTexts) distinct text\(distinctTexts == 1 ? "" : "s") (\(documentCount - distinctTexts) repeated cop\(documentCount - distinctTexts == 1 ? "y" : "ies"))" }
        if canonicalEntities > 0 { extra += " · \(canonicalEntities) recorded person or organisation\(canonicalEntities == 1 ? "" : "s") matched" }
        return "\(d) · \(o) · \(p)" + extra + (isComplete ? " · every match is listed" : " · incomplete: see what was not searched")
    }

    /// What zero matches means — never more than what was searched.
    public var zeroMatchStatement: String? {
        guard hits.isEmpty else { return nil }
        var s = "No match among the \(receipt.searched + receipt.partlySearched) document\(receipt.searched + receipt.partlySearched == 1 ? "" : "s") searched."
        if receipt.notSearched > 0 || receipt.excluded > 0 || receipt.partlySearched > 0 || stoppedEarly != nil {
            s += " This says nothing about what was not searched: "
            var parts: [String] = []
            if receipt.notSearched > 0 { parts.append("\(receipt.notSearched) not searched") }
            if receipt.partlySearched > 0 { parts.append("\(receipt.partlySearched) searched only in part") }
            if receipt.excluded > 0 { parts.append("\(receipt.excluded) excluded from the case") }
            s += parts.joined(separator: ", ") + " (listed in the receipt)."
        }
        return s
    }

    /// What a saved search keeps of this run.
    public var storedResult: CaseSearchStoredResult {
        CaseSearchStoredResult(matchedObjectIDs: hits.map(\.objectID), names: Dictionary(uniqueKeysWithValues: hits.map { ($0.objectID.uuidString, $0.name) }),
                               documents: documentCount, occurrences: occurrenceCount, passages: passageCount, complete: isComplete,
                               receiptLines: activeScope + receipt.lines + (stoppedEarly.map { ["Stopped early: \($0)"] } ?? []) + (records?.lines ?? recordsNotSearched.map { [$0] } ?? []))
    }
}

public nonisolated struct CaseSearchPage: Sendable, Equatable {
    public let index: Int
    public let pageCount: Int
    public let total: Int
    /// The 1-based number of the first hit on this page.
    public let firstNumber: Int
    public let hits: [CaseSearchHit]
    public var rangeLine: String {
        hits.isEmpty ? "No matches" : "Matches \(firstNumber)–\(firstNumber + hits.count - 1) of \(total) · page \(index + 1) of \(pageCount)"
    }
}

public nonisolated enum CaseSearchOutcome: Sendable, Equatable {
    /// The query or its options cannot run; nothing was searched.
    case rejected([String], repair: CaseSearchParse.Repair?)
    /// The case or its documents could not be read; nothing is shown as a result.
    case failed(String)
    case ran(CaseSearchRun)

    public var run: CaseSearchRun? { if case .ran(let r) = self { return r }; return nil }
}

/// What changed for a live saved search since its baseline.
public nonisolated struct CaseSearchChanges: Sendable, Equatable {
    public let saved: CaseSavedSearch
    public let current: CaseSearchRun
    public let newMatches: [CaseSearchHit]
    /// Documents of the baseline that no longer match (or are no longer in the case).
    public let noLongerMatching: [UUID]
    public let scopeChanged: Bool
    public let indexChanged: Bool

    public var summary: String {
        var parts: [String] = []
        parts.append(newMatches.isEmpty ? "No new matches" : "\(newMatches.count) new matching document\(newMatches.count == 1 ? "" : "s")")
        if !noLongerMatching.isEmpty { parts.append("\(noLongerMatching.count) no longer match") }
        if scopeChanged { parts.append("the case's documents changed") }
        if indexChanged && !scopeChanged { parts.append("documents were read again") }
        return parts.joined(separator: " · ") + " since \(saved.executedAt.formatted(date: .abbreviated, time: .shortened))."
    }
}

/// S4 (SEARCH-11) — how far a run is (documents searched of the documents it will search).
public nonisolated struct CaseSearchProgress: Sendable, Equatable {
    public let searched: Int
    public let total: Int
    public var line: String { "Searched \(searched) of \(total) document\(total == 1 ? "" : "s")…" }
}

/// S4 (SEARCH-11) — what a stopped run had done, so it can continue without searching anything twice.
public nonisolated struct CaseSearchContinuation: Sendable, Equatable {
    let reachedIDs: Set<UUID>
    let hits: [CaseSearchHit]
    let docItems: [CaseSearchReceipt.Item]
    let searchedInFull: Int
    let setAside: Int
    let undatedStated: Int
    let undatedModified: Int
    let scopeFingerprint: String
    let reachedRevision: String
    /// Documents not reached yet.
    public let remaining: Int
}

/// S4 (SEARCH-10) — a live search re-run under its policy found new matches. Each new match keeps its provenance: the
/// source versions it was read from, the index revision and the case scope the re-run ran over.
public nonisolated struct CaseSearchAlert: Sendable, Equatable, Identifiable {
    public var id: UUID { saved.id }
    public let saved: CaseSavedSearch
    public let changes: CaseSearchChanges
    public let digest: String
    public var provenance: [String] {
        changes.newMatches.map { h in
            "\(h.name) — read from " + h.versionIDs.map { "version \($0.uuidString.prefix(8))" }.joined(separator: ", ")
                + " · index \(changes.current.indexRevision) · re-run \(changes.current.executedAt.formatted(date: .abbreviated, time: .shortened))"
        }
    }
    static func digest(_ ids: [UUID], index: String) -> String {
        let canonical = ids.map(\.uuidString).sorted().joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The service

public actor CaseSearchService {
    private let sources: CaseSearchSources
    public init(sources: CaseSearchSources) { self.sources = sources }

    public nonisolated var repository: CaseSearchRepository { sources.repository }

    /// Parse strictly, then run. An invalid query runs nothing (its repair, if any, is only offered).
    public func run(caseID: UUID, text: String, options: CaseSearchOptions = CaseSearchOptions(), now: Date = Date()) async -> CaseSearchOutcome {
        let parsed = CaseSearchParser.parse(text)
        guard parsed.isValid, let q = parsed.query else { return .rejected(parsed.errors, repair: parsed.repair) }
        return await run(caseID: caseID, query: q, options: options, now: now)
    }

    public func run(caseID: UUID, query: CaseSearchQuery, options: CaseSearchOptions = CaseSearchOptions(), now: Date = Date(),
                    progress: (@Sendable (CaseSearchProgress) -> Void)? = nil) async -> CaseSearchOutcome {
        await execute(caseID: caseID, query: query, options: options, now: now, progress: progress, resume: nil)
    }

    /// S4 (SEARCH-11) — continue a run that stopped early (cancelled, the time limit) from where it stopped. Refused when
    /// the case's documents or scope changed since (a re-read or rebuilt index), so a resumed run never mixes two states.
    /// `timeLimitSeconds`: the time the continued part may take (the matching options themselves never change).
    public func resume(_ run: CaseSearchRun, timeLimitSeconds: Double? = nil, now: Date = Date(),
                       progress: (@Sendable (CaseSearchProgress) -> Void)? = nil) async -> CaseSearchOutcome {
        guard let c = run.continuation else {
            return .rejected(["This run cannot be continued: it searched everything it could, or it stopped at a limit that a new run must change."], repair: nil)
        }
        var o = run.options
        if let t = timeLimitSeconds { o.timeLimitSeconds = t }
        return await execute(caseID: run.caseID, query: run.query, options: o, now: now, progress: progress, resume: c)
    }

    private func execute(caseID: UUID, query: CaseSearchQuery, options: CaseSearchOptions, now: Date,
                         progress: (@Sendable (CaseSearchProgress) -> Void)?, resume: CaseSearchContinuation?) async -> CaseSearchOutcome {
        guard query.version == CaseSearchQuery.currentVersion else {
            return .rejected(["This search was saved with query version \(query.version); this app reads version \(CaseSearchQuery.currentVersion). It is not reinterpreted — type it again."], repair: nil)
        }
        let problems = options.problems
        guard problems.isEmpty else { return .rejected(problems, repair: nil) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(options.timeLimitSeconds * 1000)))
        let repo = sources.repository

        let scope: CaseSearchScope
        do { scope = try await sources.scope(caseID) } catch {
            KalsmritikoshLog.app.error("Case search scope failed: \(error.localizedDescription, privacy: .public)")
            return .failed("The case could not be read (it may have been erased). Nothing was searched.")
        }
        guard scope.caseID == caseID else { return .failed("The case scope did not match the case. Nothing was searched.") }
        if let resume, resume.scopeFingerprint != scope.fingerprint {
            return .rejected(["The case's documents changed since this run stopped, so it cannot be continued. Run the search again."], repair: nil)
        }
        let plan = CaseSearchPlan(query: query, options: options)

        do {
            let (allDocs, withoutDocument) = try await repo.documents(versionIDs: scope.versionIDs)
            let docs = allDocs.sorted { ($0.name.lowercased(), $0.objectID.uuidString) < ($1.name.lowercased(), $1.objectID.uuidString) }
            let coverage = await sources.coverage(caseID, scope.versionIDs)
            let labels = await sources.labels(Array(withoutDocument))
            var docItems: [CaseSearchReceipt.Item] = resume?.docItems ?? []
            var items: [CaseSearchReceipt.Item] = []
            var notes: [String] = []

            // Over the document cap: listed, not searched.
            let candidates = Array(docs.prefix(options.maxDocuments))
            var stoppedEarly: String?
            if docs.count > candidates.count {
                stoppedEarly = "This run searches at most \(options.maxDocuments) documents; \(docs.count - candidates.count) more were not searched."
                for d in docs.dropFirst(candidates.count) {
                    items.append(.init(name: d.name, category: .notReached, reason: "beyond the \(options.maxDocuments)-document limit of one run", versionIDs: d.versionIDs))
                }
            }
            let ids = candidates.map(\.objectID)
            // A resumed run checks that what it already searched was not read again since (an index rebuild).
            let already = resume?.reachedIDs ?? []
            if let resume {
                let reachedRows = candidates.filter { already.contains($0.objectID) }
                if try await repo.indexRevision(reachedRows, semantics: CaseSearchQuery.currentVersion) != resume.reachedRevision {
                    return .rejected(["Documents this run had already searched were read again since it stopped, so it cannot be continued. Run the search again."], repair: nil)
                }
            }
            let revisionAtStart = try await repo.indexRevision(candidates, semantics: CaseSearchQuery.currentVersion)

            // Stored-field clauses: parameterised SQL over the case's documents only.
            var stored: [CaseSearchStoredField: Set<UUID>] = [:]
            for f in plan.storedFields { stored[f] = try await repo.matching(f, within: ids, zone: options.timeZone) }
            let mentions = plan.needsMentions ? try await repo.mentions(objectIDs: ids) : [:]
            let mentionEntities = plan.needsMentions ? try await repo.mentionEntities(objectIDs: ids) : [:]

            // Partly read documents, from the case's reading record (Package B).
            let partlyByName = Dictionary((coverage?.partlyRead ?? []).map { ($0.name, $0.reason ?? "only part of it could be read") }, uniquingKeysWith: { a, _ in a })
            let notReadByName = Dictionary((coverage?.notRead ?? []).map { ($0.name, $0.reason ?? "it could not be read") }, uniquingKeysWith: { a, _ in a })

            var hits: [CaseSearchHit] = resume?.hits ?? []
            var searchedInFull = resume?.searchedInFull ?? 0
            var setAside = resume?.setAside ?? 0
            var undatedStated = resume?.undatedStated ?? 0, undatedModified = resume?.undatedModified ?? 0
            var reachedIDs = already
            let todo = candidates.filter { !already.contains($0.objectID) }
            progress?(CaseSearchProgress(searched: reachedIDs.count, total: candidates.count))
            batches: for batch in stride(from: 0, to: todo.count, by: 16).map({ Array(todo[$0..<min($0 + 16, todo.count)]) }) {
                if Task.isCancelled { stoppedEarly = "The search was cancelled."; break batches }
                if clock.now >= deadline { stoppedEarly = "The time limit of \(Int(options.timeLimitSeconds)) seconds was reached."; break batches }
                let batchIDs = batch.map(\.objectID)
                let texts = plan.hasTextLeaves ? try await repo.contents(objectIDs: batchIDs) : [:]
                let passages = try await repo.passages(objectIDs: batchIDs)
                for d in batch {
                    if clock.now >= deadline { stoppedEarly = "The time limit of \(Int(options.timeLimitSeconds)) seconds was reached."; break batches }
                    reachedIDs.insert(d.objectID)
                    let stated = CaseSearchDates.parseStated(d.statedDateText)
                    if plan.usesStatedDate, stated == nil { undatedStated += 1 }
                    if plan.usesModifiedDate, d.modifiedAt == nil { undatedModified += 1 }
                    var facts = CaseSearchDocumentFacts(fileName: d.name, statedDate: stated, statedDateText: d.statedDateText,
                                                        mentions: mentions[d.objectID] ?? [])
                    facts.mentionEntities = mentionEntities[d.objectID] ?? [:]
                    for (f, set) in stored where set.contains(d.objectID) { facts.stored.insert(f) }
                    let docPassages = passages[d.objectID] ?? []
                    let live = docPassages.filter { !$0.setAside }
                    let masked = Self.setAsideRanges(docPassages)
                    setAside += docPassages.filter(\.setAside).count

                    var partly: String? = partlyByName[d.name].map { "partly read: \($0)" }
                    var docText: CaseSearchDocumentText?
                    var content = ""
                    if plan.hasTextLeaves {
                        content = texts[d.objectID] ?? ""
                        // Decided by its fields alone? Then its text is not needed.
                        let fieldsOnly = CaseSearchEvaluator.leafOutcomes(plan, text: nil, facts: facts)
                        let pre = plan.evaluate { fieldsOnly[$0]?.matched }
                        if pre == false {
                            if partly != nil { docItems.append(.init(name: d.name, category: .partlySearched, reason: partly ?? "", versionIDs: d.versionIDs)) } else { searchedInFull += 1 }
                            continue
                        }
                        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let reason = notReadByName[d.name] ?? "the ledger holds no text for it"
                            docItems.append(.init(name: d.name, category: Self.category(reason, fallback: .noText), reason: reason, versionIDs: d.versionIDs))
                            if pre == true {
                                hits.append(Self.hit(d, plan: plan, outcomes: fieldsOnly,
                                                     content: "", passages: live, partly: nil, textNotSearched: true))
                            }
                            continue
                        }
                        if content.utf16.count > options.maxCharactersPerDocument {
                            let cut = Self.prefix(content, utf16: options.maxCharactersPerDocument)
                            partly = "only the first \(options.maxCharactersPerDocument) characters were searched (of \(content.utf16.count))"
                            content = cut
                        }
                        docText = CaseSearchDocumentText(content, options: options, masked: masked, needsLiteral: plan.needsLiteral, needsAmounts: plan.needsAmounts)
                    }
                    let outcomes = CaseSearchEvaluator.leafOutcomes(plan, text: docText, facts: facts)
                    if let partly { docItems.append(.init(name: d.name, category: .partlySearched, reason: partly, versionIDs: d.versionIDs)) } else { searchedInFull += 1 }
                    guard plan.evaluate({ outcomes[$0]?.matched }) == true else { continue }
                    hits.append(Self.hit(d, plan: plan, outcomes: outcomes, content: content, passages: live, partly: partly, textNotSearched: false))
                }
                progress?(CaseSearchProgress(searched: reachedIDs.count, total: candidates.count))
            }
            let unreached = candidates.filter { !reachedIDs.contains($0.objectID) }
            if !unreached.isEmpty, let why = stoppedEarly {
                for d in unreached { items.append(.init(name: d.name, category: .notReached, reason: why, versionIDs: d.versionIDs)) }
            }
            // The index was rebuilt or documents were read again while the run went on: never shown as complete.
            let revision = try await repo.indexRevision(candidates, semantics: CaseSearchQuery.currentVersion)
            if revision != revisionAtStart, stoppedEarly == nil {
                stoppedEarly = "Documents of the case were read again while the search ran, so the result may mix two states. Run it again."
            }

            // Versions of the case with no document here: still waiting, unsupported, could not be read, or no text here.
            for v in withoutDocument.sorted(by: { $0.uuidString < $1.uuidString }) {
                let name = labels[v] ?? "Source \(v.uuidString.prefix(8))"
                if let why = notReadByName[name], why != CaseCoverageReadout.noReadingRecord {
                    items.append(.init(name: name, category: Self.category(why, fallback: .failed), reason: why, versionIDs: [v]))
                } else {
                    items.append(.init(name: name, category: .unavailable, reason: "no text for it in this Mac's ledger", versionIDs: [v]))
                }
            }
            items = docItems + items
            // What the reading record lists as not read and is not one of the above (an archive's members).
            let listed = Set(items.map(\.name)).union(docs.map(\.name))
            for e in coverage?.notRead ?? [] where !listed.contains(e.name) {
                let why = e.reason ?? "it could not be read"
                items.append(.init(name: e.name, category: Self.category(why, fallback: .failed), reason: why))
            }
            for n in scope.excludedNames.sorted() { items.append(.init(name: n, category: .excluded, reason: "excluded from the case; never searched")) }
            notes += coverage?.notes ?? []
            if undatedStated > 0 { notes.append("\(undatedStated) searched document\(undatedStated == 1 ? " states no date of its own" : "s state no date of their own"), so a stated-date clause cannot match \(undatedStated == 1 ? "it" : "them").") }
            if undatedModified > 0 { notes.append("\(undatedModified) searched document\(undatedModified == 1 ? " has" : "s have") no file modified date, so a modified-date clause cannot match \(undatedModified == 1 ? "it" : "them").") }
            if plan.usesEventDate {
                let withEvents = try await repo.documentsWithEvents(objectIDs: ids)
                let none = ids.count - withEvents.count
                if none > 0 { notes.append("\(none) searched document\(none == 1 ? " has" : "s have") no extracted event, so an event-date clause cannot match \(none == 1 ? "it" : "them").") }
            }
            if plan.needsAmounts { notes.append("Amounts are read only where a currency mark is written next to the number (₹, Rs, INR, $, €, £ …); amounts in words or in lakh/crore are not read, and currencies are never converted.") }
            if case .not = query.root { notes.append("This search lists documents that LACK what you typed; documents that were not searched are never listed as lacking it.") }

            let complete = stoppedEarly == nil && items.allSatisfy { $0.category == .excluded }
            let receipt = CaseSearchReceipt(searched: searchedInFull, items: items, setAsidePassages: setAside, coverageLine: coverage?.summaryLine,
                                            notes: notes, complete: complete)
            // SEARCH-05 / SEARCH-07 — attachment context, copies of the same text, canonical entities.
            let matchedVersions = hits.flatMap(\.versionIDs)
            let nesting = try await repo.nesting(versionIDs: matchedVersions)
            let digests = try await repo.textDigests(versionIDs: matchedVersions)
            var byDigest: [String: [UUID]] = [:]
            for h in hits {
                let ds = Set(h.versionIDs.compactMap { digests[$0] })
                if let d = ds.sorted().first { byDigest[d, default: []].append(h.objectID) }
            }
            let groups = byDigest.values.filter { $0.count > 1 }.map { $0.sorted { $0.uuidString < $1.uuidString } }.sorted { $0[0].uuidString < $1[0].uuidString }
            let copyOf = Dictionary(groups.flatMap { g in g.map { id in (id, g.filter { $0 != id }) } }, uniquingKeysWith: { a, _ in a })
            hits = hits.map { h in
                var x = h
                x.nesting = h.versionIDs.compactMap { nesting[$0] }.first ?? []
                x.copies = copyOf[h.objectID] ?? []
                return x
            }
            let sorted = hits.sorted { ($0.name.lowercased(), $0.objectID.uuidString) < ($1.name.lowercased(), $1.objectID.uuidString) }
            var run = CaseSearchRun(caseID: caseID, query: query, options: options, executedAt: now, scopeFingerprint: scope.fingerprint,
                                    scopeVersionIDs: scope.versionIDs.sorted { $0.uuidString < $1.uuidString }, indexRevision: revision,
                                    hits: sorted, receipt: receipt, stoppedEarly: stoppedEarly)
            run.copyGroups = groups
            run.canonicalEntities = Set(sorted.flatMap(\.entities)).count
            run.activeScope = Self.activeScope(scope, plan: plan, options: options, documents: candidates.count)
            // A run stopped by cancellation or the time limit can be continued from where it stopped (not a cap: a cap is
            // a setting of the run, changed by running again).
            if !unreached.isEmpty, stoppedEarly != nil {
                let reachedRows = candidates.filter { reachedIDs.contains($0.objectID) }
                run.continuation = CaseSearchContinuation(reachedIDs: reachedIDs, hits: hits.map { var h = $0; h.nesting = []; h.copies = []; return h },
                                                          docItems: docItems, searchedInFull: searchedInFull, setAside: setAside,
                                                          undatedStated: undatedStated, undatedModified: undatedModified, scopeFingerprint: scope.fingerprint,
                                                          reachedRevision: try await repo.indexRevision(reachedRows, semantics: CaseSearchQuery.currentVersion),
                                                          remaining: unreached.count)
            }
            // SEARCH-01 — the case's own records, with the same query.
            if let records = sources.records {
                if let projection = await records(caseID), projection.caseID == caseID {
                    run.records = CaseRecordSearch.run(plan, projection: projection)
                } else {
                    run.recordsNotSearched = "The case's records (questions, notes, report points, tasks, people, money) could not be read for this search; only its documents were searched."
                }
            } else {
                run.recordsNotSearched = "Only the case's documents were searched here; its records (questions, notes, report points, tasks, people, money) were not."
            }
            return .ran(run)
        } catch {
            KalsmritikoshLog.app.error("Case search failed: \(error.localizedDescription, privacy: .public)")
            return .failed("The case's documents could not be read (\(error.localizedDescription)). Nothing is shown as a result.")
        }
    }

    /// SEARCH-06 — the reading record's reason sorted into the receipt's categories.
    static func category(_ reason: String, fallback: CaseSearchReceipt.Category) -> CaseSearchReceipt.Category {
        let r = reason.lowercased()
        if r.contains("waiting to be read") || r.contains("not read yet") || r.contains("queued") { return .pending }
        if r.contains("unsupported") { return .unsupported }
        return fallback
    }

    /// SEARCH-04 — the banner of what this run searched: the mother case, the historical selection, every constraint.
    static func activeScope(_ scope: CaseSearchScope, plan: CaseSearchPlan, options: CaseSearchOptions, documents: Int) -> [String] {
        var out = ["Mother case: \(scope.caseTitle ?? "this case") — only its \(scope.versionIDs.count) authorised source version\(scope.versionIDs.count == 1 ? "" : "s") (\(documents) document\(documents == 1 ? "" : "s")) are read."]
        out.append(scope.historicalSelection.isEmpty ? "Prior cases: none — a case search never reads another case's material, nor its names or counts."
                                                     : "Prior cases included by your selection: " + scope.historicalSelection.joined(separator: ", "))
        if !scope.excludedNames.isEmpty { out.append("Excluded from the case (never read): \(scope.excludedNames.count)") }
        for (i, leaf) in plan.leaves.enumerated() {
            switch leaf {
            case .statedDate(let d), .stored(.modified(let d)), .stored(.event(let d)):
                out.append("Date meaning: \(d.kind.label.lowercased()) — “\(plan.clauseText[i])” (calendar days in \(options.timeZoneID))")
            default: break
            }
        }
        out.append("Matching: " + options.summary)
        out.append("Limits of this run: at most \(options.maxDocuments) documents, \(options.maxCharactersPerDocument) characters each, \(Int(options.timeLimitSeconds)) seconds")
        return out
    }

    // MARK: Building a hit

    static func setAsideRanges(_ passages: [CaseSearchPassageRow]) -> [Range<Int>] {
        // Blank only what no live passage also covers (passages may overlap).
        let aside = passages.filter(\.setAside).map(\.range).sorted { $0.lowerBound < $1.lowerBound }
        guard !aside.isEmpty else { return [] }
        let live = passages.filter { !$0.setAside }.map(\.range)
        var out: [Range<Int>] = []
        for r in aside {
            var pieces = [r]
            for l in live {
                pieces = pieces.flatMap { p -> [Range<Int>] in
                    guard p.overlaps(l) else { return [p] }
                    var keep: [Range<Int>] = []
                    if p.lowerBound < l.lowerBound { keep.append(p.lowerBound..<l.lowerBound) }
                    if l.upperBound < p.upperBound { keep.append(l.upperBound..<p.upperBound) }
                    return keep
                }
            }
            out += pieces
        }
        out.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for r in out {
            if let last = merged.last, last.upperBound >= r.lowerBound { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound) }
            else { merged.append(r) }
        }
        return merged
    }

    static func prefix(_ s: String, utf16 n: Int) -> String {
        var idx = s.startIndex, count = 0
        for ch in s {
            let w = ch.utf16.count
            if count + w > n { break }
            count += w
            idx = s.index(after: idx)
        }
        return String(s[..<idx])
    }

    static func hit(_ d: CaseSearchDocumentRow, plan: CaseSearchPlan, outcomes: [CaseSearchLeafOutcome?], content: String,
                    passages: [CaseSearchPassageRow], partly: String?, textNotSearched: Bool) -> CaseSearchHit {
        var satisfied: [String] = [], absent: [String] = []
        var ranges: [Range<Int>] = []
        for (i, o) in outcomes.enumerated() {
            guard let o else { continue }   // unknown: the text was not searched
            if plan.positive[i], o.matched {
                satisfied.append(plan.clauseText[i] + (o.detail.map { " — \($0)" } ?? ""))
                ranges += o.ranges
            } else if !plan.positive[i], !o.matched {
                absent.append(plan.absentText[i])
            }
        }
        // Occurrences: places in the text; overlapping matches count once.
        ranges.sort { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        var merged: [Range<Int>] = []
        for r in ranges {
            if let last = merged.last, last.overlaps(r) { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound) }
            else { merged.append(r) }
        }
        var passageIDs = Set<UUID>()
        var crossing = 0
        var witnesses: [CaseSearchWitness] = []
        let ns = content as NSString
        for r in merged {
            let overlapping = passages.filter { $0.range.overlaps(r) }
            for p in overlapping { passageIDs.insert(p.id) }
            let container = overlapping.first { $0.range.lowerBound <= r.lowerBound && r.upperBound <= $0.range.upperBound }
            let crosses = container == nil && !overlapping.isEmpty
            if crosses { crossing += 1 }
            guard witnesses.count < plan.options.witnessesPerDocument, r.upperBound <= ns.length else { continue }
            let from = max(0, r.lowerBound - 90), to = min(ns.length, r.upperBound + 90)
            let window = ns.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from))
            // Line breaks shown as spaces, one unit for one, so the highlight offsets stay exact.
            let raw = ns.substring(with: window) as NSString
            let once = raw.replacingOccurrences(of: "\n", with: " ", options: .literal, range: NSRange(location: 0, length: raw.length)) as NSString
            let snippet = once.replacingOccurrences(of: "\r", with: " ", options: .literal, range: NSRange(location: 0, length: once.length))
            // Highlight every merged range that falls in the window.
            let hl = merged.filter { $0.lowerBound >= window.location && $0.upperBound <= window.location + window.length }
                .map { ($0.lowerBound - window.location)..<($0.upperBound - window.location) }
            let first = container ?? overlapping.first
            witnesses.append(CaseSearchWitness(snippet: (window.location > 0 ? "…" : "") + snippet + (window.location + window.length < ns.length ? "…" : ""),
                                               highlights: hl.map { r2 in window.location > 0 ? (r2.lowerBound + 1)..<(r2.upperBound + 1) : r2 },
                                               matchedText: ns.substring(with: NSRange(location: r.lowerBound, length: r.count)),
                                               range: r, passageID: first?.id, passageOrdinal: first?.ordinal, page: first?.page,
                                               crossesPassageBoundary: crosses))
        }
        var hit = CaseSearchHit(objectID: d.objectID, versionIDs: d.versionIDs, name: d.name, sourceType: d.sourceType, occurrences: merged.count,
                                passages: passageIDs.count, crossBoundaryOccurrences: crossing, satisfied: satisfied, absentAsRequired: absent,
                                witnesses: witnesses, partly: partly, textNotSearched: textNotSearched)
        var bases = Set<CaseSearchMatchBasis>(), entities = Set<UUID>()
        for (i, o) in outcomes.enumerated() {
            guard let o, plan.positive[i], o.matched else { continue }
            bases.insert(o.basis); entities.formUnion(o.entities)
        }
        hit.bases = CaseSearchMatchBasis.allCases.filter(bases.contains)
        hit.entities = entities.sorted { $0.uuidString < $1.uuidString }
        return hit
    }

    // MARK: Saved searches

    /// Save a run: `.live` keeps the query and this run as its baseline; `.receipt` freezes this run.
    @discardableResult
    public func save(_ run: CaseSearchRun, name: String, kind: CaseSavedSearch.Kind, actor: String) async throws -> UUID {
        try await sources.repository.save(caseID: run.caseID, name: name, kind: kind, query: run.query, options: run.options,
                                          scopeFingerprint: run.scopeFingerprint, scopeVersionIDs: run.scopeVersionIDs,
                                          indexRevision: run.indexRevision, executedAt: run.executedAt, result: run.storedResult, actor: actor)
    }

    /// Run a live saved search again over the case's CURRENT scope and say what changed since its baseline.
    /// It reads only the case's authorised material: a document outside the case is never added or searched.
    public func changes(for saved: CaseSavedSearch, now: Date = Date()) async -> Result<CaseSearchChanges, CaseSearchServiceError> {
        guard let q = saved.query, let options = saved.options else { return .failure(.unreadable) }
        switch await run(caseID: saved.caseID, query: q, options: options, now: now) {
        case .rejected(let why, _): return .failure(.rejected(why.joined(separator: " ")))
        case .failed(let why): return .failure(.failed(why))
        case .ran(let current):
            let before = Set(saved.result.matchedObjectIDs)
            let now = Set(current.hits.map(\.objectID))
            return .success(CaseSearchChanges(saved: saved, current: current, newMatches: current.hits.filter { !before.contains($0.objectID) },
                                              noLongerMatching: saved.result.matchedObjectIDs.filter { !now.contains($0) },
                                              scopeChanged: current.scopeFingerprint != saved.scopeFingerprint,
                                              indexChanged: current.indexRevision != saved.indexRevision))
        }
    }

    /// S4 (SEARCH-10) — re-run the case's live searches whose policy is "when the case's material changes", but only those
    /// whose scope or index changed since their baseline. A new-match set that was already reported is not reported again
    /// (its digest is kept); seeing an alert is not acknowledging it — the baseline moves only when the person marks it seen.
    public func rerunDue(caseID: UUID, now: Date = Date()) async -> [CaseSearchAlert] {
        let saved: [CaseSavedSearch]
        do { saved = try await sources.repository.savedSearches(caseID: caseID) } catch {
            KalsmritikoshLog.app.error("Saved case searches unreadable for re-run: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var out: [CaseSearchAlert] = []
        for s in saved where s.kind == .live && s.rerunPolicy == .onMaterialChange {
            guard case .success(let c) = await changes(for: s, now: now) else { continue }
            guard c.scopeChanged || c.indexChanged, !c.newMatches.isEmpty else { continue }
            let digest = CaseSearchAlert.digest(c.newMatches.map(\.objectID), index: c.current.indexRevision)
            guard digest != s.alertedDigest else { continue }   // the same new matches were reported already
            do { try await sources.repository.markAlerted(id: s.id, caseID: caseID, digest: digest, at: now) } catch {
                KalsmritikoshLog.app.error("Case search alert not recorded: \(error.localizedDescription, privacy: .public)")
            }
            out.append(CaseSearchAlert(saved: s, changes: c, digest: digest))
        }
        return out
    }

    /// The person has seen the changes: the live search's baseline becomes `run`. (A receipt never changes.)
    public func acknowledge(_ saved: CaseSavedSearch, run: CaseSearchRun) async throws {
        try await sources.repository.updateBaseline(id: saved.id, caseID: saved.caseID, scopeFingerprint: run.scopeFingerprint,
                                                    scopeVersionIDs: run.scopeVersionIDs, indexRevision: run.indexRevision,
                                                    executedAt: run.executedAt, result: run.storedResult)
    }
}

public nonisolated enum CaseSearchServiceError: Error, Equatable, LocalizedError {
    case unreadable
    case rejected(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "This saved search was written by a different version and cannot be read; it is not reinterpreted."
        case .rejected(let s), .failed(let s): return s
        }
    }
}

// MARK: - Stated dates

public nonisolated enum CaseSearchDates {
    /// The date a document states in its own date field (ISO 8601 or an email's RFC 2822 Date), or nil.
    public static func parseStated(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let iso = ISO8601DateFormatter().date(from: s) { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ",
                    "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

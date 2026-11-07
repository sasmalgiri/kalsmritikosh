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
}

/// What the search covered — over the case scope it actually ran on.
public nonisolated struct CaseSearchReceipt: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case partlySearched, failed, unavailable, noText, notReached, excluded

        public var label: String {
            switch self {
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
            for i in items(c) { out.append("\(c.label): \(i.name) — \(i.reason)") }
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
        return "\(d) · \(o) · \(p)" + (isComplete ? " · every match is listed" : " · incomplete: see what was not searched")
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
                               receiptLines: receipt.lines + (stoppedEarly.map { ["Stopped early: \($0)"] } ?? []))
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

    public func run(caseID: UUID, query: CaseSearchQuery, options: CaseSearchOptions = CaseSearchOptions(), now: Date = Date()) async -> CaseSearchOutcome {
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
        let plan = CaseSearchPlan(query: query, options: options)

        do {
            let (allDocs, withoutDocument) = try await repo.documents(versionIDs: scope.versionIDs)
            let docs = allDocs.sorted { ($0.name.lowercased(), $0.objectID.uuidString) < ($1.name.lowercased(), $1.objectID.uuidString) }
            let coverage = await sources.coverage(caseID, scope.versionIDs)
            let labels = await sources.labels(Array(withoutDocument))
            var items: [CaseSearchReceipt.Item] = []
            var notes: [String] = []

            // Over the document cap: listed, not searched.
            let candidates = Array(docs.prefix(options.maxDocuments))
            var stoppedEarly: String?
            if docs.count > candidates.count {
                stoppedEarly = "This run searches at most \(options.maxDocuments) documents; \(docs.count - candidates.count) more were not searched."
                for d in docs.dropFirst(candidates.count) {
                    items.append(.init(name: d.name, category: .notReached, reason: "beyond the \(options.maxDocuments)-document limit of one run"))
                }
            }
            let ids = candidates.map(\.objectID)

            // Stored-field clauses: parameterised SQL over the case's documents only.
            var stored: [CaseSearchStoredField: Set<UUID>] = [:]
            for f in plan.storedFields { stored[f] = try await repo.matching(f, within: ids, zone: options.timeZone) }
            let mentions = plan.needsMentions ? try await repo.mentions(objectIDs: ids) : [:]

            // Partly read documents, from the case's reading record (Package B).
            let partlyByName = Dictionary((coverage?.partlyRead ?? []).map { ($0.name, $0.reason ?? "only part of it could be read") }, uniquingKeysWith: { a, _ in a })
            let notReadByName = Dictionary((coverage?.notRead ?? []).map { ($0.name, $0.reason ?? "it could not be read") }, uniquingKeysWith: { a, _ in a })

            var hits: [CaseSearchHit] = []
            var searchedInFull = 0
            var setAside = 0
            var undatedStated = 0, undatedModified = 0
            var reached = 0
            batches: for batch in stride(from: 0, to: candidates.count, by: 16).map({ Array(candidates[$0..<min($0 + 16, candidates.count)]) }) {
                if Task.isCancelled { stoppedEarly = "The search was cancelled."; break batches }
                if clock.now >= deadline { stoppedEarly = "The time limit of \(Int(options.timeLimitSeconds)) seconds was reached."; break batches }
                let batchIDs = batch.map(\.objectID)
                let texts = plan.hasTextLeaves ? try await repo.contents(objectIDs: batchIDs) : [:]
                let passages = try await repo.passages(objectIDs: batchIDs)
                for d in batch {
                    if clock.now >= deadline { stoppedEarly = "The time limit of \(Int(options.timeLimitSeconds)) seconds was reached."; break batches }
                    reached += 1
                    let stated = CaseSearchDates.parseStated(d.statedDateText)
                    if plan.usesStatedDate, stated == nil { undatedStated += 1 }
                    if plan.usesModifiedDate, d.modifiedAt == nil { undatedModified += 1 }
                    var facts = CaseSearchDocumentFacts(fileName: d.name, statedDate: stated, statedDateText: d.statedDateText,
                                                        mentions: mentions[d.objectID] ?? [])
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
                            if partly != nil { items.append(.init(name: d.name, category: .partlySearched, reason: partly ?? "")) } else { searchedInFull += 1 }
                            continue
                        }
                        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let reason = notReadByName[d.name] ?? "the ledger holds no text for it"
                            items.append(.init(name: d.name, category: .noText, reason: reason))
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
                        docText = CaseSearchDocumentText(content, options: options, masked: masked, needsLiteral: plan.needsLiteral)
                    }
                    let outcomes = CaseSearchEvaluator.leafOutcomes(plan, text: docText, facts: facts)
                    if let partly { items.append(.init(name: d.name, category: .partlySearched, reason: partly)) } else { searchedInFull += 1 }
                    guard plan.evaluate({ outcomes[$0]?.matched }) == true else { continue }
                    hits.append(Self.hit(d, plan: plan, outcomes: outcomes, content: content, passages: live, partly: partly, textNotSearched: false))
                }
            }
            if reached < candidates.count, let why = stoppedEarly {
                for d in candidates.dropFirst(reached) { items.append(.init(name: d.name, category: .notReached, reason: why)) }
            }

            // Versions of the case with no document here: could not be read, or no text in this ledger.
            for v in withoutDocument.sorted(by: { $0.uuidString < $1.uuidString }) {
                let name = labels[v] ?? "Source \(v.uuidString.prefix(8))"
                if let why = notReadByName[name], why != CaseCoverageReadout.noReadingRecord {
                    items.append(.init(name: name, category: .failed, reason: why))
                } else {
                    items.append(.init(name: name, category: .unavailable, reason: "no text for it in this Mac's ledger"))
                }
            }
            // What the reading record lists as not read and is not one of the above (an archive's members).
            let listed = Set(items.map(\.name)).union(docs.map(\.name))
            for e in coverage?.notRead ?? [] where !listed.contains(e.name) {
                items.append(.init(name: e.name, category: .failed, reason: e.reason ?? "it could not be read"))
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
            if case .not = query.root { notes.append("This search lists documents that LACK what you typed; documents that were not searched are never listed as lacking it.") }

            let complete = stoppedEarly == nil && items.allSatisfy { $0.category == .excluded }
            let receipt = CaseSearchReceipt(searched: searchedInFull, items: items, setAsidePassages: setAside, coverageLine: coverage?.summaryLine,
                                            notes: notes, complete: complete)
            let revision = try await repo.indexRevision(candidates, semantics: CaseSearchQuery.currentVersion)
            let sorted = hits.sorted { ($0.name.lowercased(), $0.objectID.uuidString) < ($1.name.lowercased(), $1.objectID.uuidString) }
            return .ran(CaseSearchRun(caseID: caseID, query: query, options: options, executedAt: now, scopeFingerprint: scope.fingerprint,
                                      scopeVersionIDs: scope.versionIDs.sorted { $0.uuidString < $1.uuidString }, indexRevision: revision,
                                      hits: sorted, receipt: receipt, stoppedEarly: stoppedEarly))
        } catch {
            KalsmritikoshLog.app.error("Case search failed: \(error.localizedDescription, privacy: .public)")
            return .failed("The case's documents could not be read (\(error.localizedDescription)). Nothing is shown as a result.")
        }
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
        return CaseSearchHit(objectID: d.objectID, versionIDs: d.versionIDs, name: d.name, sourceType: d.sourceType, occurrences: merged.count,
                             passages: passageIDs.count, crossBoundaryOccurrences: crossing, satisfied: satisfied, absentAsRequired: absent,
                             witnesses: witnesses, partly: partly, textNotSearched: textNotSearched)
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

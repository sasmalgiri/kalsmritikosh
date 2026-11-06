//
//  CaseSearchModel.swift
//  Kalsmritikosh
//
//  Living case map M5 — the "Search case evidence" panel's state: the visual rule groups and the expert text
//  (both are the one query tree: rules are turned into the tree and its text, text is parsed into the tree and
//  shown as rules), the readable explanation, the run with its pages, receipt and witnesses, and the case's
//  saved searches. Nothing here searches by itself: a run starts only when the person chooses Search, and a
//  repaired query is only offered. Everything is read from this Mac's ledger.
//

import Foundation
import os

/// One rule of the visual builder.
struct CaseSearchRule: Identifiable, Hashable {
    enum Field: String, CaseIterable, Identifiable {
        case words, prefix, exact, near, person, type, file, tag, date
        var id: String { rawValue }
        var label: String {
            switch self {
            case .words: return "Words (in this order)"
            case .prefix: return "Word starting with"
            case .exact: return "Exact characters"
            case .near: return "Near each other"
            case .person: return "Person or organisation"
            case .type: return "Document type"
            case .file: return "File name contains"
            case .tag: return "Tag"
            case .date: return "Date"
            }
        }
    }
    let id = UUID()
    var field: Field = .words
    var value = ""
    var other = ""
    var distance = 5
    var dateKind: CaseSearchDateKind = .documentStated
    var dateRelation: CaseSearchDateRelation = .on
}

/// A group of rules: all of them, at least one, or none.
struct CaseSearchRuleGroup: Identifiable, Hashable {
    enum Mode: String, CaseIterable, Identifiable {
        case all, any, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All of these"
            case .any: return "At least one of these"
            case .none: return "None of these"
            }
        }
    }
    let id = UUID()
    var mode: Mode = .all
    var rules: [CaseSearchRule] = [CaseSearchRule()]
    var groups: [CaseSearchRuleGroup] = []

    /// The tree for these rules, or why they cannot make one (an empty or unreadable rule is refused, not dropped).
    func node() -> Result<CaseSearchNode, CaseSearchBuilderError> {
        var kids: [CaseSearchNode] = []
        for r in rules {
            switch Self.node(r) {
            case .success(let n): kids.append(n)
            case .failure(let e): return .failure(e)
            }
        }
        for g in groups {
            switch g.node() {
            case .success(let n): kids.append(n)
            case .failure(let e): return .failure(e)
            }
        }
        guard !kids.isEmpty else { return .failure(.init(message: "A group has no rules. Add a rule or remove the group.")) }
        switch mode {
        case .all: return .success(kids.count == 1 ? kids[0] : .all(kids))
        case .any: return .success(kids.count == 1 ? kids[0] : .any(kids))
        case .none: return .success(.not(kids.count == 1 ? kids[0] : .any(kids)))
        }
    }

    static func node(_ r: CaseSearchRule) -> Result<CaseSearchNode, CaseSearchBuilderError> {
        let v = r.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return .failure(.init(message: "A “\(r.field.label)” rule is empty. Fill it in or remove it.")) }
        guard !v.contains("\""), !v.contains("\u{201C}"), !v.contains("\u{201D}") else {
            return .failure(.init(message: "“\(v)”: a rule cannot contain quotation marks."))
        }
        let opts = CaseSearchOptions()
        switch r.field {
        case .words:
            guard !CaseSearchText.tokens(of: v, options: opts).isEmpty else {
                return .failure(.init(message: "“\(v)” has no letters or digits; use “Exact characters” to search for it."))
            }
            return .success(.textTerm(v))
        case .prefix:
            guard CaseSearchText.tokens(of: v, options: opts).count == 1, let w = CaseSearchText.firstTokenText(of: v) else {
                return .failure(.init(message: "“Word starting with” takes one word (letters and digits)."))
            }
            return .success(.prefix(w))
        case .exact: return .success(.literal(v))
        case .near:
            let o = r.other.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !CaseSearchText.tokens(of: v, options: opts).isEmpty, !CaseSearchText.tokens(of: o, options: opts).isEmpty, !o.contains("\"") else {
                return .failure(.init(message: "“Near each other” needs two words or phrases."))
            }
            guard (1...100).contains(r.distance) else { return .failure(.init(message: "The distance is 1 to 100 words.")) }
            return .success(.near(.textTerm(v), .textTerm(o), distance: r.distance))
        case .person:
            guard !CaseSearchText.tokens(of: v, options: opts).isEmpty else { return .failure(.init(message: "Type the name to look for.")) }
            return .success(.person(v))
        case .type: return .success(.type(v))
        case .file: return .success(.file(v))
        case .tag: return .success(.tag(v))
        case .date:
            guard let c = CaseSearchDate.canonical(v) else {
                return .failure(.init(message: "“\(v)” is not a date this search reads — write 2024-01-31, 2024-01, 2024 or 31/01/2024."))
            }
            return .success(.date(CaseSearchDate(kind: r.dateKind, relation: r.dateRelation, value: c)))
        }
    }

    /// The rules showing a tree (every tree can be shown as groups).
    static func from(_ node: CaseSearchNode) -> CaseSearchRuleGroup {
        var g = CaseSearchRuleGroup(); g.rules = []
        let kids: [CaseSearchNode]
        switch node {
        case .all(let c): g.mode = .all; kids = c
        case .any(let c): g.mode = .any; kids = c
        case .not(.any(let c)): g.mode = .none; kids = c
        case .not(let x): g.mode = .none; kids = [x]
        default: g.mode = .all; kids = [node]
        }
        for k in kids {
            if let r = rule(k) { g.rules.append(r) } else { g.groups.append(from(k)) }
        }
        return g
    }

    static func rule(_ n: CaseSearchNode) -> CaseSearchRule? {
        var r = CaseSearchRule()
        switch n {
        case .word(let v), .phrase(let v): r.field = .words; r.value = v
        case .prefix(let v): r.field = .prefix; r.value = v
        case .literal(let v): r.field = .exact; r.value = v
        case .near(let a, let b, let d):
            r.field = .near; r.distance = d
            func text(_ x: CaseSearchNode) -> String {
                switch x { case .word(let v), .phrase(let v), .prefix(let v): return v; default: return "" }
            }
            r.value = text(a); r.other = text(b)
        case .person(let v): r.field = .person; r.value = v
        case .type(let v): r.field = .type; r.value = v
        case .file(let v): r.field = .file; r.value = v
        case .tag(let v): r.field = .tag; r.value = v
        case .date(let d): r.field = .date; r.value = d.value; r.dateKind = d.kind; r.dateRelation = d.relation
        default: return nil
        }
        return r
    }
}

struct CaseSearchBuilderError: Error, Equatable { let message: String }

@MainActor @Observable
final class CaseSearchModel {
    let caseID: UUID
    var service: CaseSearchService?
    var rules = CaseSearchRuleGroup()
    var text = ""
    var options = CaseSearchOptions()
    var builderError: String?
    var outcome: CaseSearchOutcome?
    var pageIndex = 0
    var running = false
    var saved: [CaseSavedSearch] = []
    var changes: CaseSearchChanges?
    var viewingReceipt: CaseSavedSearch?
    var notice: String?
    var error: String?
    private var task: Task<Void, Never>?

    init(caseID: UUID) { self.caseID = caseID }

    /// What the typed text means now (shown before anything runs).
    var parse: CaseSearchParse { CaseSearchParser.parse(text) }

    var run: CaseSearchRun? { outcome?.run }
    var page: CaseSearchPage? { run?.page(pageIndex) }

    /// Rules → the tree → its text (the text field then shows exactly what will run).
    func useRules() {
        switch rules.node() {
        case .success(let n):
            text = CaseSearchQuery(root: n).text
            builderError = nil
        case .failure(let e):
            builderError = e.message
        }
    }

    /// Text → the tree → rules (only when the text is valid).
    func showAsRules() {
        guard let q = parse.query else { builderError = "Fix the search text first; the rules show a valid search only."; return }
        rules = CaseSearchRuleGroup.from(q.root)
        builderError = nil
    }

    /// The repaired query replaces the text; it still runs only when the person chooses Search.
    func useRepair(_ repair: CaseSearchParse.Repair) {
        text = repair.text
        notice = "The repaired search is in the text field. Read its explanation, then choose Search to run it."
    }

    func search() {
        guard let service else { error = "The ledger isn't ready yet."; return }
        task?.cancel()
        running = true
        error = nil; notice = nil; changes = nil
        let text = self.text, options = self.options, caseID = self.caseID
        task = Task { [weak self] in
            let o = await service.run(caseID: caseID, text: text, options: options)
            guard let self, !Task.isCancelled else { return }
            self.outcome = o
            self.pageIndex = 0
            self.running = false
        }
    }

    func cancel() { task?.cancel(); running = false; notice = "The search was cancelled; nothing is shown as a result." }

    func loadSaved() async {
        guard let service else { return }
        do { saved = try await service.repository.savedSearches(caseID: caseID) } catch {
            KalsmritikoshLog.ui.error("Saved case searches read failed: \(error.localizedDescription, privacy: .public)")
            self.error = "The saved searches could not be read."
        }
    }

    func save(name: String, kind: CaseSavedSearch.Kind, actor: String) async {
        guard let service, let run else { return }
        do {
            _ = try await service.save(run, name: name, kind: kind, actor: actor)
            notice = kind == .live ? "Saved as a live search: it runs again over the case's documents as they are then." : "Saved as a frozen result: it keeps this result as it is."
            await loadSaved()
        } catch {
            KalsmritikoshLog.ui.error("Case search save failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Not saved: \(error.localizedDescription)"
        }
    }

    func open(_ s: CaseSavedSearch) {
        guard let q = s.query else { error = "This saved search cannot be read by this version; it is not reinterpreted."; return }
        text = q.text
        if let o = s.options { options = o }
        rules = CaseSearchRuleGroup.from(q.root)
        notice = "“\(s.name)” is in the text field. Choose Search to run it over the case's documents now."
    }

    func checkForNewMatches(_ s: CaseSavedSearch) async {
        guard let service else { return }
        running = true
        defer { running = false }
        switch await service.changes(for: s) {
        case .success(let c):
            changes = c
            outcome = .ran(c.current)
            pageIndex = 0
            if let q = s.query { text = q.text }
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    func acknowledge() async {
        guard let service, let c = changes else { return }
        do {
            try await service.acknowledge(c.saved, run: c.current)
            changes = nil
            notice = "Marked as seen. New matches are counted from now on. Seeing a match is not reviewing it."
            await loadSaved()
        } catch {
            KalsmritikoshLog.ui.error("Case search acknowledge failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Not recorded: \(error.localizedDescription)"
        }
    }

    func remove(_ s: CaseSavedSearch) async {
        guard let service else { return }
        do { try await service.repository.deleteSavedSearch(id: s.id, caseID: caseID); await loadSaved() } catch {
            KalsmritikoshLog.ui.error("Case search remove failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Not removed: \(error.localizedDescription)"
        }
    }
}

//
//  CaseReportStructure.swift
//  Kalsmritikosh
//
//  Smart-map S4 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §10 REPORT; schema v180): the structure a
//  supplied report is given around its points, over the ONE case file repository and its savepoint.
//
//  • Sections (REPORT-02): the report's own headings, nested, so a point can be placed where the report put it. A point is
//    recorded in one step with its section, the time it is about and (through point uses) the question and person it
//    concerns — never retyped from one branch to another.
//  • Suggested points (REPORT-02 / REPORT-06): a RULE-BASED reading of the report's own passages (no model is called; AI
//    can be off). Every suggestion is a proposal awaiting a person: accepting it records a point through the case's one
//    verifier; dismissing it needs a reason. Reading the report again adds only sentences not proposed before — an
//    accepted point, its qualifications, its review and its citation are never touched by a re-reading.
//  • Point uses (REPORT-07): the SAME point referenced from a question, a person, a chronology entry, a money movement, a
//    hypothesis, a briefing or an output. A use records the point's review and wording digest at the time, so the
//    canonical point stays one record and a later change shows as "changed since it was used here".
//  • Version comparison (REPORT-08): an amendment or supplement compared with the report it amends — wording, added and
//    removed qualifications, report fields, and the work that rests on a changed point. That work gets a review-needed
//    flag; no review, decision or outcome is changed.
//  • Supplied specialist items (REPORT-09): tables, figures, media and datasets a specialist supplied, kept and shown as
//    supplied. The app did not perform the acquisition or the analysis and never says it did.
//  Nothing here calls a model or the network.
//

import CryptoKit
import Foundation
import os

// MARK: - Records

/// Where a new point goes and what it is about, recorded with it in the same write (REPORT-02).
public nonisolated struct CasePointPlacement: Sendable, Equatable {
    public var sectionID: UUID?
    /// The time the point is about, and the report's own wording of it ("on the morning of 3 March").
    public var eventAt: Date?
    public var eventText: String?
    /// The suggestion the point was accepted from.
    public var proposalID: UUID?
    public init(sectionID: UUID? = nil, eventAt: Date? = nil, eventText: String? = nil, proposalID: UUID? = nil) {
        self.sectionID = sectionID; self.eventAt = eventAt; self.eventText = eventText; self.proposalID = proposalID
    }
}

public nonisolated struct CaseReportSection: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let reportID: UUID
    public let parentSectionID: UUID?
    public let ordinal: Int
    public let heading: String
    public let locatorNote: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public var isActive: Bool { withdrawnAt == nil }
}

public nonisolated enum CaseReportProposalState: String, Sendable, Codable, CaseIterable {
    case proposed, accepted, dismissed
    public var label: String {
        switch self {
        case .proposed: return "Suggested — not a point until you accept it"
        case .accepted: return "Accepted as a point"
        case .dismissed: return "Dismissed"
        }
    }
}

/// A suggested point from the rule-based reading of the report's text. A suggestion is not a point and not a fact.
public nonisolated struct CaseReportPointProposal: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let reportID: UUID
    public let runID: UUID
    public let sourceVersionID: UUID
    public let blockID: UUID?
    /// The sentence exactly as it is in the report's text.
    public let quote: String
    public let statement: String
    public let kind: CaseReportPointKind
    /// The heading the sentence sits under in the report's text, when one was found.
    public let sectionHint: String?
    public let rule: String
    public let ruleVersion: Int
    public let state: CaseReportProposalState
    public let decidedBy: String?
    public let decidedAt: Date?
    public let decisionNote: String?
    public let pointID: UUID?
    public let recordedAt: Date
    /// "Suggested by rule “finding words” v1 — not reviewed" — how it came to be proposed.
    public var originLabel: String { "Suggested by the rule “\(rule)” (version \(ruleVersion)) from the report's own words — no model was used" }
}

/// The branch a point is used in (REPORT-07).
public nonisolated enum CasePointUseContext: String, Sendable, Codable, CaseIterable, Identifiable {
    case question, person, chronology, money, hypothesis, briefing, output
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .question: return "Question"
        case .person: return "Person"
        case .chronology: return "Chronology entry"
        case .money: return "Money movement"
        case .hypothesis: return "Hypothesis"
        case .briefing: return "Briefing"
        case .output: return "Output"
        }
    }
}

public nonisolated struct CaseReportPointUse: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let pointID: UUID
    public let context: CasePointUseContext
    public let contextID: String
    public let note: String?
    /// The point's review state and wording digest when it was used here.
    public let reviewAtUse: CaseReportPointReview
    public let digestAtUse: String
    public let createdBy: String
    public let createdAt: Date
    public let withdrawnAt: Date?
    public let withdrawnReason: String?
    public var isActive: Bool { withdrawnAt == nil }

    /// Whether the point is still as it was when used here; otherwise what changed.
    public func change(against point: CaseReportPoint) -> String? {
        var parts: [String] = []
        if CaseReportPointText.digest(point) != digestAtUse { parts.append("its wording changed") }
        if point.review != reviewAtUse { parts.append("its review is now “\(point.review.label)” (was “\(reviewAtUse.label)”)") }
        if !point.isActive { parts.append("it was withdrawn") }
        return parts.isEmpty ? nil : "Since it was used here, " + parts.joined(separator: "; ") + "."
    }
}

public nonisolated enum CaseReportArtifactKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case table, figure, media, dataset, other
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .table: return "Table"
        case .figure: return "Figure"
        case .media: return "Media item"
        case .dataset: return "Dataset"
        case .other: return "Other supplied item"
        }
    }
}

/// A table, figure, media item or dataset a specialist supplied with a report (REPORT-09).
public nonisolated struct CaseReportArtifact: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let reportID: UUID
    public let kind: CaseReportArtifactKind
    public let label: String
    public let sourceVersionID: UUID?
    public let locator: String?
    public let description: String?
    public let suppliedBy: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
    /// The line shown wherever the item is shown.
    public var line: String {
        "\(kind.label): \(label)" + (suppliedBy.map { " — supplied by \($0)" } ?? "") + (locator.map { " (\($0))" } ?? "")
            + (sourceVersionID == nil ? " — no file of it in the case yet" : "") + ". " + LegalNotice.suppliedSpecialistResult
    }
}

/// Work that rests on a point a later version of its report changed (REPORT-08).
public nonisolated struct CaseWorkReviewFlag: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let workKind: CaseWorkLink.WorkKind
    public let workID: UUID
    public let pointID: UUID
    public let comparisonID: UUID
    public let reason: String
    public let raisedAt: Date
    public let clearedBy: String?
    public let clearedAt: Date?
    public let clearNote: String?
    public var isOpen: Bool { clearedAt == nil }
}

/// Everything v180 holds around a case's reports, read together.
public nonisolated struct CaseReportStructure: Sendable, Equatable {
    public var sections: [CaseReportSection] = []
    public var proposals: [CaseReportPointProposal] = []
    public var uses: [CaseReportPointUse] = []
    public var artifacts: [CaseReportArtifact] = []
    public var comparisons: [CaseRecordedComparison] = []
    public var flags: [CaseWorkReviewFlag] = []
    public init() {}
    public func sections(of report: UUID) -> [CaseReportSection] { sections.filter { $0.reportID == report && $0.isActive } }
    public func proposals(of report: UUID, _ state: CaseReportProposalState? = nil) -> [CaseReportPointProposal] {
        proposals.filter { $0.reportID == report && (state == nil || $0.state == state) }
    }
    public func uses(of point: UUID) -> [CaseReportPointUse] { uses.filter { $0.pointID == point && $0.isActive } }
    public func openFlags(work: UUID) -> [CaseWorkReviewFlag] { flags.filter { $0.workID == work && $0.isOpen } }
}

public nonisolated struct CaseRecordedComparison: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let earlierReportID: UUID
    public let laterReportID: UUID
    public let result: CaseReportVersionComparison
    public let recordedBy: String
    public let recordedAt: Date
}

// MARK: - The text of a point wherever it is summarised (REPORT-03)

public nonisolated enum CaseReportPointText {
    /// The digest of what a point says (kind, statement, quoted words) — a use records it.
    public static func digest(_ p: CaseReportPoint) -> String {
        let canonical = [p.kind.rawValue, p.statement, p.quote ?? ""].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every qualification of the point, and what the quoted words left out of their sentence — the lines that travel
    /// with the point into every summary, export and brief.
    public static func qualificationLines(_ p: CaseReportPoint, _ quals: [CaseReportQualification]) -> [String] {
        quals.filter { $0.pointID == p.id }.map(\.line) + (p.sourceCheck?.lines ?? [])
    }

    /// One summary line of a point: never shorter than its conditions. A conditional result therefore cannot read as an
    /// unconditional finding in an export or a brief.
    public static func summary(_ p: CaseReportPoint, _ quals: [CaseReportQualification], review: Bool = true) -> String {
        var line = "\(p.kind.label): \(p.statement)"
        if let q = p.quote, !q.isEmpty { line += " — “\(q)”" }
        line += " [\(p.locatorText)\(p.isVerified ? "; words verified in the report" : "; words NOT verified")]"
        if review { line += " (\(p.review.label))" }
        let ql = qualificationLines(p, quals)
        if !ql.isEmpty { line += " — QUALIFIED: " + ql.joined(separator: "; ") }
        return line
    }

    /// The reports and their points as a document section (the case file report uses it).
    public static func section(_ ledger: CaseReportLedger, structure: CaseReportStructure? = nil) -> String {
        let reports = ledger.reports.filter(\.isActive)
        guard !reports.isEmpty else { return "" }
        var o = "\n## Supplied reports and their points\n"
        o += "_A point is the investigator's statement of what a report says — not that it is true. Every qualification of a point is printed with it._\n"
        for r in reports {
            o += "\n### \(r.kind.label): \(r.title)\n"
            let meta = [r.producer.map { "Producer: \($0)" }, r.author.map { "Author: \($0)" }, r.examinedMaterial.map { "Material examined: \($0)" },
                        r.reportDateText.map { "Report date: \($0)" }, r.methods.map { "Methods: \($0)" }, r.limitations.map { "Limitations: \($0)" }]
                .compactMap { $0 }
            for m in meta { o += "- \(m)\n" }
            if let a = r.amendsReportID, let earlier = ledger.report(a) { o += "- \(r.kind == .amendment ? "Amends" : "Supplements") “\(earlier.title)” (kept as it was)\n" }
            for item in structure?.artifacts.filter({ $0.reportID == r.id && $0.isActive }) ?? [] { o += "- \(item.line)\n" }
            let points = ledger.points.filter { $0.reportID == r.id && $0.isActive }
            if points.isEmpty { o += "\nNo points recorded.\n"; continue }
            o += "\n" + points.map { "- " + summary($0, ledger.qualifications) }.joined(separator: "\n") + "\n"
        }
        return o
    }
}

// MARK: - Rule-based point suggestions (AI off)

/// A suggestion before it is stored.
public nonisolated struct CasePointSuggestion: Sendable, Equatable {
    public let quote: String
    public let kind: CaseReportPointKind
    public let sectionHint: String?
    public let rule: String
}

/// The rule-based reader: deterministic sentence and heading rules over the report's own text. It proposes; it decides
/// nothing. Version 1 rules: a sentence (20–400 characters) is suggested when it carries a finding, recommendation,
/// allegation or attribution cue; a short unpunctuated line (numbered, or in capitals / title case) is a heading.
public nonisolated enum CaseReportPointSuggester {
    public static let ruleVersion = 1

    static let cues: [(CaseReportPointKind, String, [String])] = [
        (.recommendation, "recommendation words", ["recommend", "should be", "we advise", "it is advised", "is suggested", "must be"]),
        (.allegation, "allegation words", ["alleged", "allegation", "accused", "claims that", "claimed that"]),
        (.finding, "finding words", ["found", "observed", "concluded", "conclusion", "determined", "established", "identified", "showed", "shows that",
                                     "indicates", "was intact", "was broken", "weighed", "measured", "result", "detected", "confirmed", "matched", "did not match"]),
        (.claim, "attribution words", ["stated", "states that", "said", "reported", "according to", "told"]),
    ]

    /// Is `line` a heading? Numbered ("3.", "2.1 Method", "Section 4") or short capitals / title case, no final stop.
    public static func isHeading(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard (2...80).contains(t.count), let last = t.last, !".!?;,:".contains(last) else { return false }
        if t.range(of: #"^(section\s+)?\d+(\.\d+)*\.?\s+\S"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let letters = t.filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        if letters.allSatisfy(\.isUppercase) { return true }
        let words = t.split(separator: " ")
        return words.count <= 6 && words.allSatisfy { $0.first?.isUppercase == true || $0.first?.isNumber == true }
    }

    /// Sentences of `text`, exactly as written (trimmed), with the heading above each.
    public static func sentences(_ text: String) -> [(sentence: String, heading: String?)] {
        var out: [(String, String?)] = []
        var heading: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if isHeading(line) { heading = line; continue }
            var current = ""
            let chars = Array(line)
            for (i, c) in chars.enumerated() {
                current.append(c)
                let atEnd = i == chars.count - 1
                if ".!?".contains(c), atEnd || chars[i + 1] == " " {
                    // "No. 7", "Dr. Rao", "e.g." are not sentence ends.
                    let lastWord = current.split(separator: " ").last.map(String.init) ?? ""
                    if ["No.", "Dr.", "Mr.", "Mrs.", "Ms.", "e.g.", "i.e.", "approx.", "p.", "pp.", "vs.", "St."].contains(lastWord) && !atEnd { continue }
                    let s = current.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { out.append((s, heading)) }
                    current = ""
                }
            }
            let rest = current.trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { out.append((rest, heading)) }
        }
        return out
    }

    /// The suggestions of one passage of the report.
    public static func suggest(_ text: String) -> [CasePointSuggestion] {
        var seen = Set<String>()
        return sentences(text).compactMap { s, heading in
            guard (20...400).contains(s.count), seen.insert(s).inserted else { return nil }
            let lower = s.lowercased()
            for (kind, rule, words) in cues where words.contains(where: { lower.contains($0) }) {
                return CasePointSuggestion(quote: s, kind: kind, sectionHint: heading, rule: rule)
            }
            return nil
        }
    }
}

/// What one reading of a report proposed.
public nonisolated struct CasePointSuggestionRun: Sendable, Equatable {
    public let runID: UUID
    /// New suggestions stored by this reading.
    public let added: Int
    /// Sentences already proposed earlier (still awaiting a decision) — not proposed twice.
    public let alreadyProposed: Int
    /// Sentences a person already accepted or dismissed — never proposed again.
    public let alreadyDecided: Int
    /// Why nothing could be read (no document, no passages), when so.
    public let unavailable: String?
}

// MARK: - Version comparison (REPORT-08)

public nonisolated struct CaseReportVersionComparison: Codable, Sendable, Equatable, Hashable {
    public enum Change: String, Codable, Sendable { case unchanged, reworded, requalified, added, removed }

    public struct FieldChange: Codable, Sendable, Equatable, Hashable {
        public let field: String
        public let before: String?
        public let after: String?
    }

    public struct PointChange: Codable, Sendable, Equatable, Hashable {
        public let change: Change
        public let earlierPointID: UUID?
        public let laterPointID: UUID?
        public let earlierStatement: String?
        public let laterStatement: String?
        public let wordsRemoved: [String]
        public let wordsAdded: [String]
        public let qualificationsAdded: [String]
        public let qualificationsRemoved: [String]
        public let kindChanged: Bool
        public let quoteChanged: Bool
        /// How the two points were paired ("same quoted words", "same statement", "same position").
        public let pairedBy: String?
    }

    public struct AffectedWork: Codable, Sendable, Equatable, Hashable {
        public let workKind: String
        public let workID: UUID
        public let pointID: UUID
        public let reason: String
    }

    public let earlierReportID: UUID
    public let laterReportID: UUID
    public let fields: [FieldChange]
    public let points: [PointChange]
    public let affectedWork: [AffectedWork]
    /// Uses of a changed earlier point in other branches (they reference the earlier point, which is kept as it was).
    public let affectedUses: [String]

    public var changedPoints: [PointChange] { points.filter { $0.change != .unchanged } }

    public var lines: [String] {
        var out: [String] = []
        for f in fields { out.append("\(f.field): “\(f.before ?? "—")” → “\(f.after ?? "—")”") }
        for p in points {
            switch p.change {
            case .unchanged: continue
            case .added: out.append("New point: \(p.laterStatement ?? "")")
            case .removed: out.append("Not in the later version: \(p.earlierStatement ?? "")")
            case .reworded, .requalified:
                var s = "Changed point (\(p.pairedBy ?? "paired")): “\(p.earlierStatement ?? "")” → “\(p.laterStatement ?? "")”"
                if !p.wordsRemoved.isEmpty { s += " · removed: \(p.wordsRemoved.joined(separator: " "))" }
                if !p.wordsAdded.isEmpty { s += " · added: \(p.wordsAdded.joined(separator: " "))" }
                if p.kindChanged { s += " · its kind changed" }
                if p.quoteChanged { s += " · it quotes different words" }
                out.append(s)
            }
            for q in p.qualificationsAdded { out.append("  Qualification added: \(q)") }
            for q in p.qualificationsRemoved { out.append("  Qualification removed: \(q)") }
        }
        if !affectedWork.isEmpty { out.append("\(affectedWork.count) piece\(affectedWork.count == 1 ? "" : "s") of work rest on a changed point and need review. No decision or outcome was changed.") }
        for u in affectedUses { out.append("  Used elsewhere: \(u)") }
        if out.isEmpty { out.append("No difference in the recorded points, their qualifications or the report's details.") }
        return out
    }

    /// Compare two reports of a case (normally an original and its amendment). Points are paired deterministically: the
    /// same quoted words first, then the same statement, then the same position among the unpaired.
    public static func compare(_ ledger: CaseReportLedger, earlier: UUID, later: UUID) -> CaseReportVersionComparison? {
        guard let a = ledger.report(earlier), let b = ledger.report(later) else { return nil }
        func norm(_ s: String?) -> String { (s ?? "").lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        var fields: [FieldChange] = []
        for (name, x, y) in [("Producer", a.producer, b.producer), ("Author", a.author, b.author), ("Material examined", a.examinedMaterial, b.examinedMaterial),
                             ("Report date", a.reportDateText, b.reportDateText), ("Methods", a.methods, b.methods), ("Limitations", a.limitations, b.limitations)]
            where norm(x) != norm(y) {
            fields.append(FieldChange(field: name, before: x, after: y))
        }
        let ea = ledger.points.filter { $0.reportID == earlier && $0.isActive }.sorted { $0.ordinal < $1.ordinal }
        let lb = ledger.points.filter { $0.reportID == later && $0.isActive }.sorted { $0.ordinal < $1.ordinal }
        var pairs: [(CaseReportPoint, CaseReportPoint, String)] = []
        var leftA = ea, leftB = lb
        func pair(_ key: (CaseReportPoint) -> String?, _ how: String) {
            for x in leftA {
                guard let k = key(x), !k.isEmpty, let i = leftB.firstIndex(where: { key($0) == k }) else { continue }
                pairs.append((x, leftB[i], how)); leftB.remove(at: i)
                leftA.removeAll { $0.id == x.id }
            }
        }
        pair({ $0.quote.map { norm($0) } }, "same quoted words")
        pair({ norm($0.statement) }, "same statement")
        // Same position: the n-th unpaired point of each, in order.
        let k = min(leftA.count, leftB.count)
        for i in 0..<k { pairs.append((leftA[i], leftB[i], "same position")) }
        let removed = Array(leftA.dropFirst(k)), added = Array(leftB.dropFirst(k))
        func quals(_ p: CaseReportPoint) -> Set<String> { Set(ledger.qualifications(of: p.id).map(\.line)) }
        var changes: [PointChange] = []
        var affected: [AffectedWork] = []
        func dependent(_ p: CaseReportPoint, _ why: String) {
            for w in ledger.workLinks where w.isActive && w.targetKind == .point && w.targetID == p.id {
                affected.append(AffectedWork(workKind: w.workKind.rawValue, workID: w.workID, pointID: p.id, reason: why))
            }
        }
        for (x, y, how) in pairs.sorted(by: { $0.0.ordinal < $1.0.ordinal }) {
            let (removedWords, addedWords) = wordDiff(x.statement, y.statement)
            let qa = quals(y).subtracting(quals(x)).sorted(), qr = quals(x).subtracting(quals(y)).sorted()
            let kindChanged = x.kind != y.kind, quoteChanged = norm(x.quote) != norm(y.quote)
            let change: Change = (!removedWords.isEmpty || !addedWords.isEmpty || kindChanged || quoteChanged) ? .reworded
                : (!qa.isEmpty || !qr.isEmpty) ? .requalified : .unchanged
            changes.append(PointChange(change: change, earlierPointID: x.id, laterPointID: y.id, earlierStatement: x.statement, laterStatement: y.statement,
                                       wordsRemoved: removedWords, wordsAdded: addedWords, qualificationsAdded: qa, qualificationsRemoved: qr,
                                       kindChanged: kindChanged, quoteChanged: quoteChanged, pairedBy: how))
            if change != .unchanged { dependent(x, "The later version of the report changes this point (\(change == .reworded ? "its wording" : "its qualifications")).") }
        }
        for x in removed {
            changes.append(PointChange(change: .removed, earlierPointID: x.id, laterPointID: nil, earlierStatement: x.statement, laterStatement: nil,
                                       wordsRemoved: [], wordsAdded: [], qualificationsAdded: [], qualificationsRemoved: [], kindChanged: false, quoteChanged: false, pairedBy: nil))
            dependent(x, "The later version of the report no longer contains this point.")
        }
        for y in added {
            changes.append(PointChange(change: .added, earlierPointID: nil, laterPointID: y.id, earlierStatement: nil, laterStatement: y.statement,
                                       wordsRemoved: [], wordsAdded: [], qualificationsAdded: [], qualificationsRemoved: [], kindChanged: false, quoteChanged: false, pairedBy: nil))
        }
        return CaseReportVersionComparison(earlierReportID: earlier, laterReportID: later, fields: fields, points: changes, affectedWork: affected, affectedUses: [])
    }

    /// Words removed and added between two statements (longest common subsequence over words; case kept as written).
    static func wordDiff(_ a: String, _ b: String) -> (removed: [String], added: [String]) {
        let x = a.split(whereSeparator: { $0.isWhitespace }).map(String.init), y = b.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard x.count * y.count <= 250_000 else { return (x, y) }   // very long statements: shown whole rather than diffed
        var t = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                t[i][j] = x[i].lowercased() == y[j].lowercased() ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var i = 0, j = 0
        var removed: [String] = [], added: [String] = []
        while i < x.count && j < y.count {
            if x[i].lowercased() == y[j].lowercased() { i += 1; j += 1 }
            else if t[i + 1][j] >= t[i][j + 1] { removed.append(x[i]); i += 1 }
            else { added.append(y[j]); j += 1 }
        }
        removed += x[i...]; added += y[j...]
        return (removed, added)
    }

    func encoded() -> String {
        guard let d = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
    static func decode(_ s: String?) -> CaseReportVersionComparison? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        do { return try JSONDecoder().decode(CaseReportVersionComparison.self, from: d) } catch {
            KalsmritikoshLog.app.error("Recorded report comparison unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

public nonisolated enum CaseReportStructureError: Error, Equatable, LocalizedError {
    case proposalDecided
    case notAnAmendment
    case contextNotInCase(String)
    case alreadyUsed
    public var errorDescription: String? {
        switch self {
        case .proposalDecided: return "This suggestion was already decided. Nothing was changed."
        case .notAnAmendment: return "Compare a report with its amendment or supplement (or two reports of this case)."
        case .contextNotInCase(let what): return "That \(what) is not part of this case."
        case .alreadyUsed: return "The point is already used there."
        }
    }
}

// MARK: - Persistence (the case file repository's one savepoint)

extension CaseFileRepository {

    public func reportStructure(caseID: UUID) async throws -> CaseReportStructure {
        let c: [SQLValue] = [.uuid(caseID)]
        var s = CaseReportStructure()
        s.sections = try await database.query("""
            SELECT id, case_id, report_id, parent_section_id, ordinal, heading, locator_note, recorded_by, recorded_at, withdrawn_at, withdrawn_reason
            FROM case_report_sections WHERE case_id = ? ORDER BY report_id, ordinal, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let rid = r.uuid(2), let h = r.string(5), let by = r.string(7), let at = r.date(8) else { return nil }
            return CaseReportSection(id: id, caseID: cid, reportID: rid, parentSectionID: r.uuid(3), ordinal: Int(r.int(4) ?? 0), heading: h, locatorNote: r.string(6),
                                     recordedBy: by, recordedAt: at, withdrawnAt: r.date(9), withdrawnReason: r.string(10))
        }
        s.proposals = try await database.query("""
            SELECT id, case_id, report_id, run_id, source_version_id, block_id, quote, statement, point_kind, section_hint, rule, rule_version, state,
                   decided_by, decided_at, decision_note, point_id, recorded_at
            FROM case_report_point_proposals WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let rid = r.uuid(2), let run = r.uuid(3), let v = r.uuid(4), let q = r.string(6), let st = r.string(7),
                  let kind = r.string(8).flatMap(CaseReportPointKind.init(rawValue:)), let rule = r.string(10),
                  let state = r.string(12).flatMap(CaseReportProposalState.init(rawValue:)), let at = r.date(17) else { return nil }
            return CaseReportPointProposal(id: id, caseID: cid, reportID: rid, runID: run, sourceVersionID: v, blockID: r.uuid(5), quote: q, statement: st, kind: kind,
                                           sectionHint: r.string(9), rule: rule, ruleVersion: Int(r.int(11) ?? 1), state: state, decidedBy: r.string(13),
                                           decidedAt: r.date(14), decisionNote: r.string(15), pointID: r.uuid(16), recordedAt: at)
        }
        s.uses = try await database.query("""
            SELECT id, case_id, point_id, context_kind, context_id, note, review_at_use, digest_at_use, created_by, created_at, withdrawn_at, withdrawn_reason
            FROM case_report_point_uses WHERE case_id = ? ORDER BY created_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let pid = r.uuid(2), let ctx = r.string(3).flatMap(CasePointUseContext.init(rawValue:)), let cxid = r.string(4),
                  let rev = r.string(6).flatMap(CaseReportPointReview.init(rawValue:)), let dg = r.string(7), let by = r.string(8), let at = r.date(9) else { return nil }
            return CaseReportPointUse(id: id, caseID: cid, pointID: pid, context: ctx, contextID: cxid, note: r.string(5), reviewAtUse: rev, digestAtUse: dg,
                                      createdBy: by, createdAt: at, withdrawnAt: r.date(10), withdrawnReason: r.string(11))
        }
        s.artifacts = try await database.query("""
            SELECT id, case_id, report_id, artifact_kind, label, source_version_id, locator, description, supplied_by, recorded_by, recorded_at, withdrawn_at
            FROM case_report_artifacts WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let rid = r.uuid(2), let k = r.string(3).flatMap(CaseReportArtifactKind.init(rawValue:)), let l = r.string(4),
                  let by = r.string(9), let at = r.date(10) else { return nil }
            return CaseReportArtifact(id: id, caseID: cid, reportID: rid, kind: k, label: l, sourceVersionID: r.uuid(5), locator: r.string(6), description: r.string(7),
                                      suppliedBy: r.string(8), recordedBy: by, recordedAt: at, withdrawnAt: r.date(11))
        }
        s.comparisons = try await database.query("""
            SELECT id, case_id, earlier_report_id, later_report_id, result_json, recorded_by, recorded_at FROM case_report_comparisons WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let a = r.uuid(2), let b = r.uuid(3), let res = CaseReportVersionComparison.decode(r.string(4)),
                  let by = r.string(5), let at = r.date(6) else { return nil }
            return CaseRecordedComparison(id: id, caseID: cid, earlierReportID: a, laterReportID: b, result: res, recordedBy: by, recordedAt: at)
        }
        s.flags = try await database.query("""
            SELECT id, case_id, work_kind, work_id, point_id, comparison_id, reason, raised_at, cleared_by, cleared_at, clear_note
            FROM case_work_review_flags WHERE case_id = ? ORDER BY raised_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let cid = r.uuid(1), let wk = r.string(2).flatMap(CaseWorkLink.WorkKind.init(rawValue:)), let wid = r.uuid(3), let pid = r.uuid(4),
                  let cmp = r.uuid(5), let why = r.string(6), let at = r.date(7) else { return nil }
            return CaseWorkReviewFlag(id: id, caseID: cid, workKind: wk, workID: wid, pointID: pid, comparisonID: cmp, reason: why, raisedAt: at,
                                      clearedBy: r.string(8), clearedAt: r.date(9), clearNote: r.string(10))
        }
        return s
    }

    // MARK: Sections

    @discardableResult
    public func addSection(caseID: UUID, reportID: UUID, heading: String, parentSectionID: UUID? = nil, locatorNote: String? = nil,
                           actor: String, at date: Date = Date()) async throws -> UUID {
        let h = try Self.clean(heading, "The section heading")
        let who = try Self.clean(actor, "Actor")
        let id = UUID()
        try await write("cf_sec", caseID: caseID, actor: who, action: "reportSectionAdded", detail: h, at: date) { db in
            guard try !db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(reportID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("report")
            }
            if let p = parentSectionID, try db.query("SELECT 1 FROM case_report_sections WHERE id = ? AND report_id = ? AND withdrawn_at IS NULL;", [.uuid(p), .uuid(reportID)]).isEmpty {
                throw CaseWorkError.notInCase("parent section")
            }
            let ordinal = (try db.query("SELECT COALESCE(MAX(ordinal), 0) + 1 FROM case_report_sections WHERE report_id = ?;", [.uuid(reportID)]).first?.int(0)) ?? 1
            try db.exec("""
                INSERT INTO case_report_sections (id, case_id, report_id, parent_section_id, ordinal, heading, locator_note, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(reportID), parentSectionID.map { .uuid($0) } ?? .null, .integer(ordinal), .text(h),
                      .optionalText(Self.blankToNil(locatorNote)), .text(who), .date(date)])
        }
        return id
    }

    // MARK: Proposals

    /// Store one reading's suggestions. A sentence already proposed for this report and version is not proposed again
    /// (awaiting, accepted or dismissed); points are never read or written here.
    func recordProposals(caseID: UUID, reportID: UUID, sourceVersionID: UUID, suggestions: [(CasePointSuggestion, UUID?)], actor: String,
                         at date: Date) async throws -> CasePointSuggestionRun {
        let who = try Self.clean(actor, "Actor")
        let run = UUID()
        let box = SuggestionCountBox()
        try await write("cf_sug", caseID: caseID, actor: who, action: "pointsSuggested", detail: "\(suggestions.count) sentence(s) read by rule", at: date) { db in
            guard try !db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(reportID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("report")
            }
            for (s, block) in suggestions {
                if let state = try db.query("SELECT state FROM case_report_point_proposals WHERE case_id = ? AND report_id = ? AND source_version_id = ? AND quote = ?;",
                                            [.uuid(caseID), .uuid(reportID), .uuid(sourceVersionID), .text(s.quote)]).first?.string(0) {
                    if state == CaseReportProposalState.proposed.rawValue { box.already += 1 } else { box.decided += 1 }
                    continue
                }
                try db.exec("""
                    INSERT INTO case_report_point_proposals (id, case_id, report_id, run_id, source_version_id, block_id, quote, statement, point_kind,
                        section_hint, rule, rule_version, recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(caseID), .uuid(reportID), .uuid(run), .uuid(sourceVersionID), block.map { .uuid($0) } ?? .null,
                          .text(s.quote), .text(s.quote), .text(s.kind.rawValue), .optionalText(s.sectionHint), .text(s.rule),
                          .integer(Int64(CaseReportPointSuggester.ruleVersion)), .date(date)])
                box.added += 1
            }
        }
        return CasePointSuggestionRun(runID: run, added: box.added, alreadyProposed: box.already, alreadyDecided: box.decided, unavailable: nil)
    }

    func markProposal(caseID: UUID, id: UUID, state: CaseReportProposalState, pointID: UUID?, note: String?, actor: String, at date: Date) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_sugd", caseID: caseID, actor: who, action: state == .accepted ? "suggestionAccepted" : "suggestionDismissed", detail: note, at: date) { db in
            guard let st = try db.query("SELECT state FROM case_report_point_proposals WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first?.string(0) else {
                throw CaseWorkError.notInCase("suggested point")
            }
            guard st == CaseReportProposalState.proposed.rawValue else { throw CaseReportStructureError.proposalDecided }
            try db.exec("UPDATE case_report_point_proposals SET state = ?, decided_by = ?, decided_at = ?, decision_note = ?, point_id = ? WHERE id = ?;",
                        [.text(state.rawValue), .text(who), .date(date), .optionalText(Self.blankToNil(note)), pointID.map { .uuid($0) } ?? .null, .uuid(id)])
        }
    }

    // MARK: Point uses

    /// Use a point in another branch: the context must be a record of this case (a money movement is named by the id the map
    /// shows it with). The point's review and wording digest are recorded with the use.
    @discardableResult
    public func usePoint(caseID: UUID, pointID: UUID, in context: CasePointUseContext, contextID: String, note: String? = nil,
                         actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        let cid = try Self.clean(contextID, "The record it is used in")
        let id = UUID()
        try await write("cf_use", caseID: caseID, actor: who, action: "pointUsed", detail: "\(context.rawValue) \(cid)", at: date) { db in
            guard let r = try db.query("SELECT point_kind, statement, quote, review_state, withdrawn_at FROM case_report_points WHERE id = ? AND case_id = ?;",
                                       [.uuid(pointID), .uuid(caseID)]).first, r.date(4) == nil else { throw CaseWorkError.notInCase("point") }
            let table: String? = {
                switch context {
                case .question: return "SELECT 1 FROM case_allegations WHERE lower(id) = lower(?) AND case_id = ?;"
                case .person: return "SELECT 1 FROM case_people WHERE lower(id) = lower(?) AND case_id = ? AND removed_at IS NULL;"
                case .chronology: return "SELECT 1 FROM case_journal WHERE lower(id) = lower(?) AND case_id = ? AND removed_at IS NULL;"
                case .hypothesis: return "SELECT 1 FROM investigation_hypotheses WHERE lower(id) = lower(?) AND case_id = ?;"
                case .briefing: return "SELECT 1 FROM case_briefings WHERE lower(id) = lower(?) AND case_id = ? AND withdrawn_at IS NULL;"
                case .output: return "SELECT 1 FROM case_document_outputs WHERE lower(id) = lower(?) AND case_id = ?;"
                case .money: return nil
                }
            }()
            if let table, try db.query(table, [.text(cid), .uuid(caseID)]).isEmpty { throw CaseReportStructureError.contextNotInCase(context.label.lowercased()) }
            guard try db.query("SELECT 1 FROM case_report_point_uses WHERE case_id = ? AND point_id = ? AND context_kind = ? AND context_id = ? AND withdrawn_at IS NULL;",
                               [.uuid(caseID), .uuid(pointID), .text(context.rawValue), .text(cid)]).isEmpty else { throw CaseReportStructureError.alreadyUsed }
            let kind = r.string(0).flatMap(CaseReportPointKind.init(rawValue:)) ?? .claim
            let canonical = [kind.rawValue, r.string(1) ?? "", r.string(2) ?? ""].joined(separator: "\u{1F}")
            let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            try db.exec("""
                INSERT INTO case_report_point_uses (id, case_id, point_id, context_kind, context_id, note, review_at_use, digest_at_use, created_by, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(pointID), .text(context.rawValue), .text(cid), .optionalText(Self.blankToNil(note)),
                      .text(r.string(3) ?? CaseReportPointReview.unreviewed.rawValue), .text(digest), .text(who), .date(date)])
        }
        return id
    }

    public func withdrawPointUse(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let why = try Self.clean(reason, "The reason")
        let who = try Self.clean(actor, "Actor")
        try await write("cf_usew", caseID: caseID, actor: who, action: "pointUseWithdrawn", detail: why, at: date) { db in
            guard try !db.query("SELECT 1 FROM case_report_point_uses WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(id), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("point use")
            }
            try db.exec("UPDATE case_report_point_uses SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    // MARK: Supplied specialist items

    @discardableResult
    public func addArtifact(caseID: UUID, reportID: UUID, kind: CaseReportArtifactKind, label: String, sourceVersionID: UUID? = nil, locator: String? = nil,
                            description: String? = nil, suppliedBy: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let l = try Self.clean(label, "The item's label")
        let who = try Self.clean(actor, "Actor")
        let id = UUID()
        try await write("cf_art", caseID: caseID, actor: who, action: "reportItemSupplied", detail: l, at: date) { db in
            guard try !db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(reportID), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("report")
            }
            if let v = sourceVersionID, !(try Self.versionInCase(db, v, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_report_artifacts (id, case_id, report_id, artifact_kind, label, source_version_id, locator, description, supplied_by, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(reportID), .text(kind.rawValue), .text(l), sourceVersionID.map { .uuid($0) } ?? .null,
                      .optionalText(Self.blankToNil(locator)), .optionalText(Self.blankToNil(description)), .optionalText(Self.blankToNil(suppliedBy)),
                      .text(who), .date(date)])
        }
        return id
    }

    // MARK: Comparisons and review-needed flags

    /// Record a comparison and flag every piece of work that rests on a changed point. Reviews, decisions and outcomes are
    /// left exactly as they were; a flag is cleared by a person.
    func recordComparison(caseID: UUID, _ cmp: CaseReportVersionComparison, actor: String, at date: Date) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        let id = UUID()
        let json = cmp.encoded()
        try await write("cf_cmp", caseID: caseID, actor: who, action: "reportVersionsCompared", detail: "\(cmp.changedPoints.count) changed point(s)", at: date) { db in
            for r in [cmp.earlierReportID, cmp.laterReportID] {
                guard try !db.query("SELECT 1 FROM case_reports WHERE id = ? AND case_id = ?;", [.uuid(r), .uuid(caseID)]).isEmpty else { throw CaseWorkError.notInCase("report") }
            }
            try db.exec("""
                INSERT INTO case_report_comparisons (id, case_id, earlier_report_id, later_report_id, result_json, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(cmp.earlierReportID), .uuid(cmp.laterReportID), .text(json), .text(who), .date(date)])
            for w in cmp.affectedWork {
                try db.exec("""
                    INSERT INTO case_work_review_flags (id, case_id, work_kind, work_id, point_id, comparison_id, reason, raised_at) VALUES (?,?,?,?,?,?,?,?)
                    ON CONFLICT DO NOTHING;
                    """, [.uuid(UUID()), .uuid(caseID), .text(w.workKind), .uuid(w.workID), .uuid(w.pointID), .uuid(id), .text(w.reason), .date(date)])
            }
        }
        return id
    }

    public func clearReviewFlag(caseID: UUID, id: UUID, note: String, actor: String, at date: Date = Date()) async throws {
        let n = try Self.clean(note, "What the review found")
        let who = try Self.clean(actor, "Actor")
        try await write("cf_flagc", caseID: caseID, actor: who, action: "reviewFlagCleared", detail: n, at: date) { db in
            guard try !db.query("SELECT 1 FROM case_work_review_flags WHERE id = ? AND case_id = ? AND cleared_at IS NULL;", [.uuid(id), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("review flag")
            }
            try db.exec("UPDATE case_work_review_flags SET cleared_by = ?, cleared_at = ?, clear_note = ? WHERE id = ?;", [.text(who), .date(date), .text(n), .uuid(id)])
        }
    }

    /// The report's passages (live blocks of its version), in order, for the rule-based reader.
    func reportPassages(sourceVersionID: UUID) async throws -> [(block: UUID, text: String)] {
        try await database.query("""
            SELECT id, raw_text FROM evidence_blocks WHERE source_version_id = ? AND superseded_by_run IS NULL ORDER BY ordinal LIMIT 20000;
            """, [.uuid(sourceVersionID)]).compactMap { r in
            guard let id = r.uuid(0), let t = r.string(1), !t.isEmpty else { return nil }
            return (id, t)
        }
    }
}

private nonisolated final class SuggestionCountBox: @unchecked Sendable { var added = 0; var already = 0; var decided = 0 }

// MARK: - The work flows over the existing services

extension CaseFileService {

    /// "Suggest points" (AI off): read the report's own passages by rule and store each new candidate sentence as a
    /// proposal. Nothing becomes a point until a person accepts it.
    public func suggestPoints(caseID: UUID, reportID: UUID, actor: String, at date: Date = Date()) async throws -> CasePointSuggestionRun {
        guard let report = try await file.reportLedger(caseID: caseID).report(reportID) else { throw CaseWorkError.notInCase("report") }
        guard let version = report.sourceVersionID else {
            return CasePointSuggestionRun(runID: UUID(), added: 0, alreadyProposed: 0, alreadyDecided: 0,
                                          unavailable: "The report has no document in the case, so there is no text to read. Add points by hand.")
        }
        let passages = try await file.reportPassages(sourceVersionID: version)
        guard !passages.isEmpty else {
            return CasePointSuggestionRun(runID: UUID(), added: 0, alreadyProposed: 0, alreadyDecided: 0,
                                          unavailable: "The report's document has no readable passages yet (it may still be waiting to be read, or it could not be read).")
        }
        var suggestions: [(CasePointSuggestion, UUID?)] = []
        var heading: String?
        for p in passages {
            // A heading in one passage carries to the sentences of the next passages until another heading.
            for line in p.text.components(separatedBy: .newlines) where CaseReportPointSuggester.isHeading(line.trimmingCharacters(in: .whitespaces)) {
                heading = line.trimmingCharacters(in: .whitespaces)
            }
            for s in CaseReportPointSuggester.suggest(p.text) {
                suggestions.append((CasePointSuggestion(quote: s.quote, kind: s.kind, sectionHint: s.sectionHint ?? heading, rule: s.rule), p.block))
            }
        }
        return try await file.recordProposals(caseID: caseID, reportID: reportID, sourceVersionID: version, suggestions: suggestions, actor: actor, at: date)
    }

    /// Accept a suggestion: the point is recorded through the case's verifier with the suggestion's exact words (the
    /// person may word the statement differently), then the suggestion is marked accepted with the point it became.
    @discardableResult
    public func acceptSuggestion(caseID: UUID, proposalID: UUID, statement: String? = nil, kind: CaseReportPointKind? = nil,
                                 placement: CasePointPlacement = CasePointPlacement(), actor: String, at date: Date = Date()) async throws -> UUID {
        guard let p = try await file.reportStructure(caseID: caseID).proposals.first(where: { $0.id == proposalID }) else { throw CaseWorkError.notInCase("suggested point") }
        guard p.state == .proposed else { throw CaseReportStructureError.proposalDecided }
        var place = placement
        place.proposalID = proposalID
        let point = try await addPoint(caseID: caseID, reportID: p.reportID, kind: kind ?? p.kind, statement: statement ?? p.statement, quote: p.quote,
                                       locatorNote: p.sectionHint, placement: place, actor: actor, at: date)
        do { try await file.markProposal(caseID: caseID, id: proposalID, state: .accepted, pointID: point, note: nil, actor: actor, at: date) } catch {
            // The point names its proposal, so the pairing is not lost; the suggestion still reads as awaiting.
            KalsmritikoshLog.app.error("Suggestion accepted but not marked: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return point
    }

    public func dismissSuggestion(caseID: UUID, proposalID: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        _ = try CaseFileRepository.clean(reason, "The reason")
        try await file.markProposal(caseID: caseID, id: proposalID, state: .dismissed, pointID: nil, note: reason, actor: actor, at: date)
    }

    /// "Add point" with its question and person in the same step (REPORT-02): the point, then a use of it in each.
    @discardableResult
    public func addPoint(caseID: UUID, reportID: UUID, kind: CaseReportPointKind, statement: String, quote: String?, locatorNote: String? = nil,
                         placement: CasePointPlacement, questions: [UUID], people: [UUID], actor: String, at date: Date = Date()) async throws -> UUID {
        let point = try await addPoint(caseID: caseID, reportID: reportID, kind: kind, statement: statement, quote: quote, locatorNote: locatorNote,
                                       placement: placement, actor: actor, at: date)
        for q in questions { try await file.usePoint(caseID: caseID, pointID: point, in: .question, contextID: q.uuidString, actor: actor, at: date) }
        for p in people { try await file.usePoint(caseID: caseID, pointID: point, in: .person, contextID: p.uuidString, actor: actor, at: date) }
        return point
    }

    /// "Request evidence about this point" (REPORT-04): an evidence request of the case, linked raised-from the point with
    /// its purpose; what is asked for is the request's deliverable.
    @discardableResult
    public func requestEvidence(caseID: UUID, fromPoint pointID: UUID, details: EvidenceRequestDetails, purpose: String,
                                analysis: InvestigationAnalysisService, actor: String, at date: Date = Date()) async throws -> UUID {
        guard try await file.reportLedger(caseID: caseID).point(pointID)?.isActive == true else { throw CaseWorkError.notInCase("point") }
        let why = try CaseFileRepository.clean(purpose, "The purpose")
        let request = try await analysis.createEvidenceRequest(caseID: caseID, details: details, actor: actor, at: date)
        do {
            try await file.addWorkLink(caseID: caseID, work: .request, workID: request.id, target: .point, targetID: pointID, role: .raisedFrom, purpose: why, actor: actor, at: date)
        } catch {
            KalsmritikoshLog.app.error("Evidence request from a point not linked; cancelling it: \(error.localizedDescription, privacy: .public)")
            do { _ = try await analysis.cancelRequest(requestID: request.id, expectedRevision: request.revision, actor: actor, at: date) } catch {
                KalsmritikoshLog.app.error("The unlinked request could not be cancelled: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
        return request.id
    }

    /// "Compare with…" (REPORT-04): a comparison action raised from the point, naming the record it is compared with, with
    /// its purpose and expected result. The comparison is work; what it finds is recorded as its result.
    @discardableResult
    public func openComparison(caseID: UUID, fromPoint pointID: UUID, against target: CaseWorkLink.TargetKind, targetID: UUID, title: String,
                               purpose: String, deliverable: String, responsible: String? = nil, reviewer: String? = nil,
                               actor: String, at date: Date = Date()) async throws -> UUID {
        let task = try await createAction(caseID: caseID, ChildAction(title: title, purpose: purpose, deliverable: deliverable, responsible: responsible,
                                                                      reviewer: reviewer, fromPoint: pointID), actor: actor, at: date)
        do {
            try await file.addWorkLink(caseID: caseID, work: .task, workID: task, target: target, targetID: targetID, role: .compares, purpose: purpose, actor: actor, at: date)
        } catch {
            KalsmritikoshLog.app.error("Comparison target not linked; cancelling the action: \(error.localizedDescription, privacy: .public)")
            do { try await setTaskStatus(caseID: caseID, taskID: task, to: .cancelled, actor: actor, at: date) } catch {
                KalsmritikoshLog.app.error("The comparison action could not be cancelled: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
        return task
    }

    /// Compare two reports of the case (an original and its amendment) and record it; the work resting on a changed point
    /// is flagged for review. Nothing else changes.
    @discardableResult
    public func compareReports(caseID: UUID, earlier: UUID, later: UUID, actor: String, at date: Date = Date()) async throws -> (id: UUID, comparison: CaseReportVersionComparison) {
        let ledger = try await file.reportLedger(caseID: caseID)
        guard earlier != later, let cmp = CaseReportVersionComparison.compare(ledger, earlier: earlier, later: later) else { throw CaseReportStructureError.notAnAmendment }
        let id = try await file.recordComparison(caseID: caseID, cmp, actor: actor, at: date)
        return (id, cmp)
    }
}

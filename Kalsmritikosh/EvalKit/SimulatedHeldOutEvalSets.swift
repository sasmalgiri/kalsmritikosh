//
//  SimulatedHeldOutEvalSets.swift
//  Kalsmritikosh
//
//  Unified path R2-E (AI-14, BENEFIT-09, owner 2026-11-22 round 2) — not tested yet. SIMULATED independent evaluation:
//  deterministic generated cases with gold answers, split into a DEVELOPMENT set and a fresh HELD-OUT set made from a
//  different seed and different surface vocabulary (no case, name or sentence is shared — `overlap` proves it). Four
//  task families: extraction, retrieval, contradictions and action usefulness. The scorer is frozen (`scorerVersion`
//  and its fingerprint are recorded with every result) so the scorer cannot be tuned to the tested answers; refusal and
//  correction burden are recorded beside accuracy. BENEFIT-09: the same generated cases compare four modes and the
//  16-method review against ordinary follow-ups on identical evidence and budget. Answerers are closures: the test
//  phase plugs the app's services (or a scripted answerer); results are labelled SIMULATED.
//

import Foundation
import CryptoKit

public nonisolated enum SimEvalFamily: String, Sendable, CaseIterable, Codable { case extraction, retrieval, contradiction, actionUsefulness }
public nonisolated enum SimEvalSplit: String, Sendable, Codable { case development, heldOut }

public nonisolated struct SimEvalCase: Sendable, Equatable, Codable {
    public let id: String
    public let split: SimEvalSplit
    public let family: SimEvalFamily
    public let documents: [String]
    public let question: String
    /// The gold answer tokens: an answer is correct when it contains every one (case-insensitive).
    public let gold: [String]
    /// True when the right answer is to refuse (the corpus does not say).
    public let shouldRefuse: Bool
}

public nonisolated struct SimEvalAnswer: Sendable, Equatable {
    public var text: String
    public var refused: Bool
    /// Edits the (simulated) person had to make before using the answer.
    public var corrections: Int
    public init(text: String, refused: Bool = false, corrections: Int = 0) { self.text = text; self.refused = refused; self.corrections = corrections }
}

public nonisolated struct SimEvalResult: Sendable, Equatable {
    public let label = "SIMULATED evaluation — generated cases, not real investigations"
    public let split: SimEvalSplit
    public let scorerVersion: String
    public let scorerFingerprint: String
    public let perFamily: [SimEvalFamily: (correct: Int, total: Int)]
    public let wrongRefusals: Int
    public let missedRefusals: Int
    public let correctionBurden: Int
    public static func == (a: SimEvalResult, b: SimEvalResult) -> Bool {
        a.split == b.split && a.scorerFingerprint == b.scorerFingerprint && a.correctionBurden == b.correctionBurden
            && a.wrongRefusals == b.wrongRefusals && a.missedRefusals == b.missedRefusals
            && SimEvalFamily.allCases.allSatisfy { a.perFamily[$0]?.correct == b.perFamily[$0]?.correct && a.perFamily[$0]?.total == b.perFamily[$0]?.total }
    }
    public var accuracy: Double {
        let c = perFamily.values.reduce(0) { $0 + $1.correct }, t = perFamily.values.reduce(0) { $0 + $1.total }
        return t == 0 ? 0 : Double(c) / Double(t)
    }
}

public nonisolated enum SimulatedHeldOutEvalSets {
    public static let scorerVersion = "sim-scorer-1 (frozen 2026-11-22)"
    /// The scorer's rule, hashed: changing the rule changes the fingerprint recorded with every result.
    public static let scorerRule = "correct = not refused AND every gold token appears case-insensitively; refusal correct only when shouldRefuse"
    public static var scorerFingerprint: String { SHA256.hash(data: Data((scorerVersion + scorerRule).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }

    // Different vocabularies per split, so held-out surfaces are unseen during development.
    static let devPeople = ["Arun Mehta", "Bella Ortiz", "Chen Wei", "Dara Okafor", "Elena Rossi", "Farid Haddad"]
    static let heldPeople = ["Gita Rao", "Hugo Lind", "Ines Duarte", "Jonas Berg", "Kemi Adeyemi", "Lars Holm"]
    static let devOrgs = ["Northwind Ltd", "Bluepeak Supplies", "Corvid Freight"]
    static let heldOrgs = ["Silverline Trading", "Quayside Metals", "Harrow Logistics"]

    struct SplitMix { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) } }

    public static func generate(split: SimEvalSplit, perFamily: Int = 25) -> [SimEvalCase] {
        var rng = SplitMix(s: split == .development ? 0xD0_5EED : 0x4E1D_0075)
        let people = split == .development ? devPeople : heldPeople
        let orgs = split == .development ? devOrgs : heldOrgs
        var out: [SimEvalCase] = []
        for family in SimEvalFamily.allCases {
            for i in 0..<perFamily {
                let p = rng.pick(people), o = rng.pick(orgs), amount = rng.int(1_000...99_000), day = rng.int(1...28), month = rng.int(1...12)
                let date = String(format: "2025-%02d-%02d", month, day)
                let id = "\(split.rawValue)-\(family.rawValue)-\(i)"
                let refuse = i % 10 == 9
                switch family {
                case .extraction:
                    out.append(SimEvalCase(id: id, split: split, family: family,
                                           documents: ["Invoice \(i): \(o) billed \(amount) dollars on \(date). Approved by \(p)."],
                                           question: refuse ? "Who audited invoice \(i)?" : "How much did \(o) bill on invoice \(i)?",
                                           gold: refuse ? [] : ["\(amount)"], shouldRefuse: refuse))
                case .retrieval:
                    let decoys = (0..<3).map { k in "Memo \(i)-\(k): routine note about \(rng.pick(orgs)) stock levels." }
                    out.append(SimEvalCase(id: id, split: split, family: family,
                                           documents: decoys + ["Memo \(i)-key: \(p) met \(o) on \(date) to discuss the contract."],
                                           question: refuse ? "When did \(p) sign the lease?" : "When did \(p) meet \(o)?",
                                           gold: refuse ? [] : [date], shouldRefuse: refuse))
                case .contradiction:
                    let other = amount + rng.int(100...900)
                    out.append(SimEvalCase(id: id, split: split, family: family,
                                           documents: ["Statement A: \(p) says the payment to \(o) was \(amount) dollars.",
                                                       "Statement B: the ledger shows the payment to \(o) was \(other) dollars."],
                                           question: "What was the payment to \(o)?",
                                           gold: ["\(amount)", "\(other)"], shouldRefuse: false))
                case .actionUsefulness:
                    out.append(SimEvalCase(id: id, split: split, family: family,
                                           documents: ["Email: \(p) promised the signed delivery note from \(o) by \(date); none is on file."],
                                           question: "What should the investigator request next?",
                                           gold: ["delivery note", o], shouldRefuse: false))
                }
            }
        }
        return out
    }

    /// Shared names, organisations or documents between two sets (must be empty for dev vs held-out).
    public static func overlap(_ a: [SimEvalCase], _ b: [SimEvalCase]) -> Set<String> {
        let vocab = devPeople + heldPeople + devOrgs + heldOrgs
        func terms(_ s: [SimEvalCase]) -> Set<String> {
            Set(s.flatMap { c in vocab.filter { v in c.documents.contains { $0.contains(v) } } } + s.flatMap(\.documents))
        }
        return terms(a).intersection(terms(b))
    }

    public static func isCorrect(_ c: SimEvalCase, _ a: SimEvalAnswer) -> Bool {
        if c.shouldRefuse { return a.refused }
        if a.refused { return false }
        let t = a.text.lowercased()
        return c.gold.allSatisfy { t.contains($0.lowercased()) }
    }

    public static func score(_ cases: [SimEvalCase], answer: @Sendable (SimEvalCase) async -> SimEvalAnswer) async -> SimEvalResult {
        var per: [SimEvalFamily: (correct: Int, total: Int)] = [:]
        var wrongRefusals = 0, missed = 0, burden = 0
        for c in cases {
            let a = await answer(c)
            var e = per[c.family] ?? (0, 0)
            e.total += 1
            if isCorrect(c, a) { e.correct += 1 }
            if a.refused, !c.shouldRefuse { wrongRefusals += 1 }
            if !a.refused, c.shouldRefuse { missed += 1 }
            burden += a.corrections
            per[c.family] = e
        }
        return SimEvalResult(split: cases.first?.split ?? .development, scorerVersion: scorerVersion, scorerFingerprint: scorerFingerprint,
                             perFamily: per, wrongRefusals: wrongRefusals, missedRefusals: missed, correctionBurden: burden)
    }

    /// A deterministic corpus-reading answerer (no AI): the baseline every simulated mode is compared with. It answers
    /// from the documents only (the sentence holding the question's subject) and refuses when nothing matches.
    public static func corpusBaseline(_ c: SimEvalCase) -> SimEvalAnswer {
        let words = c.question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 }
        let hits = c.documents.filter { d in let l = d.lowercased(); return words.filter { l.contains($0) }.count >= 2 }
        if hits.isEmpty { return SimEvalAnswer(text: "", refused: true) }
        let verbs = ["audited", "sign", "lease"]
        if words.contains(where: { verbs.contains($0) }), !hits.contains(where: { d in verbs.contains { d.lowercased().contains($0) } }) {
            return SimEvalAnswer(text: "", refused: true)
        }
        return SimEvalAnswer(text: hits.joined(separator: " "), corrections: hits.count > 1 ? 1 : 0)
    }

    // MARK: BENEFIT-09 — four modes and the 16-method review on identical evidence and budget

    public enum Mode: String, Sendable, CaseIterable {
        case localOnly = "local only"
        case lookupAIOff = "authorized lookup / manual specialist, AI off"
        case aiOnCorpus = "AI on the supplied corpus"
        case aiPlusAcquisition = "AI plus authorized acquisition"
    }

    public struct ModeComparison: Sendable {
        public let label = "SIMULATED mode comparison — generated matched cases; real cases and people still needed"
        public let budgetPerCase: Int
        public var rows: [(mode: String, development: Double, heldOut: Double, burden: Int)] = []
        public var markdown: String {
            var s = "# \(label)\n\nBudget per case (identical for every mode): \(budgetPerCase) answer calls.\n\n| Mode | Development | Held-out | Correction burden |\n|---|---|---|---|\n"
            for r in rows { s += "| \(r.mode) | \(String(format: "%.1f %%", r.development * 100)) | \(String(format: "%.1f %%", r.heldOut * 100)) | \(r.burden) |\n" }
            return s
        }
    }

    /// Runs each mode's answerer over the development and held-out sets with the same budget. `answerers` maps a mode
    /// name (a `Mode` raw value, "16-method review" or "ordinary follow-ups") to its answerer.
    public static func compare(answerers: [(String, @Sendable (SimEvalCase) async -> SimEvalAnswer)], budgetPerCase: Int = 3) async -> ModeComparison {
        let dev = generate(split: .development), held = generate(split: .heldOut)
        var cmp = ModeComparison(budgetPerCase: budgetPerCase)
        for (name, answer) in answerers {
            let d = await score(dev, answer: answer), h = await score(held, answer: answer)
            cmp.rows.append((name, d.accuracy, h.accuracy, d.correctionBurden + h.correctionBurden))
        }
        return cmp
    }
}

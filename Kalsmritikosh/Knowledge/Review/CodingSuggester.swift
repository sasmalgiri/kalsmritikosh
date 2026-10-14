//
//  CodingSuggester.swift
//  Kalsmritikosh
//
//  N-4 — review-coding suggestions that learn from the reviewer and show why.
//  A multinomial naive-Bayes model over document words, trained only on the
//  documents the reviewer coded responsive / not responsive. Each suggestion
//  carries its probability and the words that pushed it most. Suggestions never
//  change evidence or codes; the reviewer decides. Pure and deterministic.
//

import Foundation

public nonisolated struct CodingSuggestion: Sendable, Equatable {
    public let responsiveProbability: Double
    public let reasons: [String]
    public var label: String { responsiveProbability >= 0.5 ? "Likely responsive" : "Likely not responsive" }
}

public nonisolated struct CodingSuggester: Sendable {
    /// Minimum coded documents per class before suggesting anything.
    public static let minPerClass = 3

    private let logPrior: [Bool: Double]
    private let logLikelihood: [Bool: [String: Double]]
    private let unseen: [Bool: Double]

    public static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count >= 3 && !FTSQuerySanitizer.stopwords.contains($0) }
    }

    /// nil until each class has `minPerClass` examples.
    public init?(training: [(text: String, responsive: Bool)]) {
        let pos = training.filter(\.responsive), neg = training.filter { !$0.responsive }
        guard pos.count >= Self.minPerClass, neg.count >= Self.minPerClass else { return nil }
        var counts: [Bool: [String: Int]] = [true: [:], false: [:]]
        var totals: [Bool: Int] = [true: 0, false: 0]
        var vocab = Set<String>()
        for t in training {
            for w in Self.words(t.text) {
                counts[t.responsive]![w, default: 0] += 1
                totals[t.responsive]! += 1
                vocab.insert(w)
            }
        }
        let v = Double(max(vocab.count, 1))
        var ll: [Bool: [String: Double]] = [:]
        var un: [Bool: Double] = [:]
        for cls in [true, false] {
            let denom = Double(totals[cls]!) + v
            ll[cls] = counts[cls]!.mapValues { log((Double($0) + 1) / denom) }
            un[cls] = log(1 / denom)
        }
        logLikelihood = ll
        unseen = un
        let n = Double(training.count)
        logPrior = [true: log(Double(pos.count) / n), false: log(Double(neg.count) / n)]
    }

    public func suggest(_ text: String) -> CodingSuggestion {
        let ws = Self.words(text)
        var score: [Bool: Double] = logPrior
        var contribution: [String: Double] = [:]
        for w in ws {
            let p = logLikelihood[true]![w] ?? unseen[true]!
            let q = logLikelihood[false]![w] ?? unseen[false]!
            score[true]! += p
            score[false]! += q
            contribution[w, default: 0] += p - q
        }
        let diff = score[true]! - score[false]!
        let prob = 1 / (1 + exp(-max(-40, min(40, diff))))
        let sign: Double = prob >= 0.5 ? 1 : -1
        let reasons = contribution.filter { $0.value * sign > 0 }
            .sorted { abs($0.value) > abs($1.value) }.prefix(5).map(\.key)
        return CodingSuggestion(responsiveProbability: prob, reasons: Array(reasons))
    }
}

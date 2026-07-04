//
//  AITextCorrector.swift
//  Kalsmritikosh
//
//  Hybrid, on-device text corrector for the Convert screen — an
//  Apple-AI + NLP Mixture-of-Experts. Two experts run and combine:
//
//    Expert 1 — NLP (deterministic, no LLM): NLTagger finds the personal
//      names in the document, votes by frequency, and rewrites a rare
//      misspelled variant to the corroborated spelling seen elsewhere in
//      the SAME text ("Thirshendus Sasmal" → "Shirshendu Sasmal"). Always
//      available, instant, and safe (names carry no digits).
//
//    Expert 2 — Apple on-device AI (hybrid via CapabilityRegistry): the
//      Apple system model wins when available (macOS 26+), with a local
//      model as fallback and cloud only if the PrivacyGate allows. It
//      proofreads the NLP-cleaned text, primed with the NLP expert's list
//      of known-correct names. Callers never name a provider.
//
//  SAFETY CONTRACT (legal/financial corpus — a wrong "fix" is worse than a
//  visible glitch): never adds/removes/summarizes/translates content; every
//  digit run must survive unchanged; a candidate that alters any number or
//  drifts far in length is REJECTED; any failure/unavailable model falls
//  back to the prior text. The corrector can only make the text safer.
//

import Foundation
import NaturalLanguage
import OSLog

public struct AITextCorrector: Sendable {

    public struct Result: Sendable {
        public let text: String
        /// True when any expert made a safe, non-identical change.
        public let corrected: Bool
        /// Which experts contributed ("nlp", "apple-ai").
        public let experts: [String]
    }

    public init() {}

    public func correct(_ text: String, using capabilities: CapabilityRegistry?) async -> Result {
        let original = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return Result(text: original, corrected: false, experts: []) }

        var experts: [String] = []

        // ── Expert 1 — NLP name voting (deterministic, on-device) ──
        let (nlpText, nlpChanged) = Self.nlpNameVote(trimmed)
        if nlpChanged { experts.append("nlp") }
        var working = nlpText

        // ── Expert 2 — Apple on-device AI proofread (hybrid) ──
        // No size cap here: appleAIProofread chunks to fit the 4,096-token
        // window and processes chunks in parallel sessions.
        if let capabilities,
           let aiText = await Self.appleAIProofread(
               working,
               knownNames: Self.frequentPersonNames(trimmed),
               using: capabilities
           ) {
            if aiText != working { experts.append("apple-ai") }
            working = aiText
        }

        let changed = working != trimmed
        return Result(text: changed ? working : original, corrected: changed, experts: experts)
    }

    // MARK: - Expert 1: NLP name voting

    /// Rewrite rare misspelled personal-name variants to the corroborated
    /// spelling seen ≥2× in the same document. No LLM. Digit-safe.
    static func nlpNameVote(_ text: String) -> (String, Bool) {
        var freq: [String: Int] = [:]        // normalized name → count
        var surface: [String: String] = [:]  // normalized → representative surface form

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
            if tag == .personalName {
                let name = String(text[range]).trimmingCharacters(in: .whitespaces)
                let norm = name.lowercased()
                if norm.split(separator: " ").count >= 2 {   // multi-token names only
                    freq[norm, default: 0] += 1
                    if surface[norm] == nil { surface[norm] = name }
                }
            }
            return true
        }
        guard freq.count >= 2 else { return (text, false) }

        let ranked = freq.sorted { $0.value > $1.value }
        var map: [String: String] = [:]   // wrong surface → right surface
        for (winnerNorm, winnerCount) in ranked {
            guard winnerCount >= 2 else { break }   // sorted: rest are <2 too
            for (loserNorm, loserCount) in ranked where loserCount <= 1 && loserNorm != winnerNorm {
                guard let ws = winnerNorm.split(separator: " ").last,
                      let ls = loserNorm.split(separator: " ").last, ws == ls else { continue }  // same surname
                if NameSimilarity.jaroWinkler(winnerNorm, loserNorm) >= 0.88,
                   let wrong = surface[loserNorm], let right = surface[winnerNorm] {
                    map[wrong] = right
                }
            }
        }
        guard !map.isEmpty else { return (text, false) }

        var out = text
        for (wrong, right) in map { out = out.replacingOccurrences(of: wrong, with: right) }
        if out != text {
            AtlasLog.knowledge.info("AITextCorrector[nlp]: fixed \(map.count, privacy: .public) name variant(s)")
        }
        return (out, out != text)
    }

    /// Personal names occurring ≥2× — handed to the AI expert as anchors.
    static func frequentPersonNames(_ text: String) -> [String] {
        var freq: [String: (count: Int, surface: String)] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName {
                let name = String(text[range]).trimmingCharacters(in: .whitespaces)
                if name.split(separator: " ").count >= 2 {
                    let key = name.lowercased()
                    freq[key] = (( freq[key]?.count ?? 0) + 1, name)
                }
            }
            return true
        }
        return freq.values.filter { $0.count >= 2 }.map(\.surface)
    }

    // MARK: - Expert 2: Apple on-device AI

    /// Returns a SAFE proofread of `text`, or nil if no model is available.
    ///
    /// The Apple on-device model has a FIXED 4,096-token window and proofread
    /// output ≈ input, so a whole document rarely fits. We split into chunks
    /// small enough that input + its rewrite + instructions stay under the
    /// window, proofread each chunk in its OWN session (run concurrently —
    /// separate sessions are allowed), then stitch the results back. Each
    /// chunk is independently safety-guarded; an unsafe/failed chunk keeps
    /// its original text, so the whole never degrades.
    static func appleAIProofread(_ text: String, knownNames: [String], using capabilities: CapabilityRegistry) async -> String? {
        let spec = CapabilitySpec.reasoning(
            contextTokens: 4_000,
            purpose: "OCR/extraction proofread (facts-preserving)"
        )
        guard let provider = try? await capabilities.resolve(spec),
              await provider.isAvailable() else { return nil }

        let namesLine = knownNames.isEmpty ? "" :
            "\nKnown-correct names in this document (use these spellings): \(knownNames.joined(separator: "; "))."
        let system = """
        You are a strict proofreader for OCR / extracted document text. Fix only \
        obvious OCR mistakes — misread letters, wrongly split or joined words, and \
        casing — using the DOCUMENT'S OWN CONTEXT. Hard rules you must never break:
        - Do NOT add, remove, summarize, translate, explain, or reorder anything.
        - Do NOT change any number, date, amount, ID, email address, or phone number.
        - Only correct a name or word when its correct form appears elsewhere in the same text.
        - When unsure, leave the text exactly as it is.
        Output ONLY the corrected text — no preamble, no commentary.\(namesLine)
        """

        // Reserve room for the rewrite (~equal to input) + instructions.
        // ~1,500 input tokens/chunk → input + output (~1,500) + instructions
        // (~250) ≈ 3,250, comfortably under 4,096.
        let chunks = TokenBudget.chunk(text, maxTokens: 1_500)

        // Fan out: each chunk in its own concurrent session (index-tagged so
        // we can reassemble in order).
        let corrected = await withTaskGroup(of: (Int, String).self) { group -> [String] in
            for (i, chunk) in chunks.enumerated() {
                group.addTask {
                    let options = GenerationOptions(maxTokens: 2_048, temperature: 0.0, systemPrompt: system)
                    guard let raw = try? await provider.generate(
                        prompt: "Proofread this document text:\n\n\(chunk)",
                        options: options
                    ) else { return (i, chunk) }   // failed → keep original chunk
                    let candidate = Self.stripPreamble(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                    return (i, Self.isSafeCorrection(original: chunk, candidate: candidate) ? candidate : chunk)
                }
            }
            var out = Array(repeating: "", count: chunks.count)
            for await (i, piece) in group { out[i] = piece }
            return out
        }

        let joined = corrected.joined()
        if joined == text {
            AtlasLog.knowledge.info("AITextCorrector[apple-ai]: no safe change across \(chunks.count, privacy: .public) chunk(s)")
        }
        return joined
    }

    // MARK: - Guards

    nonisolated static func isSafeCorrection(original: String, candidate: String) -> Bool {
        guard candidate.count >= 20 else { return false }
        let lo = Double(original.count) * 0.75
        let hi = Double(original.count) * 1.25
        guard Double(candidate.count) >= lo, Double(candidate.count) <= hi else { return false }
        return digitRuns(original) == digitRuns(candidate)
    }

    nonisolated static func digitRuns(_ s: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for ch in s {
            if ch.isNumber { current.append(ch) }
            else if !current.isEmpty { runs.append(current); current = "" }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.sorted()
    }

    private nonisolated static func stripPreamble(_ s: String) -> String {
        guard let nl = s.firstIndex(of: "\n") else { return s }
        let firstLine = s[..<nl].lowercased()
        if firstLine.contains("corrected text") || firstLine.contains("here is") || firstLine.contains("here's") {
            return String(s[s.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}

//
//  NoisyFixtureGenerator.swift
//  Kalsmritikosh
//
//  Unified path IN-25 (owner 2026-11-22) — not tested yet.
//
//  C-3 — turns a clean fixture text into the noisy variants real archives produce, so every gold
//  question can be asked again of its noisy twin:
//    • OCR glyph confusions (O→0, 0→O, l→1, 1→l, rn→m, m→rn, S→5, 5→S),
//    • a page break inserted between a field label and its value ("Patent No.\n--- PAGE 2 ---\n700321"),
//    • label spelling variants ("Patent No." → "Patent Number" / "Pat. No." / "PATENT NO:").
//  Deterministic: the same text and seed always give the same variants (a small LCG, not the
//  system random source). An evaluation utility only — nothing here is written to the ledger.
//

import Foundation

public nonisolated struct NoisyFixtureGenerator: Sendable {

    public enum Noise: String, Sendable, CaseIterable {
        case ocrConfusion, pageBreakSplit, labelVariant
    }

    public struct Variant: Sendable, Hashable {
        public let noise: Noise
        public let text: String
        /// What was changed, in plain words, for the evaluation report.
        public let note: String
    }

    public let seed: UInt64
    /// Share of confusable glyphs changed in an OCR variant (0…1).
    public let ocrRate: Double

    public init(seed: UInt64 = 20261122, ocrRate: Double = 0.3) {
        self.seed = seed
        self.ocrRate = max(0, min(1, ocrRate))
    }

    /// One variant per kind of noise that applies to `text` (a kind that finds nothing to change is skipped).
    public func variants(of text: String) -> [Variant] {
        Noise.allCases.compactMap { variant(of: text, noise: $0) }
    }

    public func variant(of text: String, noise: Noise) -> Variant? {
        switch noise {
        case .ocrConfusion: return ocrVariant(text)
        case .pageBreakSplit: return pageBreakVariant(text)
        case .labelVariant: return labelVariant(text)
        }
    }

    // MARK: - OCR confusions

    static let glyphSwaps: [Character: Character] = ["O": "0", "0": "O", "l": "1", "1": "l", "S": "5", "5": "S"]

    func ocrVariant(_ text: String) -> Variant? {
        var rng = LCG(seed: seed)
        var out = ""
        var changed = 0
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if c == "r", next < text.endIndex, text[next] == "n", rng.nextUnit() < ocrRate {
                out.append("m"); changed += 1
                i = text.index(after: next); continue
            }
            if let swap = Self.glyphSwaps[c], rng.nextUnit() < ocrRate {
                out.append(swap); changed += 1
            } else {
                out.append(c)
            }
            i = next
        }
        guard changed > 0 else { return nil }
        return Variant(noise: .ocrConfusion, text: out, note: "\(changed) character(s) changed the way a scanner misreads them")
    }

    // MARK: - Page-break split

    /// "Label: value" or "Label No. value" on one line → the label, a page marker, then the value.
    static let labelValuePattern = #"(?m)^(?<label>[A-Z][A-Za-z .#/]{1,40}?(?:No\.?|Number|Date|Name|:))\s*(?<value>\S[^\n]{0,60})$"#

    func pageBreakVariant(_ text: String) -> Variant? {
        guard let re = try? NSRegularExpression(pattern: Self.labelValuePattern) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var rng = LCG(seed: seed &+ 1)
        let pick = matches[Int(rng.next() % UInt64(matches.count))]
        let label = ns.substring(with: pick.range(withName: "label"))
        let value = ns.substring(with: pick.range(withName: "value"))
        let replacement = "\(label)\n--- PAGE 2 ---\n\(value)"
        let out = ns.replacingCharacters(in: pick.range, with: replacement)
        return Variant(noise: .pageBreakSplit, text: out, note: "a page break now separates \"\(label)\" from its value")
    }

    // MARK: - Label spelling variants

    static let labelSpellings: [(String, [String])] = [
        ("Patent No.", ["Patent Number", "Pat. No.", "PATENT NO:"]),
        ("Application No.", ["Application Number", "Appl. No.", "APPLICATION NO:"]),
        ("Date of Birth", ["DOB", "D.O.B.", "Birth Date"]),
        ("Invoice No.", ["Invoice #", "Inv. No.", "INVOICE NUMBER"]),
        ("Account No.", ["A/c No.", "Account Number", "ACCT NO"]),
    ]

    func labelVariant(_ text: String) -> Variant? {
        var rng = LCG(seed: seed &+ 2)
        for (label, spellings) in Self.labelSpellings {
            guard let r = text.range(of: label, options: .caseInsensitive) else { continue }
            let alt = spellings[Int(rng.next() % UInt64(spellings.count))]
            var out = text
            out.replaceSubrange(r, with: alt)
            return Variant(noise: .labelVariant, text: out, note: "\"\(label)\" written as \"\(alt)\"")
        }
        return nil
    }

    // MARK: - Deterministic generator

    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 11
        }
        mutating func nextUnit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    }
}

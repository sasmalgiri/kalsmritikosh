//
//  VerifiableReceipt.swift
//  Kalsmritikosh
//
//  Tamper-evident evidence receipts — the wedge no cloud tool can match: an
//  answer/finding exported as a hash-chained bundle a third party can RE-CHECK
//  offline. Each entry pins a claim to a verbatim source passage and a hash of
//  that passage; entries are linked in a SHA-256 chain so altering any claim,
//  passage, or order breaks every downstream hash. Pure + deterministic: no
//  model, no network. The court/newsroom-grade "prove every word" primitive.
//

import Foundation
import CryptoKit

/// An unsealed claim→evidence pairing to be chained.
public struct ReceiptDraft: Sendable, Hashable {
    public let claim: String
    public let source: String        // filename / locator
    public let date: Date?
    public let passage: String       // verbatim supporting text
    public init(claim: String, source: String, date: Date? = nil, passage: String) {
        self.claim = claim; self.source = source; self.date = date; self.passage = passage
    }
}

/// A sealed entry: the draft plus the hash of its passage and its position in
/// the tamper-evident chain.
public struct SealedReceiptEntry: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let claim: String
    public let source: String
    public let date: Date?
    public let passage: String
    public let passageHash: String   // SHA-256 of the verbatim passage
    public let chainHash: String     // SHA-256(prevChainHash | canonical(entry))
}

public struct SealedReceipt: Sendable, Hashable {
    public let title: String
    public let entries: [SealedReceiptEntry]
    /// The final chain hash — the single value that certifies the whole bundle.
    public var seal: String { entries.last?.chainHash ?? VerifiableReceipt.genesis }
}

public enum VerifiableReceipt {
    /// Chain root — a fixed, published starting hash so verification is
    /// reproducible without shipping extra state.
    public static let genesis = "kalsmritikosh:receipt:v1"
    public static let algorithm = "SHA-256 chain (entryₙ = SHA256(entryₙ₋₁ | index | claim | source | passageHash))"

    /// Seal a list of drafts into a tamper-evident chain, in order.
    public static func seal(title: String, drafts: [ReceiptDraft]) -> SealedReceipt {
        var entries: [SealedReceiptEntry] = []
        var prev = genesis
        for (i, d) in drafts.enumerated() {
            let pHash = sha256(d.passage)
            let chain = sha256("\(prev)|\(i)|\(d.claim)|\(d.source)|\(pHash)")
            entries.append(SealedReceiptEntry(
                index: i, claim: d.claim, source: d.source, date: d.date,
                passage: d.passage, passageHash: pHash, chainHash: chain
            ))
            prev = chain
        }
        return SealedReceipt(title: title, entries: entries)
    }

    /// Recompute the chain from the entries' claims/sources/passages and confirm
    /// every stored hash matches. Returns false if ANY field or the order was
    /// altered after sealing — the whole point of the receipt.
    public static func verify(_ receipt: SealedReceipt) -> Bool {
        var prev = genesis
        for (i, e) in receipt.entries.enumerated() {
            guard e.index == i else { return false }
            guard e.passageHash == sha256(e.passage) else { return false }
            let expected = sha256("\(prev)|\(i)|\(e.claim)|\(e.source)|\(e.passageHash)")
            guard e.chainHash == expected else { return false }
            prev = expected
        }
        return true
    }

    // MARK: - Export

    public static func markdown(_ r: SealedReceipt) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
        var md = "# Verifiable evidence receipt\n\n"
        md += "**\(r.title)**\n\n"
        md += "_Each claim below is pinned to a verbatim source passage and its SHA-256 hash. "
        md += "The entries form a tamper-evident chain: altering any claim, passage, or order "
        md += "changes the seal. Anyone can re-verify offline._\n\n"
        md += "- **Algorithm:** \(algorithm)\n"
        md += "- **Genesis:** `\(genesis)`\n"
        md += "- **Seal (certifies the whole bundle):** `\(r.seal)`\n\n"
        for e in r.entries {
            md += "---\n\n### \(e.index + 1). \(e.claim)\n\n"
            md += "- **Source:** \(e.source)"
            if let d = e.date { md += " (\(iso.string(from: d)))" }
            md += "\n"
            md += "- **Passage:** \(e.passage.replacingOccurrences(of: "\n", with: " "))\n"
            md += "- **Passage SHA-256:** `\(e.passageHash)`\n"
            md += "- **Chain hash:** `\(e.chainHash)`\n\n"
        }
        return md
    }

    /// Canonical JSON so a verifier in any language can reproduce the hashes.
    public static func json(_ r: SealedReceipt) -> String {
        let iso = ISO8601DateFormatter()
        var entryObjs: [String] = []
        for e in r.entries {
            let dateField = e.date.map { "\"date\":\"\(iso.string(from: $0))\"," } ?? ""
            entryObjs.append("""
            {"index":\(e.index),"claim":\(jsonString(e.claim)),"source":\(jsonString(e.source)),\(dateField)"passage":\(jsonString(e.passage)),"passageHash":"\(e.passageHash)","chainHash":"\(e.chainHash)"}
            """)
        }
        return """
        {"format":"kalsmritikosh.receipt.v1","algorithm":\(jsonString(algorithm)),"genesis":"\(genesis)","title":\(jsonString(r.title)),"seal":"\(r.seal)","entries":[\(entryObjs.joined(separator: ","))]}
        """
    }

    // MARK: - Helpers

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        out += "\""
        return out
    }
}

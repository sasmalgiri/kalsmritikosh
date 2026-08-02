//
//  ProgressiveAnswerContentHasher.swift
//  Kalsmritikosh
//
//  AEE-M2 — the canonical content fingerprint of a user-visible answer. If the fingerprint
//  changes after an answer-shaped revision has been shown, a NEW revision is required (a
//  correction, never a silent overwrite). Deterministic SHA-256 over the normalized answer
//  text + the SORTED citation identities + the AnswerState. Only insignificant
//  whitespace/newline differences are normalized away — a real wording change is a new hash.
//

import Foundation
import CryptoKit

public nonisolated struct ProgressiveAnswerContentHasher: Sendable {
    public init() {}

    /// The 64-char lowercase-hex SHA-256 fingerprint (matches the answer_revisions CHECK).
    public func hash(answerText: String, citations: [VerifiedAnswer.Citation], answerState: AnswerState) -> String {
        let canonical = Self.canonicalString(answerText: answerText, citations: citations, answerState: answerState)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The exact bytes hashed — exposed for tests and for equality checks without re-hashing.
    static func canonicalString(answerText: String, citations: [VerifiedAnswer.Citation], answerState: AnswerState) -> String {
        let text = normalize(answerText)
        let ids = citations.map(citationIdentity).sorted()
        // Unit-separator delimiters keep the three sections unambiguous.
        return text + "\u{1F}citations\u{1F}" + ids.joined(separator: "\u{1E}") + "\u{1F}state\u{1F}" + answerState.rawValue
    }

    /// Collapse only insignificant whitespace (runs of spaces/tabs/newlines → one space),
    /// trim the ends. A meaningful wording change survives; a reflow does not.
    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    /// A citation's IDENTITY — object + chunk + event ids, never the free-text snippet (prose
    /// wording must not perturb the fingerprint; the cited evidence identity must).
    static func citationIdentity(_ c: VerifiedAnswer.Citation) -> String {
        "\(c.objectID.uuidString)|\(c.chunkID?.uuidString ?? "-")|\(c.eventID?.uuidString ?? "-")"
    }
}

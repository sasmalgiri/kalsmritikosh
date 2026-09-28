//
//  AnswerPresentation.swift
//  Kalsmritikosh
//
//  U-1 (implement-all) — ANSWER/EVIDENCE SEPARATION, the organizing law
//  of the answer surface: nothing that fails in evidence may touch the
//  answer; there is always an answer sentence. This stage is PURE — it
//  never composes, never re-words, never drops a byte of the rendered
//  body. It only decides which bytes belong to the Answer section
//  (sentence · badge · one-line trust note) and which to the Evidence
//  section (About/footers · confidence details · conflicts), and grades
//  the evidence as complete / partial / failed with the reason shown.
//

import Foundation

/// The badge semantics table (U-1). Labels are the Language-Contract
/// blessed strings — render them verbatim, never re-word per call site.
public enum AnswerBadge: String, Sendable, CaseIterable {
    case supported
    case partiallySupported
    case unverified
    case notFound
    case twinVerified
    case aiReadingDiffered

    public var label: String {
        switch self {
        case .supported:         return "Supported"
        case .partiallySupported: return "Partially supported"
        case .unverified:        return "Unverified — AI reading; evidence check failed"
        case .notFound:          return "Not found"
        case .twinVerified:      return "Twin-verified"
        case .aiReadingDiffered: return "AI reading differed"
        }
    }
}

/// One answer, split for the two-section card. `answerText` and
/// `evidenceText` are byte-exact partitions of the rendered body (plus
/// the relocated trust-note line) — concatenating them restores every
/// non-whitespace byte, so the composers' output is provably untouched.
public struct AnswerSplit: Sendable {
    public struct AnswerSection: Sendable {
        public let text: String
        public let badge: AnswerBadge?
        /// The single confidence line ("Confidence: strong · 2 sources"),
        /// relocated from the body's footer — the ONE confidence
        /// presentation, never a second phrasing.
        public let trustNote: String?
    }
    public enum EvidenceState: Sendable, Equatable {
        case complete
        case partial(reason: String)
        case failed(reason: String)
    }
    public struct EvidenceSection: Sendable {
        public let text: String
        public let state: EvidenceState
    }
    public let answer: AnswerSection
    public let evidence: EvidenceSection
}

public enum AnswerPresentation {

    /// Split a rendered turn body into the two sections. Pure function of
    /// (body, VerifiedAnswer); no I/O, no model, no re-wording.
    public nonisolated static func split(body: String, answer: VerifiedAnswer?) -> AnswerSplit {
        guard let answer else {
            // Legacy turn (loaded history without its VerifiedAnswer):
            // everything is the answer; evidence details are gone, and the
            // section says so instead of pretending completeness.
            return AnswerSplit(
                answer: .init(text: body, badge: nil, trustNote: nil),
                evidence: .init(text: "", state: .partial(reason: "Evidence details are not available for this answer.")))
        }

        var answerPart = body
        var evidencePart = ""
        if let sentence = answer.answerText, !sentence.isEmpty,
           let range = body.range(of: sentence) {
            answerPart = String(body[..<range.upperBound])
            evidencePart = String(body[range.upperBound...])
        }

        // Relocate the one-line confidence note into the Answer section —
        // same bytes, same single presentation, different placement.
        var trustNote: String?
        var lines = evidencePart.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("Confidence: ") }) {
            trustNote = lines.remove(at: i)
            evidencePart = lines.joined(separator: "\n")
        }

        return AnswerSplit(
            answer: .init(
                text: answerPart.trimmingCharacters(in: .whitespacesAndNewlines),
                badge: badge(for: answer),
                trustNote: trustNote),
            evidence: .init(
                text: evidencePart.trimmingCharacters(in: .whitespacesAndNewlines),
                state: evidenceState(for: answer)))
    }

    /// Badge from the closed-corpus verdict. States whose story is told
    /// elsewhere (conflicts list, coverage note) carry no badge rather
    /// than a second, disagreeing presentation.
    public nonisolated static func badge(for answer: VerifiedAnswer) -> AnswerBadge? {
        if answer.refused {
            return answer.answerState == .notFound ? .notFound : nil
        }
        switch answer.answerState {
        case .supported:            return .supported
        case .partiallySupported:   return .partiallySupported
        case .unverified:           return .unverified
        case .notFound:             return .notFound
        case .contradicted, .insufficientlyIndexed, .unknown:
            return nil
        }
    }

    /// Evidence grade: whatever fails here marks THIS section only — the
    /// answer sentence above renders regardless.
    public nonisolated static func evidenceState(for answer: VerifiedAnswer) -> AnswerSplit.EvidenceState {
        if answer.refused {
            // A receipted abstention IS its evidence — nothing failed.
            return .complete
        }
        if answer.answerState == .unverified {
            return .failed(reason: "The evidence check could not confirm this reading — no source is attached. Verify it against your documents before relying on it.")
        }
        if answer.citations.isEmpty && answer.answerState != .notFound {
            return .failed(reason: "No supporting sources were attached to this answer. The answer text is shown unchanged.")
        }
        if case .none = answer.report, !answer.citations.isEmpty {
            return .partial(reason: "The full confidence details were not produced for this answer.")
        }
        return .complete
    }
}

/// U-1 — the per-persona Unverified policy. When the deterministic sweep
/// cannot confirm a composed reading, the reading either ships badged
/// "Unverified — AI reading; evidence check failed" (researcher-class
/// personas) or is withheld and the ladder falls through (legal-class
/// personas). Until the onboarding persona choice lands (§7.4), the user
/// override IS the control; the default (off = abstain) preserves the
/// sealed behavior byte-for-byte.
public enum UnverifiedAnswerPolicy {
    public nonisolated static let defaultsKey = "kalsmritikosh.answers.showUnverified"
    public nonisolated static var showBadged: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}

//
//  PipelineStageOutcome.swift
//  Kalsmritikosh
//
//  The four things a pipeline-stage check may report, and the reason there are
//  four rather than two.
//
//  A bare count cannot distinguish the cases that matter. "0 facts" is the same
//  number whether the document legitimately has none, the extractor failed, or
//  the probe that was supposed to count them threw. This project's recurring
//  defect — absence rendered as verification — is exactly that collapse, and it
//  has been found in the health audit's probes, the parser coverage table, the
//  language limit, the erase confirmation and the module matrix. Every one of
//  them was a zero that could not say which kind of zero it was.
//
//  So a stage check must commit to one of:
//
//    .present            — it is there, with a count and a human detail
//    .absentExpected     — empty, AND THE REASON IS REQUIRED by the signature.
//                          "expected" without a stated expectation is a zero in
//                          a nicer coat, so the compiler asks for the why.
//    .absentUnexpected   — empty when it should not be. This is the finding.
//    .couldNotCheck      — the check itself failed. NOT a pass, and not a defect
//                          in the pipeline either: a defect in the knowing.
//
//  Shared rather than copied. It began inside GoldenThread; the topic-layer
//  diagnosis needs the identical discipline, and two enums with the same job
//  would drift — one of them would eventually grow a bare "empty" case and the
//  distinction would be lost in half the reports.
//

import Foundation

public enum PipelineStageOutcome: Sendable, Equatable {
    case present(count: Int, detail: String)
    case absentExpected(reason: String)
    case absentUnexpected(reason: String)
    case couldNotCheck(why: String)

    public var symbol: String {
        switch self {
        case .present:          return "✓"
        case .absentExpected:   return "·"
        case .absentUnexpected: return "✗"
        case .couldNotCheck:    return "?"
        }
    }

    public var isDefect: Bool {
        if case .absentUnexpected = self { return true }
        return false
    }

    public var isUnknown: Bool {
        if case .couldNotCheck = self { return true }
        return false
    }

    /// True only for `.present`. Named so a caller cannot read "not a defect"
    /// as "fine" — `.absentExpected` and `.couldNotCheck` are both not-defects
    /// and neither one means the stage produced anything.
    public var isPopulated: Bool {
        if case .present = self { return true }
        return false
    }

    public var line: String {
        switch self {
        case .present(let n, let d):   return "\(n) — \(d)"
        case .absentExpected(let r):   return "none, and that is expected: \(r)"
        case .absentUnexpected(let r): return "NONE — \(r)"
        case .couldNotCheck(let w):    return "could not be checked: \(w)"
        }
    }
}

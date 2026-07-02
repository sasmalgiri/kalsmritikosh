//
//  IngestEstimator.swift
//  Kalsmritikosh
//
//  Rough, honest ingest-time estimates per file type and per system
//  mode. The numbers are approximate and hardware/model dependent — the
//  point is to show the RELATIVE cost of the three architectures and of
//  different file types (a scanned PDF or audio file costs far more than
//  plain email), so a user can predict and choose.
//
//  Cost model:
//    ruleSeconds  = sizeMB × ruleSecPerMB[class]        (parse+chunk+embed+rule-extract, no generative LLM)
//    llmCalls     = sizeMB × chunksPerMB[class] × llmCallsPerChunk[mode]
//    llmSeconds   = llmCalls × effectiveSecPerLLMCall
//    total        = ruleSeconds + llmSeconds
//
//  All constants are `public static` so they can be tuned / shown.
//

import Foundation

public enum FileClass: String, CaseIterable, Identifiable, Sendable {
    case emailText          // .eml / mbox / chat exports — text-dense
    case plainText          // .txt / .md / .csv
    case officeDoc          // .docx / .pptx / .odt
    case spreadsheet        // .xlsx / .ods
    case pdfDigital         // text-layer PDF
    case pdfScanned         // image-only PDF → OCR
    case image              // .png/.jpg → OCR
    case audio              // → speech transcription (ASR)
    case video              // → audio extract + ASR

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .emailText:   return "Email / chat (text)"
        case .plainText:   return "Plain text / CSV / Markdown"
        case .officeDoc:   return "Word / PowerPoint"
        case .spreadsheet: return "Excel / spreadsheet"
        case .pdfDigital:  return "PDF (digital text)"
        case .pdfScanned:  return "PDF (scanned → OCR)"
        case .image:       return "Image → OCR"
        case .audio:       return "Audio → transcription"
        case .video:       return "Video → transcription"
        }
    }

    public var systemImage: String {
        switch self {
        case .emailText:   return "envelope"
        case .plainText:   return "doc.plaintext"
        case .officeDoc:   return "doc.richtext"
        case .spreadsheet: return "tablecells"
        case .pdfDigital:  return "doc.text"
        case .pdfScanned:  return "doc.text.magnifyingglass"
        case .image:       return "photo"
        case .audio:       return "waveform"
        case .video:       return "film"
        }
    }

    /// Seconds of rule-based work (parse + chunk + embed + rule extract)
    /// per MB. OCR / ASR classes dominate this term.
    public var ruleSecondsPerMB: Double {
        switch self {
        case .emailText:   return 4
        case .plainText:   return 3
        case .officeDoc:   return 7
        case .spreadsheet: return 6
        case .pdfDigital:  return 10
        case .pdfScanned:  return 120   // Vision OCR
        case .image:       return 25    // per-image OCR
        case .audio:       return 240   // ASR ~ slower than realtime on-device
        case .video:       return 320
        }
    }

    /// Approximate semantic chunks produced per MB (drives LLM count).
    public var chunksPerMB: Double {
        switch self {
        case .emailText:   return 380
        case .plainText:   return 650
        case .officeDoc:   return 500
        case .spreadsheet: return 300
        case .pdfDigital:  return 450
        case .pdfScanned:  return 300
        case .image:       return 30
        case .audio:       return 120   // per MB of audio ≈ transcript chunks
        case .video:       return 120
        }
    }
}

public struct IngestEstimator: Sendable {
    /// Built-in default effective wall-clock seconds per LLM call
    /// (local model, ~4-wide parallelism). Used until enough real calls
    /// have been observed on this machine.
    public static let defaultEffectiveSecondsPerLLMCall: Double = 3.5

    /// The BASELINE hardware the default numbers assume. Surfaced in the
    /// UI so the per-100 MB figures read honestly as a *reference-config*
    /// estimate — measured on the developer's machine, NOT the user's —
    /// until self-calibration replaces the default with this Mac's measured
    /// throughput. Once `CalibrationStore.isCalibrated`, the estimate is
    /// this Mac's, not the reference.
    public static let referenceMachineDescription =
        "reference machine config — a modern Apple-silicon Mac running a local ~8B model at ~3.5 s per LLM call"

    /// Effective seconds per LLM call — the MEASURED value from
    /// CalibrationStore once ≥ minSamples calls have run on this Mac,
    /// otherwise the built-in default. This is what makes the estimates
    /// self-tune to real hardware after the first ingest.
    public static var effectiveSecondsPerLLMCall: Double {
        CalibrationStore.measuredEffectiveSecondsPerCall ?? defaultEffectiveSecondsPerLLMCall
    }

    /// LLM calls per chunk, by system mode.
    ///   • Full LLM   = an LLM context-prefix on every chunk + a share of
    ///     memory distillation (deepest).
    ///   • Hot/Warm/Cold = one document-card call per file (small per-chunk
    ///     fraction) + deep LLM on the ~hot slice.
    ///   • Ledger     = one document-card call per file, nothing else at
    ///     ingest (query-time LLM is separate).
    /// The per-file card is amortized over a file's chunks, so it lands as a
    /// small per-chunk number rather than zero.
    public static func llmCallsPerChunk(_ mode: SystemMode) -> Double {
        switch mode {
        case .fullLLM:           return 0.40
        case .hotWarmCold:       return 0.06
        case .ledgerEventDriven: return 0.02
        }
    }

    public init() {}

    public struct Estimate: Sendable {
        public let ruleSeconds: Double
        public let llmSeconds: Double
        public let llmCalls: Double
        public var totalSeconds: Double { ruleSeconds + llmSeconds }
    }

    /// Estimate for a single file class at a given size.
    public func estimate(sizeMB: Double, fileClass: FileClass, mode: SystemMode) -> Estimate {
        let rule = sizeMB * fileClass.ruleSecondsPerMB
        let calls = sizeMB * fileClass.chunksPerMB * Self.llmCallsPerChunk(mode)
        let llm = calls * Self.effectiveSecondsPerLLMCall
        return Estimate(ruleSeconds: rule, llmSeconds: llm, llmCalls: calls)
    }

    /// A representative "mixed personal archive" profile (fractions of
    /// total MB by class). Used for the headline "100 MB mixed" number.
    public static let mixedProfile: [(FileClass, Double)] = [
        (.emailText, 0.45),
        (.pdfDigital, 0.20),
        (.officeDoc, 0.12),
        (.plainText, 0.08),
        (.spreadsheet, 0.05),
        (.pdfScanned, 0.05),
        (.image, 0.03),
        (.audio, 0.02)
    ]

    /// Estimate for a mixed archive of `sizeMB` using `mixedProfile`.
    public func estimateMixed(sizeMB: Double, mode: SystemMode) -> Estimate {
        var rule = 0.0, llm = 0.0, calls = 0.0
        for (cls, frac) in Self.mixedProfile {
            let e = estimate(sizeMB: sizeMB * frac, fileClass: cls, mode: mode)
            rule += e.ruleSeconds; llm += e.llmSeconds; calls += e.llmCalls
        }
        return Estimate(ruleSeconds: rule, llmSeconds: llm, llmCalls: calls)
    }

    /// Human phrase for a duration: "~40s", "~6 min", "~2.5 h", "~1.3 days".
    public static func humanDuration(_ seconds: Double) -> String {
        if seconds < 1 { return "instant" }
        if seconds < 90 { return "~\(Int(seconds.rounded()))s" }
        let minutes = seconds / 60
        if minutes < 90 { return "~\(Int(minutes.rounded())) min" }
        let hours = minutes / 60
        if hours < 36 { return String(format: "~%.1f h", hours) }
        return String(format: "~%.1f days", hours / 24)
    }
}

//
//  CalibrationStore.swift
//  Kalsmritikosh
//
//  Persists the ONE machine-dependent number the ingest estimator can't
//  guess: the effective wall-clock seconds per LLM call on THIS Mac +
//  model (throughput, so it already folds in provider parallelism). The
//  LLM counters feed a live measurement here; the estimator reads it
//  once enough calls have been observed, so the "per 100 MB" times tune
//  to reality after the first real ingest instead of staying a guess.
//
//  UserDefaults-backed + nonisolated so any actor can read/write cheaply.
//

import Foundation

public enum CalibrationStore {
    private nonisolated static let kEffSeconds = "kalsmritikosh.calib.effSecPerLLMCall"
    private nonisolated static let kSamples    = "kalsmritikosh.calib.llmSamples"

    /// Minimum observed calls before the measurement is trusted over the
    /// built-in default.
    public nonisolated static let minSamples = 30

    /// Record the current effective throughput (seconds per call, over
    /// the active window). Called by LLMCallCounters as calls accrue.
    public nonisolated static func record(effectiveSecondsPerCall: Double, samples: Int) {
        guard effectiveSecondsPerCall.isFinite, effectiveSecondsPerCall > 0 else { return }
        UserDefaults.standard.set(effectiveSecondsPerCall, forKey: kEffSeconds)
        UserDefaults.standard.set(samples, forKey: kSamples)
    }

    /// Measured effective seconds/call, or nil until enough samples.
    public nonisolated static var measuredEffectiveSecondsPerCall: Double? {
        guard UserDefaults.standard.integer(forKey: kSamples) >= minSamples else { return nil }
        let v = UserDefaults.standard.double(forKey: kEffSeconds)
        return v > 0 ? v : nil
    }

    public nonisolated static var sampleCount: Int {
        UserDefaults.standard.integer(forKey: kSamples)
    }

    /// True when the estimator is using real measured throughput.
    public nonisolated static var isCalibrated: Bool {
        measuredEffectiveSecondsPerCall != nil
    }
}

//
//  IngestionCompletionError.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-008) — typed errors for canonical completion evaluation.
//

import Foundation

public nonisolated enum IngestionCompletionError: Error, Sendable, Equatable {
    /// No readiness aggregate exists for this exact source version.
    case readinessUnavailable(UUID)
    /// The exact source version row does not exist.
    case sourceVersionMissing(UUID)
}

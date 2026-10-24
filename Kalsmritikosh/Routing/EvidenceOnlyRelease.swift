//
//  EvidenceOnlyRelease.swift
//  Kalsmritikosh
//
//  Owner decision 2026-10-24: this release answers from the evidence only — keyword, structured-field
//  and document matching, no generative model (on-device or cloud). Every answer is a value or a
//  passage the documents state, with its citation, or an honest "the documents don't say". AI comes
//  back later as a separate step (cloud, opt-in), by flipping `generativeAIEnabled`.
//
//  In the app this forces PrivacyGate's no-AI switch on and the general-knowledge lane off, whatever
//  was stored before. The test host keeps the stored behaviour so the AI code stays tested and
//  ready for the cloud step (same test-host rule as Purchase and LedgerEncryption).
//

import Foundation

public nonisolated enum EvidenceOnlyRelease {
    /// False = this build ships evidence-only. Flip to true when AI answers return.
    public static let generativeAIEnabled = false

    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// True when the app must not consult any generative model.
    public static var enforced: Bool { !generativeAIEnabled && !isTestHost }
}

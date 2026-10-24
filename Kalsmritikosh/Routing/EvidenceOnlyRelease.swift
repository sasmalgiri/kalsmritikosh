//
//  EvidenceOnlyRelease.swift
//  Kalsmritikosh
//
//  Owner decision 2026-10-24: answers come from the evidence only — keyword, structured-field and
//  document matching, no generative model — unless the person turns "Use AI to write answers" on in
//  Settings. Every evidence-only answer is a value or a passage the documents state, with its
//  citation, or an honest "the documents don't say". With the switch on, the existing AI choices
//  return: Apple's on-device model, or the person's own cloud AI key through Online mode (consent
//  before every send).
//
//  While the switch is off, PrivacyGate's no-AI switch is forced on and the general-knowledge lane
//  off, whatever was stored before. The test host keeps the stored behaviour so the AI code stays
//  tested (same test-host rule as Purchase and LedgerEncryption).
//

import Foundation

public nonisolated enum EvidenceOnlyRelease {
    /// The person's choice. Absent = off (evidence only).
    public static let aiEnabledKey = "kalsmritikosh.answers.aiEnabled"

    public static var aiEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: aiEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: aiEnabledKey) }
    }

    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// True when the app must not consult any generative model.
    public static var enforced: Bool { !aiEnabled && !isTestHost }
}

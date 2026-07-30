//
//  PersonaTerminologyResolver.swift
//  Kalsmritikosh
//
//  PJE-010 Part A — the terminology runtime. Resolves a version-pinned
//  presentation LABEL for a closed terminology token from a run's FROZEN
//  contract snapshot. This is presentation only:
//
//    * it never returns a runtime identifier, enum case name, database key,
//      workflow transition, or step kind;
//    * it never alters canonical identity, evidence status, citation scope,
//      source independence, SensitiveScope, export policy, workflow state,
//      stored provenance, work-product manifests, or any derived hash;
//    * a run always resolves the terminology VERSION frozen in its contract —
//      a later-registered version never silently upgrades an old run.
//

import Foundation

public enum PersonaTerminologyError: Error, Equatable, Sendable {
    case wrongApplication(expected: String, snapshot: String)
    case wrongVersion(expected: Int, snapshot: Int)
    case blankLabel(token: String)
}

public nonisolated struct PersonaTerminologyResolver: Sendable {

    public nonisolated init() {}

    /// Resolve the presentation label for `token` from a frozen terminology
    /// snapshot. A persona-specific, nonblank label wins; otherwise the caller's
    /// canonical fallback is returned. The snapshot must belong to the expected
    /// application, and — when an expected version is supplied — must match it
    /// exactly (version pinning). Never returns blank text or an identifier.
    public nonisolated func label(
        for token: PersonaTerminologyToken,
        in terminology: TerminologyDefinitionSnapshot,
        expectedApplicationID: ApplicationDefinitionID,
        expectedVersion: Int? = nil,
        canonicalFallback: String
    ) throws -> String {
        guard terminology.applicationID == expectedApplicationID.rawValue else {
            throw PersonaTerminologyError.wrongApplication(
                expected: expectedApplicationID.rawValue, snapshot: terminology.applicationID)
        }
        if let expectedVersion, terminology.version != expectedVersion {
            throw PersonaTerminologyError.wrongVersion(
                expected: expectedVersion, snapshot: terminology.version)
        }

        // A persona-specific label is used only when present AND nonblank; a
        // registered blank label never wins — it falls through to the canonical.
        if let entry = terminology.labels.first(where: { $0.token == token.rawValue }),
           !entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entry.label
        }

        let fallback = canonicalFallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else {
            throw PersonaTerminologyError.blankLabel(token: token.rawValue)
        }
        return fallback
    }

    /// Resolve a label directly from a reopened run's FROZEN contract, pinning to
    /// the contract's application and terminology version.
    public nonisolated func label(
        for token: PersonaTerminologyToken,
        in contract: WorkflowRunContractSnapshot,
        canonicalFallback: String
    ) throws -> String {
        try label(
            for: token,
            in: contract.terminology,
            expectedApplicationID: contract.applicationKey.id,
            expectedVersion: contract.terminology.version,
            canonicalFallback: canonicalFallback)
    }
}

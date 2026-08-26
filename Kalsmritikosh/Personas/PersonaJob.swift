//
//  PersonaJob.swift
//  Kalsmritikosh
//
//  #142 — the shared, launchable persona-job surface. A PersonaJob is a discoverable, enumerable descriptor
//  for ONE real capability a persona offers. It is persona-neutral: any persona package declares its jobs as
//  a list of these, and the ONE live consumer (PersonaJobService) routes a selected job into that persona's
//  REAL implementation. A PersonaJob is a POINTER to a real service entry point — never a second engine and
//  never a stub. The `kind` names the concrete capability the router dispatches to.
//

import Foundation

// PersonaJobKind moved to PersonaJobKind.swift (Phase A) — the standalone
// verifier is generated from that file; this one keeps the app-side job
// descriptor types the verifier must not carry.

/// A discoverable, launchable job for one persona. `persona` is the owning application's id (rawValue);
/// `id` is a stable job identifier unique within the persona; `kind` is the concrete capability the ONE
/// router dispatches into the persona's real implementation.
public nonisolated struct PersonaJob: Sendable, Identifiable, Hashable {
    public let persona: String
    public let id: String
    public let title: String
    public let detail: String
    public let kind: PersonaJobKind

    public nonisolated init(persona: String, id: String, title: String, detail: String, kind: PersonaJobKind) {
        self.persona = persona; self.id = id; self.title = title; self.detail = detail; self.kind = kind
    }
}

/// The launch envelope handed to PersonaJobService.launch. It carries the union of inputs the real services
/// may need; each job uses only what its real entry point requires and fails closed (missingContext) when a
/// required input is absent. This is a routing envelope, not a second parameter model.
public nonisolated struct PersonaJobLaunchContext: Sendable {
    public let caseID: UUID?
    public let workspaceID: UUID?
    public let title: String?
    public let access: SensitiveAccessContext?
    public let actor: String
    public let question: String?
    public let at: Date

    public nonisolated init(caseID: UUID? = nil, workspaceID: UUID? = nil, title: String? = nil,
                            access: SensitiveAccessContext? = nil, actor: String, question: String? = nil, at: Date) {
        self.caseID = caseID; self.workspaceID = workspaceID; self.title = title
        self.access = access; self.actor = actor; self.question = question; self.at = at
    }
}

/// The outcome of routing a selected job into its real implementation. `summary` is an audit-facing
/// description of the REAL action performed; `producedID` is the durable id the real service created or
/// resolved (e.g. a new case id, a findings run id), when one applies.
public nonisolated struct PersonaJobLaunch: Sendable {
    public let job: PersonaJob
    public let summary: String
    public let producedID: UUID?

    public nonisolated init(job: PersonaJob, summary: String, producedID: UUID? = nil) {
        self.job = job; self.summary = summary; self.producedID = producedID
    }
}

public nonisolated enum PersonaJobError: Error, Sendable, Equatable {
    /// The persona is not present in the production catalog (not discoverable).
    case unknownPersona(String)
    /// No job with this id/kind is registered for the persona.
    case unknownJob(String)
    /// The real service backing this job is not wired (fail-closed; never a fabricated result).
    case serviceUnavailable(PersonaJobKind)
    /// A required launch input was absent for this job.
    case missingContext(String)
}

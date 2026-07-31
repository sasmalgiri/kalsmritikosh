//
//  ProfessionalMethodValidationTypes.swift
//  Kalsmritikosh
//
//  PM-004 — the deterministic professional-method validator contract. Validators
//  are pure functions over a single-snapshot aggregate + its exact definition;
//  they receive NO database and NO repository, and return proposal-layer issues
//  only. The engine supplies all trusted metadata (validator identity, batch id,
//  evaluated revision) — a validator never asserts them.
//

import Foundation

/// The read-only context a validator evaluates.
public nonisolated struct ProfessionalMethodValidationContext: Sendable {
    public let definition: ProfessionalMethodDefinition
    public let aggregate: MethodRunAggregate
    public let runID: UUID
    public let workspaceID: UUID
    public let runRevision: Int
    public let contentRevision: Int

    public nonisolated init(
        definition: ProfessionalMethodDefinition, aggregate: MethodRunAggregate,
        runID: UUID, workspaceID: UUID, runRevision: Int, contentRevision: Int
    ) {
        self.definition = definition
        self.aggregate = aggregate
        self.runID = runID
        self.workspaceID = workspaceID
        self.runRevision = runRevision
        self.contentRevision = contentRevision
    }
}

/// A proposal-layer issue a validator raises. It carries no validator identity,
/// batch identity, evaluated revision, canonical text, or Claim update.
public nonisolated struct ProfessionalMethodValidationIssue: Sendable, Equatable {
    public let severity: MethodValidationSeverity
    public let code: String
    public let message: String
    public let subjectKind: MethodValidationSubjectKind
    public let subjectID: UUID?

    public nonisolated init(
        severity: MethodValidationSeverity, code: String, message: String,
        subjectKind: MethodValidationSubjectKind, subjectID: UUID? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.subjectKind = subjectKind
        self.subjectID = subjectID
    }
}

/// A deterministic validator. Pure over the context; no I/O.
public protocol ProfessionalMethodValidating: Sendable {
    var validatorID: String { get }
    var validatorVersion: String { get }
    func validate(context: ProfessionalMethodValidationContext) async throws -> [ProfessionalMethodValidationIssue]
}

public nonisolated enum ProfessionalMethodValidatorRegistryError: Error, Equatable, Sendable {
    case blankID
    case notTrimStableID(String)
    case blankVersion(String)
    case duplicateID(String)
}

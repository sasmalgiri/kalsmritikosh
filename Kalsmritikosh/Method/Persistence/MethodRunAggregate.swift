//
//  MethodRunAggregate.swift
//  Kalsmritikosh
//
//  PM-002 — the reconstructed MethodRun aggregate: the run plus its ordered
//  working graph, evidence links, assumptions, findings and append-only review
//  and validation ledgers. Read-only value snapshot; mutation goes through
//  MethodRunRepository.
//

import Foundation

public nonisolated struct MethodRunAggregate: Sendable, Equatable {
    public let run: MethodRun
    public let nodes: [MethodNode]
    public let edges: [MethodEdge]
    public let evidenceLinks: [MethodEvidenceLink]
    public let assumptions: [MethodAssumption]
    public let findings: [MethodFinding]
    public let reviews: [MethodReview]
    public let validationResults: [MethodValidationResult]
    public let lifecycleEvents: [MethodLifecycleEvent]

    public nonisolated init(
        run: MethodRun,
        nodes: [MethodNode] = [],
        edges: [MethodEdge] = [],
        evidenceLinks: [MethodEvidenceLink] = [],
        assumptions: [MethodAssumption] = [],
        findings: [MethodFinding] = [],
        reviews: [MethodReview] = [],
        validationResults: [MethodValidationResult] = [],
        lifecycleEvents: [MethodLifecycleEvent] = []
    ) {
        self.run = run
        self.nodes = nodes
        self.edges = edges
        self.evidenceLinks = evidenceLinks
        self.assumptions = assumptions
        self.findings = findings
        self.reviews = reviews
        self.validationResults = validationResults
        self.lifecycleEvents = lifecycleEvents
    }
}

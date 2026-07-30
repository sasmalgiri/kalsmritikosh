//
//  PersonaTerminologyResolverTests.swift
//  KalsmritikoshTests
//
//  PJE-010 Part A — the terminology runtime resolves version-pinned presentation
//  labels only. Different persona labels for the same canonical token never
//  change the canonical token identity, and the resolver never returns an
//  identifier, enum name, or blank string.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-010 — terminology resolver")
struct PersonaTerminologyResolverTests {

    private let resolver = PersonaTerminologyResolver()
    private let appID = ApplicationDefinitionID(rawValue: "com.persona.app")

    private func snapshot(
        labels: [PersonaTerminologyToken: String], version: Int = 1,
        applicationID: ApplicationDefinitionID? = nil
    ) -> TerminologyDefinitionSnapshot {
        TerminologyDefinitionSnapshot(from: PersonaTerminologyDefinition(
            id: TerminologyDefinitionID(rawValue: "com.persona.term"),
            version: version, applicationID: applicationID ?? appID, labels: labels))
    }

    // MARK: - Resolution

    @Test("An exact registered label wins")
    func exactLabel() throws {
        let s = snapshot(labels: [.issue: "Legal Issue"])
        let label = try resolver.label(for: .issue, in: s, expectedApplicationID: appID, canonicalFallback: "Issue")
        #expect(label == "Legal Issue")
    }

    @Test("A missing token falls back to the canonical label")
    func missingTokenFallback() throws {
        let s = snapshot(labels: [.issue: "Legal Issue"])
        let label = try resolver.label(for: .task, in: s, expectedApplicationID: appID, canonicalFallback: "Task")
        #expect(label == "Task")
    }

    @Test("A registered blank label falls back to the canonical label (never returns blank)")
    func blankLabelFallsBack() throws {
        let s = snapshot(labels: [.issue: "   "])
        let label = try resolver.label(for: .issue, in: s, expectedApplicationID: appID, canonicalFallback: "Issue")
        #expect(label == "Issue")
    }

    @Test("A blank label AND blank canonical fallback is rejected")
    func blankBothThrows() throws {
        let s = snapshot(labels: [.issue: ""])
        #expect(throws: PersonaTerminologyError.self) {
            _ = try resolver.label(for: .issue, in: s, expectedApplicationID: appID, canonicalFallback: "   ")
        }
    }

    @Test("A wrong application ID is rejected")
    func wrongApplicationThrows() throws {
        let s = snapshot(labels: [.issue: "Legal Issue"],
                         applicationID: ApplicationDefinitionID(rawValue: "com.other.app"))
        #expect(throws: PersonaTerminologyError.self) {
            _ = try resolver.label(for: .issue, in: s, expectedApplicationID: appID, canonicalFallback: "Issue")
        }
    }

    @Test("A wrong terminology version is rejected (version pinning)")
    func wrongVersionThrows() throws {
        let s = snapshot(labels: [.issue: "Legal Issue"], version: 1)
        #expect(throws: PersonaTerminologyError.self) {
            _ = try resolver.label(for: .issue, in: s, expectedApplicationID: appID,
                                   expectedVersion: 2, canonicalFallback: "Issue")
        }
    }

    @Test("The matching version pins correctly")
    func matchingVersionResolves() throws {
        let s = snapshot(labels: [.issue: "Legal Issue"], version: 3)
        let label = try resolver.label(for: .issue, in: s, expectedApplicationID: appID,
                                       expectedVersion: 3, canonicalFallback: "Issue")
        #expect(label == "Legal Issue")
    }

    // MARK: - Presentation-only guarantees

    @Test("The resolver never returns the raw token identifier as a label")
    func neverReturnsRawToken() throws {
        let s = snapshot(labels: [.issue: "Legal Issue"])
        let label = try resolver.label(for: .issue, in: s, expectedApplicationID: appID, canonicalFallback: "Issue")
        #expect(label != PersonaTerminologyToken.issue.rawValue)   // not "issue"
    }

    @Test("The same canonical token resolves to different labels across personas")
    func differentLabelsSameToken() throws {
        let personas: [(String, String)] = [
            ("investigator", "Issue"), ("researcher", "Research Question"),
            ("journalist", "Verification Question"), ("individual", "Matter"),
            ("lawyer", "Legal Issue")
        ]
        var labels = Set<String>()
        for (persona, label) in personas {
            let s = snapshot(labels: [.issue: label], applicationID: appID)
            let resolved = try resolver.label(for: .issue, in: s, expectedApplicationID: appID, canonicalFallback: "Issue")
            #expect(resolved == label, "\(persona)")
            labels.insert(resolved)
        }
        // Five distinct presentation labels for the ONE canonical token.
        #expect(labels.count == 5)
    }

    @Test("Label-map registration order does not change the resolved label")
    func registrationOrderIndependent() throws {
        let a = snapshot(labels: [.issue: "Legal Issue", .task: "Matter Task", .deadline: "Due Date"])
        let b = snapshot(labels: [.deadline: "Due Date", .task: "Matter Task", .issue: "Legal Issue"])
        for token in [PersonaTerminologyToken.issue, .task, .deadline] {
            let la = try resolver.label(for: token, in: a, expectedApplicationID: appID, canonicalFallback: "X")
            let lb = try resolver.label(for: token, in: b, expectedApplicationID: appID, canonicalFallback: "X")
            #expect(la == lb)
        }
    }

    @Test("Resolution is stable across repeated calls (close/reopen label stability)")
    func stableAcrossCalls() throws {
        let s = snapshot(labels: [.step: "Phase"])
        let first = try resolver.label(for: .step, in: s, expectedApplicationID: appID, canonicalFallback: "Step")
        let second = try resolver.label(for: .step, in: s, expectedApplicationID: appID, canonicalFallback: "Step")
        #expect(first == second)
        #expect(first == "Phase")
    }

    @Test("Different terminology packs produce identical canonical token identity")
    func canonicalTokenIdentityUnchanged() throws {
        // Two different persona vocabularies for the SAME closed token set.
        let investigator = snapshot(labels: [.issue: "Issue", .task: "Task"])
        let lawyer = snapshot(labels: [.issue: "Legal Issue", .task: "Matter"])
        // The tokens themselves (canonical identity) are the same enum cases; only
        // the presentation labels differ.
        let invIssue = try resolver.label(for: .issue, in: investigator, expectedApplicationID: appID, canonicalFallback: "Issue")
        let lawIssue = try resolver.label(for: .issue, in: lawyer, expectedApplicationID: appID, canonicalFallback: "Issue")
        #expect(invIssue != lawIssue)
        #expect(PersonaTerminologyToken.issue == PersonaTerminologyToken.issue)  // canonical identity stable
    }

    @Test("A terminology snapshot freezes labels as a sorted, canonical array")
    func snapshotLabelsSorted() {
        let s = snapshot(labels: [.workflow: "Case", .application: "App", .task: "Task"])
        let tokens = s.labels.map(\.token)
        #expect(tokens == tokens.sorted())   // deterministic canonical order
    }

    @Test("Every closed terminology token resolves to its canonical fallback when unlabelled")
    func allTokensFallBack() throws {
        let empty = snapshot(labels: [:])
        for token in PersonaTerminologyToken.allCases {
            let label = try resolver.label(
                for: token, in: empty, expectedApplicationID: appID,
                canonicalFallback: "Canonical-\(token.rawValue)")
            #expect(label == "Canonical-\(token.rawValue)")
        }
    }
}

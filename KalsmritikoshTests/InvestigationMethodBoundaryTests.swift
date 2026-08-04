//
//  InvestigationMethodBoundaryTests.swift
//  KalsmritikoshTests
//
//  INV-01-C2 architecture guards (§19). Prove the case-scoped Methods entry ORCHESTRATES the shared
//  method engine rather than forking it: no Investigator method registry / lifecycle / MethodRun type /
//  second evidence-selection authority; it composes the shared ProfessionalMethodRegistry +
//  MethodRunRepository + evidence gate; it reuses the ONE CaseRetrievalScopeResolver for case scope; and
//  the case authorization + shared gate run BEFORE the run is created (so unauthorized evidence can never
//  be attached). Source scanning + value checks.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-C2 — case-scoped methods architecture guards")
struct InvestigationMethodBoundaryTests {

    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private func read(_ rel: String) throws -> String { try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8) }
    private func codeOnly(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("*") || t.hasPrefix("/*") { return "" }
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }
    private let rel = "Kalsmritikosh/Personas/Investigator/InvestigationMethodService.swift"

    @Test("The Methods entry is present") func present() { #expect((try? read(rel)) != nil) }

    @Test("No model names in the Methods entry")
    func noModelNames() throws {
        let lower = codeOnly(try read(rel)).lowercased()
        for m in ["qwen", "gemma", "deepseek", "mistral", "nomic", "llama", "gpt"] { #expect(!lower.contains(m)) }
    }

    @Test("No forked method engine / registry / run type / second evidence-selection authority")
    func noForks() throws {
        let s = codeOnly(try read(rel))
        for banned in ["InvestigatorMethodEngine", "InvestigatorMethodRun", "InvestigatorMethodRegistry",
                       "InvestigatorEvidenceSelector", "actor MethodRunRepository", "class MethodRunRepository",
                       "struct ProfessionalMethodRegistry", "ProfessionalMethodLifecycleEngine"] {
            #expect(!s.contains(banned), "Methods entry forks: \(banned)")
        }
        #expect(!s.contains("InvestigationMethodService: Retriever"))
    }

    @Test("Composes the shared method engine + reuses the ONE case-scope resolver")
    func composesShared() throws {
        let s = codeOnly(try read(rel))
        #expect(s.contains("ProfessionalMethodRegistry"))
        #expect(s.contains("MethodRunRepository"))
        #expect(s.contains("WorkflowEvidenceReferenceGating"))
        #expect(s.contains("CaseRetrievalScopeResolver"))       // the one shared case scope resolver (B2/C1)
        #expect(s.contains("registry.latest("))                 // recommendations resolve to shared definitions
    }

    @Test("Recommendations reference SHARED catalog method ids, not persona-specific definitions")
    func recommendationsShared() {
        for id in InvestigationMethodService.inv01RecommendedMethodIDs {
            #expect(id.hasPrefix("com.kalsmritikosh.method."))
            #expect(!id.contains("investigator"))
        }
    }

    @Test("Both the case authorization and the shared gate run BEFORE the run is created (no attach bypass)")
    func authorizeBeforeCreate() throws {
        let s = codeOnly(try read(rel))
        guard let authIdx = s.range(of: "authorizeAll(")?.lowerBound,
              let gateIdx = s.range(of: "gate.verdict(")?.lowerBound,
              let createIdx = s.range(of: "createRun(")?.lowerBound else {
            Issue.record("expected authorizeAll / gate.verdict / createRun in the service"); return
        }
        #expect(authIdx < createIdx, "case authorization must precede run creation")
        #expect(gateIdx < createIdx, "the shared gate must precede run creation")
    }

    @Test("The authorization decision + error vocabulary exist and are fail-closed by construction")
    func decisionVocabulary() {
        // Unresolvable is a distinct, typed outcome — the fail-closed default for non-source-anchored kinds.
        #expect(InvestigationEvidenceAuthorization.unresolvable != .unauthorized)
        let id = UUID()
        #expect(InvestigationMethodError.unauthorizedEvidence(kind: "sourceVersion", id: id)
                == .unauthorizedEvidence(kind: "sourceVersion", id: id))
        #expect(InvestigationMethodError.caseNotFound(id) != .unknownMethod("x"))
    }
}

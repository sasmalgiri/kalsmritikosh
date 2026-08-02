//
//  PM005MethodCatalogBoundaryTests.swift
//  KalsmritikoshTests
//
//  Stage B / PM-005 architecture guards. The concrete methods COMPOSE the generic PM-001..004
//  foundation and never fork it: the catalog declares no second run store / lifecycle / registry /
//  validation authority; brainstorming produces only proposals (no finding kinds); 5W1H's slot
//  confirmation is a human review; the catalog rejects a method whose validator is missing. Source
//  scanning + value assertions — no data.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-005 — method catalog architecture guards")
struct PM005MethodCatalogBoundaryTests {

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
    private let catalogRels = [
        "Kalsmritikosh/Method/Catalog/ProfessionalMethodCatalog.swift",
        "Kalsmritikosh/Method/Catalog/BrainstormingMethod.swift",
        "Kalsmritikosh/Method/Catalog/FiveW1HMethod.swift"]
    private func catalogFiles() -> [(String, String)] { catalogRels.compactMap { rel in (try? read(rel)).map { (rel, $0) } } }

    @Test("The catalog subsystem is present and assembles the standard methods")
    func presentAndAssembles() async throws {
        #expect(catalogFiles().count == 3)
        let catalog = try await ProfessionalMethodCatalog.standard()
        let count = await ProfessionalMethodCatalog.standardMethods.count
        #expect(catalog.methods.all.count == count)
    }

    @Test("The catalog declares no second run store / lifecycle / registry / validator authority")
    func noFoundationFork() {
        let banned = ["actor MethodRunRepository", "struct ProfessionalMethodLifecycleEngine",
                      "struct ProfessionalMethodRegistry ", "struct ProfessionalMethodValidatorRegistry ",
                      "struct MethodRun ", "actor MethodRun"]
        for (name, text) in catalogFiles() {
            let code = codeOnly(text)
            for t in banned { #expect(!code.contains(t), "\(name) redeclares \(t)") }
        }
    }

    @Test("No model names anywhere in the method catalog")
    func noModelNames() {
        let models = ["qwen", "gemma", "deepseek", "llama", "mistral", "nomic", "gpt"]
        for (name, text) in catalogFiles() {
            let lower = text.lowercased()
            for m in models { #expect(!lower.contains(m), "\(name) names model \(m)") }
        }
    }

    @Test("Brainstorming produces only proposals — its output contract allows no findings")
    func brainstormingProducesNoFindings() {
        let def = BrainstormingMethod().definition
        #expect(def.outputContract.allowedFindingKinds.isEmpty)
        #expect(def.requiredInputRoles.contains(BrainstormingMethod.caseContextRole))   // an anchored proposal space
    }

    @Test("5W1H confirms each answered slot through a required HUMAN review")
    func fiveW1HHumanReview() {
        let def = FiveW1HMethod().definition
        let review = def.requiredReviews.first { $0.reviewKey == FiveW1HMethod.confirmReviewKey }
        #expect(review != nil)
        #expect(review?.mustBeHuman == true)
        #expect(def.outputContract.allowedFindingKinds.isEmpty)                          // slot values, not facts
    }

    @Test("The catalog rejects a method whose declared validator is not supplied")
    func rejectsMissingValidator() async {
        struct BrokenMethod: ConcreteProfessionalMethod {
            var definition: ProfessionalMethodDefinition {
                ProfessionalMethodDefinition(
                    id: ProfessionalMethodDefinitionID(rawValue: "com.kalsmritikosh.method.broken"),
                    version: 1, label: "Broken", category: .analysis,
                    requiredInputRoles: [], allowedNodeKinds: [MethodNodeKind(rawValue: "x")],
                    allowedEdgeKinds: [], requiredReviews: [],
                    validationIdentifiers: ["method.missing.v1"],   // no validator supplies this
                    outputContract: MethodOutputContract(allowedFindingKinds: []))
            }
            var validators: [any ProfessionalMethodValidating] { [] }
        }
        await #expect(throws: ProfessionalMethodCatalogError.self) {
            _ = try await ProfessionalMethodCatalog.assemble([BrokenMethod()])
        }
    }
}

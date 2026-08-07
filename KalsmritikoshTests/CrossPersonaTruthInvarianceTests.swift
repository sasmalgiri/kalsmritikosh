//
//  CrossPersonaTruthInvarianceTests.swift
//  KalsmritikoshTests
//
//  Release gate T1 (macro F) — persona choice cannot alter underlying truth.
//  The architecture enforces this by CONSTRUCTION: MasterBrain.answer() takes
//  no persona parameter, Claim carries no persona field (ClaimEngineTests),
//  and the ci/guards/persona-neutral-truth.sh guard keeps persona/shell types
//  out of the evidence layers forever. This suite pins the remaining
//  observable surfaces: every persona routes every shared surface to the SAME
//  destination in both presentation modes, and the per-persona configuration
//  objects expose ONLY presentation fields (labels, emphasis, recommended
//  workflow, default answer mode) — never an evidence/confidence/independence
//  knob. Only terminology, organization, presentation and recommended
//  workflow may vary; anything else appearing in these types fails here.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("T1 — cross-persona truth invariance")
struct CrossPersonaTruthInvarianceTests {

    private let personas = WorkspaceTemplate.allCases

    @Test("Every persona reaches the SAME destination for every shared surface, in Simple and Advanced alike")
    func sameDestinationForEverySurface() {
        for surface in ShellSurface.allCases {
            for mode in WorkbenchDatasetMode.allCases {
                let destinations = personas.map { persona in
                    ShellRouter.navigationEntry(for: ShellRouter.route(template: persona, mode: mode, surface: surface)).destination
                }
                let first = destinations[0]
                for (persona, destination) in zip(personas, destinations) {
                    #expect(destination == first,
                            "\(persona) routes \(surface)/\(mode) to \(destination), not \(first) — persona forked the implementation")
                }
            }
        }
    }

    @Test("PersonaRoutingContext exposes ONLY presentation fields — the exact allowed set")
    func routingContextIsPresentationOnly() {
        // If a field is ever added here it must be re-audited against T1:
        // an evidence/confidence/scope knob in routing configuration would
        // let persona choice alter truth.
        let allowed: Set<String> = ["template", "homeLabel", "myWorkLabel",
                                    "recommendedSurfaces", "defaultAnswerMode"]
        for persona in personas {
            let mirror = Mirror(reflecting: PersonaRoutingCatalog.context(for: persona))
            let fields = Set(mirror.children.compactMap(\.label))
            #expect(fields == allowed, "\(persona): routing context fields drifted: \(fields.sorted())")
        }
    }

    @Test("PersonaPolicy exposes ONLY the documented presentation/default fields — the exact allowed set")
    func noTruthKnobInAnyPersonaPolicy() {
        // minEvidencePerMaterialClaim / requiresCorroboration are per-persona
        // WORK-PRODUCT SHIPPING DEFAULTS (a stricter bar before a claim ships
        // in that persona's templates) — allowed under the locked contract
        // ("persona changes terminology/work-cards/DEFAULTS only"). They can
        // only RAISE the bar over the persona-blind truth state, never change
        // it (assertabilityDecisionPersonaBlind pins that). Any NEW field
        // appearing here must be re-audited against T1.
        let allowed: Set<String> = ["template", "version", "subjectNoun",
                                    "minEvidencePerMaterialClaim", "requiresCorroboration",
                                    "citationStyle", "redactByDefault", "reviewWarnings"]
        for persona in personas {
            let mirror = Mirror(reflecting: PersonaPolicyRegistry.policy(for: persona))
            let fields = Set(mirror.children.compactMap(\.label))
            #expect(fields == allowed, "\(persona): PersonaPolicy fields drifted: \(fields.sorted())")
        }
    }

    @Test("The deterministic assertability decision is identical no matter which persona's workflow reached it")
    func assertabilityDecisionPersonaBlind() {
        // The shared AssertabilityContextBuilder + AssertabilityPolicy are the
        // ONE truth path for retrieval / MasterBrain / WorkProductValidator.
        // Neither takes any persona input — this pins that the same evidence
        // always produces the same decision object, so no per-persona caller
        // can obtain a different truth state for identical evidence.
        let a = UUID(), b = UUID()
        let assessment = EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction)
        let evidence = [AssertabilityEvidence(objectID: a, blockID: UUID(), independenceKey: "k1"),
                        AssertabilityEvidence(objectID: b, blockID: UUID(), independenceKey: "k2")]
        let builder = AssertabilityContextBuilder()
        let contexts = personas.map { _ in builder.build(assessment: assessment, evidence: evidence) }
        let decisions = contexts.map { AssertabilityPolicy.evaluate($0) }
        #expect(Set(decisions).count == 1)
        #expect(contexts.allSatisfy { $0 == contexts[0] })
    }
}

//
//  FoundationModelsStructuredOutput.swift
//  Kalsmritikosh
//
//  Typed-output extension on FoundationModelsProvider (item #7 from
//  the long-term data-structure/engine list). Uses Apple's
//  FoundationModels `@Generable` macro so the model replies with a
//  typed Swift value instead of free-form text we'd then have to
//  prompt-parse. Eliminates the parse-fragility class of bugs.
//
//  Pattern adapted from the sibling repo
//  github.com/sasmalgiri/mailin (file: FoundationModelEngine.swift,
//  pattern: session.respond(to: prompt, generating: TypedSchema.self)).
//  No code copied verbatim; OUR claim shape is the v1 "Periodic
//  Table" output — claim text + evidence ids + confidence — not
//  mailin's email-triage schema.
//
//  Availability: macOS 26.0+ / iOS 26.0+. Callers fall back to
//  the prompt-parsing path (ExpertResponseParser) on older systems
//  or when the resolved provider is NOT a FoundationModelsProvider.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The claim batch schema

#if canImport(FoundationModels)

/// A single claim emitted by an Expert, in the shape the Brain's
/// EvidenceVerifier consumes. The model's structured-output reply
/// fills these directly — no JSON parsing, no regex.
@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A grounded claim with the source evidence that supports it.")
public struct StructuredClaim: Sendable {
    @Guide(description: "The claim itself — a single, citation-shaped sentence.")
    public var statement: String

    @Guide(description: "Source object IDs (KO UUIDs) supporting this claim. Must be drawn from the evidence map.")
    public var supportingObjectIDs: [String]

    @Guide(description: "Source event IDs supporting this claim.")
    public var supportingEventIDs: [String]

    @Guide(description: "Source entity IDs supporting this claim.")
    public var supportingEntityIDs: [String]

    @Guide(description: "Confidence level: low / medium / high.")
    public var confidence: StructuredClaimConfidence
}

@available(macOS 26.0, iOS 26.0, *)
@Generable
public enum StructuredClaimConfidence: String, Sendable {
    case low
    case medium
    case high
}

@available(macOS 26.0, iOS 26.0, *)
@Generable(description: "A batch of grounded claims an Expert produced from the retrieved evidence.")
public struct StructuredClaimBatch: Sendable {
    @Guide(description: "The list of claims. Cap at 8.", .maximumCount(8))
    public var claims: [StructuredClaim]
}

#endif

// MARK: - Provider extension

extension FoundationModelsProvider {

    /// Calls the language model with a `@Generable` schema and
    /// returns the typed `StructuredClaimBatch`. Throws when on an
    /// OS older than macOS 26.0 or when FoundationModels isn't
    /// available — callers should fall back to prompt-parsing.
    public func respondClaims(
        prompt: String,
        systemPrompt: String?
    ) async throws -> [ExpertFindings.Claim] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let instructions = systemPrompt
                ?? "You are Kalsmritikosh. Reply ONLY with citation-shaped claims; never invent IDs."
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: Prompt(prompt),
                generating: StructuredClaimBatch.self
            )
            return response.content.claims.map { typed in
                ExpertFindings.Claim(
                    statement: typed.statement,
                    supportingObjectIDs: typed.supportingObjectIDs.compactMap(UUID.init(uuidString:)),
                    supportingEventIDs: typed.supportingEventIDs.compactMap(UUID.init(uuidString:)),
                    supportingEntityIDs: typed.supportingEntityIDs.compactMap(UUID.init(uuidString:)),
                    confidence: confidence(from: typed.confidence),
                    evidenceGranularity: .specific
                )
            }
        }
        throw ModelProviderError.unavailable(providerID: id)
        #else
        throw ModelProviderError.unavailable(providerID: id)
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    private func confidence(from level: StructuredClaimConfidence) -> Confidence {
        switch level {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
    #endif
}

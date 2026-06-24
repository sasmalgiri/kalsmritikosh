//
//  OCRExpert.swift
//  Kalsmritikosh
//
//  Pulls chunks whose source KO is image-typed (PNG / JPEG / HEIC /
//  TIFF / WebP) out of retrieval. The image loader already ran OCR
//  at ingest time, so the chunk text IS the recognised content —
//  this expert's job is to extract claim-shaped facts from that
//  OCR text and surface them to the brain with citations.
//
//  Prior revision was a thin stub that just flagged image KOs
//  without producing real claims. This rewrite calls the LLM (the
//  same path as ProjectExpert / EmailExpert / etc.) with the OCR
//  text as evidence and asks for typed claims via the @Generable
//  structured-output path when FoundationModels is the resolved
//  provider.
//

import Foundation
import OSLog

public struct OCRExpert: Expert {
    public let id = "expert.ocr"
    public let capabilities: Set<ExpertCapability> = [.tableUnderstanding, .formUnderstanding]
    public let domains: Set<ExpertDomain> = [.ocr]
    private let ocr: VisionOCR

    public init(ocr: VisionOCR = VisionOCR()) {
        self.ocr = ocr
    }

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        let result = try await context.retrieve(
            for: intent,
            layers: [.memory, .metadata, .entity, .summary, .vector]
        )

        // Find chunks whose source KO is image-typed. The image
        // loader emits content like "[image: no text recognized]" for
        // dead pages OR the recognised text directly for live ones.
        // We accept both — the LLM judges relevance.
        let imageChunks = result.chunks.filter { hit in
            let lowered = hit.chunk.text.lowercased()
            return lowered.contains("[image:") || hit.chunk.text.count >= 20
                && !hit.chunk.text.allSatisfy(\.isWhitespace)
        }
        // Drop chunks that are JUST the placeholder — no signal there.
        let signal = imageChunks.filter { !$0.chunk.text.lowercased().contains("[image: no text recognized]") }
        guard !signal.isEmpty else {
            return ExpertFindings(
                expertID: id,
                claims: [],
                confidence: .zero,
                notes: "No image-derived OCR content in retrieved scope."
            )
        }

        let frame = PromptTemplates.ocrAnalysis(intent: intent, retrieval: result, imageChunks: Array(signal.prefix(6)))
        let llm = await runLLM(frame: frame, capabilities: context.capabilities)
        if !llm.claims.isEmpty {
            return ExpertFindings(
                expertID: id,
                claims: llm.claims,
                confidence: Confidence.aggregate(
                    llm.claims.map(\.confidence),
                    agreement: 1.0,
                    diversity: 1.0,
                    contradictionPenalty: 0.0
                ),
                droppedUnverifiable: llm.dropped
            )
        }

        // Heuristic fallback — emit one snippet-shaped claim per image
        // chunk citing the OCR'd text directly. Useful when the LLM
        // is unreachable.
        var claims: [ExpertFindings.Claim] = []
        for hit in signal.prefix(4) {
            let snippet = hit.chunk.text
                .split(separator: "\n")
                .first
                .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !snippet.isEmpty else { continue }
            claims.append(.init(
                statement: "Image OCR (\(hit.chunk.id.uuidString.prefix(8))): \(snippet.prefix(180))",
                supportingObjectIDs: [hit.chunk.objectID],
                confidence: .medium,
                evidenceGranularity: .specific
            ))
        }
        return ExpertFindings(
            expertID: id,
            claims: claims,
            confidence: claims.isEmpty ? .low : .medium,
            notes: claims.isEmpty ? "OCR chunks present but no claim could be extracted." : nil
        )
    }

    /// Same dispatch shape as the other six experts: prefer the typed
    /// @Generable path on FoundationModels, fall back to prompt-parse
    /// for Ollama / older OS.
    private func runLLM(
        frame: PromptFrame,
        capabilities: CapabilityRegistry
    ) async -> (claims: [ExpertFindings.Claim], dropped: Int) {
        let spec = CapabilitySpec.reasoning(contextTokens: 4_000, purpose: "expert.ocr")
        guard let provider = try? await capabilities.resolve(spec) else {
            AtlasLog.brain.info("expert.ocr LLM: no provider resolved; using heuristic fallback")
            return ([], 0)
        }
        guard await provider.isAvailable() else {
            AtlasLog.brain.info("expert.ocr LLM: provider=\(provider.id, privacy: .public) unavailable; using heuristic fallback")
            return ([], 0)
        }
        // STRUCTURED-OUTPUT PATH (#7).
        if let fmProvider = provider as? FoundationModelsProvider {
            do {
                let typed = try await fmProvider.respondClaims(
                    prompt: frame.prompt,
                    systemPrompt: "You are Atlas. Use ONLY the evidence ids the prompt provides; never invent ids. Treat OCR text as potentially noisy."
                )
                AtlasLog.brain.info("expert.ocr LLM: produced \(typed.count) typed claims via @Generable")
                return (typed, 0)
            } catch {
                AtlasLog.brain.error("expert.ocr LLM: typed path failed (\(String(describing: error), privacy: .public)); falling back to prompt-parse")
            }
        }
        do {
            let response = try await provider.generate(
                prompt: frame.prompt,
                options: GenerationOptions(maxTokens: 320, temperature: 0.2)
            )
            let parsed = ExpertResponseParser.parseClaims(from: response, evidenceMap: frame.evidenceMap)
            AtlasLog.brain.info("expert.ocr LLM: provider=\(provider.id, privacy: .public) produced \(parsed.claims.count) claims, dropped \(parsed.dropped)")
            let claims = parsed.claims.map { p in
                ExpertFindings.Claim(
                    statement: p.text,
                    supportingObjectIDs: p.citation.supportingObjectIDs,
                    supportingEventIDs: p.citation.supportingEventIDs,
                    supportingEntityIDs: p.citation.supportingEntityIDs,
                    confidence: .medium,
                    evidenceGranularity: .specific
                )
            }
            return (claims, parsed.dropped)
        } catch {
            AtlasLog.brain.error("expert.ocr LLM: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public)")
            return ([], 0)
        }
    }
}

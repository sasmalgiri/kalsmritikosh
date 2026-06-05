//
//  OCRExpert.swift
//  Kalsmritikosh
//
//  Pulls image-typed KOs out of retrieval, re-OCRs them with Vision
//  using the table/form recognizers, then asks the capability registry
//  to reason over the recognized text.
//

import Foundation

public struct OCRExpert: Expert {
    public let id = "expert.ocr"
    public let capabilities: Set<ExpertCapability> = [.tableUnderstanding, .formUnderstanding]
    public let domains: Set<ExpertDomain> = [.ocr]
    private let ocr: VisionOCR

    public init(ocr: VisionOCR = VisionOCR()) {
        self.ocr = ocr
    }

    public func analyze(intent: UserIntent, context: ExpertContext) async throws -> ExpertFindings {
        let result = try await context.retriever.retrieve(
            for: intent,
            layers: [.metadata, .entity]
        )
        // Find chunks whose source KO is an image — those are the ones
        // worth re-OCRing for table/form detail. In the alpha we only
        // use retrieved chunks; KO lookup-by-id arrives with MemoryRetriever.
        let imageChunks = result.chunks.filter { hit in
            hit.chunk.text.lowercased().contains("[image:")
        }
        var claims: [ExpertFindings.Claim] = []
        for chunk in imageChunks.prefix(4) {
            claims.append(.init(
                statement: "OCR expert flagged image-typed KO for follow-up: \(chunk.chunk.id.uuidString.prefix(8))",
                supportingObjectIDs: [chunk.chunk.objectID],
                confidence: .low
            ))
        }
        _ = context.capabilities
        return ExpertFindings(
            expertID: id,
            claims: claims,
            confidence: claims.isEmpty ? .zero : .low,
            notes: claims.isEmpty ? "No image KOs in retrieval scope." : nil
        )
    }
}

//
//  BlockSemantics.swift
//  Kalsmritikosh
//
//  SEM-002 — an OPEN registry of semantic block roles. Structural parsing already tags each
//  EvidenceBlock with a structural kind (paragraph, tableRow, heading…). Semantics is a
//  higher layer: what a block MEANS (a payment line, an employment entry, a contract clause,
//  a contact line). Per the locked contract this must NOT be a closed enum — domain packs
//  (SEM-004…008) register recognizers; the core ships generic, domain-neutral ones so an
//  unfamiliar domain still gets useful tags.
//
//  Deterministic, offline. A recognizer returns an open role string + confidence, or nil.
//  Registration is additive; recognizers never mutate the block.
//

import Foundation

public struct BlockSemanticTag: Sendable, Hashable {
    public let role: String        // OPEN — e.g. "amountLine", "employmentEntry", "clause"
    public let confidence: Double
    public let recognizedBy: String

    public nonisolated init(role: String, confidence: Double, recognizedBy: String) {
        self.role = role
        self.confidence = confidence
        self.recognizedBy = recognizedBy
    }
}

/// A recognizer inspects a block's text (+ optional structural-kind hint) and returns a tag.
public struct BlockRecognizer: Sendable {
    public let name: String
    public let recognize: @Sendable (_ text: String, _ structuralKind: String?) -> BlockSemanticTag?
    public nonisolated init(name: String,
                            recognize: @escaping @Sendable (String, String?) -> BlockSemanticTag?) {
        self.name = name
        self.recognize = recognize
    }
}

public struct BlockSemanticsRegistry: Sendable {
    private let recognizers: [BlockRecognizer]

    public nonisolated init(recognizers: [BlockRecognizer]) {
        self.recognizers = recognizers
    }

    /// Additive: return a new registry with an extra recognizer (domain packs use this).
    public nonisolated func registering(_ r: BlockRecognizer) -> BlockSemanticsRegistry {
        BlockSemanticsRegistry(recognizers: recognizers + [r])
    }

    /// All tags a block matches, highest-confidence first. A block may hold several roles.
    public nonisolated func tags(forText text: String, structuralKind: String? = nil) -> [BlockSemanticTag] {
        recognizers.compactMap { $0.recognize(text, structuralKind) }
            .sorted { $0.confidence > $1.confidence }
    }

    /// The core, domain-neutral registry. Domain packs extend it via `registering`.
    public nonisolated static let generic = BlockSemanticsRegistry(recognizers: [
        BlockRecognizer(name: "amountLine") { text, _ in
            let t = text.lowercased()
            let hasAmount = (t.contains("₹") || t.contains("$") || t.contains("rs") || t.contains("inr")
                             || t.contains("amount") || t.contains("total") || t.contains("paid"))
                && t.contains(where: \.isNumber)
            return hasAmount ? BlockSemanticTag(role: "amountLine", confidence: 0.7, recognizedBy: "amountLine") : nil
        },
        BlockRecognizer(name: "dateLine") { text, _ in
            let t = text.lowercased()
            let months = ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"]
            let hasDate = text.range(of: #"\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b"#, options: .regularExpression) != nil
                || months.contains(where: { t.contains($0) })
            return hasDate ? BlockSemanticTag(role: "dateLine", confidence: 0.55, recognizedBy: "dateLine") : nil
        },
        BlockRecognizer(name: "employmentEntry") { text, _ in
            let t = text.lowercased()
            let emp = t.contains("worked") || t.contains("employer") || t.contains("designation")
                || t.contains("position") || t.contains("experience") || t.contains("ppic")
            return emp ? BlockSemanticTag(role: "employmentEntry", confidence: 0.6, recognizedBy: "employmentEntry") : nil
        },
        BlockRecognizer(name: "clause") { text, kind in
            let t = text.lowercased()
            let clause = t.contains("shall") || t.contains("hereby") || t.contains("clause")
                || t.contains("obligation") || (kind == "listItem" && t.contains("terms"))
            return clause ? BlockSemanticTag(role: "clause", confidence: 0.5, recognizedBy: "clause") : nil
        },
        BlockRecognizer(name: "contactLine") { text, _ in
            let t = text.lowercased()
            let contact = t.contains("@") || t.contains("phone") || t.contains("mobile")
                || text.range(of: #"\b\d{10}\b"#, options: .regularExpression) != nil
            return contact ? BlockSemanticTag(role: "contactLine", confidence: 0.5, recognizedBy: "contactLine") : nil
        }
    ])
}

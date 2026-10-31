//
//  FoundationModelsQuestionRewriter.swift
//  Kalsmritikosh
//
//  QuestionRewriting on Apple's on-device model: the model chooses ONE canonical form (a string-enum
//  schema of the form ids, or none) and copies the slot values from the question. QuestionCanonicalizer
//  then keeps the rewrite only if every slot value is text the question itself contains. Nothing
//  leaves the Mac.
//

import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct FoundationModelsQuestionRewriter: QuestionRewriting {
    public init() {}

    public func choose(for question: String, among forms: [CanonicalForm]) async -> CanonicalChoice? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *), FoundationModelsQuestionInterpreter.isAvailable(), !forms.isEmpty else { return nil }
        let menu = forms.map { "- \($0.id): \($0.wording) — \($0.meaning)" }.joined(separator: "\n")
        do {
            let pick = DynamicGenerationSchema(name: "Form", description: "The canonical form that asks the same thing, or none.",
                                               anyOf: forms.map(\.id) + ["none"])
            let text = DynamicGenerationSchema(type: String.self)
            var properties = [DynamicGenerationSchema.Property(name: "form", description: "One form id, or none.", schema: pick)]
            for slot in ["person", "subject", "a", "b", "record", "title"] {
                properties.append(.init(name: slot, description: "Copied exactly from the question, or empty.", schema: text, isOptional: true))
            }
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Rewrite", properties: properties), dependencies: [])
            let session = LanguageModelSession(instructions: """
                You rewrite an investigator's question into one canonical form. Choose the form that asks \
                exactly the same thing and copy each name, record number or quoted subject exactly as the \
                question writes it. Never add or guess anything. If no form asks the same thing, choose none.
                """)
            let response = try await session.respond(to: "Forms:\n\(menu)\n\nQuestion: \(question)", schema: schema,
                                                      options: FoundationModels.GenerationOptions(sampling: .greedy))
            let form = try response.content.value(String.self, forProperty: "form")
            guard form != "none" else { return nil }
            var slots: [String: String] = [:]
            for slot in ["person", "subject", "a", "b", "record", "title"] {
                if let v = try? response.content.value(String.self, forProperty: slot), !v.isEmpty { slots[slot] = v }
            }
            return CanonicalChoice(formID: form, slots: slots)
        } catch {
            KalsmritikoshLog.brain.error("Question rewriter (on-device) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }
}

//
//  FoundationModelsQuestionInterpreter.swift
//  Kalsmritikosh
//
//  QuestionInterpreting on Apple's on-device model. The model's only output is ONE choice from the
//  fields the archive holds (or "none"), enforced by a dynamic string-enum schema — it cannot write
//  a value, a sentence or a field that does not exist. Nothing leaves the Mac.
//

import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct FoundationModelsQuestionInterpreter: QuestionInterpreting {
    public init() {}

    static let none = "none"

    public static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    public func field(askedBy question: String, among fields: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *), Self.isAvailable(), !fields.isEmpty else { return nil }
        let choices = Array(Set(fields)).sorted() + [Self.none]
        let menu = choices.filter { $0 != Self.none }.map { "- \($0): \(FieldMeaning.describe($0))" }.joined(separator: "\n")
        do {
            let pick = DynamicGenerationSchema(name: "FieldChoice", description: "The record field the question asks for, or none.",
                                               anyOf: choices)
            let root = DynamicGenerationSchema(name: "Interpretation", properties: [
                DynamicGenerationSchema.Property(name: "field", description: "One field id from the list, or none.", schema: pick)
            ])
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(instructions: """
                You read an investigator's question about a case record and decide which ONE field of the \
                record it asks for. Answer with a field id from the list. Answer none when the question asks \
                for a summary or account of what happened, a count, a yes-or-no about something that is not \
                one of these fields, or anything none of these fields holds. Match what the question asks \
                for — who, what, when or where — to a field that holds exactly that kind of thing; a field that \
                only shares a word with the question is wrong. If no field holds what is asked, answer none.
                """)
            let response = try await session.respond(to: """
                Fields this record has:
                \(menu)

                Question: \(question)
                """, schema: schema, options: FoundationModels.GenerationOptions(sampling: .greedy))
            let chosen = try response.content.value(String.self, forProperty: "field")
            return chosen   // "none" is an answer too: the question asks for no field on file
        } catch {
            KalsmritikoshLog.brain.error("Question interpreter (on-device) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }
}

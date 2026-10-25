//
//  CloudQuestionInterpreter.swift
//  Kalsmritikosh
//
//  Step 3 of QuestionUnderstanding: the person's own cloud AI, used ONLY to say which field a
//  question asks for. It is reached only for questions the rules and the on-device model could not
//  place, only in Online mode, and through OnlineCloudProvider — so masking, the daily limit and the
//  consent screen apply. What is sent: the question and the names of the case's fields (a few
//  hundred characters). What comes back: one field id. No document text is sent and no answer is
//  written by the cloud model.
//

import Foundation

public struct CloudQuestionInterpreter: QuestionInterpreting {
    private let generate: @Sendable (String) async throws -> String

    /// `generate` sends one prompt through the Online provider and returns its text reply.
    public init(generate: @escaping @Sendable (String) async throws -> String) {
        self.generate = generate
    }

    static func prompt(question: String, fields: [String]) -> String {
        let menu = fields.map { "- \($0): \(FieldMeaning.describe($0))" }.joined(separator: "\n")
        return """
            Which ONE field of a case record does this question ask for? Reply with the field id only, \
            exactly as listed, or the word none if it asks for a summary, a count, or anything not listed.

            Fields:
            \(menu)

            Question: \(question)
            """
    }

    /// The reply's field id, only when it is exactly one of `fields`.
    static func parse(_ reply: String, fields: [String]) -> String? {
        let token = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'.:"))
            .lowercased()
        if token == "none" { return "none" }
        return fields.first { $0 == token }
    }

    public func field(askedBy question: String, among fields: [String]) async -> String? {
        guard !fields.isEmpty else { return nil }
        do {
            return Self.parse(try await generate(Self.prompt(question: question, fields: fields)), fields: fields)
        } catch {
            return nil   // declined, offline, limit reached: the question stays with the rules
        }
    }
}

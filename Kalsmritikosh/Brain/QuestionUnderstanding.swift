//
//  QuestionUnderstanding.swift
//  Kalsmritikosh
//
//  Owner decision 2026-10-25 — three steps to understand a question, cheapest first:
//    1. the phrase rules (free, instant; most questions);
//    2. the on-device model, only for questions the rules could not place (free, nothing leaves
//       the Mac);
//    3. a cloud model, only for what both missed, only with Online mode and the person's own key.
//  Every step only CHOOSES one of the fields the case's retrieved facts carry — the answer is still
//  read word for word from the documents and goes through every gate.
//
//  Measured on 1,088 held-out question wordings (190 real cases): rules alone placed 83.1%, the
//  on-device model alone 70.0%, rules then model (model only for unplaced value questions) 95.8%,
//  with 15% of questions reaching the model.
//
//  Questions that a dedicated gate answers (who announced, what happened / summaries, how many, a
//  release's announcement date) never go to a model: they ask for no single field, and the model is
//  poor at knowing that.
//

import Foundation
import os

public nonisolated enum QuestionUnderstanding {

    /// The field chosen for a question by step 2 or 3, read by `SlotFieldResolver` for the rest of
    /// that answer. Keyed by the question text; only the most recent few are kept.
    private static let chosen = OSAllocatedUnfairLock(initialState: [String: String]())

    /// Keyed case- and space-insensitively: callers pass the question as asked or lowercased.
    static func key(_ question: String) -> String {
        question.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func interpretedField(for question: String) -> String? {
        chosen.withLock { $0[key(question)] }
    }

    /// Remembered when the interpreter found that no field on file answers the question.
    public static let noField = ""

    /// Questions a dedicated gate answers, offered to the model beside the fields when the rules
    /// could not place a wording ("Which office put out …", "When did … come out", "What number of
    /// workers were hurt …"). The model only chooses the gate; the gate still reads the answer from
    /// the documents, or says the documents don't give it.
    public enum GateIntent: String, CaseIterable, Sendable {
        case announcingOffice = "announcingoffice"
        case releaseDate = "releasedate"
        case peopleCount = "peoplecount"
    }

    private static let intents = OSAllocatedUnfairLock(initialState: [String: GateIntent]())

    /// The gate the interpreter chose for this question, if any.
    public static func gateIntent(for question: String) -> GateIntent? {
        intents.withLock { $0[key(question)] }
    }

    static func remember(_ intent: GateIntent?, for question: String) {
        intents.withLock { table in
            if table.count > 64 { table.removeAll() }
            table[key(question)] = intent
        }
    }

    static func remember(_ field: String?, for question: String) {
        chosen.withLock { table in
            if table.count > 64 { table.removeAll() }
            table[key(question)] = field
        }
    }

    /// Fields too generic to trust from the rules alone — "date" when the record has a named date,
    /// "product" for "what was wrong with the product", "court" for "what did the court rule".
    static let weakRuleFields: Set<String> = ["date", "product", "court", "status", "amount", "employer", "location"]

    /// True when a dedicated gate answers this kind of question, so no model is asked.
    public static func handledByAGate(_ question: String) -> Bool {
        let l = question.lowercased()
        // A question a dedicated answerer reads (a person's proceeding, an email by its subject).
        if ProceedingAnswerer.parse(question) != nil || EmailHeaderAnswerer.parse(question) != nil { return true }
        return IssuingOfficeGate.asksIssuingOffice(question)
            || SentenceQuoteComposer.asksWhatHappened(question)
            || CountQuestionGate.asksCount(question)
            || (DateQuestionGate.asksWhen(question) && DateQuestionGate.asksPublicationDate(question))
            || l.range(of: #"^(?:give me a summary|summari[sz]e|describe|tell me about|what is the case)\b"#, options: .regularExpression) != nil
    }

    /// Steps 2 and 3 for one question, given the fields its retrieved facts carry. Stores the
    /// choice for `SlotFieldResolver`; returns which step decided ("rules", "on-device", "cloud",
    /// or nil when no step placed it).
    @discardableResult
    public static func interpret(question: String, fields: Set<String>,
                                 onDevice: (any QuestionInterpreting)?, cloud: (any QuestionInterpreting)?,
                                 modelsAllowed: Bool = FeatureFlags.aiRegimeValue().allowsAI) async -> String? {
        remember(nil as String?, for: question)
        remember(nil as GateIntent?, for: question)
        guard !fields.isEmpty, !handledByAGate(question) else { return nil }
        let rules = SlotFieldResolver.resolve(in: question, knownFields: fields).first?.fieldID
        // A rule that names a field this record does not hold ("decided" → decision date, asked of a
        // defect investigation) has not placed the question either.
        if let rules, !weakRuleFields.contains(rules), fields.contains(rules) { return "rules" }
        // "Fully private" means no model at all — not even on-device — so the rules decide alone.
        guard modelsAllowed else { return rules == nil ? nil : "rules" }
        // The bare "date" field is offered only when the record has no date of its own kind
        // ("decisiondate", "dateopened") — otherwise the model takes the generic one.
        let specificDates = fields.filter { $0 != "date" && FactSchemaRegistry.expectedShape(of: $0) == .date }
        var menu = Array(specificDates.isEmpty ? fields : fields.subtracting(["date"])).sorted()
        // The gates, where they can apply: a release's own date only when the record has no date
        // of its own kind; the announcing office only when no field already says who issued it
        // (a recall's firm, a decision's court).
        if specificDates.isEmpty { menu.append(GateIntent.releaseDate.rawValue) }
        if !fields.contains(where: { ["recallingfirm", "manufacturer", "court", "opinionauthor"].contains($0) }) {
            menu.append(GateIntent.announcingOffice.rawValue)
        }
        menu.append(GateIntent.peopleCount.rawValue)
        var said: String?
        if let onDevice { said = await onDevice.field(askedBy: question, among: menu) }
        if said == nil, rules == nil, let cloud { said = await cloud.field(askedBy: question, among: menu) }
        guard let said else { return rules == nil ? nil : "rules" }
        if let gate = GateIntent(rawValue: said) {
            remember(gate, for: question)
            return "interpreted:" + said
        }
        if fields.contains(said) {
            remember(said, for: question)
            return "interpreted:" + said
        }
        // "none": no field on file holds what is asked. A weak rule match ("court" for "What did
        // the court rule …?" when no ruling was filed) is then set aside rather than answered.
        if said == "none", rules != nil { remember(Self.noField, for: question); return "interpreted:none" }
        return rules == nil ? nil : "rules"
    }
}

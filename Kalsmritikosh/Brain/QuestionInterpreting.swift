//
//  QuestionInterpreting.swift
//  Kalsmritikosh
//
//  Owner decision 2026-10-25: a model may UNDERSTAND the question, never write the answer. Wide
//  case bench: the hand-written phrase rules understood 94% of the wordings they were tuned on but
//  only 72% of new wordings ("What did the court rule in …?", "Who made the announcement …?"). An
//  interpreter maps the question onto ONE of the fields this archive actually holds — or none —
//  and the evidence engine then answers word for word from the documents, through the same gates.
//
//  The interpreter is a capability: the on-device model first; a cloud model only with Online mode
//  and the person's own key. It is consulted only when the rules found no field, so most questions
//  never reach a model and no tokens are spent on them.
//

import Foundation

public protocol QuestionInterpreting: Sendable {
    /// The field of `fields` (normalised ids, e.g. "disposition", "recallingfirm") the question asks
    /// for; "none" when it asks for none of them (an account, a count, something not on file); nil
    /// when the interpreter could not answer at all (unavailable, declined, failed).
    func field(askedBy question: String, among fields: [String]) async -> String?
}

/// Words that describe what a field holds, so a model choosing among field ids reads meaning, not
/// run-together names. Unknown fields fall back to their human label.
public enum FieldMeaning {
    public nonisolated static let descriptions: [String: String] = [
        // The gates (QuestionUnderstanding.GateIntent).
        "announcingoffice": "WHO put out, issued or released the announcement or press release itself (the office or agency) — not a person in it",
        "releasedate": "WHEN the announcement, press release or statement itself was issued or came out — not when the events in it happened",
        "peoplecount": "HOW MANY people (workers, employees, victims) were hurt, injured or killed",
        "disposition": "WHAT the court decided: its ruling, outcome or result (affirmed, reversed, dismissed …)",
        "opinionauthor": "WHO wrote the court's opinion or decision (the judge or justice)",
        "court": "the NAME of the court that heard the case — not what it decided",
        "decisiondate": "WHEN the court decided the case (a date) — not who wrote the decision",
        "casenumber": "the docket or case number",
        "parties": "the parties or litigants in the case",
        "recallingfirm": "the company or firm that recalled the product",
        "classification": "the recall's class (Class I, II or III)",
        "reasonforrecall": "why the product was recalled; what was wrong with it",
        "recallinitiationdate": "the date the recall was started",
        "status": "whether the recall or matter is ongoing, completed or terminated",
        "distributionpattern": "where the product was distributed",
        "productquantity": "how much product was recalled",
        "product": "the product concerned",
        "manufacturer": "the company that makes the vehicles or product",
        "component": "the vehicle part or component investigated",
        "dateopened": "the date the investigation was opened",
        "location": "where the accident or event happened",
        "dateandtime": "when the accident or event happened",
        "aircraft": "the aircraft involved (make, model, registration)",
        "probablecause": "the cause of the accident as found by the investigators",
        "injuries": "how many people were hurt or killed",
        "eventdate": "when the incident happened",
        "inspectionnumbers": "the inspection number",
    ]

    public nonisolated static func describe(_ field: String) -> String {
        descriptions[field] ?? SlotFieldResolver.humanLabel(forFieldID: field).lowercased()
    }
}

//
//  QuestionCanonicalizer.swift
//  Kalsmritikosh
//
//  Any wording, one meaning. The deterministic answerers each understand a few phrasings ("When was
//  X sentenced?", "Who sent the email "S"?"); investigators ask in hundreds of ways ("Can you tell me
//  the date on which X was sentenced?", "Who was on the receiving end of the email "S"?"). When no
//  rule recognises a question, a model rewrites it into ONE of the canonical forms below, copying
//  the question's own names, record numbers and quoted subjects — nothing else. The rewritten
//  question then runs through the same deterministic pipeline, which reads the answer from the
//  documents and cites it. The model never sees a document and never writes an answer.
//
//  Cascade (owner decision 2026-10-25): rules first; the on-device model next; the person's own
//  cloud AI (Online mode only) last. A rewrite is used only when every slot it fills is text the
//  question itself contains and the rewritten question is one the rules recognise.
//
//  Measured with Claude on 3,302 rewordings of real closed-case questions (closed-case simulation,
//  2026-10-26): see docs/CLOSED_CASE_SIMULATION.md.
//

import Foundation

/// A canonical form: an id, its wording with {slots}, and what it means (for the model's menu).
public nonisolated struct CanonicalForm: Sendable, Equatable {
    public let id: String
    public let wording: String
    public let meaning: String
}

/// A model's choice: the form, and the slot values copied from the question.
public nonisolated struct CanonicalChoice: Sendable, Equatable {
    public let formID: String
    public let slots: [String: String]
    public init(formID: String, slots: [String: String]) { self.formID = formID; self.slots = slots }
}

/// Rewrites a question into one canonical form. nil: could not answer (unavailable, failed).
public protocol QuestionRewriting: Sendable {
    func choose(for question: String, among forms: [CanonicalForm]) async -> CanonicalChoice?
}

public nonisolated enum QuestionCanonicalizer {

    public static let forms: [CanonicalForm] = [
        // A person in a proceeding.
        .init(id: "person-sentenced-when", wording: "When was {person} sentenced?", meaning: "the date a person was sentenced"),
        .init(id: "person-charged-when", wording: "When was {person} charged?", meaning: "the date a person was charged or indicted"),
        .init(id: "person-arrested-when", wording: "When was {person} arrested?", meaning: "the date a person was arrested"),
        .init(id: "person-convicted-when", wording: "When was {person} convicted?", meaning: "the date a person was convicted or found guilty"),
        .init(id: "person-pleaded-when", wording: "When did {person} plead guilty?", meaning: "the date a person pleaded guilty"),
        .init(id: "person-pardoned-when", wording: "When was {person} pardoned?", meaning: "the date a person was pardoned"),
        .init(id: "person-pleaded-whether", wording: "Did {person} plead guilty?", meaning: "whether a person pleaded guilty (yes/no)"),
        .init(id: "person-convicted-whether", wording: "Was {person} convicted?", meaning: "whether a person was convicted (yes/no)"),
        .init(id: "person-sentence", wording: "What sentence did {person} receive?", meaning: "the punishment / prison term imposed on a person"),
        .init(id: "person-charge", wording: "What was {person} charged with?", meaning: "the crime or offence a person was charged with"),
        .init(id: "person-timeline", wording: "Give me the timeline of the case against {person}.", meaning: "the steps of a person's case in date order"),
        .init(id: "person-documents", wording: "How many documents are about {person}?", meaning: "how many documents name a person"),
        .init(id: "person-office", wording: "Which office prosecuted {person}?", meaning: "the prosecutor's office that brought a person's case"),
        // An email, named by its subject.
        .init(id: "email-sender", wording: "Who sent the email \"{subject}\"?", meaning: "who sent the email with that subject"),
        .init(id: "email-date", wording: "When was the email \"{subject}\" sent?", meaning: "when the email with that subject was sent"),
        .init(id: "email-recipients", wording: "Who received the email \"{subject}\"?", meaning: "who the email with that subject was sent to"),
        .init(id: "email-content", wording: "What did the email \"{subject}\" say?", meaning: "what the email with that subject says"),
        .init(id: "email-count", wording: "How many emails did {a} send to {b}?", meaning: "how many emails one person sent another"),
        .init(id: "email-when", wording: "When did {a} email {b}?", meaning: "when one person emailed another"),
        // A record named by its number (an accident, recall, inspection, investigation).
        .init(id: "record-date", wording: "When did the accident in {record} happen?", meaning: "when the event of a numbered record happened"),
        .init(id: "record-place", wording: "Where did the {record} accident happen?", meaning: "where the event of a numbered record happened"),
        .init(id: "record-killed", wording: "How many people were killed in {record}?", meaning: "how many people died in a numbered record's event"),
        .init(id: "record-cause", wording: "What was the probable cause of {record}?", meaning: "the official cause found for a numbered record's event"),
        .init(id: "record-conclusion", wording: "What did the investigators conclude caused the accident in {record}?", meaning: "the investigators' conclusion about the cause"),
        .init(id: "record-aircraft", wording: "Which aircraft was involved in {record}?", meaning: "the aircraft of a numbered accident record"),
        .init(id: "record-account", wording: "What happened in {record}?", meaning: "an account of a numbered record's event"),
        // A release or document named by its title.
        .init(id: "title-office", wording: "Which office announced \"{title}\"?", meaning: "the office that issued the release with that title"),
        .init(id: "title-date", wording: "When was the press release \"{title}\" issued?", meaning: "the date the release with that title was issued"),
        .init(id: "title-account", wording: "What happened in the case \"{title}\"?", meaning: "an account of the matter the titled release is about"),
    ]

    /// The question without its courtesy wrapper — deterministic, before any rule or model reads it:
    /// "Can you tell me the date on which X was sentenced?" → "When X was sentenced?", "I need to know
    /// the probable cause listed for NTSB case Y — what was it?" → "the probable cause listed for NTSB
    /// case Y?". Claude-written rewordings of real closed-case questions (2026-10-26) sent four in five
    /// questions to the cloud only because of such wrappers.
    public static func normalize(_ question: String) -> String {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadIns = #"^(?i:(?:hi|hey|hello|ok|okay|so)[,!.]?\s+)?(?i:(?:can|could|would|will) you\s+(?:please\s+)?(?:tell|show|give|let)\s+me\s+(?:know\s+)?|(?:can|could) you\s+(?:please\s+)?(?:identify|find|confirm|provide|check|clarify|walk me through|share|pull up|pull|look up|get|retrieve|dig up)\s+|i(?:'d| would)? (?:like|want|need) to (?:know|find out|confirm|see|understand)\s+|i need\s+|please\s+(?:tell me|let me know|confirm|provide|identify|show me|give me)?\s*|do you know\s+|tell me\s+|i'm (?:trying|looking|attempting) to (?:find out|figure out|learn|determine|establish|identify|confirm|work out|understand|pin down)\s+)"#
        while let r = q.range(of: leadIns, options: .regularExpression), !r.isEmpty {
            q = String(q[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            // "I need to confirm — when exactly …": the dash after a wrapper goes with it.
            q = q.replacingOccurrences(of: #"^[—–\-:,]\s*"#, with: "", options: .regularExpression)
        }
        // A trailing "— what was it?" / ", please?" adds nothing.
        // So do "— when was it?", "— when did that occur?", "— do you have that on record?".
        q = q.replacingOccurrences(of: #"(?i)\s*(?:[—–-]|,)\s*(?:what (?:was|is|were|are) (?:it|they|that)|please|when (?:was|did) (?:it|that|this)(?: (?:occur|happen|take place))?|do (?:you|we) have (?:that|it|this)(?: (?:on record|on file|anywhere))?)\s*\?*\s*$"#, with: "?", options: .regularExpression)
        // "the sentencing date for X" asks for it: "What was the sentencing date for X?".
        q = q.replacingOccurrences(of: #"(?i)^(the\s+(?:\w+\s+)?(?:date|day)\s+(?:for|of)\s+)"#, with: "What was $1", options: .regularExpression)
        // "the date on which X happened" / "the day X was sentenced" → "When X …".
        q = q.replacingOccurrences(of: #"(?i)^(?:the\s+)?(?:exact\s+|specific\s+|precise\s+)?(?:date|day)\s+(?:on which|when|that)\s+"#, with: "When ", options: .regularExpression)
        // "the exact date Demarcus Foy was sentenced" — no connector, a name follows.
        q = q.replacingOccurrences(of: #"^(?i:(?:the\s+)?(?:exact\s+|specific\s+|precise\s+)?(?:date|day))\s+(?=[A-Z]|[\w.+-]+@)"#, with: "When ", options: .regularExpression)
        // "whether X pleaded guilty" → "Did X plead guilty".
        q = q.replacingOccurrences(of: #"(?i)^whether\s+(.+?)\s+pleaded guilty"#, with: "Did $1 plead guilty", options: .regularExpression)
        q = q.replacingOccurrences(of: #"(?i)^(who|what|when|where|which|how)\b"#, with: "$1", options: .regularExpression)
        if let first = q.first, first.isLowercase { q = first.uppercased() + q.dropFirst() }
        if !q.hasSuffix("?") && !q.hasSuffix(".") { q += "?" }
        return q.isEmpty ? question : q
    }

    /// True when a rule already understands the question — no model is asked.
    public static func recognizedByRules(_ question: String) -> Bool {
        ProceedingAnswerer.parse(question) != nil
            || EmailHeaderAnswerer.parse(question) != nil
            || QuestionUnderstanding.handledByAGate(question)
            || DateQuestionGate.asksWhen(question)
            || ConclusionGate.asksConclusion(question)
            || RecordLineGate.asksKilled(question)
            || !SlotFieldResolver.resolve(in: question).isEmpty
    }

    /// The canonical question for a model's choice — only when every slot is text the question holds
    /// and the result is a question the rules recognise.
    public static func build(_ choice: CanonicalChoice, from question: String) -> String? {
        guard let form = forms.first(where: { $0.id == choice.formID }) else { return nil }
        var text = form.wording
        let names = slotNames(in: form.wording)
        for name in names {
            // The question's own spelling of the value, so names and subjects match the documents.
            guard let value = choice.slots[name]?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))),
                  value.count >= 2,
                  let r = question.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            var spelled = String(question[r])
            // A name typed in lower case ("brandy mize") is written as a name, so the rules read it as one.
            if ["person", "a", "b"].contains(name), spelled == spelled.lowercased() {
                spelled = spelled.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
            text = text.replacingOccurrences(of: "{\(name)}", with: spelled)
        }
        return recognizedByRules(text) ? text : nil
    }

    static func slotNames(in wording: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\{([a-z]+)\}"#) else { return [] }
        let ns = wording as NSString
        return re.matches(in: wording, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// The menu a text model reads.
    public static func prompt(question: String) -> String {
        let menu = forms.map { "- \($0.id): \($0.wording)  — \($0.meaning)" }.joined(separator: "\n")
        return """
            Rewrite the investigator's question into ONE of the forms below. Copy every name, record \
            number and quoted subject EXACTLY as the question writes it; never add or guess anything. If no \
            form asks the same thing, choose none.
            Reply with JSON only: {"form": "<form id or none>", "slots": {"person": "...", "subject": "...", "a": "...", "b": "...", "record": "...", "title": "..."}} — only the slots the form uses.

            Forms:
            \(menu)

            Question: \(question)
            """
    }

    /// A text reply as a choice.
    public static func parse(_ reply: String) -> CanonicalChoice? {
        guard let r = reply.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
              let data = String(reply[r]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let form = object["form"] as? String, form != "none" else { return nil }
        let slots = (object["slots"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }.filter { !$0.value.isEmpty }
        return CanonicalChoice(formID: form, slots: slots)
    }

    /// Rules first; then the on-device model; then the cloud. nil: keep the question as asked.
    public static func canonicalize(_ question: String, onDevice: (any QuestionRewriting)?, cloud: (any QuestionRewriting)?,
                                    modelsAllowed: Bool) async -> String? {
        guard modelsAllowed, !recognizedByRules(question) else { return nil }
        for rewriter in [onDevice, cloud].compactMap({ $0 }) {
            if let choice = await rewriter.choose(for: question, among: forms), let canonical = build(choice, from: question) {
                return canonical
            }
        }
        return nil
    }
}

/// The cloud step: one prompt through the person's own provider (Online mode), the reply parsed.
public nonisolated struct CloudQuestionRewriter: QuestionRewriting {
    private let generate: @Sendable (String) async throws -> String
    public init(generate: @escaping @Sendable (String) async throws -> String) { self.generate = generate }
    public func choose(for question: String, among forms: [CanonicalForm]) async -> CanonicalChoice? {
        do { return QuestionCanonicalizer.parse(try await generate(QuestionCanonicalizer.prompt(question: question))) } catch { return nil }
    }
}

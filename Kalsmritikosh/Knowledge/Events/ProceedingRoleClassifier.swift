//
//  ProceedingRoleClassifier.swift
//  Kalsmritikosh
//
//  P4 (real-case evaluation 2026-11-03, D5) — who a person IS in a proceeding document, read from the
//  document's own words. The findings report listed the judge, the U.S. Attorney and the prosecutors
//  as defendants ("John Michael Vazquez charged … convicted", "Michael DiGiacomo pleaded guilty",
//  "Booth Goodwin charged … sentenced", "Trini E. Ross charged"): every person a release names was
//  checked for steps, and a plural lead ("Two men … were convicted") went to whoever the next
//  sentences named — the judge before whom the trial was held included.
//
//  The roles, each from the title or wording the document attaches to the person:
//    prosecutor — "U.S. Attorney X", "Acting U.S. Attorney X", "Assistant U.S. Attorney(s) X (and Y)",
//                 "AUSA X", "prosecuted by X", "X, who is handling the case"
//    judge      — "U.S. District (Court) Judge X", "Judge X", "Magistrate (Judge) X", "Justice X"
//    agent      — "Special Agent (in Charge) X", "FBI agent X", "X, Director of …", "investigated by X"
//    counsel    — "X, Esq.", "X Esq.", "represented by X", "attorney for … X", "defense attorney X",
//                 a defence-counsel list line ("Gillar: Thomas Ashley Esq., Newark")
//    victim     — "victim X", "X, the victim"
//    witness    — "witness X", "X testified"
//    defendant  — "X, 45, of …" (an introduction), "defendant X", "X was sentenced/charged/…",
//                 "X pleaded guilty", "charging A, B and X"
//  A defendant's own signal outranks a title (a former judge "X, 60, of …, was sentenced" is a
//  defendant); otherwise an official title wins. No signal: nil — the person's role is not stated.
//
//  Deterministic, offline, pure.
//

import Foundation

public nonisolated enum ProceedingRole: String, Sendable, CaseIterable, Codable {
    case defendant, prosecutor, judge, agent, counsel, victim, witness

    /// Officials take no proceeding step of their own in the case: the steps they announce, preside
    /// over or prosecute are the defendants'.
    public var isOfficial: Bool { [.prosecutor, .judge, .agent, .counsel].contains(self) }

    /// A role that never receives a defendant's step (charged, pleaded, convicted, sentenced …).
    public var takesNoSteps: Bool { self != .defendant }

    public var label: String {
        switch self {
        case .defendant: return "defendant"
        case .prosecutor: return "prosecutor"
        case .judge: return "judge"
        case .agent: return "investigator"
        case .counsel: return "defence counsel"
        case .victim: return "victim"
        case .witness: return "witness"
        }
    }

    /// Words a quote must carry to support this role (the cloud reading is used only when its own
    /// quote supports what it says).
    var supportPattern: String {
        switch self {
        case .defendant: return #"(?i)\b(?:defendants?|co-?defendants?|charged|charging|indicted|pleaded|pled|pleads|convicted|sentenced|found guilty|arrested|\d{2},\s+of)\b"#
        case .prosecutor: return #"(?i)\b(?:attorneys?|ausa|prosecut\w*|handling the case|in charge of the prosecution)\b"#
        case .judge: return #"(?i)\b(?:judge|justice|magistrate|court)\b"#
        case .agent: return #"(?i)\b(?:agents?|fbi|investigat\w*|director|inspector|detective|officer|police|trooper)\b"#
        case .counsel: return #"(?i)\b(?:esq|counsel|represent\w*|attorney for|defen[cs]e attorney|lawyer)\b"#
        case .victim: return #"(?i)\bvictims?\b"#
        case .witness: return #"(?i)\b(?:witness\w*|testif\w*)\b"#
        }
    }
}

public nonisolated enum ProceedingRoleClassifier {

    /// The role `person` (a full name) holds in `text`, or nil when the text states none.
    public static func role(of person: String, in text: String) -> ProceedingRole? {
        let tokens = ProceedingEventExtractor.nameTokens(person)
        guard let first = tokens.first, let last = tokens.last, tokens.count >= 2 else { return nil }
        let full = fullNamePattern(first: first, last: last)
        let sur = #"(?i:\b"# + loose(last) + #"\b)"#
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

        // Up to two more names before this one in a title's list ("Assistant U.S. Attorneys Paul E.
        // Bonanno and Douglas A. C. Penrose"): capitalised words, initials, one "and" or comma.
        let listed = #"(?:(?:[A-Z][\w'’\-]*\.?\s+){0,3}[A-Z][\w'’\-]*\.?(?:,\s+(?:and\s+)?|\s+and\s+)){0,2}"#
        // A title then the person: the full name after a list, or the bare surname right after it.
        func titled(_ title: String) -> Bool {
            has(title + #"\s+"# + listed + full) || has(title + #"\s+"# + sur + #"(?!\s+[A-Z][a-z])"#)
        }

        // Defendant signals first — they outrank a title.
        let age = full + #",\s+(?:a\s)?\d{2},"#
        let defendantWord = #"(?i:\b(?:co-?)?defendants?)\s+"# + listed + #"(?:(?i:mr|mrs|ms)\.?\s+)?(?:"# + full + "|" + sur + ")"
        let stepAfter = "(?:" + full + "|" + sur + #")(?:,\s+(?:a\s)?\d{2},[^.;]{0,80}?,)?\s+(?i:(?:was|were|has been|had been|have been)\s+(?:\w+\s+){0,2}?(?:sentenced|convicted|indicted|charged|arrested|arraigned|found guilty)|(?:\w+\s+){0,2}?(?:pleaded|pled|pleads|plead)\s+guilty|entered\s+(?:a\s+)?(?:guilty\s+plea|plea\s+of\s+guilty))"#
        let charging = #"(?i:\bcharging|\bindicted|\bsentenced|\bconvicted)\s+"# + listed + full
        if has(age) || has(defendantWord) || has(stepAfter) || has(charging) { return .defendant }

        // Officials.
        let prosecutorTitles = [
            #"(?i:(?:acting\s+|first\s+)?(?:assistant\s+)?(?:united\s+states|u\.\s?s\.)\s+attorneys?(?:\s+general)?)"#,
            #"(?i:(?:assistant\s+)?(?:attorney\s+general|district\s+attorney|state'?s\s+attorney|trial\s+attorneys?|prosecutors?|ausa))"#,
            #"(?i:prosecuted\s+by)"#,
        ]
        if prosecutorTitles.contains(where: titled)
            || has(full + #",?\s+(?i:who\s+(?:is|are|was)\s+(?:handling|prosecuting)\s+the\s+case|is\s+in\s+charge\s+of\s+the\s+prosecution)"#) {
            return .prosecutor
        }
        let judgeTitles = [
            #"(?i:(?:(?:u\.\s?s\.|united\s+states|chief|senior|federal|presiding|circuit|superior|county)\s+)*(?:district\s+(?:court\s+)?|magistrate\s+|circuit\s+|bankruptcy\s+)?judge)"#,
            #"(?i:magistrate|justice)"#,
        ]
        if judgeTitles.contains(where: titled) { return .judge }
        let counselSignals = [
            full + #",?\s+(?i:esq)\b"#,
            #"(?i:represented\s+by|defen[cs]e\s+(?:attorneys?|counsel|lawyers?))\s+"# + listed + full,
            #"(?m)^\s*[A-Z][\w'’\-]+:\s+"# + full + #"[^\n]{0,20}(?i:esq)"#,
            full + #",\s+(?i:(?:an?\s+|the\s+)?(?:attorney|lawyer|counsel)\s+(?:for|representing))"#,
        ]
        if counselSignals.contains(where: has) { return .counsel }
        let agentTitles = [
            #"(?i:(?:acting\s+)?(?:assistant\s+)?special\s+agents?(?:[-\s]+in[-\s]+charge)?)"#,
            #"(?i:(?:fbi|dea|atf|irs|hsi|secret\s+service)\s+(?:special\s+)?agents?|(?:police\s+)?(?:chief|commissioner|inspector|detective|investigator|trooper|sheriff))"#,
            #"(?i:investigated\s+by|under\s+the\s+direction\s+of)"#,
        ]
        if agentTitles.contains(where: titled)
            || has(full + #",\s+(?i:(?:acting\s+)?(?:director|special\s+agent|inspector|chief|commissioner)\b)"#) {
            return .agent
        }
        if has(#"(?i:\bvictims?)\s+"# + full) || has(full + #",\s+(?i:the\s+victim)"#) { return .victim }
        if has(#"(?i:\bwitness(?:es)?)\s+"# + full) || has(full + #"\s+(?i:testified)"#) { return .witness }
        return nil
    }

    /// The role, confirmed or overridden by a verified reading: the reading wins only when its quote
    /// names the person in full, lies verbatim in the document and carries the role's own wording.
    public static func resolve(deterministic: ProceedingRole?, reading: VerifiedRoleReading?) -> ProceedingRole? {
        guard let reading else { return deterministic }
        return reading.role
    }

    // MARK: - patterns

    static func loose(_ token: String) -> String {
        NSRegularExpression.escapedPattern(for: token).replacingOccurrences(of: #"\-"#, with: "-").replacingOccurrences(of: "-", with: #"[\s-]?"#)
    }

    /// The full name, case-insensitive, with middle names or initials between first and last.
    static func fullNamePattern(first: String, last: String) -> String {
        #"(?i:\b"# + loose(first) + #"\b(?:\s+(?:[a-z]\.|[a-z][\w'’\-]*\.?)){0,3}\s+"# + loose(last) + #"\b)"#
    }
}

/// One person's role as a cloud reader stated it, with its verified quote (provenance kept).
public nonisolated struct VerifiedRoleReading: Sendable, Equatable, Codable {
    public let person: String
    public let role: ProceedingRole
    public let quote: String
    public let objectID: UUID
    /// "cloud reader; quote verified verbatim" — who said it and how it was checked.
    public let provenance: String

    public init(person: String, role: ProceedingRole, quote: String, objectID: UUID, provenance: String) {
        self.person = person; self.role = role; self.quote = quote; self.objectID = objectID; self.provenance = provenance
    }
}

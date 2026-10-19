//
//  LegalCaseDomainPack.swift
//  Kalsmritikosh
//
//  Starter pack — the LITIGATION / legal-case domain (the lawyer /
//  forensic / compliance persona). Distinct from ContractDomainPack:
//  contracts are agreements between parties; this pack reads COURT
//  matters — case numbers, courts, plaintiff/defendant, hearing dates.
//  Optional, additive, marker-gated (silent on non-legal text).
//  Deterministic, offline.
//

import Foundation

public enum LegalCaseDomainPack {

    // Live-archive hardening: dropped the loose markers that fire on patent
    // and general correspondence ("hearing", "vs.", " v. ", "tribunal",
    // "adjourned", "court of") — patents have office hearings, and "vs."/
    // "v." appear everywhere. A real litigation document carries a numbered
    // case, named parties, or the court-of formula.
    nonisolated static let markers: [String] = [
        "plaintiff", "defendant", "petitioner", "respondent",
        "case no", "suit no", "in the court of", "hon'ble",
        // Case bench 2026-10-18 — US appellate captions ("Plaintiff-Appellant", "Appellee").
        "appellant", "appellee",
    ]

    nonisolated static func isLegalCase(_ lower: String) -> Bool {
        markers.contains { lower.contains($0) }
    }

    /// caseNumber is an identifier (display constant "Case No."); the rest
    /// are text/date and render their own atom.
    public nonisolated static let emittedFields: [String] =
        ["caseNumber", "court", "plaintiff", "defendant", "hearingDate", "decisionDate", "disposition"]

    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        let lower = text.lowercased()
        // The decision's closing words ("Affirmed.", "Reversed and remanded.") sit in the last
        // block, which rarely carries the caption markers; the end-of-text pattern is strict
        // enough to run without them.
        var facts: [GenericFact] = []
        if let d = disposition(in: text) {
            facts.append(fact(subjectLabel, "disposition", d, blockID, 0.75))
        }
        guard isLegalCase(lower) else { return facts }

        if let v = DomainPackText.labeledIdentifier(after: ["case no", "suit no", "case number", "c.a. no", "w.p. no",
                                                            "docket no", "docket number"], in: text)
            ?? captionDocketNumber(in: text) ?? flowingDocketNumber(in: text) {
            facts.append(fact(subjectLabel, "caseNumber", v, blockID, 0.8))
        }
        if let v = DomainPackText.labeledValue(after: ["in the court of", "court of", "before the", "tribunal"], in: text)
            ?? captionCourtName(in: text) {
            facts.append(fact(subjectLabel, "court", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["plaintiff", "petitioner", "appellant", "complainant"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "plaintiff", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["defendant", "respondent", "accused"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "defendant", v, blockID, 0.7))
        }
        if let raw = DomainPackText.labeledDate(after: ["hearing on", "date of hearing", "listed on", "next hearing", "adjourned to"], in: text),
           let iso = PatentDomainPack.normalizeDate(raw) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "hearingDate", value: iso,
                                     status: .sourceAsserted, confidence: 0.65, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        }
        // The decision date: "Decided July 23, 1993", "Opinion filed August 3, 1971", or the
        // caption's own date line ("August 8, 1924.)"). Case bench 2026-10-18: US decisions
        // carried no decision-date fact at all, so "When was X decided?" had nothing to read.
        if let raw = DomainPackText.labeledDate(after: ["decided", "opinion filed", "date of decision",
                                                        "date of judgment", "judgment dated"], in: text)
            ?? captionDateLine(in: text),
           let iso = PatentDomainPack.normalizeDate(raw), iso.count == 10 {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "decisionDate", value: iso,
                                     status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        }
        return facts
    }

    /// A caption line that is ONLY a docket number: "No. 92-5255." / "Nos. 87-1234, 87-1235".
    /// The whole-line requirement is what keeps "No. 5 of the agreement" out.
    nonisolated static func captionDocketNumber(in text: String) -> String? {
        for raw in text.components(separatedBy: .newlines).prefix(40) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: #"^(?:Nos?\.|Docket)\s*([A-Za-z0-9][A-Za-z0-9/\-]*[0-9][A-Za-z0-9/\-]*)[.,]?(?:\s*(?:,|and)\s*[A-Za-z0-9/\-]+)*\.?$"#,
                                     options: .regularExpression) else { continue }
            let body = line[r].replacingOccurrences(of: #"^(?:Nos?\.|Docket)\s*"#, with: "", options: .regularExpression)
            let first = body.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" }
            if first.count >= 3, first.contains(where: \.isNumber) { return String(first) }
        }
        return nil
    }

    /// The docket number when the block's line breaks were normalized away: "No. 92-5255"
    /// near the start of a legal block. A hyphenated court number ("92-5255", "3:06-cv-00862")
    /// is what separates it from "No. 5 of the agreement".
    nonisolated static func flowingDocketNumber(in text: String) -> String? {
        let head = String(text.prefix(800))
        let pattern = #"\bNos?\.\s+((?:\d{1,2}:)?\d{1,4}[-–](?:[A-Za-z]{2}[-–])?\d{2,6}(?:[-–][0-9A-Za-z]+)*)"#
        guard let r = head.range(of: pattern, options: .regularExpression) else { return nil }
        return head[r].replacingOccurrences(of: #"^Nos?\.\s+"#, with: "", options: .regularExpression)
    }

    /// A US court as a caption names it: "United States Court of Appeals, District of Columbia
    /// Circuit", "District Court, D. Tennessee", "Supreme Court of Pennsylvania". Case bench
    /// 2026-10-18: the labeled rule above expects "In the Court of …", so US captions gave none.
    nonisolated static func captionCourtName(in text: String) -> String? {
        let head = String(text.prefix(1200))
        let pattern = #"(?:United States |U\.\s?S\. )?(?:Circuit Court of Appeals|Court of Appeals|District Court|Supreme Court|Court of Claims|Tax Court|Court of Criminal Appeals|Appellate Court|Superior Court|Bankruptcy Court)(?:,? (?:for the |of the |of )?[A-Z][A-Za-z.]*(?: (?:of )?[A-Z][A-Za-z.]*){0,5})?"#
        guard let r = head.range(of: pattern, options: .regularExpression) else { return nil }
        // A period after a full word ends the name ("… Circuit. Argued"); initials keep it
        // ("District Court, D. Tennessee").
        let v = String(head[r])
            .replacingOccurrences(of: #"([A-Za-z]{3,})\..*$"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        return v.count >= 10 ? v : nil
    }

    /// The disposition in a decision's closing words: "Affirmed.", "Reversed and remanded.",
    /// "The judgment of the district court is AFFIRMED." → "affirmed", "reversed and remanded".
    /// Only the LAST sentence is read, and only a sentence made of disposition words (optionally
    /// "The judgment … is"), so prose that merely mentions "affirmed" never matches.
    nonisolated static func disposition(in text: String) -> String? {
        let tail = text.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        var last = tail
        if let cut = tail.dropLast().range(of: #"[.!?]\s+(?=[A-Z])"#, options: [.regularExpression, .backwards]) {
            last = String(tail[cut.upperBound...])
        }
        let verbs = "affirmed|reversed|vacated|remanded|dismissed|modified"
        let pattern = "^(?:(?:the )?(?:judgments?|orders?|decisions?|convictions?|sentences?)[^.]{0,120}? (?:is|are|be) )?((?:\(verbs))(?:(?: in part)?(?:,? and|,)(?: in part)? (?:\(verbs)))*(?: in part)?)\\.?$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = last as NSString
        guard let m = re.firstMatch(in: last, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).lowercased()
    }

    /// A caption line that is ONLY a date ("August 8, 1924.)"), among the first lines.
    nonisolated static func captionDateLine(in text: String) -> String? {
        for raw in text.components(separatedBy: .newlines).prefix(25) {
            let line = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".()[]")))
            guard line.count <= 22, let d = DomainPackText.firstDate(in: line), d.count >= line.count - 1 else { continue }
            return d
        }
        return nil
    }

    nonisolated static func fact(_ subject: String, _ field: String, _ value: String,
                                 _ block: UUID, _ conf: Double) -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }
}

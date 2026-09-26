//
//  DocumentClassifier.swift
//  Kalsmritikosh
//
//  Rule-based MVP — tags KnowledgeObjects with their likely document
//  class (email, invoice, contract, meeting notes, research, resume,
//  receipt, image, audio). M3 swaps in a model-based classifier via
//  ModelRegistry when latency budget allows.
//

import Foundation

public enum DocumentClass: String, Codable, CaseIterable, Sendable {
    case email
    case invoice
    case contract
    case meetingNotes
    case researchPaper
    case resume
    case receipt
    case image
    case audio
    case video
    case spreadsheet
    case presentation
    /// V4 (D-17 Part A) — a legal/official proceeding document (patent office
    /// letter, hearing notice, power of attorney…). The legal event extractor
    /// is PRIMARY here; commercial boilerplate markers never fire (EV-1).
    case legalDocument
    /// V4 (D-17 Part A) — a certificate (grant certificate, registration…).
    /// Conservative by ruling: only unambiguous certificate language classifies.
    case certificate
    case other
}

public struct DocumentClassifier: Sendable {
    public nonisolated init() {}

    public nonisolated func classify(_ object: KnowledgeObject) -> DocumentClass {
        switch object.sourceType.category {
        case .email: return .email
        case .image: return .image
        case .audio: return .audio
        case .video: return .video
        case .spreadsheet: return .spreadsheet
        case .presentation: return .presentation
        default: break
        }

        let body = object.content.lowercased()

        // L3 (2026-09-26) — SCORED, WORD-BOUNDED classification. The first
        // version took the first class with any substring hit, and "vat"
        // matched inside "private" and "motivated": 16 of 25 résumés on the
        // owner's archive were filed as invoices, two as research papers (a
        // "References" section). Now every class counts its distinct markers
        // as whole words/phrases; the highest count wins; a tie keeps the
        // historical priority order (legal before commercial — EV-1).
        var best: (cls: DocumentClass, score: Int)? = nil
        for (cls, markers) in Self.markerTable {
            let score = markers.reduce(0) { $0 + (Self.containsPhrase(body, $1) ? 1 : 0) }
            guard score > 0 else { continue }
            if best == nil || score > best!.score { best = (cls, score) }
        }
        return best?.cls ?? .other
    }

    /// Classes in PRIORITY order (a tie resolves to the earlier entry), each
    /// with the markers a document of that class states about itself.
    nonisolated static let markerTable: [(DocumentClass, [String])] = [
        (.legalDocument, [
            "the patents act", "controller of patents", "the patent office",
            "form of authorization of an agent", "hearing notice",
            "patent rules, 2003", "ld. controller",
            "intellectual property office", "letter of grant", "register of patents",
            "application for patent", "date of grant",
        ]),
        (.certificate, [
            "this is to certify", "certificate of grant", "certificate of registration",
            "certificate no.", "certificate number",
        ]),
        (.invoice, [
            "invoice number", "invoice no", "amount due", "subtotal", "vat",
            "bill to", "payable to", "tax invoice", "gstin", "hsn",
        ]),
        (.contract, [
            "this agreement", "party of the first part", "in witness whereof",
            "non-disclosure", "scope of work", "terms and conditions",
        ]),
        (.meetingNotes, [
            "minutes of meeting", "attendees", "agenda", "action items",
            "decisions taken",
        ]),
        (.researchPaper, [
            "abstract", "references", "doi:", "isbn", "we propose", "experimental setup",
        ]),
        (.resume, [
            "professional experience", "education", "skills", "curriculum vitae",
            "curriculam vitae", "curriculam-vitae", "curriculum-vitae", "resume", "bio-data", "biodata",
            "objective:", "career objective", "work experience", "date of birth",
            "marital status", "nationality", "hobbies", "declaration", "linkedin.com/in",
            "present employer", "total experience", "current ctc", "expected ctc",
        ]),
        (.receipt, [
            "thank you for your purchase", "receipt", "total amount", "subtotal",
        ]),
    ]

    /// A marker matches as a whole word or phrase — never inside another word.
    nonisolated static func containsPhrase(_ body: String, _ marker: String) -> Bool {
        var searchStart = body.startIndex
        while let r = body.range(of: marker, range: searchStart..<body.endIndex) {
            let beforeOK = r.lowerBound == body.startIndex
                || !(body[body.index(before: r.lowerBound)].isLetter || body[body.index(before: r.lowerBound)].isNumber)
            let afterOK = r.upperBound == body.endIndex
                || !(body[r.upperBound].isLetter || body[r.upperBound].isNumber)
            if beforeOK && afterOK { return true }
            searchStart = body.index(after: r.lowerBound)
        }
        return false
    }

    private nonisolated func matchesAny(_ body: String, _ markers: [String]) -> Bool {
        for m in markers where body.contains(m) { return true }
        return false
    }
}

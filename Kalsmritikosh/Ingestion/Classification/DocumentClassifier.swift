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

        // V4 — legal/certificate BEFORE invoice/contract: a patent-office letter
        // routinely mentions fees and agreement language, which would otherwise
        // misclassify it commercially and invite boilerplate events (EV-1).
        // Markers are conservative — official-proceeding phrasings only.
        if matchesAny(body, [
            "the patents act", "controller of patents", "the patent office",
            "form of authorization of an agent", "hearing notice",
            "patent rules, 2003", "ld. controller",
            "intellectual property office", "letter of grant", "register of patents",
            "application for patent", "date of grant"
        ]) { return .legalDocument }

        if matchesAny(body, [
            "this is to certify", "certificate of grant", "certificate of registration",
            "certificate no.", "certificate number"
        ]) { return .certificate }

        if matchesAny(body, [
            "invoice number", "invoice no", "amount due", "subtotal", "vat",
            "bill to", "payable to"
        ]) { return .invoice }

        if matchesAny(body, [
            "this agreement", "party of the first part", "in witness whereof",
            "non-disclosure", "scope of work", "terms and conditions"
        ]) { return .contract }

        if matchesAny(body, [
            "minutes of meeting", "attendees", "agenda", "action items",
            "decisions taken"
        ]) { return .meetingNotes }

        if matchesAny(body, [
            "abstract", "references", "doi:", "isbn", "we propose", "experimental setup"
        ]) { return .researchPaper }

        if matchesAny(body, [
            "professional experience", "education", "skills", "curriculum vitae",
            "objective:", "linkedin.com/in"
        ]) { return .resume }

        if matchesAny(body, [
            "thank you for your purchase", "receipt", "total amount", "subtotal"
        ]) { return .receipt }

        return .other
    }

    private nonisolated func matchesAny(_ body: String, _ markers: [String]) -> Bool {
        for m in markers where body.contains(m) { return true }
        return false
    }
}

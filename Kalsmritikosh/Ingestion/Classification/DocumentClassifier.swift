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

//
//  IdentityFieldResolver.swift
//  Kalsmritikosh
//
//  MMI-FINAL — the deterministic identity-answer resolver. It maps an identity/document
//  question to the field type it asks for, then answers from the located typed fields:
//  ONE dominant value → a deterministic answer (0 generative calls); several distinct located
//  values → CANDIDATES (never a guess); none → not found. It never invents a value and never
//  silently picks a winner between conflicting sources.
//

import Foundation

/// The outcome of resolving an identity question against located typed fields.
public nonisolated enum IdentityResolution: Sendable, Equatable {
    /// No located value clears the confidence floor.
    case notFound
    /// Exactly one distinct value — answered deterministically from this located field.
    case answer(TypedField)
    /// Several distinct located values — surfaced as candidates (highest-confidence per value),
    /// never resolved to one.
    case ambiguous([TypedField])
}

public nonisolated struct IdentityFieldResolver: Sendable {
    public init() {}

    /// A located value must clear this confidence to be answerable deterministically. The
    /// low-confidence title-name heuristic (≈0.45) stays below it, so a header is never asserted.
    public static let confidenceFloor = 0.5

    /// Map an identity/document question to the field type it asks for (nil = not one).
    public static func questionFieldType(_ question: String) -> TypedFieldType? {
        let q = question.lowercased()
        func any(_ ks: [String]) -> Bool { ks.contains { q.contains($0) } }
        // Most specific first so "date of issue" isn't swallowed by "date"/"name".
        if any(["date of birth", "d.o.b", " dob", "birth date"]) { return .dateOfBirth }
        if any(["date of issue", "issue date", "issued on", "date issued", "when was it issued", "when was this issued"]) { return .issueDate }
        if any(["expiry", "expiration", "valid until", "valid upto", "valid up to", "when does it expire", "expire"]) { return .expiryDate }
        if any(["document number", "passport number", "passport no", "id number", "licence number", "license number", "card number", "document no"]) { return .documentNumber }
        if any(["invoice number", "invoice no"]) { return .invoiceNumber }
        if any(["reference number", "reference no", "ref no"]) { return .referenceNumber }
        if any(["account number", "account no", "iban"]) { return .accountIdentifier }
        if any(["pan number", " pan", "gstin", "tax id", "tax identifier", "national id", "ssn"]) { return .taxIdentifier }
        if any(["email address", "e-mail", "email"]) { return .email }
        if any(["phone number", "phone", "mobile number", "contact number"]) { return .phone }
        if any(["organization", "organisation", "company", "issued by", "issuing authority"]) { return .organizationName }
        if any(["address"]) { return .address }
        if any(["what is the name", "the name in", "name in this", "name on this", "whose name",
                "who is this document for", "who is this for", "person's name", "name of the holder",
                "holder name", "name of person"]) { return .personName }
        return nil
    }

    /// Resolve a field type against located fields.
    public func resolve(fieldType: TypedFieldType, fields: [TypedField]) -> IdentityResolution {
        let matching = fields
            .filter { $0.fieldType == fieldType && $0.confidence >= Self.confidenceFloor }
            .sorted { $0.confidence > $1.confidence }
        guard !matching.isEmpty else { return .notFound }
        let byValue = Dictionary(grouping: matching, by: { $0.normalizedValue })
        if byValue.count == 1 { return .answer(matching[0]) }
        // Several distinct values → one representative (highest confidence) per value, ordered.
        let representatives = byValue.values
            .compactMap { $0.max(by: { $0.confidence < $1.confidence }) }
            .sorted { ($0.confidence, $0.normalizedValue) > ($1.confidence, $1.normalizedValue) }
        return .ambiguous(representatives)
    }

    /// A neutral human label for a field type (for the deterministic answer prose).
    public static func label(_ type: TypedFieldType) -> String {
        switch type {
        case .personName:        return "name"
        case .organizationName:  return "organization"
        case .documentNumber:    return "document number"
        case .dateOfBirth:       return "date of birth"
        case .issueDate:         return "date of issue"
        case .expiryDate:        return "expiry date"
        case .address:           return "address"
        case .email:             return "email"
        case .phone:             return "phone number"
        case .amount:            return "amount"
        case .currency:          return "currency"
        case .invoiceNumber:     return "invoice number"
        case .referenceNumber:   return "reference number"
        case .accountIdentifier: return "account number"
        case .taxIdentifier:     return "tax identifier"
        case .other:             return "field"
        }
    }
}

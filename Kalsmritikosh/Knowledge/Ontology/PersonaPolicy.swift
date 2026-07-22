//
//  PersonaPolicy.swift
//  Kalsmritikosh
//
//  PER-001 — a versioned PersonaPolicy registry. A persona controls PRESENTATION and
//  workflow defaults only: terminology, evidence requirements for a work product, citation
//  style, review warnings, and sharing/redaction defaults. It NEVER controls evidence, the
//  truth state of a fact, confidence, contradiction logic, or whether a source is
//  independent (locked contract §3). That invariant is enforced structurally here: the
//  policy type simply has no field that could change truth, and every persona shares the
//  same evidence ledger.
//
//  Deterministic, offline. Versioned so a work product can record which policy produced it.
//

import Foundation

public struct PersonaPolicy: Sendable, Hashable {
    public let template: WorkspaceTemplate
    public let version: Int
    /// Domain wording, e.g. "matter"/"case"/"story"/"study" for the same underlying corpus.
    public let subjectNoun: String
    /// Minimum supporting evidence blocks a MATERIAL claim needs before it ships in this
    /// persona's work products (presentation strictness — not a truth change).
    public let minEvidencePerMaterialClaim: Int
    /// Whether this persona's default work products require corroboration for key claims.
    public let requiresCorroboration: Bool
    public let citationStyle: CitationStyle
    /// Redact sensitive values by default when sharing/exporting (individual/journalism lean on).
    public let redactByDefault: Bool
    /// Neutral review warnings surfaced to the user for this persona.
    public let reviewWarnings: [String]

    public enum CitationStyle: String, Sendable, Hashable {
        case inline          // [src abc123]
        case footnote        // ¹ … with a references block
        case legalPin        // Doc, p.n
        case bibliographic   // Author, Title, Year
    }

    public nonisolated init(template: WorkspaceTemplate, version: Int, subjectNoun: String,
                            minEvidencePerMaterialClaim: Int, requiresCorroboration: Bool,
                            citationStyle: CitationStyle, redactByDefault: Bool,
                            reviewWarnings: [String]) {
        self.template = template
        self.version = version
        self.subjectNoun = subjectNoun
        self.minEvidencePerMaterialClaim = minEvidencePerMaterialClaim
        self.requiresCorroboration = requiresCorroboration
        self.citationStyle = citationStyle
        self.redactByDefault = redactByDefault
        self.reviewWarnings = reviewWarnings
    }
}

public enum PersonaPolicyRegistry {
    /// Bump when any policy changes so work products can record provenance.
    public nonisolated static let version = 1

    public nonisolated static func policy(for template: WorkspaceTemplate) -> PersonaPolicy {
        switch template {
        case .legalMatter:
            return PersonaPolicy(template: template, version: version, subjectNoun: "matter",
                minEvidencePerMaterialClaim: 2, requiresCorroboration: true, citationStyle: .legalPin,
                redactByDefault: false,
                reviewWarnings: ["Not legal advice.", "Verify every citation opens the exact source."])
        case .investigation:
            return PersonaPolicy(template: template, version: version, subjectNoun: "case",
                minEvidencePerMaterialClaim: 2, requiresCorroboration: true, citationStyle: .inline,
                redactByDefault: true,
                reviewWarnings: ["A missing record is not proof of wrongdoing.",
                                 "Duplicate copies are not independent corroboration."])
        case .journalism:
            return PersonaPolicy(template: template, version: version, subjectNoun: "story",
                minEvidencePerMaterialClaim: 2, requiresCorroboration: true, citationStyle: .footnote,
                redactByDefault: true,
                reviewWarnings: ["Seek right-of-reply for claims about people.",
                                 "Attribute each claim to its source."])
        case .researchReview:
            return PersonaPolicy(template: template, version: version, subjectNoun: "study",
                minEvidencePerMaterialClaim: 1, requiresCorroboration: false, citationStyle: .bibliographic,
                redactByDefault: false,
                reviewWarnings: ["Distinguish primary sources from commentary."])
        case .personalMatter:
            return PersonaPolicy(template: template, version: version, subjectNoun: "records",
                minEvidencePerMaterialClaim: 1, requiresCorroboration: false, citationStyle: .inline,
                redactByDefault: true,
                reviewWarnings: ["Redaction is on by default when sharing."])
        case .general:
            return PersonaPolicy(template: template, version: version, subjectNoun: "collection",
                minEvidencePerMaterialClaim: 1, requiresCorroboration: false, citationStyle: .inline,
                redactByDefault: false, reviewWarnings: [])
        }
    }
}

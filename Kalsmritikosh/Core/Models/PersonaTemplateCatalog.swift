//
//  PersonaTemplateCatalog.swift
//  Kalsmritikosh
//
//  Persona features (F6). A template changes DEFAULT fields, suggested
//  tags, view names, terminology, and the disclaimer shown on exports —
//  it must NOT change the truth model, evidence rules, or LLM safety rules.
//  This catalog is therefore pure presentation data: the stored review
//  semantics (ReviewState / ReviewTarget) remain shared across personas.
//
//  Values are transcribed from the research-grounded persona instructions
//  (§11). Disclaimers are load-bearing safety text and must ship verbatim.
//

import Foundation

public enum PersonaTemplateCatalog {

    /// Suggested default tags seeded when a workspace of this template is
    /// created. The user can add/remove freely; these are only starters.
    public static func defaultTags(for template: WorkspaceTemplate) -> [String] {
        switch template {
        case .general:
            return []
        case .legalMatter:
            return ["responsive", "notResponsive", "key", "privilegeCandidate",
                    "workProductCandidate", "witness", "exhibit", "damages",
                    "liability", "timeline", "followUp"]
        case .investigation:
            return ["lead", "confirmed", "disputed", "subject", "associate",
                    "location", "financial", "communication", "custody", "followUp"]
        case .journalism:
            return ["finding", "confirmed", "singleSource", "needsCorroboration",
                    "needsResponse", "rightOfReply", "background", "quote",
                    "dataPoint", "publicationCandidate", "sensitive"]
        case .researchReview:
            return ["candidate", "include", "exclude", "duplicate", "awaitingFullText",
                    "background", "primarySource", "secondarySource", "method",
                    "result", "limitation", "citationChecked"]
        case .personalMatter:
            return []
        }
    }

    /// Suggested view names for the workspace's overview navigation (§11).
    public static func defaultViewTitles(for template: WorkspaceTemplate) -> [String] {
        switch template {
        case .general:
            return ["Timeline", "Findings", "Contradictions", "Missing Evidence"]
        case .legalMatter:
            return ["Chronology", "Witness dossiers", "Issue views", "Privilege candidates",
                    "Potential exhibits", "Contradictions", "Missing documents"]
        case .investigation:
            return ["Subject dossier", "Connection map", "Chronology", "Contradictions",
                    "Unresolved leads", "Evidence inventory", "Technical custody log"]
        case .journalism:
            return ["Findings and sources", "Single-source claims", "Needs response",
                    "Paper trail", "People trail", "Chronology", "Data issues", "Reporting gaps"]
        case .researchReview:
            return ["Screening log", "Included", "Excluded", "Awaiting full text",
                    "Extraction table", "Citation audit"]
        case .personalMatter:
            return ["Important dates", "Payments and amounts", "People and organizations",
                    "Documents requiring action", "Contradictions", "Missing records"]
        }
    }

    /// The disclaimer shown on this template's work products and exports.
    /// SAFETY TEXT — ships verbatim from §11. Never soften or omit.
    public static func disclaimer(for template: WorkspaceTemplate) -> String {
        switch template {
        case .general:
            return "Kalsmritikosh organizes and summarizes the records you supply, with a source for each finding. It does not provide professional advice."
        case .legalMatter:
            return "Kalsmritikosh flags candidates and organizes source material. It does not determine privilege, admissibility, legal relevance, or legal conclusions."
        case .investigation:
            return "The report summarizes and links user-supplied records. It does not certify evidence, perform surveillance, determine legality, or guarantee admissibility."
        case .journalism:
            return "Kalsmritikosh analyzes documents you supply. It does not perform live OSINT, scraping, FOIA filing, publishing, or source communication."
        case .researchReview:
            return "Single-user v1 provides a transparent screening log and PRISMA-compatible counts. It does not claim independent dual-review compliance, statistical meta-analysis, or final risk-of-bias judgment."
        case .personalMatter:
            return "Record organization only. Not medical, tax, legal, or insurance advice, diagnosis, or coverage determination."
        }
    }

    /// Export work products this template offers (§11). Used by F3/F4 UIs to
    /// present the right starting set; all reuse the shared export engine.
    public static func exportKinds(for template: WorkspaceTemplate) -> [String] {
        switch template {
        case .general:
            return ["General sourced summary", "Chronology report", "Source index"]
        case .legalMatter:
            return ["Chronology table", "Fact memo", "Privilege-candidate log",
                    "Witness summary", "Exhibit index", "Document review CSV"]
        case .investigation:
            return ["Findings report", "Subject dossier", "Timeline",
                    "Contradiction matrix", "Evidence index", "Technical provenance log"]
        case .journalism:
            return ["Fact-check sheet", "Source matrix", "Annotated draft",
                    "Right-of-reply question list", "Reporting-gap list", "Document appendix"]
        case .researchReview:
            return ["Screening log", "Inclusion/exclusion CSV", "PRISMA-compatible counts",
                    "Extraction table", "BibTeX", "RIS", "CSL-JSON", "Claim-source audit"]
        case .personalMatter:
            return ["Personal matter summary", "Medical visit chronology", "Payment table",
                    "Insurance/contract key-date sheet", "Family archive timeline", "Source index"]
        }
    }
}

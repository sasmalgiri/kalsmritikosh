//
//  ResearchAppraisal.swift
//  Kalsmritikosh
//
//  The recognized frameworks a researcher / evidence-synthesiser reports against:
//  PRISMA for how studies were screened into the review, and GRADE for the
//  certainty of the resulting body of evidence. An extraction table that reports
//  neither leaves the reader unable to judge how complete or how strong the
//  synthesis is.
//
//  Pure reference value (no schema, no engine); the extraction-table DataLab
//  template surfaces it so screening and certainty are stated, not implied.
//

import Foundation

/// GRADE certainty of a body of evidence.
public nonisolated enum GRADECertainty: String, Codable, Sendable, CaseIterable, Equatable {
    case high, moderate, low, veryLow

    public var label: String {
        switch self {
        case .high:     return "High"
        case .moderate: return "Moderate"
        case .low:      return "Low"
        case .veryLow:  return "Very low"
        }
    }
    public var detail: String {
        switch self {
        case .high:     return "Very confident the true effect lies close to the estimate."
        case .moderate: return "Moderately confident; the true effect is likely close, but may differ."
        case .low:      return "Confidence is limited; the true effect may be substantially different."
        case .veryLow:  return "Very little confidence; the estimate is highly uncertain."
        }
    }
}

public nonisolated struct PRISMAStage: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public init(id: String, title: String, detail: String) {
        self.id = id; self.title = title; self.detail = detail
    }
}

public nonisolated enum ResearchAppraisal {

    /// PRISMA-style flow: how records move from found to included.
    public static let prismaStages: [PRISMAStage] = [
        .init(id: "identification", title: "Identification", detail: "Records found across sources, with duplicates removed."),
        .init(id: "screening", title: "Screening", detail: "Titles/abstracts screened; records excluded with reasons."),
        .init(id: "eligibility", title: "Eligibility", detail: "Full texts assessed against inclusion criteria; exclusions recorded with reasons."),
        .init(id: "included", title: "Included", detail: "Studies that met the criteria and entered the synthesis.")
    ]

    public static let gradeLevels = GRADECertainty.allCases

    /// One-line summary for a field's help / template note.
    public static var helpSummary: String {
        let prisma = prismaStages.map(\.title).joined(separator: " → ")
        let grade = gradeLevels.map(\.label).joined(separator: " / ")
        return "PRISMA stages: \(prisma). GRADE certainty: \(grade)."
    }

    public static let disciplineNote =
        "Record the screening at each PRISMA stage (with reasons for exclusion) and rate the certainty of the body of evidence (GRADE)."
}

//
//  InvestigationDataLabPreset.swift
//  Kalsmritikosh
//
//  INV-01-C3 — code-backed Investigator DataLab presets. A preset is a RECIPE over the shared Workbench
//  (LAB-001…006): a stable id, plain-language framing, the canonical evidence surfaces it draws from, and
//  the field shape of the prepared dataset. It is configuration only — it defines no dataset identity,
//  persistence, transformation model, or lineage representation of its own; the InvestigationDataLabService
//  compiles a preset into a real WorkbenchDataset whose inputs are restricted to the active case's
//  authorized source scope. A preset may legitimately yield an empty-but-valid dataset when the case holds
//  no matching authorized evidence — it never widens to the workspace to fill rows.
//

import Foundation

/// One field of a preset dataset: a name + the shared Workbench value shape it will be created with.
public nonisolated struct InvestigationDataLabField: Sendable, Equatable {
    public let name: String
    public let valueShape: FactSchemaRegistry.ValueShape
    public nonisolated init(_ name: String, _ valueShape: FactSchemaRegistry.ValueShape) {
        self.name = name; self.valueShape = valueShape
    }
}

public nonisolated struct InvestigationDataLabPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let purpose: String
    /// The canonical evidence surfaces the preset draws from (descriptive; the service enforces scope).
    public let requiredSurfaces: [String]
    public let fields: [InvestigationDataLabField]
    public let limitations: [String]

    public nonisolated init(id: String, displayName: String, purpose: String,
                            requiredSurfaces: [String], fields: [InvestigationDataLabField], limitations: [String]) {
        self.id = id; self.displayName = displayName; self.purpose = purpose
        self.requiredSurfaces = requiredSurfaces; self.fields = fields; self.limitations = limitations
    }

    public nonisolated var fieldNames: [String] { fields.map(\.name) }
}

/// The nine INV-01 presets over the shared Workbench.
public nonisolated enum InvestigationDataLabPresetCatalog {

    public static let sourceInventory = InvestigationDataLabPreset(
        id: "inv.datalab.source-inventory", displayName: "Source overview",
        purpose: "Every source authorized for this investigation, with its readiness and scope status.",
        requiredSurfaces: ["sourceVersion"],
        fields: [.init("sourceVersion", .identifier), .init("sourceName", .text), .init("sourceType", .text),
                 .init("readiness", .text), .init("date", .date), .init("scopeStatus", .text),
                 .init("sensitiveStatus", .text), .init("extractionStatus", .text), .init("warnings", .text)],
        limitations: ["Lists only sources inside this investigation's scope; never the whole workspace."])

    public static let timeline = InvestigationDataLabPreset(
        id: "inv.datalab.timeline", displayName: "Timeline",
        purpose: "Dated events drawn from authorized sources, preserving precision and uncertainty.",
        requiredSurfaces: ["event", "evidenceBlock", "sourceVersion"],
        fields: [.init("date", .date), .init("precision", .text), .init("event", .text),
                 .init("sourceVersion", .identifier), .init("evidenceBlock", .identifier), .init("status", .text)],
        limitations: ["Unknown dates stay unknown; conflicting dates are shown, not averaged."])

    public static let peopleOrganizations = InvestigationDataLabPreset(
        id: "inv.datalab.people-organizations", displayName: "People & organizations",
        purpose: "Entities observed in authorized sources with their provenance.",
        requiredSurfaces: ["entity", "relationship", "sourceVersion"],
        fields: [.init("entity", .identifier), .init("label", .text), .init("kind", .text),
                 .init("status", .text), .init("sourceVersion", .identifier)],
        limitations: ["Identities are never merged on matching labels alone; resolution stays human-gated."])

    public static let communications = InvestigationDataLabPreset(
        id: "inv.datalab.communications", displayName: "Communications",
        purpose: "Messages between parties, drawn from authorized sources.",
        requiredSurfaces: ["event", "entity", "evidenceBlock", "sourceVersion"],
        fields: [.init("date", .date), .init("sender", .text), .init("recipients", .text),
                 .init("subject", .text), .init("sourceVersion", .identifier)],
        limitations: ["Only communications evidenced in authorized sources appear."])

    public static let transactions = InvestigationDataLabPreset(
        id: "inv.datalab.transactions", displayName: "Transactions",
        purpose: "Amounts and parties, with calculation provenance and missing legs surfaced.",
        requiredSurfaces: ["evidenceBlock", "sourceVersion"],
        fields: [.init("date", .date), .init("amount", .money), .init("direction", .text),
                 .init("parties", .text), .init("sourceVersion", .identifier), .init("missingLegs", .text)],
        limitations: ["A calculated amount is deterministically derived, never presented as source-observed."])

    public static let contradictions = InvestigationDataLabPreset(
        id: "inv.datalab.contradictions", displayName: "Contradictions",
        purpose: "Conflicting propositions with the evidence on each side, drawn from authorized sources.",
        requiredSurfaces: ["contradiction", "evidenceBlock", "sourceVersion"],
        fields: [.init("contradiction", .identifier), .init("sideA", .text), .init("sideB", .text),
                 .init("evidence", .text), .init("status", .text)],
        limitations: ["Every conflicting side is preserved; the app never decides which side wins."])

    public static let gaps = InvestigationDataLabPreset(
        id: "inv.datalab.gaps", displayName: "Missing evidence",
        purpose: "What is missing, why it matters, and any collection action — never a guessed value.",
        requiredSurfaces: ["gap"],
        fields: [.init("gap", .identifier), .init("missing", .text), .init("whyItMatters", .text),
                 .init("requiredBy", .text), .init("collectionAction", .text), .init("status", .text)],
        limitations: ["A gap is never filled with a guessed value; acquiring a source still requires intake + authorization."])

    public static let evidenceMatrix = InvestigationDataLabPreset(
        id: "inv.datalab.evidence-matrix", displayName: "Evidence matrix",
        purpose: "Questions/hypotheses against supporting, opposing and missing evidence.",
        requiredSurfaces: ["claim", "evidenceBlock", "sourceVersion"],
        fields: [.init("question", .text), .init("supporting", .text), .init("opposing", .text),
                 .init("missing", .text), .init("independence", .text), .init("reviewState", .text)],
        limitations: ["Duplicate copies are not independent corroboration; the app never decides which side wins."])

    public static let relationships = InvestigationDataLabPreset(
        id: "inv.datalab.relationships", displayName: "Relationships",
        purpose: "Connections between entities, each carrying its evidence provenance.",
        requiredSurfaces: ["relationship", "entity", "sourceVersion"],
        fields: [.init("from", .identifier), .init("to", .identifier), .init("kind", .text),
                 .init("evidence", .text), .init("sourceVersion", .identifier)],
        limitations: ["Each edge cites evidence from an authorized source; nothing is inferred without it."])

    public static let all: [InvestigationDataLabPreset] = [
        sourceInventory, timeline, peopleOrganizations, communications, transactions,
        contradictions, gaps, evidenceMatrix, relationships,
    ]

    public static func preset(id: String) -> InvestigationDataLabPreset? { all.first { $0.id == id } }
}

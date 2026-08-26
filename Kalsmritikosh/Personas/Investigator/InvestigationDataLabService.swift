//
//  InvestigationDataLabService.swift
//  Kalsmritikosh
//
//  INV-01-C3 — the real Investigator DataLab entry point. Orchestration only: it compiles an Investigator
//  preset into a SHARED WorkbenchDataset whose inputs are restricted to the active case's authorized
//  source scope (∩ SensitiveScope). No InvestigatorDataLab / dataset repository / transformation or
//  scenario engine / lineage store — everything persists through the shared WorkbenchDatasetRepository
//  with exact canonical source bindings. Case→source-version semantics reuse the ONE
//  CaseRetrievalScopeResolver (B2/C1/C2), so Ask, Methods and DataLab all inherit the same authorization.
//
//  Hard boundary: a case-prepared dataset can bind only source versions in the case's authorized set that
//  are also permitted by the active SensitiveScope. An unauthorized source is structurally absent — it is
//  never in the iterated set — so it cannot enter the dataset, a saved view, or (later) a transformation
//  or scenario. When no authorized source is eligible the dataset is empty-but-valid; the service never
//  widens to the workspace to populate rows.
//
//  Durable case↔dataset association + the canonical scope fingerprint are INV-01-C4; this returns the
//  association in-memory. The dataset itself persists through the shared repo and reopens by id.
//

import Foundation
import OSLog

public nonisolated struct InvestigationDataset: Sendable {
    public let caseID: UUID
    public let presetID: String
    public let scope: RetrievalSourceScope
    public let dataset: WorkbenchDatasetRecord
    /// The authorized source versions actually included (deterministic order).
    public let includedSourceVersionIDs: [UUID]
    /// Authorized versions withheld because the active SensitiveScope did not permit them (case ∩ scope).
    public let withheldBySensitivity: Int

    public nonisolated init(caseID: UUID, presetID: String, scope: RetrievalSourceScope,
                            dataset: WorkbenchDatasetRecord, includedSourceVersionIDs: [UUID], withheldBySensitivity: Int) {
        self.caseID = caseID; self.presetID = presetID; self.scope = scope; self.dataset = dataset
        self.includedSourceVersionIDs = includedSourceVersionIDs; self.withheldBySensitivity = withheldBySensitivity
    }
}

public nonisolated enum InvestigationDataLabError: Error, Sendable, Equatable {
    case caseNotFound(UUID)
    case unknownPreset(String)
    case presetFieldMissing(String)
}

public actor InvestigationDataLabService {
    private let cases: InvestigationCaseRepository
    private let resolver: CaseRetrievalScopeResolver
    private let datasets: WorkbenchDatasetRepository
    private let scopes: SensitiveScopeRepository

    /// PHASE B-2 (v115) — records that the dataLab phase produced a dataset
    /// for the case, so the conformance assessor can OBSERVE the phase.
    private let artifacts: CasePhaseArtifactRepository?

    public init(cases: InvestigationCaseRepository, resolver: CaseRetrievalScopeResolver,
                datasets: WorkbenchDatasetRepository, scopes: SensitiveScopeRepository,
                artifacts: CasePhaseArtifactRepository? = nil) {
        self.cases = cases; self.resolver = resolver; self.datasets = datasets; self.scopes = scopes
        self.artifacts = artifacts
    }

    public nonisolated func presets() -> [InvestigationDataLabPreset] { InvestigationDataLabPresetCatalog.all }

    /// The eligible source versions for a case: authorized by scope AND permitted by the active
    /// SensitiveScope. Deterministic order. Returns (eligible, withheldBySensitivity).
    public func eligibleSourceVersions(caseID: UUID, access: SensitiveAccessContext) async throws -> (included: [UUID], withheld: Int) {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDataLabError.caseNotFound(caseID) }
        let scope = try await resolver.scope(for: record)
        var included: [UUID] = []
        var withheld = 0
        for version in scope.authorizedSourceVersionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let resolution = try await scopes.effectiveLabel(for: SensitiveScopeTarget(kind: .sourceVersion, id: version))
            switch resolution {
            case .brokenLineage:
                withheld += 1                                   // fail-closed: unresolved sensitivity is withheld
            case .resolved(let label):
                if access.scope.permits(label) { included.append(version) } else { withheld += 1 }
            }
        }
        return (included, withheld)
    }

    /// Prepare the foundational Source Inventory dataset: one row per eligible (case-authorized ∩
    /// SensitiveScope-permitted) source version, each bound via a `.sourceVersion` drill-through. An
    /// unauthorized source is never iterated, so it cannot appear. Empty-but-valid when nothing is eligible.
    public func prepareSourceInventory(caseID: UUID, access: SensitiveAccessContext,
                                       actor: String, at date: Date) async throws -> InvestigationDataset {
        guard let record = try await cases.fetch(caseID: caseID) else { throw InvestigationDataLabError.caseNotFound(caseID) }
        let scope = try await resolver.scope(for: record)
        let preset = InvestigationDataLabPresetCatalog.sourceInventory
        let (included, withheld) = try await eligibleSourceVersions(caseID: caseID, access: access)

        var rec = try await datasets.createDataset(
            workspaceID: record.caseHeader.workspaceID,
            title: "\(record.caseHeader.title) — \(preset.displayName)", mode: .advanced, actor: actor, at: date)
        let datasetID = rec.dataset.id

        // Fields, in preset order.
        var fieldID: [String: UUID] = [:]
        for field in preset.fields {
            rec = try await datasets.addField(datasetID: datasetID, name: field.name, valueShape: field.valueShape,
                                              expectedRevision: rec.dataset.revision, actor: actor, at: date)
            guard let created = rec.fields.first(where: { $0.name == field.name }) else {
                throw InvestigationDataLabError.presetFieldMissing(field.name)
            }
            fieldID[field.name] = created.id
        }
        guard let versionFieldID = fieldID["sourceVersion"] else {
            throw InvestigationDataLabError.presetFieldMissing("sourceVersion")
        }

        // One row per eligible authorized source version, drill-through bound to that exact version.
        for version in included {
            rec = try await datasets.addRow(datasetID: datasetID, expectedRevision: rec.dataset.revision, actor: actor, at: date)
            guard let row = rec.rows.last else { throw InvestigationDataLabError.presetFieldMissing("row") }
            rec = try await datasets.setCell(datasetID: datasetID, rowID: row.id, fieldID: versionFieldID,
                                             kind: .sourceValue, value: version.uuidString, status: .directlyObserved,
                                             expectedRevision: rec.dataset.revision, actor: actor, at: date)
            guard let cell = rec.cells.first(where: { $0.rowID == row.id && $0.fieldID == versionFieldID }) else {
                throw InvestigationDataLabError.presetFieldMissing("cell")
            }
            rec = try await datasets.bindSource(cellID: cell.id, targetKind: .sourceVersion, targetID: version.uuidString,
                                                sourceVersionID: version, locator: nil,
                                                expectedRevision: rec.dataset.revision, actor: actor, at: date)
        }
        // PHASE B-2 — observable dataLab phase, recorded ONLY after the whole
        // preparation succeeded (fields + rows + bindings). A throw above means
        // no phase evidence exists (eighth audit: completion, not intent). A
        // failed observation write is logged, never swallowed — the phase then
        // stays machine-unobserved, which is the fail-closed direction.
        // ELEVENTH AUDIT — bound to the exact case state (revision + the
        // INV-01-C4 scope fingerprint of THIS preparation's resolved scope).
        if let artifacts {
            do {
                let fingerprint = CaseScopeFingerprinter.fingerprint(
                    caseID: caseID, caseRevision: record.caseHeader.revision, scope: scope)
                try await artifacts.record(caseID: caseID, caseRevision: record.caseHeader.revision,
                                           scopeFingerprint: fingerprint,
                                           phase: .dataLab, artifactID: datasetID,
                                           detail: "preset=\(preset.id)", at: date)
            } catch {
                KalsmritikoshLog.storage.error("dataLab phase-artifact record failed (phase stays unobserved): \(error)")
            }
        }
        return InvestigationDataset(caseID: caseID, presetID: preset.id, scope: scope, dataset: rec,
                                    includedSourceVersionIDs: included, withheldBySensitivity: withheld)
    }
}

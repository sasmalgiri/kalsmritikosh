//
//  AppState+StudioCase.swift
//  Kalsmritikosh
//
//  A2 (investigation focus) — the live adapter behind "Fill from case" in the persona studios:
//  lists the open cases and reads one case's facts, events and documents over the case's
//  AUTHORIZED scope (the same scope its answers and findings use), so a studio is never filled
//  from a document outside the case.
//

import Foundation
import os

/// A case a studio can be filled from.
public struct StudioCaseChoice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let title: String
}

extension AppState {
    /// Open cases across every workspace, newest first.
    public func studioCaseChoices() async -> [StudioCaseChoice] {
        guard let cases = investigationCases, let workspaces else { return [] }
        var out: [(StudioCaseChoice, Date)] = []
        for ws in (try? await workspaces.all(includeArchived: false)) ?? [] {
            for c in (try? await cases.listCases(workspaceID: ws.id)) ?? [] where c.status == .open {
                out.append((StudioCaseChoice(id: c.id, workspaceID: ws.id, title: c.title), c.createdAt))
            }
        }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The case's facts for a studio draft. `includePrivileged` admits privileged sources (a
    /// privilege log lists them by description; it never prints their content).
    public func studioCaseFacts(_ choice: StudioCaseChoice, includePrivileged: Bool) async -> StudioCaseFacts? {
        guard let dataLab = investigationDataLab, let genericFacts, let events, let objects else { return nil }
        let entityRepo = entities
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: choice.workspaceID, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: includePrivileged, purpose: .export))
        do {
            let (included, _) = try await dataLab.eligibleSourceVersions(caseID: choice.id, access: access)
            let reader = StudioCaseFactsReader(facts: genericFacts, events: events, objects: objects, entities: entityRepo)
            return try await reader.read(caseTitle: choice.title, sourceVersionIDs: Set(included))
        } catch {
            KalsmritikoshLog.app.error("Studio fill from case failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension AppState {
    /// Final brief §3.2 — what a studio draft's case can check its references against, under the
    /// export access policy. nil when the draft has no case (or the case cannot be read).
    public func studioEvidenceContext(caseID: UUID?, workspaceID: UUID?, includePrivileged: Bool) async -> StudioEvidenceContext? {
        guard let caseID, let dataLab = investigationDataLab, let objects, let database else { return nil }
        let ws: UUID
        if let workspaceID { ws = workspaceID } else if let choice = await studioCaseChoices().first(where: { $0.id == caseID }) { ws = choice.workspaceID } else { return nil }
        let access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: includePrivileged, purpose: .export))
        do {
            let (included, _) = try await dataLab.eligibleSourceVersions(caseID: caseID, access: access)
            let versions = Set(included)
            let objectIDs = try await objects.objectIDs(inSourceVersionIDs: versions)
            let names = try await objects.sourceFilenames(for: objectIDs)
            let objectVersions = try await objects.sourceVersionsByObject(inSourceVersionIDs: versions)
            return StudioEvidenceContext(
                eligibleSourceVersions: versions, caseObjects: objectIDs, documentNames: names, objectVersions: objectVersions,
                blockText: { id in
                    guard let r = try? await database.query("SELECT source_version_id, raw_text FROM evidence_blocks WHERE id = ? LIMIT 1;", [.uuid(id)]).first,
                          let text = r.string(1) else { return nil }
                    return (r.uuid(0), text)
                },
                objectText: { id in (try? await objects.fetchContent(id: id)) ?? nil })
        } catch {
            KalsmritikoshLog.app.error("Studio evidence check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - D1 — the first case, from onboarding

/// What the person is investigating, as onboarding asks it: the sidebar focus it tailors, and
/// the persona whose case it opens.
public struct InvestigationKindChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let guidePersona: String
    public let applicationID: ApplicationDefinitionID

    public static let all: [InvestigationKindChoice] = [
        .init(id: "internal", title: "Internal misconduct, an IP leak or an incident", detail: "Who did what, when — with custody of every source.",
              guidePersona: "investigation", applicationID: InvestigatorPersonaPackage.applicationID),
        .init(id: "ipTheft", title: "IP theft or a data leak", detail: "What data left, how, when and by whom — devices and accounts first.",
              guidePersona: "investigation", applicationID: InvestigatorPersonaPackage.applicationID),
        .init(id: "safety", title: "A safety incident", detail: "The sequence of events, the causes and corrective actions.",
              guidePersona: "investigation", applicationID: InvestigatorPersonaPackage.applicationID),
        .init(id: "litigation", title: "A litigation matter", detail: "Fact-finding, chronology, privilege log and production.",
              guidePersona: "legal", applicationID: LawyerPersonaPackage.applicationID),
        .init(id: "workplace", title: "A workplace complaint", detail: "Harassment, discrimination or a policy breach — a fair, documented process.",
              guidePersona: "investigation", applicationID: CompliancePersonaPackage.applicationID),
        .init(id: "financial", title: "Financial fraud or missing funds", detail: "Funds tracing, net worth and the schedule behind every figure.",
              guidePersona: "investigation", applicationID: ForensicAccountantPersonaPackage.applicationID),
        .init(id: "insurance", title: "A suspicious insurance claim", detail: "Red flags, chronology and an SIU referral.",
              guidePersona: "investigation", applicationID: SIUPersonaPackage.applicationID),
        .init(id: "story", title: "A story to verify", detail: "Claims checked to sources, right of reply recorded.",
              guidePersona: "journalism", applicationID: JournalistPersonaPackage.applicationID),
        .init(id: "research", title: "A research-integrity question", detail: "What the papers and data actually show.",
              guidePersona: "research", applicationID: ResearcherPersonaPackage.applicationID),
        .init(id: "lineage", title: "An identity or heirship question", detail: "Who is who, proven to the Genealogical Proof Standard.",
              guidePersona: "research", applicationID: GenealogistPersonaPackage.applicationID),
        .init(id: "personal", title: "A personal dispute", detail: "An insurance claim, a deposit, a job — your file, in order.",
              guidePersona: "general", applicationID: IndividualPersonaPackage.applicationID),
    ]
}

extension AppState {
    /// The key the persona jobs screen reads to open with the persona onboarding chose.
    public static let investigationPersonaKey = "kalsmritikosh.investigationPersona"

    /// Open the person's first case: in their first workspace (created if none exists), through
    /// the persona's own intake job, so the workspace's documents come into the case's scope.
    /// Returns the case id, or nil when the persona's intake is unavailable.
    @discardableResult
    public func createStarterCase(title: String, kind: InvestigationKindChoice) async -> UUID? {
        guard let service = personaJobs, let workspaces else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var list = (try? await workspaces.all(includeArchived: false)) ?? []
        if list.isEmpty {
            let ws = Workspace(title: "My investigations")
            try? await workspaces.upsert(ws)
            list = [ws]
        }
        guard let ws = list.first,
              let intake = await service.jobs(forPersona: kind.applicationID).first(where: { $0.kind == .caseIntake }) else { return nil }
        do {
            let out = try await service.launch(intake, context: PersonaJobLaunchContext(
                workspaceID: ws.id, title: trimmed, actor: InvestigatorProfile.name, at: Date()))
            UserDefaults.standard.set(kind.applicationID.rawValue, forKey: Self.investigationPersonaKey)
            // The case file: owner, the investigation-type template (plan, tasks, starter allegations), triage.
            if let caseID = out.producedID, let files = caseFiles {
                let actor = InvestigatorProfile.name
                if let template = CaseTemplate.template(id: kind.id) {
                    try await files.applyTemplate(template, caseID: caseID, workspaceID: ws.id, actor: actor, at: Date())
                }
                try await files.file.recordTriage(caseID: caseID, CaseTriage(), actor: actor, at: Date())
            }
            return out.producedID
        } catch {
            KalsmritikoshLog.app.error("Starter case failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

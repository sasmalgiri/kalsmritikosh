//
//  RawSavepointRatchetTests.swift
//  KalsmritikoshTests
//
//  F28 — a raw `exec("SAVEPOINT …")` whose body awaits other database calls is NOT an isolated
//  transaction on the shared Database actor: other callers interleave, a rollback can undo their
//  writes and a release can swallow their savepoint. The safe shape is `Database.withSavepoint`
//  (synchronous, isolated closure). This ratchet freezes the files that still use the raw pattern
//  (audited 2026-09-28, review finding F28) so the list can only SHRINK: a new file using it fails
//  here, and a converted file must be removed from the list.
//

import Foundation
import Testing

@Suite("F28 — raw SAVEPOINT ratchet")
struct RawSavepointRatchetTests {

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh")
    }

    /// Files still issuing raw savepoints across suspension points — each is open conversion work.
    private static let knownRawSavepointFiles: Set<String> = [
        "Jobs/Persistence/JobRepository.swift",
        "Knowledge/Backfill/ChunkReindexCoordinator.swift",
        "Knowledge/Backfill/EntityRegisterRefresh.swift",
        "Knowledge/Backfill/LedgerDrainCoordinator.swift",
        "Knowledge/Topics/AgglomerativeCommunityDetector.swift",
        "Knowledge/Topics/CooccurrenceGraphBuilder.swift",
        "Knowledge/Topics/SubjectSpine.swift",
        "Knowledge/Topics/TermSalienceComputer.swift",
        "Knowledge/Topics/TopicTreeBuilder.swift",
        "Personas/Investigator/InvestigationAnalysisRepository.swift",
        "Personas/Investigator/InvestigationCaseRepository.swift",
        "Personas/Investigator/InvestigationClosureRepository.swift",
        "Personas/Investigator/InvestigationDeskReviewRepository.swift",
        "Personas/Investigator/InvestigationFindingsApprovalRepository.swift",
        "Personas/Investigator/InvestigationIdentityDecisionRepository.swift",
        "Personas/Investigator/InvestigationScopeLedger.swift",
        "Personas/Investigator/InvestigationSubjectRepository.swift",
        "Shell/Navigation/ShellSessionRepository.swift",
        "Storage/Repositories/DeadlineRepository.swift",
        "Storage/Repositories/EmailParticipantRepository.swift",
        "Storage/Repositories/EventLinksRepository.swift",
        "Storage/Repositories/EventMutator.swift",
        "Storage/Repositories/EventVersionsRepository.swift",
        "Storage/Repositories/InvestigationsRepository.swift",
        "Storage/Repositories/ProfessionalIssueRepository.swift",
        "Storage/Repositories/ProfessionalTaskRepository.swift",
        "Storage/Repositories/SourceReliabilityAssessmentRepository.swift",
        "Storage/Repositories/WorkspaceRepository.swift",
        "Workbench/Persistence/WorkbenchDatasetRepository.swift",
        "Workbench/Scenario/WorkbenchScenarioRepository.swift",
    ]

    @Test("No NEW file opens a raw SAVEPOINT; converted files leave the list")
    func rawSavepointsOnlyShrink() throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: appRoot, includingPropertiesForKeys: nil) else {
            Issue.record("source tree not found at \(appRoot.path)"); return
        }
        var found = Set<String>()
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(appRoot.path.count + 1))
            // The Database actor and migrations own SAVEPOINT legitimately (synchronous, isolated).
            if rel.hasPrefix("Storage/Database/") || rel.hasPrefix("Storage/Schema/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("exec(\"SAVEPOINT") { found.insert(rel) }
        }
        let added = found.subtracting(Self.knownRawSavepointFiles)
        #expect(added.isEmpty, "new raw SAVEPOINT use — use Database.withSavepoint instead: \(added.sorted())")
        let converted = Self.knownRawSavepointFiles.subtracting(found)
        #expect(converted.isEmpty, "remove converted files from the ratchet list: \(converted.sorted())")
        #expect(!found.contains("Workbench/Persistence/WorkbenchTransformRepository.swift"))
    }
}

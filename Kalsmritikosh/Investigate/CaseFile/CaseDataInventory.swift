//
//  CaseDataInventory.swift
//  Kalsmritikosh
//
//  Smart-map BASE-04 / DATA-08 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §01, §03, §E): the
//  registered inventory of every case store in the ledger — its record family, the code that owns it, how case
//  erasure treats it, and how the map shows it. Every store lives in the ONE encrypted ledger, so a complete backup
//  carries all of them; nothing here is a second copy of any record.
//
//  The inventory is checked against the actual migrated schema (CaseDataInventoryTests): a table that carries
//  case_id, is named case_* / investigation_*, or is a declared child of a case table must be registered here with
//  its lifecycle — so a store added by a later migration without erasure handling fails the check instead of being
//  silently forgotten. Omitted classes are explicit (`lifecycle: .notCaseData(reason)`).
//

import Foundation

public nonisolated enum CaseDataInventory {

    /// How a case erasure treats a store.
    public enum Lifecycle: Sendable, Equatable {
        /// Rows carry case_id; the generic pass of a case erasure deletes them (a full erase empties the table).
        case caseID
        /// Rows belong to a parent case table through `column` with no declared foreign key (CaseErasure.undeclaredChildren).
        case undeclaredChild(column: String, parent: String)
        /// Rows cascade from a parent through a declared ON DELETE CASCADE foreign key.
        case cascade(parent: String)
        /// The task engine: a task linked to this case only is erased with the case (its children cascade).
        case taskEngine
        /// A record of erasure itself — kept by every case or person erasure (content-free by design).
        case erasureRecord
        /// Not case data; the reason it is outside a case's lifecycle.
        case notCaseData(String)
    }

    public struct Entry: Sendable, Equatable {
        public let table: String
        /// The record family of the TODO's section E.
        public let family: String
        /// The type or service that owns the store.
        public let owner: String
        public let lifecycle: Lifecycle
        /// The map kind that shows it, or why there is none ("not shown: …").
        public let map: String
    }

    static func e(_ t: String, _ family: String, _ owner: String, _ l: Lifecycle, _ map: String) -> Entry {
        Entry(table: t, family: family, owner: owner, lifecycle: l, map: map)
    }

    public static let families = [
        "Mother case and scope", "Frames and appearances", "Evidence and source occurrences", "Physical exhibits and examined material",
        "Reports, sections and key points", "People and organizations", "Witness accounts and interviews", "Events and locations",
        "Financial objects", "Reasoning records", "Work and participants", "Governance and protection", "Historical/review references",
        "Derived and operational records",
    ]

    /// Every registered store.
    public static let entries: [Entry] = [
        // Mother case and scope
        e("investigation_cases", "Mother case and scope", "InvestigationCaseRepository", .caseID, "case"),
        e("case_profiles", "Mother case and scope", "CaseFileRepository", .caseID, "case"),
        e("investigation_case_sources", "Mother case and scope", "InvestigationCaseRepository", .caseID, "document"),
        e("investigation_case_events", "Mother case and scope", "InvestigationCaseRepository", .caseID, "not shown: case event log (History)"),
        e("investigation_scope_artifacts", "Mother case and scope", "InvestigationCaseRepository", .caseID, "not shown: scope artifacts"),
        // v178 (IN-01 / IN-05 / IN-11) — the case-intake contract record of every item and the named trusted-source policies.
        e("case_intake_items", "Evidence and source occurrences", "CaseIntakeLedger (InvestigationWorkspaceIntake, CaseFileRepository.addJournal)", .caseID, "not shown: intake list (Review new documents)"),
        e("case_intake_policies", "Governance and protection", "CaseIntakeLedger", .caseID, "not shown: trusted-source policies (Review new documents)"),
        e("investigation_case_closures", "Mother case and scope", "InvestigationClosureRepository", .caseID, "case (closed stage)"),
        e("case_phase_artifacts", "Mother case and scope", "CasePhaseArtifactRepository", .caseID, "not shown: phase bookkeeping"),
        e("case_method_runs", "Mother case and scope", "MethodRunRepository", .caseID, "not shown: method run bookkeeping"),
        // Frames and appearances
        e("case_map_views", "Frames and appearances", "CaseMapRepository", .caseID, "saved view (strip)"),
        e("case_map_layout", "Frames and appearances", "CaseMapRepository", .caseID, "position per frame"),
        e("case_map_links", "Frames and appearances", "CaseMapRepository", .caseID, "investigatorLink"),
        e("case_frame_members", "Frames and appearances", "CaseFileRepository (CaseRecordContracts)", .caseID, "frameMember (placed here)"),
        // Evidence and source occurrences — documents themselves are library data shared across cases; erasure of the
        // case's exclusive documents is CaseErasure.eraseSources (opt-in), not this inventory.
        e("case_redaction_log", "Evidence and source occurrences", "CaseFileRepository", .caseID, "not shown: redaction log (Outputs)"),
        // Physical exhibits
        e("case_exhibits", "Physical exhibits and examined material", "CaseFileRepository", .caseID, "exhibit"),
        // Reports
        e("case_reports", "Reports, sections and key points", "CaseFileRepository (CaseReports)", .caseID, "report"),
        e("case_report_points", "Reports, sections and key points", "CaseFileRepository (CaseReports)", .caseID, "reportPoint"),
        e("case_report_qualifications", "Reports, sections and key points", "CaseFileRepository (CaseReports)", .caseID, "qualification (on its point)"),
        e("case_report_items", "Reports, sections and key points", "CaseFileRepository", .caseID, "reportItem"),
        // People
        e("case_people", "People and organizations", "CaseFileRepository", .caseID, "person"),
        e("case_contacts", "People and organizations", "CaseFileRepository", .undeclaredChild(column: "person_id", parent: "case_people"), "not shown: contact details (person inspector)"),
        e("investigation_subjects", "People and organizations", "InvestigationSubjectRepository", .caseID, "person"),
        e("investigation_identity_decisions", "People and organizations", "InvestigationSubjectRepository", .caseID, "possibleSamePerson (review)"),
        // Witness accounts
        e("case_interviews", "Witness accounts and interviews", "CaseFileRepository", .caseID, "interview"),
        e("case_credibility", "Witness accounts and interviews", "CaseFileRepository", .undeclaredChild(column: "interview_id", parent: "case_interviews"), "not shown: credibility notes (interview inspector)"),
        e("case_statement_addenda", "Witness accounts and interviews", "CaseFileRepository", .caseID, "addendum"),
        // Events
        e("case_journal", "Events and locations", "CaseFileRepository", .caseID, "journal"),
        e("case_fact_attestations", "Events and locations", "CaseFileRepository (attestations)", .caseID, "on its chronology entry"),
        // Reasoning
        e("case_allegations", "Reasoning records", "CaseFileRepository", .caseID, "allegation"),
        e("case_allegation_evidence", "Reasoning records", "CaseFileRepository", .undeclaredChild(column: "allegation_id", parent: "case_allegations"), "allegationEvidence (supports / challenges)"),
        e("investigation_hypotheses", "Reasoning records", "InvestigationAnalysisRepository", .caseID, "hypothesis"),
        e("investigation_hypothesis_evidence", "Reasoning records", "InvestigationAnalysisRepository", .cascade(parent: "investigation_hypotheses"), "hypothesisEvidence"),
        e("investigation_hypothesis_decisions", "Reasoning records", "InvestigationAnalysisRepository", .cascade(parent: "investigation_hypotheses"), "on its hypothesis (history)"),
        e("investigation_hypothesis_evidence_assessments", "Reasoning records", "InvestigationAnalysisRepository", .cascade(parent: "investigation_hypothesis_evidence"), "on its evidence link"),
        e("ach_analyses", "Reasoning records", "ACHRepository", .caseID, "not shown: ACH matrix (Analysis)"),
        e("ach_hypotheses", "Reasoning records", "ACHRepository", .undeclaredChild(column: "analysis_id", parent: "ach_analyses"), "not shown: ACH matrix"),
        e("ach_evidence", "Reasoning records", "ACHRepository", .undeclaredChild(column: "analysis_id", parent: "ach_analyses"), "not shown: ACH matrix"),
        e("ach_cells", "Reasoning records", "ACHRepository", .undeclaredChild(column: "analysis_id", parent: "ach_analyses"), "not shown: ACH matrix"),
        e("investigation_review_decisions", "Reasoning records", "InvestigationDeskReviewRepository", .caseID, "reviewDecision (on its contradiction)"),
        e("investigation_worksheet_cells", "Reasoning records", "InvestigationAnalysisRepository", .caseID, "not shown: worksheet (Analysis)"),
        e("investigation_desk_reviews", "Reasoning records", "InvestigationDeskReviewRepository", .caseID, "not shown: desk review"),
        e("investigation_findings_approvals", "Reasoning records", "InvestigationFindingsApprovalRepository", .caseID, "not shown: findings approval (Outputs)"),
        // Work and participants
        e("case_task_links", "Work and participants", "CaseFileRepository", .caseID, "task"),
        e("professional_tasks", "Work and participants", "ProfessionalTaskRepository (one task engine)", .taskEngine, "task"),
        e("professional_task_dependencies", "Work and participants", "CaseFileRepository (CaseRecordContracts)", .cascade(parent: "professional_tasks"), "actionDependency (depends on)"),
        e("professional_task_reviews", "Work and participants", "ProfessionalTaskRepository", .cascade(parent: "professional_tasks"), "on its task (history)"),
        e("professional_task_evidence_links", "Work and participants", "ProfessionalTaskRepository", .cascade(parent: "professional_tasks"), "not shown: task evidence links"),
        e("deadlines", "Work and participants", "DeadlineRepository", .cascade(parent: "professional_tasks"), "on its task (due)"),
        e("deadline_candidates", "Work and participants", "DeadlineRepository", .cascade(parent: "professional_tasks"), "not shown: proposed deadlines"),
        e("deadline_reviews", "Work and participants", "DeadlineRepository", .cascade(parent: "deadlines"), "not shown: deadline reviews"),
        e("deadline_candidate_reviews", "Work and participants", "DeadlineRepository", .cascade(parent: "deadline_candidates"), "not shown: deadline proposal reviews"),
        e("case_action_contracts", "Work and participants", "CaseFileRepository (CaseReports)", .caseID, "actionContract (on its task)"),
        e("case_work_links", "Work and participants", "CaseFileRepository (CaseReports)", .caseID, "workLink (raised from / serves)"),
        e("case_actors", "Work and participants", "CaseFileRepository (CaseRecordContracts)", .caseID, "not shown: actor identities (attribution text)"),
        e("investigation_evidence_requests", "Work and participants", "InvestigationAnalysisRepository", .caseID, "request"),
        e("investigation_evidence_request_items", "Work and participants", "InvestigationAnalysisRepository", .caseID, "on its request"),
        e("investigation_evidence_request_receipts", "Work and participants", "InvestigationAnalysisRepository", .caseID, "requestReceipt"),
        e("investigation_evidence_request_events", "Work and participants", "InvestigationAnalysisRepository", .caseID, "on its request (history)"),
        // Governance and protection
        e("case_hold_notices", "Governance and protection", "CaseFileRepository", .caseID, "not shown: hold notices (case header)"),
        e("case_review_batches", "Governance and protection", "CaseFileRepository", .caseID, "not shown: review batches"),
        e("case_conflict_checks", "Governance and protection", "CaseFileRepository", .caseID, "not shown: conflict checks (case header)"),
        e("governance_events", "Governance and protection", "GovernanceEventsRepository", .caseID, "not shown: governance log"),
        e("conformance_assessments", "Governance and protection", "ConformanceAssessmentRepository", .caseID, "not shown: SOP conformance"),
        e("case_actions", "Governance and protection", "CaseFileRepository (every write)", .caseID, "history of each item"),
        e("case_erasures", "Governance and protection", "CaseErasure", .erasureRecord, "not shown: erasure register"),
        e("studio_erasures", "Governance and protection", "CaseErasure", .erasureRecord, "not shown: erasure register"),
        e("ledger_case_erase", "Governance and protection", "CaseErasure (marker inside the erase)", .erasureRecord, "not shown: marker"),
        // Historical / review references
        e("case_record_revisions", "Historical/review references", "CaseRecordRevisions", .caseID, "history of each item"),
        e("case_checkpoints", "Historical/review references", "CaseHistoryRepository", .caseID, "recorded state (History)"),
        e("case_change_seen", "Historical/review references", "CaseChangeFeed", .caseID, "What changed (seen position)"),
        // Derived and operational records
        e("case_saved_searches", "Derived and operational records", "CaseSearchRepository", .caseID, "not shown: saved searches (Search)"),
        e("job_results", "Derived and operational records", "JobResultRepository", .caseID, "not shown: job results (Outputs)"),
        e("job_result_exports", "Derived and operational records", "JobResultRepository", .caseID, "not shown: exports (Outputs)"),
        e("case_document_outputs", "Derived and operational records", "CaseOutputService", .caseID, "not shown: produced documents (Outputs)"),
        e("studio_records", "Derived and operational records", "StudioRecordRepository", .caseID, "not shown: drafts (Outputs)"),
        e("conversations", "Derived and operational records", "ConversationsRepository (Ask in a case)", .caseID, "not shown: Ask conversations"),
        e("conversation_turns", "Derived and operational records", "ConversationsRepository", .cascade(parent: "conversations"), "not shown: Ask turns (erased explicitly, CaseErasure.eraseCaseAsk)"),
        // Named like case stores, but not case data
        e("case_history_install", "Historical/review references", "CaseHistoryRepository", .notCaseData("one ledger-wide row: when this build began recording case history"), "not shown"),
        e("case_action_seal_boundaries", "Governance and protection", "v153 migration (action-log seal)", .notCaseData("ledger-wide seal boundary of the action log"), "not shown"),
        e("case_issues", "Reasoning records", "PlanFeatureRepositories", .notCaseData("workspace issue taxonomy shared by all cases"), "not shown"),
        e("case_issue_links", "Reasoning records", "PlanFeatureRepositories", .notCaseData("links of the shared issue taxonomy to library items"), "not shown"),
        e("investigation_steps", "Derived and operational records", "InvestigationsRepository (library research threads)", .notCaseData("steps of a library research thread, not of a case"), "not shown"),
    ]

    public static func entry(_ table: String) -> Entry? { entries.first { $0.table == table } }

    /// Tables of `db` that look like case data but are not registered here: carrying case_id, named case_* or
    /// investigation_*, or declaring a foreign key to a registered case table. A non-empty answer is a store that lacks
    /// declared lifecycle handling.
    static func unregistered(_ db: isolated Database) throws -> [String] {
        let registered = Set(entries.map(\.table))
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%';", [])
            .compactMap { $0.string(0) }
        var out: [String] = []
        for t in tables where !registered.contains(t) {
            let cols = try db.query("PRAGMA table_info(\"\(t)\");", []).compactMap { $0.string(1) }
            let parents = try db.query("PRAGMA foreign_key_list(\"\(t)\");", []).compactMap { $0.string(2) }
            if cols.contains("case_id") || t.hasPrefix("case_") || t.hasPrefix("investigation_")
                || parents.contains(where: { p in registered.contains(p) && entry(p).map { if case .notCaseData = $0.lifecycle { return false } else { return true } } == true }) {
                out.append(t)
            }
        }
        return out.sorted()
    }
}

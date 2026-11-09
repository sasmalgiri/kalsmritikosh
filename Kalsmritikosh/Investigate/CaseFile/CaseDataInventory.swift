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
        // v179 (BRIEF-02/05/08) — the investigator's versioned briefs, brief relevance decisions and briefings (live or frozen).
        e("case_briefs", "Frames and appearances", "CaseFileRepository (CaseBriefs)", .caseID, "not shown as an item: case and branch brief (Brief)"),
        e("case_brief_relevance", "Frames and appearances", "CaseFileRepository (CaseBriefs)", .caseID, "not shown as an item: set aside from the brief (Brief)"),
        e("case_briefings", "Frames and appearances", "CaseFileRepository (CaseBriefs)", .caseID, "not shown as an item: briefings (Brief ▸ Briefings)"),
        e("case_briefing_items", "Frames and appearances", "CaseFileRepository (CaseBriefs)", .caseID, "not shown as an item: briefing steps (open into the map)"),
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
        // v180 (REPORT-02/06/07/08/09) — sections, rule-based point proposals, point uses in other branches, recorded version
        // comparisons with the review-needed flags they raised, and supplied specialist items.
        e("case_report_sections", "Reports, sections and key points", "CaseFileRepository (CaseReportStructure)", .caseID, "not shown as an item: report sections (report inspector)"),
        e("case_report_point_proposals", "Reports, sections and key points", "CaseFileRepository (CaseReportStructure)", .caseID, "not shown as an item: suggested points awaiting a decision (report inspector)"),
        e("case_report_point_uses", "Reports, sections and key points", "CaseFileRepository (CaseReportStructure)", .caseID, "not shown as an item: point uses in other branches (point inspector)"),
        e("case_report_comparisons", "Reports, sections and key points", "CaseFileRepository (CaseReportStructure)", .caseID, "not shown as an item: version comparisons (report inspector)"),
        e("case_work_review_flags", "Work and participants", "CaseFileRepository (CaseReportStructure)", .caseID, "on its work (review needed)"),
        e("case_report_artifacts", "Reports, sections and key points", "CaseFileRepository (CaseReportStructure)", .caseID, "not shown as an item: supplied tables, figures and media (report inspector)"),
        // People
        e("case_people", "People and organizations", "CaseFileRepository", .caseID, "person"),
        e("case_contacts", "People and organizations", "CaseFileRepository", .undeclaredChild(column: "person_id", parent: "case_people"), "not shown: contact details (person inspector)"),
        e("investigation_subjects", "People and organizations", "InvestigationSubjectRepository", .caseID, "person"),
        e("investigation_identity_decisions", "People and organizations", "InvestigationSubjectRepository", .caseID, "possibleSamePerson (review)"),
        e("case_person_identity_decisions", "People and organizations", "CaseFileRepository (CaseBriefs)", .caseID, "possibleSamePerson / samePersonDecided (recorded decision)"),
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
        // v181 (REASON-01/05/07/10/12, TIME-01/03) — attributions, independence reviews, contradiction follow-ups, decision
        // inputs, proposal decisions, typed time assertions and their interpretations.
        e("case_assertion_attributions", "Witness accounts and interviews", "CaseFileRepository (CaseReasoning)", .caseID, "not shown as an item: attributions (source inspector)"),
        e("case_source_dependence_reviews", "Evidence and source occurrences", "CaseFileRepository (CaseReasoning)", .caseID, "not shown as an item: independence reviews (dependence lines)"),
        e("case_conflict_followups", "Work and participants", "CaseFileRepository (CaseReasoning)", .caseID, "on its task (contradiction follow-up)"),
        e("case_decision_inputs", "Reasoning records", "CaseFileRepository (CaseReasoning)", .caseID, "not shown as an item: decision inputs (question inspector)"),
        e("case_proposal_decisions", "Reasoning records", "CaseFileRepository (CaseReasoning)", .caseID, "not shown: proposal decisions"),
        e("case_time_assertions", "Events and locations", "CaseFileRepository (CaseTimeModel)", .caseID, "on its record (timeline)"),
        e("case_time_interpretations", "Events and locations", "CaseFileRepository (CaseTimeModel)", .caseID, "on its record (timeline)"),
        // v182 (CHANGE / PEOPLE) — personal seen positions, acknowledgements, derivation inputs, impact notifications and their
        // checkpoint, late contributions, automated-result applications; person roles, sourced attributes, location
        // observations, interview items, same-person assessments, assignments, team memberships and profile restrictions.
        e("case_change_seen_people", "Historical/review references", "CaseChangeFeedService", .caseID, "not shown: each person's seen position (What changed)"),
        e("case_change_acknowledgements", "Historical/review references", "CaseChangeFeedService", .caseID, "not shown as an item: acknowledgements (What changed)"),
        e("case_derivation_inputs", "Reasoning records", "CaseFileRepository (CaseChangeImpact)", .caseID, "not shown as an item: derivation inputs (impact and staleness)"),
        e("case_impact_notifications", "Historical/review references", "CaseChangeFeedService", .caseID, "not shown as an item: impact notifications (What changed)"),
        e("case_change_checkpoints", "Derived and operational records", "CaseChangeFeedService", .caseID, "not shown: reconciliation checkpoint"),
        e("case_late_contributions", "Mother case and scope", "CaseFileRepository (CaseChangeImpact)", .caseID, "not shown as an item: late contributions (What changed)"),
        e("case_result_applications", "Derived and operational records", "CaseFileRepository (CaseChangeImpact)", .caseID, "not shown: automated-result applications"),
        e("case_person_roles", "People and organizations", "CaseFileRepository (CasePeopleModel)", .caseID, "on its person (roles)"),
        e("case_person_attributes", "People and organizations", "CaseFileRepository (CasePeopleModel)", .caseID, "not shown as an item: the person's profile"),
        e("case_person_locations", "Events and locations", "CaseFileRepository (CasePeopleModel)", .caseID, "not shown as an item: the person's profile (past observations)"),
        e("case_interview_items", "Witness accounts and interviews", "CaseFileRepository (CasePeopleModel)", .caseID, "on its interview (questions and responses)"),
        e("case_person_match_assessments", "People and organizations", "CaseFileRepository (CasePeopleModel)", .caseID, "not shown as an item: same-person assessments"),
        e("case_work_assignments", "Work and participants", "CaseFileRepository (CasePeopleModel)", .caseID, "on its work item (assignments)"),
        e("case_team_memberships", "Work and participants", "CaseFileRepository (CasePeopleModel)", .caseID, "not shown: the case team"),
        e("case_person_restrictions", "Governance and protection", "CaseFileRepository (CasePeopleModel)", .caseID, "on its person (restricted)"),
        // v183 (MONEY / HISTORY) — accounts, account relations, statements, money records, identity decisions, conversion rates
        // and gap proposals; chosen overlap identifiers, history sources, cross-case references, review-of links and findings.
        e("case_money_accounts", "Financial objects", "CaseFileRepository (CaseMoneyModel)", .caseID, "moneyAccount"),
        e("case_money_ownership", "Financial objects", "CaseFileRepository (CaseMoneyModel)", .caseID, "on its account (held / owned / controlled by)"),
        e("case_money_statements", "Financial objects", "CaseFileRepository (CaseMoneyModel)", .caseID, "not shown as an item: statements (their rows are money records)"),
        e("case_money_records", "Financial objects", "CaseFileRepository (CaseMoneyModel)", .caseID, "moneyRecord"),
        e("case_money_identity_decisions", "Financial objects", "CaseFileRepository (CaseMoneyModel)", .caseID, "on its money records (confirmed / split)"),
        e("case_money_conversions", "Financial objects", "CaseFileRepository (CaseMoneyModel)", .caseID, "not shown as an item: recorded rates (report)"),
        e("case_money_gap_proposals", "Financial objects", "CaseFileRepository (CaseMoneyModel)", .caseID, "not shown as an item: proposed requests"),
        e("case_overlap_identifiers", "Historical/review references", "CaseHistoryReviewService", .caseID, "not shown: identifiers checked in other cases"),
        e("case_history_sources", "Historical/review references", "CaseHistoryReviewService", .caseID, "not shown: the case's history set"),
        e("case_cross_references", "Historical/review references", "CaseHistoryReviewService", .caseID, "not shown as an item: cross-case references (review)"),
        e("case_review_of", "Historical/review references", "CaseHistoryReviewService", .caseID, "not shown: the case it reviews"),
        e("case_review_findings", "Historical/review references", "CaseHistoryReviewService", .caseID, "not shown as an item: review findings (review export)"),
        // v184 (ACTION / AUTO) — results, reviews and returned branches; routing, closure exceptions, date bases, template
        // applications, reopen proposals; automation policies, outbox, usage, external recipients/effects, compensations.
        e("case_action_results", "Work and participants", "CaseFileRepository (CaseActionWork)", .caseID, "on its action (results, by revision)"),
        e("case_action_result_reviews", "Work and participants", "CaseFileRepository (CaseActionWork)", .caseID, "on its action (reviews)"),
        e("case_action_result_branches", "Work and participants", "CaseFileRepository (CaseActionWork)", .caseID, "on each branch the result returns to"),
        e("case_action_routing", "Work and participants", "CaseFileService (CaseActionWork)", .caseID, "on its action (why this owner / unassigned)"),
        e("case_action_closure_exceptions", "Work and participants", "CaseFileRepository (CaseActionWork)", .caseID, "on the parent action (exceptions)"),
        e("case_deadline_bases", "Work and participants", "CaseFileRepository (CaseActionWork)", .caseID, "on its action (target / external / reminder)"),
        e("case_template_applications", "Work and participants", "CaseFileService (templates)", .caseID, "not shown: which template items were applied"),
        e("case_action_reopen_proposals", "Work and participants", "CaseFileRepository (CaseActionWork)", .caseID, "on its action (reopen proposals)"),
        e("case_automation_policies", "Derived and operational records", "CaseAutomationService", .caseID, "not shown: automation policy versions"),
        e("case_automation_outbox", "Derived and operational records", "CaseAutomationService", .caseID, "not shown as an item: automation queue"),
        e("case_automation_usage", "Derived and operational records", "CaseAutomationService", .caseID, "not shown: budget use"),
        e("case_external_recipients", "Governance and protection", "CaseAutomationService", .caseID, "not shown: configured recipients"),
        e("case_external_effects", "Governance and protection", "CaseAutomationService", .caseID, "not shown as an item: messages and disclosures"),
        e("case_automation_compensations", "Derived and operational records", "CaseAutomationService", .caseID, "not shown: undo records"),
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
        // v185 (SEC / ACCESS) — who may do what in the case; erasure generations and tombstones (kept by every erasure).
        e("case_access_grants", "Governance and protection", "CaseFileRepository (CaseAccessModel)", .caseID, "not shown as an item: People and roles (access history)"),
        e("local_actors", "Governance and protection", "CaseAccessPolicy", .notCaseData("names standing for people on this Mac, shared by every case they hold a role in; never accounts"), "not shown: local names"),
        e("erasure_generations", "Governance and protection", "CaseErasure (SEC-08)", .erasureRecord, "not shown: erasure generations (content-free)"),
        e("erasure_tombstones", "Governance and protection", "CaseErasure (SEC-08 triggers)", .erasureRecord, "not shown: tombstones of erased user-layer rows (identifiers only)"),
        // Historical / review references
        e("case_record_revisions", "Historical/review references", "CaseRecordRevisions", .caseID, "history of each item"),
        e("case_checkpoints", "Historical/review references", "CaseHistoryRepository", .caseID, "recorded state (History)"),
        e("case_change_seen", "Historical/review references", "CaseChangeFeed", .caseID, "What changed (seen position)"),
        // Derived and operational records
        e("case_saved_searches", "Derived and operational records", "CaseSearchRepository", .caseID, "not shown: saved searches (Search)"),
        e("case_saved_patterns", "Derived and operational records", "CaseSearchRepository (CaseMapPathSearch)", .caseID, "not shown: saved relationship patterns (Search)"),
        e("job_results", "Derived and operational records", "JobResultRepository", .caseID, "not shown: job results (Outputs)"),
        e("job_result_exports", "Derived and operational records", "JobResultRepository", .caseID, "not shown: exports (Outputs)"),
        e("case_document_outputs", "Derived and operational records", "CaseOutputService", .caseID, "not shown: produced documents (Outputs)"),
        e("studio_records", "Derived and operational records", "StudioRecordRepository", .caseID, "not shown: drafts (Outputs)"),
        e("conversations", "Derived and operational records", "ConversationsRepository (Ask in a case)", .caseID, "not shown: Ask conversations"),
        e("conversation_turns", "Derived and operational records", "ConversationsRepository", .cascade(parent: "conversations"), "not shown: Ask turns (erased explicitly, CaseErasure.eraseCaseAsk)"),
        // Named like case stores, but not case data
        e("case_history_install", "Historical/review references", "CaseHistoryRepository", .notCaseData("one ledger-wide row: when this build began recording case history"), "not shown"),
        e("case_action_seal_boundaries", "Governance and protection", "v153 migration (action-log seal)", .notCaseData("ledger-wide seal boundary of the action log"), "not shown"),
        e("ledger_recording_device", "Governance and protection", "CaseActionStamp (v181)", .notCaseData("one ledger-wide row: this ledger's recording-device id"), "not shown"),
        e("investigator_capabilities", "Work and participants", "CaseFileRepository (CasePeopleModel, v182)", .notCaseData("an investigator's declared capabilities, kept across cases; removed with their profile"), "not shown"),
        e("investigator_availability", "Work and participants", "CaseFileRepository (CasePeopleModel, v182)", .notCaseData("an investigator's declared unavailability, kept across cases; removed with their profile"), "not shown"),
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

//
//  CaseTemplates.swift
//  Kalsmritikosh
//
//  C-10 — investigation-type templates. Applying one pre-fills the plan and creates the usual tasks
//  (with due dates counted from today) and starter allegation wording the investigator edits. A
//  template only proposes the work; every task is opened by the person applying it (user authority),
//  and every due date is a date the person confirms by applying — no deadline is inferred from law.
//

import Foundation

public nonisolated struct CaseTemplateTask: Sendable, Equatable {
    public let title: String
    public let type: ProfessionalTaskType
    /// Days from the day the template is applied; nil = no due date.
    public let dueInDays: Int?
    public let priority: ProfessionalTaskPriority
    public init(_ title: String, _ type: ProfessionalTaskType = .action, due dueInDays: Int? = nil, _ priority: ProfessionalTaskPriority = .normal) {
        self.title = title; self.type = type; self.dueInDays = dueInDays; self.priority = priority
    }
}

public nonisolated struct CaseTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let plan: CasePlan
    public let tasks: [CaseTemplateTask]
    public let allegationPrompts: [String]
    public let retentionPolicy: String

    public static func template(id: String?) -> CaseTemplate? { all.first { $0.id == id } }

    public static let all: [CaseTemplate] = [
        CaseTemplate(
            id: "workplace", title: "Workplace complaint (harassment, discrimination, policy breach)",
            plan: CasePlan(method: "Fair-process investigation: hear the complainant, the respondent and witnesses; test each account against documents; decide each allegation on the balance of probabilities.",
                           evidenceToCollect: "Complaint and any prior complaints; relevant policies; emails, chats and calendar entries of the people named; HR file entries; access or rota records for the dates.",
                           interviewsToHold: "Complainant → witnesses named by the complainant → respondent (with the allegations put fairly) → follow-up witnesses."),
            tasks: [CaseTemplateTask("Acknowledge the complaint to the complainant", .action, due: 2, .high),
                    CaseTemplateTask("Run the conflict-of-interest check for the investigator", .review, due: 2, .high),
                    CaseTemplateTask("Consider interim measures (separation, leave) and record the decision", .decision, due: 3, .high),
                    CaseTemplateTask("Issue preservation (hold) notices to the custodians", .evidenceRequest, due: 3),
                    CaseTemplateTask("Collect the documents in the evidence plan", .evidenceRequest, due: 10),
                    CaseTemplateTask("Interview the complainant", .action, due: 10),
                    CaseTemplateTask("Interview the witnesses", .action, due: 20),
                    CaseTemplateTask("Interview the respondent with the allegations put fairly", .action, due: 25),
                    CaseTemplateTask("Decide each allegation and draft the report", .decision, due: 35),
                    CaseTemplateTask("Second-person review of the report", .approval, due: 40)],
            allegationPrompts: ["[Respondent] [conduct] towards [complainant] on or about [date] at [place]."],
            retentionPolicy: "Keep 6 years after closure, then review."),
        CaseTemplate(
            id: "internal", title: "Internal misconduct or an incident",
            plan: CasePlan(method: "Establish what happened and who was involved from sources first, then interviews; every finding cites its source.",
                           evidenceToCollect: "System and access logs; emails and chats of the people involved; device images if authorised; policies in force at the time.",
                           interviewsToHold: "People with first-hand knowledge → the person concerned."),
            tasks: [CaseTemplateTask("Confirm the scope and authority for the investigation", .decision, due: 2, .high),
                    CaseTemplateTask("Issue preservation (hold) notices", .evidenceRequest, due: 2, .high),
                    CaseTemplateTask("Collect and register the evidence as exhibits", .evidenceRequest, due: 10),
                    CaseTemplateTask("Build the chronology", .action, due: 15),
                    CaseTemplateTask("Interviews", .action, due: 25),
                    CaseTemplateTask("Findings and report", .decision, due: 35)],
            allegationPrompts: ["[Person] [did what] between [date] and [date]."],
            retentionPolicy: "Keep 6 years after closure, then review."),
        CaseTemplate(
            id: "ipTheft", title: "IP theft or a data leak",
            plan: CasePlan(method: "Trace what data left, how, when and by whom: device and account activity first, then communications, then interviews.",
                           evidenceToCollect: "Endpoint and USB logs; cloud-drive and email sharing logs; badge and VPN logs; the departing person's devices and accounts; NDA and IP-assignment agreements.",
                           interviewsToHold: "Line manager → IT/security → the person concerned (after the evidence is fixed)."),
            tasks: [CaseTemplateTask("Preserve devices and accounts before anyone is told", .evidenceRequest, due: 1, .critical),
                    CaseTemplateTask("Issue preservation (hold) notices", .evidenceRequest, due: 2, .high),
                    CaseTemplateTask("Collect agreements (NDA, IP assignment, policy acknowledgements)", .evidenceRequest, due: 5),
                    CaseTemplateTask("Analyse device, USB and sharing activity", .action, due: 10),
                    CaseTemplateTask("Chronology of the data movement", .action, due: 14),
                    CaseTemplateTask("Interview the person concerned", .action, due: 21),
                    CaseTemplateTask("Findings and report; consider referral to counsel", .decision, due: 30)],
            allegationPrompts: ["[Person] copied [data] to [destination] on or about [date] without authorisation."],
            retentionPolicy: "Keep until any proceedings end plus 6 years."),
        CaseTemplate(
            id: "financial", title: "Fraud, embezzlement or missing funds",
            plan: CasePlan(method: "Trace the money: build the transaction schedule, follow each flow to its end, test explanations against records.",
                           evidenceToCollect: "Bank and card statements; general ledger and payment approvals; vendor master data; expense claims; emails about the payments.",
                           interviewsToHold: "Finance staff → approvers → the person concerned."),
            tasks: [CaseTemplateTask("Secure the accounting records and statements", .evidenceRequest, due: 3, .high),
                    CaseTemplateTask("Issue preservation (hold) notices", .evidenceRequest, due: 3),
                    CaseTemplateTask("Build the transaction schedule", .action, due: 10),
                    CaseTemplateTask("Trace the flows and quantify the loss", .action, due: 20),
                    CaseTemplateTask("Interviews", .action, due: 25),
                    CaseTemplateTask("Report with the schedule behind every figure", .decision, due: 35)],
            allegationPrompts: ["[Person] diverted [amount] from [account] between [date] and [date]."],
            retentionPolicy: "Keep 7 years after closure (financial records), then review."),
        CaseTemplate(
            id: "insurance", title: "A suspicious insurance claim",
            plan: CasePlan(method: "Test the claim against independent records; list red flags with their sources; refer only on documented indicators.",
                           evidenceToCollect: "Claim file; policy; prior claims; repair, medical or police records; photos and their metadata; public records.",
                           interviewsToHold: "Claimant (recorded statement) → witnesses → providers."),
            tasks: [CaseTemplateTask("Acknowledge and log the referral", .action, due: 2),
                    CaseTemplateTask("Collect the claim file and independent records", .evidenceRequest, due: 10),
                    CaseTemplateTask("Recorded statement from the claimant", .action, due: 15),
                    CaseTemplateTask("Red-flag review with sources", .review, due: 20),
                    CaseTemplateTask("Referral decision (SIU / regulator) or close", .decision, due: 30, .high)],
            allegationPrompts: ["The loss claimed on [date] [did not happen as described / was exaggerated]."],
            retentionPolicy: "Keep 7 years after closure, then review."),
        CaseTemplate(
            id: "safety", title: "A safety incident",
            plan: CasePlan(method: "Establish the sequence of events, then the causes (5 Whys / fishbone), then corrective actions; no blame before facts.",
                           evidenceToCollect: "Incident report; photos and scene notes; maintenance and inspection records; training records; procedures; rota.",
                           interviewsToHold: "People involved → witnesses → supervisors → maintenance."),
            tasks: [CaseTemplateTask("Make the scene safe and preserve it", .action, due: 1, .critical),
                    CaseTemplateTask("Record any notification made to a regulator (dates and reference)", .action, due: 1, .critical),
                    CaseTemplateTask("Collect records and photos", .evidenceRequest, due: 5),
                    CaseTemplateTask("Interviews", .action, due: 10),
                    CaseTemplateTask("Root-cause analysis", .action, due: 15),
                    CaseTemplateTask("Corrective actions with owners", .decision, due: 20),
                    CaseTemplateTask("Effectiveness review of the actions", .review, due: 90)],
            allegationPrompts: ["[What happened] at [place] on [date]."],
            retentionPolicy: "Keep 40 years for occupational-exposure records; otherwise 6 years after closure."),
        CaseTemplate(
            id: "research", title: "A research-integrity question",
            plan: CasePlan(method: "Compare what was reported with the underlying data and records; preserve the record first.",
                           evidenceToCollect: "Publications and submissions; raw data and lab notebooks; grant applications; correspondence; image originals.",
                           interviewsToHold: "Complainant → co-authors → the respondent."),
            tasks: [CaseTemplateTask("Sequester the research records", .evidenceRequest, due: 3, .high),
                    CaseTemplateTask("Assessment: does the allegation warrant an inquiry?", .decision, due: 30),
                    CaseTemplateTask("Compare reported results with the data", .action, due: 60),
                    CaseTemplateTask("Interviews", .action, due: 90),
                    CaseTemplateTask("Report and decision", .decision, due: 120)],
            allegationPrompts: ["[Figure/result] in [publication] was [fabricated / falsified / plagiarised]."],
            retentionPolicy: "Keep 7 years after the decision, then review."),
        CaseTemplate(
            id: "litigation", title: "A litigation matter",
            plan: CasePlan(method: "Fact-finding to the pleadings: chronology, issues, key documents, privilege, then production.",
                           evidenceToCollect: "Pleadings; custodian email and files; contracts; prior correspondence; third-party records.",
                           interviewsToHold: "Client witnesses → custodians → experts."),
            tasks: [CaseTemplateTask("Issue litigation-hold notices", .evidenceRequest, due: 2, .critical),
                    CaseTemplateTask("Collect custodian data", .evidenceRequest, due: 14),
                    CaseTemplateTask("First-pass review and privilege", .review, due: 30),
                    CaseTemplateTask("Chronology and issue list", .action, due: 30),
                    CaseTemplateTask("Production set and privilege log", .action, due: 45)],
            allegationPrompts: ["[Party] [breached / did] [what] on [date]."],
            retentionPolicy: "Keep until the matter ends plus 6 years."),
        CaseTemplate(
            id: "story", title: "A story to verify",
            plan: CasePlan(method: "Every claim checked to a primary source; right of reply recorded before publication.",
                           evidenceToCollect: "Primary documents; public records; recordings; correspondence with sources.",
                           interviewsToHold: "Sources → subject (right of reply)."),
            tasks: [CaseTemplateTask("List every claim in the draft", .action, due: 2),
                    CaseTemplateTask("Check each claim to a primary source", .review, due: 7),
                    CaseTemplateTask("Right of reply to the subject", .action, due: 9, .high),
                    CaseTemplateTask("Legal read", .approval, due: 12)],
            allegationPrompts: ["Claim: [what the story says]."],
            retentionPolicy: "Keep 6 years after publication."),
        CaseTemplate(
            id: "lineage", title: "An identity or heirship question",
            plan: CasePlan(method: "Genealogical Proof Standard: reasonably exhaustive search, source citations, analysis, conflict resolution, written conclusion.",
                           evidenceToCollect: "Vital records; census; probate and land records; church records; DNA results if consented."),
            tasks: [CaseTemplateTask("Search plan and record sources", .action, due: 7),
                    CaseTemplateTask("Resolve conflicting evidence", .review, due: 30),
                    CaseTemplateTask("Proof argument", .decision, due: 45)],
            allegationPrompts: ["[Person A] is the [relationship] of [person B]."],
            retentionPolicy: "Keep permanently (family history)."),
        CaseTemplate(
            id: "personal", title: "A personal dispute",
            plan: CasePlan(method: "Put your file in order: what was agreed, what happened, what you are owed, and the proof of each.",
                           evidenceToCollect: "Contract or policy; receipts; letters and emails; photos; notes of calls (date, who, what)."),
            tasks: [CaseTemplateTask("Gather the contract or policy and the correspondence", .evidenceRequest, due: 3),
                    CaseTemplateTask("Write the timeline of what happened", .action, due: 5),
                    CaseTemplateTask("Send the written complaint or claim", .action, due: 10, .high),
                    CaseTemplateTask("Follow up if there is no answer", .followUp, due: 24)],
            allegationPrompts: ["[Company/person] [failed to do what] on [date]."],
            retentionPolicy: "Keep until the dispute ends plus 6 years."),
    ]
}

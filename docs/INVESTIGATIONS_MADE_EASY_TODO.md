# Investigations Made Easy — gap analysis and complete todo (2026-10-23)

Owner decision (2026-10-23): **"Investigations Made Easy" is the main app.** This file compares the app
as it is today (branch `investigation-docs`, after the A1–D4 work) with what a complete investigation
app must do, and lists everything left — engineering, proof, and release — as one ordered todo.

Audit method: four code audits (case management, evidence, people & analysis, governance & release),
each reporting EXISTS / PARTIAL / ABSENT with file paths. Detail per item is in the tables below.

## 1. What "complete" means

A person opens the app, says what they are investigating, and can run the whole investigation in it:

1. **Intake & triage** — a structured complaint / referral / hotline intake, a risk-rated triage and an accept/decline decision.
2. **Plan** — scope, allegations, evidence plan, interview list, tasks with owners and due dates, statutory deadlines.
3. **Evidence** — every source in (files, email, chats, phones, scans, audio), an exhibit register, custody, holds, privilege.
4. **People** — subjects, witnesses, interviews (plan → record → transcript → signed statement), credibility.
5. **Analysis** — chronology, relationships, money flow, allegations × evidence matrix, contradictions and gaps, root cause.
6. **Findings & report** — findings per allegation, a report where every sentence cites its source, redaction, production.
7. **Close** — disposition, sign-off, corrective actions, retention, reopen.
8. **Across cases** — a caseload dashboard, deadlines, team work, an audit trail.
9. **A shippable product** — accurate answers, onboarding, help, accessibility, languages, pricing, App Store.

**Judgement stays human** in every step: the app organises, finds and documents; the investigator decides.
(This is also what keeps the name "Investigations Made Easy" safe under App Review 2.3.1 — see R-2.)

## 2. Where the app stands

| Area | State | What exists | What is missing |
|---|---|---|---|
| Case record & statuses | PARTIAL | `InvestigationCase` (title, purpose, scope, window), statuses open / scopeConfirmed / closed, reopen, case event log | in-progress / on-hold statuses; case owner; typed intake fields |
| Intake forms | PARTIAL | intake steps as Work Center workflow fields (`hr.complaint-intake`, `inv.case-intake`, `siu.claim-intake`) | a typed intake (complainant, channel, anonymity, allegation, date, location) stored on the case; whistleblower / anonymous intake |
| Triage | PARTIAL | risk level as a workflow field; `CaseloadView` ranks workspaces by staleness | typed case severity / risk, accept/decline decision, triage queue |
| Assignment, roles | ABSENT | free-text "investigator" fields | case owner, team, roles, per-case permissions |
| Investigation plan | PARTIAL | free-text plan field; `WIAllegation` in the HR studio | one plan object: scope + allegations + evidence plan + interview list |
| Tasks & reminders | PARTIAL (not wired) | `ProfessionalTask` + repository (status, priority, owner, dependencies) — built only in tests | wired to cases, a task UI, reminders |
| Deadlines / SLAs | PARTIAL (not wired) | `Deadline`, `bindConfirmedDeadline` | repository booted in AppState, statutory/SLA rules, calendar, overdue alerts |
| Caseload dashboard | PARTIAL | `CaseloadView` over workspaces | over cases: status, owner, deadline, risk, next task |
| Notes / journal | PARTIAL | global Markdown notes; case event log | per-case investigator journal |
| Collaboration | PARTIAL | `TeamCase` (signed shared-folder review of documents), findings approval | case-level comments, review/approval of case steps, conflict-of-interest check |
| Templates per type | PARTIAL | ~16 authored workflows per persona; `InvestigationKindChoice` | a type template that pre-creates the plan, tasks and deadlines; IP-theft and safety-incident templates |
| Closure | EXISTS | closure decision with rationale, seal, reopen; dispositions in SIU/HR studios | case-level disposition field; archive of a case (only workspaces archive) |
| Evidence intake | PARTIAL | files, email (mbox/eml/msg/PST/NSF), WhatsApp/Signal/Slack/Telegram/iMessage…, iOS backup, web clipper, scanning, OCR, audio/video transcription | Microsoft Teams export, Cellebrite UFDR, cloud-drive import |
| Exhibit register | PARTIAL | `legalExhibit` citation style (label never set) | exhibit model: number, description, collected by / when / where; exhibit list export |
| Chain of custody | EXISTS | SHA-256 at intake, custody events, HMAC audit chain, per-case manifest | stand-alone custody report export |
| Legal hold | PARTIAL | `LegalHold`, hold blocks removal | preservation notice, custodian tracking, acknowledgements |
| Privilege & sensitivity | EXISTS | privilege log studio, privileged review code, sensitivity levels | — |
| Redaction | PARTIAL | burn-in PDF redaction + verification, PII text redaction | image redaction, redaction log |
| Production | EXISTS | Bates, DAT/OPT load files, IMAGES/TEXT/NATIVES | — |
| Report formats & receipts | EXISTS | MD/HTML/PDF/DOCX/XLSX/RTF, signed receipts, proof bundles | — |
| Dedup & threading | EXISTS | near-duplicates (MinHash), email threads | — |
| Document review | PARTIAL | review codes, coding suggester, team review leases | review batches, second-level QC |
| Search | EXISTS | FTS5, Boolean/NEAR/filters, saved searches | — |
| Subjects & identity | EXISTS | dossier, reversible merges, aliases | — |
| Witnesses | PARTIAL | witness as a role; interview log register | witness list tied to the case, contact log |
| Interviews | PARTIAL | INT register (interviewee, mode, questions, account), interview-prep workflows, transcription (not linked) | interview object on the case: plan → schedule → record → transcript link → summary → signed/attested statement |
| Credibility | PARTIAL | free-text `WICredibility`, Admiralty source rating | structured per-account factors (consistency, corroboration, plausibility, motive, demeanour) |
| Chronology | EXISTS | automatic timeline, issue chronology export | manual entries in the case chronology |
| Relationship chart | EXISTS (basic) | graph view, shortest path, canvas | force-directed chart; per-pair communication timeline |
| Money flow | PARTIAL | fund-flow view (corroboration-weighted), funds-tracing methods, net-worth template | amount-weighted tracing over transactions |
| Allegations matrix | PARTIAL | ACH (stored in AppStorage, not the ledger), hypotheses with evidence stance, ALG register | allegation × evidence × finding grid on the case; ACH in the ledger |
| Contradictions & gaps | EXISTS | detector, gap detector, confirm/dismiss desk | — |
| Root cause & CAPA | EXISTS | 5 Whys, fishbone, CAPA, effectiveness review | — |
| Ask with citations + AI | EXISTS | case-scoped Ask, on-device model, grounding guards | answer quality still uneven (see Q) |
| Persona deliverables | EXISTS (new) | eight studios filled from the case with sources + export gate; Dispute File | verify in tests (T-1) |
| Security | PARTIAL | SQLCipher ledger, app lock, tamper-evident audit chain | vault originals rely on FileVault; no user accounts; app lock untested |
| Privacy / retention | PARTIAL | erase-everything with verification, per-source removal, privacy policy | retention schedule & purge, subject-access export, per-person erasure |
| Backup / sync | EXISTS | verified backup/restore, encrypted folder sync | guided "move to a new Mac" |
| Onboarding & help | EXISTS | "What are you investigating?", guide, sample archive | Help Book; investigation-type walkthroughs |
| Accessibility | PARTIAL | 108 icon buttons named | VoiceOver walk, 81 fixed font sizes, no Dynamic Type check |
| Localization | ABSENT | 2,146 strings, English only | the 10 languages decided 2026-10-16 (or English-first decision) |
| iPhone/iPad | EXISTS (viewer) | verify, browse, search, notes/tags via sync | privacy manifest for the viewer |
| Pricing | PARTIAL | StoreKit trial + $79 unlock, 4 logic tests | StoreKit purchase-flow tests, `.storekit` in a scheme, stale "$29–49" in SHIP_DECISIONS |
| Name | MISMATCH | "Investigation Docs Made Easy" in display name, menus, onboarding, Share/Services, listing; "Kalsmritikosh" in AppleScript dictionary, URL scheme, some strings | rename to "Investigations Made Easy" everywhere a person sees it |
| Crash / diagnostics | ABSENT | feedback mail | MetricKit crash & hang reports, diagnostics bundle |
| Release gates | OPEN | SHIP_DECISIONS §3: 11 gates unchecked; README REL/EVAL/SCL items; HOLD2 script | all (owner + agent, §3 phase R) |

## 3. The todo list

IDs are stable; work top to bottom. **(A)** = agent builds, **(O)** = owner, **(A+O)** = agent prepares, owner confirms.

### Phase T — finish what is built (test and prove) — first
- [ ] T-1 (A) Test phase for the A1–D4 work: every suite touching the changed types, `InvestigationCaseSimulationTests` (9 personas, wrong facts = 0), `PersonaJobCoverageMeasuredTests`; fix every failure at its root.
- [ ] T-2 (A) Update pinned tests that change on purpose (Compliance has 17 jobs; module count; persona list hides Content creator).
- [ ] T-3 (A) One 190-case full-AI round on the final build; record per-category results in the case-bench report.
- [ ] T-4 (A) One PR → CI → merge → main CI (two-run protocol; Actions budget).

### Phase N — the name
- [ ] N-1 (A) Rename to **Investigations Made Easy** wherever a person sees it: display/bundle name (InfoPlist.xcstrings), menus, onboarding, Share extension, Services item, viewer title, feedback mail, AppleScript dictionary title, listing, website, privacy/terms/support pages, CLAIMS fragments. Bundle IDs, schemes and the `kalsmritikosh://` scheme stay (renaming them breaks updates and links).
- [ ] N-2 (A) Listing & review notes: keep "judgement stays human" in the first lines; subtitle "From evidence to findings"; keywords for investigations.
- [ ] N-3 (O) Confirm the name in App Store Connect (name availability is checked there).

### Phase C — case management (the biggest gap)
- [ ] C-1 (A) Case statuses: intake → triage → open → in progress → on hold → findings → closed → reopened; migration; status shown everywhere.
- [ ] C-2 (A) Typed intake on the case: received date, channel (hotline, email, referral, walk-in, web), complainant (or anonymous), allegation text, incident date/location, people named; an intake form per investigation type; anonymous/whistleblower intake that stores no identity.
- [ ] C-3 (A) Triage: severity, risk factors, accept / decline / refer with a reason; triage queue.
- [ ] C-4 (A) Case owner and team: owner, investigators, reviewer on the case; who did what in the case log (names on this Mac; see S-3 for accounts).
- [ ] C-5 (A) Investigation plan object: scope, allegations, evidence to collect, people to interview, method; generated from the intake, edited by the investigator, cited by the report.
- [ ] C-6 (A) Tasks: wire `ProfessionalTask` to cases — task list per case, assignee, due date, status, link to evidence; local notifications for due/overdue.
- [ ] C-7 (A) Deadlines: boot `DeadlineRepository`; statutory/SLA deadlines from the investigation type (e.g. response due, limitation dates entered by the user); case calendar; overdue alerts.
- [ ] C-8 (A) Caseload dashboard over cases: status, owner, risk, next deadline, open tasks, age; filters.
- [ ] C-9 (A) Per-case investigator journal (dated notes, linked to evidence), printed in the case file.
- [ ] C-10 (A) Investigation-type templates that pre-create plan, tasks and deadlines: workplace complaint, fraud/embezzlement, insurance claim, IP theft/data leak, safety incident, research integrity, litigation matter, personal dispute.
- [ ] C-11 (A) Conflict-of-interest check at assignment (investigator vs named people), recorded.
- [ ] C-12 (A) Case-level disposition per allegation (substantiated / unsubstantiated / inconclusive) and case archive.

### Phase E — evidence
- [ ] E-1 (A) Exhibit register: exhibit number, description, source, collected by / when / where, custody link; exhibit list export; `legalExhibit` citations use it.
- [ ] E-2 (A) Custody report export (stand-alone PDF/CSV per case).
- [ ] E-3 (A) Legal hold notices: generate from a template, record custodians, issue date, acknowledgement, reminders, release.
- [ ] E-4 (A) Redaction log (what, where, why, by whom) and image redaction.
- [ ] E-5 (A) Review batches and second-level QC for large document sets.
- [ ] E-6 (A) Microsoft Teams export import; Cellebrite UFDR import (read-only parse of the report XML); evaluate cloud-drive import (files already on disk only — no network in the main app).

### Phase P — people and interviews
- [ ] P-1 (A) Witness list on the case (role, contact log, availability), linked to subjects.
- [ ] P-2 (A) Interview object: plan (questions from the plan and the contradictions), schedule, record, link to the recording's transcript, summary drafted from the transcript with citations, statement for signature (PDF) with attestation record.
- [ ] P-3 (A) Structured credibility per account: consistency, corroboration, plausibility, motive, demeanour — each with cited evidence; never a verdict.

### Phase A — analysis
- [x] A-6 (A) Allegations × evidence × finding matrix on the case (supports / contradicts / neutral per item, cited); ACH moved into the ledger.
- [ ] A-7 (A) Manual entries in the case chronology (marked investigator entry), merged with the automatic one.
- [x] A-8 (A) Amount-weighted funds tracing over transaction facts; money-flow chart with amounts.
- [x] A-9 (A) Force-directed relationship chart; per-pair communication timeline.

### Phase Q — answer and extraction quality (from the case bench)
- [ ] Q-2 (A) Civil court outcome and docket to ≥80% correct-or-refused; the outcome question reads the disposition field first.
- [ ] Q-3 (A) DOJ / press-release questions: office from the release's office line or signature; honest "not stated" otherwise.
- [ ] Q-4 (A) "What happened" answers keep names, ages and counts of the lead.
- [ ] Q-5 (A) A 10k-case-per-category evidence-only run (scale), plus a 1,000-case AI sample; publish results.
- [ ] Q-6 (O) Owner-run large cases: NIST CFReDS Data Leakage (60 answers) and cleansed Enron.

### Phase S — security, privacy, governance
- [ ] S-1 (A) Retention schedule per case type; purge with a record (never silent); legal hold blocks purge.
- [ ] S-2 (A) Subject-access export and per-person erasure (GDPR-style) with a receipt.
- [ ] S-3 (A+O) Users: a named investigator profile per Mac user (Keychain-backed), shown in every log entry; decide whether multi-user roles are v1 or v2.
- [ ] S-4 (A) Full audit trail of user actions in a case (view, search, export, edit) into the HMAC chain.
- [ ] S-5 (A) App lock tests; refresh stale "database encryption is a separate decision" text.

### Phase U — product polish
- [ ] U-1 (A) Accessibility: VoiceOver labels on every control, remove the 81 fixed font sizes, test at the largest text size; VoiceOver walk script.
- [x] U-2 (O) Localization: **owner decided 2026-10-23 — English only for v1.** No translations ship; strings stay in the String Catalog for a later release.
- [ ] U-3 (A) Help Book (or in-app guide per investigation type) and a sample case per persona (from the case packs).
- [ ] U-4 (A) Crash & hang diagnostics (MetricKit, on-device, user sends) + a "send diagnostics" button.
- [ ] U-5 (A) Guided "move to a new Mac" flow (backup + recovery key).
- [ ] U-6 (A) Viewer privacy manifest; iPhone/iPad scope note in the listing.

### Phase R — release
- [ ] R-1 (A) Pricing: StoreKit purchase-flow tests, `.storekit` in a scheme; fix SHIP_DECISIONS "$29–49".
- [ ] R-2 (A) App Review 2.3.1 check of every claim under the new name (does the copy promise judgement? it must not); CLAIMS.md rows.
- [ ] R-3 (A) Screenshots for the five planned shots on public-domain case packs.
- [ ] R-4 (A) Update PRODUCTION_STATUS.md (dated 2026-08-07, schema v102) to today.
- [ ] R-5 (A+O) SHIP_DECISIONS §3 gates: the agent produces the evidence for each; the owner signs off.
- [ ] R-6 (O) HOLD 1 witness: walk each persona's investigation in the real app.
- [ ] R-7 (O) Clean-machine install test; owner 20-question test.
- [ ] R-8 (O) Lawyer review of privacy policy, terms, acknowledgments.
- [ ] R-9 (O) Archive, sign, submit; App Review; "1.1 is live".

## 4. Done means

Investigations Made Easy is complete when every box above is ticked, and in particular:
- each of the nine personas runs its case start to end in the real app (R-6) and in CI (T-1), with wrong facts = 0;
- a case can be taken from intake to closure without leaving the app (C, E, P, A phases);
- the answer bench shows ≥80% correct-or-honestly-refused in every category with zero fabricated values (Q);
- every SHIP_DECISIONS gate is signed (R-5) and the app is live (R-9).

Suggested order: T → N → C → E/P (parallel) → A → Q → S → U → R.

# Investigation focus — research and todo (2026-10-18)

Owner question: make the app investigation-only, with every listed persona able to run a case
start to end on its own documents, and prove it on real open-source cases.

This file is the research (what is true today), the todo list, and a plan check. Nothing here
is built yet.

## 1. What is true today (code audit)

| Layer | State | Evidence |
|---|---|---|
| Case engine (Investigator) | **Real, ledger-backed.** Case + scope, subjects, identity merge, hypotheses, source reliability, contradictions/gaps, custody manifest, findings, closure, CAPA. | `Kalsmritikosh/Personas/Investigator/` (35 files); ~30 `Investigation*Tests` suites incl. two gold cases |
| Persona job catalogs | 183 jobs across 10 personas, every one mapped to one of 16 shared case-engine kinds. | `Personas/*/…PersonaPackage.swift`, `PersonaJobKind.swift` |
| Persona job launch | **Reachability only.** Most kinds return a count ("N methods available", "N subjects in scope"); only caseIntake, ask, findings actually produce a work product. | `PersonaJobService.swift:84-197` |
| Persona studios (forms) | **Not evidence-backed.** Correct report *shapes* (privilege log, SIU referral, net-worth, ACH, fact-check memo, workplace report…) filled in by hand; no ledger reads, no evidence IDs. | `Kalsmritikosh/Investigate/*`, `UI/*StudioView.swift` |
| Persona acceptance tests | Lawyer, Journalist + Individual exist; the other 7 personas have none. | `LawyerPersonaAcceptanceTests`, `JournalistIndividualAcceptanceTests` |
| Coverage matrix | Stale (2026-08-23); most rows still "Absent" though much has shipped since. | `PERSONA_JOB_COVERAGE_MATRIX.csv` |

**Verdict:** one persona (Investigator) is complete start to end. The other nine share its
engine underneath, but their persona-specific deliverables are typed by hand and are not tied
to evidence — which breaks the claim–evidence contract for exactly the documents a user would
hand to a court, regulator or editor.

## 2. Is it "investigations made easy" or "investigation documentation made easy"?

The app does **not** investigate: it never interviews, decides guilt, establishes privilege, or
picks the root cause. Those stay human by design (human-only boundaries in every package).
What it does — and does better than anything on the market — is the *paper* of an
investigation: intake, keeping every source with custody, building the chronology, finding
contradictions and gaps, and producing the report where every sentence points at its source.

Recommended line: **"Investigation documentation made easy"**, sub-line **"From evidence to
report — every finding linked to its source."** "Investigations made easy" overclaims and would
be read by professional buyers (and App Review, Guideline 2.3.1) as promising judgement the app
deliberately does not make.

## 3. Personas under an investigation-only product

| Persona | Keep? | Investigation it serves |
|---|---|---|
| Investigator (general / internal) | Keep — reference persona | Internal misconduct, IP leakage, incident |
| Lawyer / litigation support | Keep | Matter fact-finding, privilege log, production |
| Compliance / HR / workplace | Keep | Harassment/discrimination complaint, policy breach |
| Forensic accountant | Keep | Funds tracing, net-worth, financial-statement fraud |
| SIU (insurance) | Keep | Claim fraud, staged accident rings, referral |
| Journalist | Keep | Fact-check, verification, accountability story |
| Researcher (integrity) | Keep, reframed | Research-misconduct / reproducibility inquiry |
| Genealogist | Keep, reframed | Identity/lineage proof (GPS) — heir search, probate |
| Individual | Keep, reframed | Personal disputes: insurance claim, tenancy, employment |
| Content creator | **Hide** (module off) | No investigative job; FTC disclosure checks move to Compliance |

## 4. Open-source cases (verified 2026-10-18)

| Persona | Case | Source | Licence | Ground truth to compare with |
|---|---|---|---|---|
| Investigator | NIST CFReDS **Data Leakage Case** (IP theft, 1 PC + 3 media, 2015) | cfreds.nist.gov/all/NIST/DataLeakageCase | US Gov work (public domain) | NIST answer PDF: 60 questions |
| Investigator (incident) | CSB final report, e.g. DuPont La Porte (2014) | csb.gov/documents | US Gov work; third-party photos excluded | CSB root causes + recommendations |
| Lawyer | **EDRM Enron** email set (FERC investigation) | edrm.net | CC BY 3.0 US — cite ZL Technologies; use the Nuix-cleansed copy (PII removed) | FERC findings / public trial record |
| Compliance / HR | EEOC v. PJR Enterprises (N.D. Ill. 1:04-cv-07736) complaint + consent decree | courtlistener.com RECAP docket 11998705 | Court filings, public record | Decree terms + alleged facts |
| Forensic accountant | SEC v. WorldCom (LR-17588) complaint + AAERs | sec.gov litigation releases | US Gov work | Amounts/periods stated in the complaint |
| SIU | USAO S.D. Fla. 33-defendant staged-accident indictment | justice.gov/usao-sdfl | US Gov work | Defendants, roles, scheme dates |
| Journalist | FTC v. Teami (2020) complaint vs. the company's public claims | ftc.gov legal library | US Gov work | Claims the FTC found deceptive |
| Researcher | ORI case summary + the retracted papers (Retraction Watch DB via Crossref) | ori.hhs.gov/case_summary, crossref.org | US Gov work / open data | ORI findings, retraction reasons |
| Genealogist | 1950 US census (NARA) + linked public-domain records for one family | 1950census.archives.gov | Open, US Gov records | A GPS-sound written conclusion |
| Individual | CSB / NTSB public docket as "my claim file" (insurance-dispute shape) | data.ntsb.gov/Docket | US Gov work | Docket facts and dates |

Rules for every pack: store only small, licensed extracts under
`KalsmritikoshTests/Fixtures/InvestigationCases/<persona>/` with a `SOURCES.md` (URL, date
fetched, licence, attribution); no personal data beyond what the public record already carries
(use cleansed Enron; redact private individuals in court filings); large originals (CFReDS
images, full Enron) are owner-run, not CI.

## 5. Todo list

### Phase A — make each persona's deliverable evidence-backed (the real gap)
- [ ] A1 `PersonaJobService`: every kind returns a work product (rows produced, IDs), not a count. Kinds still count-only: dataLab, subjectDossier, identityResolution, analysis, sourceReliability, contradictionGap, evidenceCustody, closure, methods, causal, linkage, capa, effectiveness.
- [ ] A2 One `StudioDraft` bridge: a studio form is pre-filled from the case (parties, dates, amounts, documents) and every filled field carries the evidence IDs it came from; hand edits are marked as "investigator entry".
- [ ] A3 Report export refuses a studio field with neither evidence nor an "investigator entry" mark (same gate as findings).
- [ ] A4 Wire each studio through A2: Privilege log (Lawyer), Workplace report (Compliance), Net-worth + funds tracing (Forensic), SIU referral (SIU), Fact-check memo (Journalist), Research appraisal (Researcher), GPS proof argument (Genealogist), Dispute file (Individual).
- [ ] A5 Hide Content creator (module off by default) and move FTC-disclosure checks into Compliance.

### Phase B — case packs (fixtures from §4)
- [ ] B1 Fetch, trim and licence-note one pack per persona; add `SOURCES.md` and an `expected.json` (facts, dates, parties, amounts, conclusions from the published record).
- [ ] B2 Claims gate: each pack's licence row in `CLAIMS.md`.

### Phase C — start-to-end simulations
- [ ] C1 `InvestigationCaseSimulationTests`, parameterised over the 9 packs: intake → ingest → subjects → chronology → contradictions/gaps → studio draft → report.
- [ ] C2 Score against `expected.json`: recall of facts/dates/parties, wrong-fact count must be 0, every report sentence cites a source in the pack.
- [ ] C3 Owner-run large cases: CFReDS Data Leakage (score against NIST's 60 answers) and full cleansed Enron; results recorded in `docs/verification/`.
- [ ] C4 Fix every miss found by C1–C3 at the layer it comes from (parser → extraction → case engine → studio), never by tuning the fixture.

### Phase D — product and listing
- [ ] D1 Onboarding asks "What are you investigating?" and opens the matching persona with a case already created.
- [ ] D2 Regenerate `PERSONA_JOB_COVERAGE_MATRIX.csv` from code (measured, not hand-written).
- [ ] D3 Listing, website and screenshots use "Investigation documentation made easy"; review notes say judgement stays human.
- [ ] D4 SHIP_DECISIONS entry for investigation-only + the persona list.

## 6. Plan check — does this list reach "each persona start to end"?

| Requirement | Covered by |
|---|---|
| Every persona produces its own report from its own documents | A1, A2, A4 |
| Report claims are tied to evidence, not typed | A2, A3 |
| Real public cases, legally usable | §4, B1, B2 |
| Proven, not asserted: compared with the published outcome | C1, C2, C3 |
| Bugs fixed at the root | C4 |
| Investigation-only product | A5, D1, D3, D4 |

Gaps that remain on purpose: the app will not decide guilt, privilege or root cause (human-only
boundaries); disk-image carving for CFReDS is outside the app (the examiner exports files, the
app documents them); large packs are owner-run because CI cannot hold them.

Open owner decisions: product name; investigation-**only** (other uses hidden) vs
investigation-**first** (still usable as a general archive); persona build order (suggested:
Lawyer → Compliance → SIU → Forensic → Journalist → Researcher → Genealogist → Individual).

# Kalsmritikosh — Persona Jobs & What We Contribute

_Product research, 2026-07-13. Purpose: for each of the 5 personas, enumerate the
full range of jobs they actually do, how they do each today, and exactly what
Kalsmritikosh can contribute to each job. Grounded in online research (sources at
the end). **Planning document — not a build spec.**_

## Legend
- **✅ have** — the app already does this today.
- **➕ add** — a feature that fits our engine and could be built.
- **⛔ out of lane** — needs external data (case law, records databases, live web/OSINT),
  field work (surveillance/GPS), business ops (billing/e-filing), or statistics/meta-analysis.
  Kalsmritikosh is the **private, on-device, evidence-cited engine over the user's own documents** —
  everything else is deliberately out of scope.

## Our core capabilities (what every contribution builds on)
Ingest any archive in place → typed evidence blocks + exact source locators →
entities / dated events / relationships / assertions → timeline reconstruction →
contradiction + gap detection → hybrid retrieval → **answers with citations** →
OCR + audio transcription → chain of custody → all fully **on-device**.

---

## 1. LAWYER (litigator)

| # | Job | How they do it today | What we contribute |
|---|---|---|---|
| 1 | Document review / e-discovery | Relativity/Everlaw; tag responsive vs privileged across thousands of docs | ✅ ingest whole set · ✅ ask across it with citations · ✅ full-text + semantic search · ➕ bulk relevance tagging · ➕ saved "issue" views |
| 2 | Privilege review + log | Flag privileged docs, build log in Excel | ✅ privilege detection + filter · ➕ one-click privilege-log export (doc/author/date/basis) |
| 3 | Chronology / statement of facts | Hand-build timeline in Word/Excel | ✅ auto timeline, each event linked to source · ➕ export chronology (table/PDF w/ doc refs) |
| 4 | Deposition prep + transcript analysis | Read 5,000+ transcripts, code metadata, hunt contradictions | ✅ ingest transcripts · ✅ contradictions across testimony · ✅ every mention of a person/topic · ➕ per-witness summary · ➕ impeachment pack |
| 5 | Legal research → memo | Westlaw/Lexis, summarize | ✅ summarize *their own* case docs · ⛔ external case law · ➕ draft the fact section from the record |
| 6 | Drafting discovery (rogs/RFPs/responses) | Draft in Word from the facts | ➕ draft grounded in the record + cite which doc answers each request |
| 7 | Trial prep (exhibit/witness lists, binders) | Compile manually | ➕ generate exhibit list + witness summaries · ➕ export trial binder (docs + index) |

---

## 2. INVESTIGATOR (private investigator)

| # | Job | How they do it today | What we contribute |
|---|---|---|---|
| 1 | Background check | Public-records DBs (Tracers) + surveillance | ⛔ records-search DB · ✅ organize/analyze records they collect · ➕ auto subject dossier |
| 2 | Infidelity / family / custody | Surveillance + social + records → court evidence | ✅ organize evidence · ✅ timeline · ✅ transcribe recordings · ➕ case report (no-admissibility disclaimer) |
| 3 | Insurance / workers-comp fraud | Surveillance + medical-record review | ✅ review claim/medical docs · ✅ flag inconsistencies (activity vs claim) · ➕ contradiction report |
| 4 | Skip tracing / missing persons | Records + "web of connections" | ⛔ live tracing · ✅ connection map across provided docs |
| 5 | Corporate / due diligence / embezzlement | Review financials + litigation history | ✅ ingest financials/emails · ✅ entity/relationship map · ✅ surface anomalies · ➕ findings report |
| 6 | Case report (every case ends here) | CaseFlow auto-drafts → PDF | ✅ `InvestigationReportBuilder` scaffolding · ➕ export report (findings+timeline+contradictions+exhibits) |
| 7 | Chain of custody | Manual log | ✅ custody events tracked · ➕ custody-log export (client/court) |
| — | Surveillance, GPS, process serving, billing | field/ops | ⛔ out of lane |

---

## 3. JOURNALIST (investigative)

| # | Job | How they do it today | What we contribute |
|---|---|---|---|
| 1 | Document / records analysis | DocumentCloud / Google Pinpoint | ✅ ingest huge dumps · ✅ ask across them · ✅ entity/date extraction · ✅ on-device (source safety) |
| 2 | FOIA / leak processing | MuckRock + DocumentCloud add-ons | ✅ find newsworthy facts fast · ➕ PII detection · ➕ weak-redaction detection (recover + scrub) |
| 3 | Data journalism | Extract tables from PDFs; "interview the data" | ✅ table extraction · ✅ deterministic table Q&A (sum/filter) · ➕ data-diary export |
| 4 | Interviews | Record → Whisper transcribe | ✅ transcription · ✅ search across interviews · ➕ speaker labels |
| 5 | Verification / fact-checking | Footnote every fact to its source | ✅ every answer carries its source · ➕ footnote each draft sentence · ✅ contradiction surfacing |
| 6 | Right of reply | Track claims needing response | ✅ findings list = the claims to put to the subject |
| 7 | Publish | CMS / DocumentCloud embed | ➕ export annotated document (PDF/HTML) · ⛔ hosting |

---

## 4. RESEARCHER (academic / historian)

| # | Job | How they do it today | What we contribute |
|---|---|---|---|
| 1 | Literature review | Zotero + read/summarize/synthesize | ✅ ingest corpus · ✅ ask + synthesize with citations |
| 2 | Systematic / scoping review (PRISMA/PICO) | Rayyan/Covidence screening, dual reviewers | ✅ per-study extraction · ➕ screening/inclusion log + PRISMA counts · ⛔ formal dual-blind workflow |
| 3 | Data analysis / meta-analysis | SPSS/R statistics | ⛔ statistics · ✅ table extraction only |
| 4 | Reference management + citations | Zotero → footnotes/bibliography | ➕ citation export (BibTeX / RIS / footnotes) — biggest gap |
| 5 | Peer review | Read manuscript, assess | ✅ ingest manuscript + refs, cross-check claims vs cited sources · ➕ flag unsupported claims |
| 6 | Thesis / dissertation writing | Draft in Word + citations | ➕ draft-from-evidence section with inline citations |
| 7 | Archival history | Zotero-as-research-log + OCR | ✅ ledger *is* the research log · ✅ OCR · ✅ every fact sourced |

---

## 5. EVERYBODY / INDIVIDUAL

| # | Job | How they do it today | What we contribute |
|---|---|---|---|
| 1 | Find my own info | Dig folders + email search | ✅ ask in plain English → sourced answer |
| 2 | Financial / tax docs | Shoebox of PDFs | ✅ "what did I pay, when" cited to statement · ➕ simple totals via table path |
| 3 | Medical records | Portals + PDFs | ✅ ask across visits/labs, fully private |
| 4 | Home / legal / insurance matter | Scattered contracts | ✅ reconstruct the matter + key dates as a timeline |
| 5 | Genealogy / personal archive | Notes + scans | ✅ OCR + entity/relationship map across a lifetime of docs |
| 6 | Share a summary | Copy-paste into a message | ➕ export a clean, sourced summary (PDF/Markdown) |

---

## The pattern — additions that repeat across personas
The same short list of `➕` features completes jobs for 3–5 personas each. Building
these turns Kalsmritikosh from "gives insight" into "finishes the job":

| Addition | Jobs it completes | Personas |
|---|---|---|
| **Report / draft generator** (memo, discovery, trial doc, PI report, story, review, summary) | lawyer 3/5/6/7, PI 6, journalist 5, researcher 6, individual 6 | all 5 |
| **Citation export** (BibTeX / footnotes / Bates) | researcher 4, lawyer 1/3, journalist 5 | 3 |
| **Redaction + PII detection** | journalist 2, lawyer 1, PI 2 | 3 |
| **Privilege-log + chain-of-custody export** | lawyer 2, PI 7 | 2 |
| **Tagging / saved issue-views / dossier** | lawyer 1, PI 1, journalist 1 | 3 |
| **Speaker labels on transcripts** | PI 2, journalist 4, lawyer 4 | 3 |
| **Screening / inclusion log** | researcher 2 | 1 |

## Recommended priority (jobs-unlocked ÷ effort)
1. **Report / draft generator** — serves all 5; scaffolding exists (`InvestigationReportBuilder` + `AnswerSynthesizer`).
2. **Citation / export layer** (footnotes, BibTeX, Bates, privilege/custody logs) — reuses the same export plumbing.
3. **Redaction + PII detection** — highest "wow," self-contained.
4. Tagging / saved views / dossier; speaker labels; screening log — smaller, per-persona polish.

## Hard boundary (keeps the product focused)
External data (case law, records DBs, live web/OSINT), field work (surveillance/GPS),
business ops (billing, e-filing), and statistics/meta-analysis are **out of lane**.
Our promise is narrower and stronger: *read your own private archive, answer with the
evidence attached, and never send anything off your device.*

---

## Sources
- Lawyer: [MyCase – AI legal review](https://www.mycase.com/blog/ai/ai-for-legal-document-review/) · [CaseFox – eDiscovery 2025](https://www.casefox.com/blog/top-ediscovery-software-solution-list-for-law-firms/) · [Everlaw – trial prep](https://www.everlaw.com/blog/ediscovery-best-practices/trial-preparation-complete-guide/) · [Nextpoint – depositions](https://www.nextpoint.com/ediscovery-blog/taking-depositions/)
- Investigator: [CROSStrax – best PI software 2025](https://www.crosstrax.co/best-private-investigator-software/) · [NITA – 35 types of PIs](https://investigativeacademy.com/blogs/nita/types-of-private-investigators) · [Tracers – 7 types of investigations](https://www.tracers.com/blog/seven-types-of-private-investigations/) · [CaseFlow Investigator](https://www.caseflowinvestigator.com/)
- Journalist: [GIJN – intro to investigative journalism](https://gijn.org/resource/introduction-investigative-journalism/) · [GIJN – data journalism](https://gijn.org/resource/introduction-investigative-journalism-data-journalism/) · [GIJN – fact-checking](https://gijn.org/resource/introduction-investigative-journalism-fact-checking/) · [Media Copilot – Pinpoint vs DocumentCloud](https://mediacopilot.ai/google-pinpoint-vs-documentcloud-investigative-journalism/)
- Researcher: [MDPI – science of literature reviews](https://www.mdpi.com/2304-6775/11/1/2) · [ScienceDirect – systematic review guidelines](https://www.sciencedirect.com/science/article/pii/S0260691723000977) · [Harvard – Zotero for archival research](https://guides.library.harvard.edu/zotero_archival_research) · [PapersGPT](https://www.papersgpt.com/literature-review)
- Individual: [Second Brain comparison 2025](https://www.thesecondbrain.io/blog/notion-vs-obsidian-vs-notebooklm-vs-second-brain-comparison-2025)

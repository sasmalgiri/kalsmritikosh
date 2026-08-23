# SOP Register — the app's standing procedures, mapped to the world's governing bodies (2026-08-23)

**Why this document exists.** The whole app was built on one idea: an app is not
a bag of features — it is a set of Standard Operating Procedures, executed
faithfully, gate by gate, ending in the professional's real deliverable. If
that is true, the SOPs must be *listed*, so any user, auditor, or regulator can
read what the app binds itself to and compare it with the actual SOP of the
governing body in their own country. This is that list.

Every SOP below is enforced in code (stage gates + tests), not aspirational.
Its machine-readable form is the Sūtra (versioned, amendable, certified per
run — see SUTRA_GOVERNANCE.md).

## Part A — Core SOPs (apply to every workflow, every persona)

| # | SOP | What it binds | Enforced by |
|---|-----|---------------|-------------|
| A1 | Evidence-only answering | No claim without cited evidence IDs; validated against the retrieval set | Claim–evidence contract, evidence gate (ship/downgrade/refuse/surface-conflict) |
| A2 | Conflict preservation | Conflicting evidence shown with both sources — never averaged | Contradiction register + doctrine "never average a conflict away" |
| A3 | Reserved human decisions | Merges, root causes, dispositions, approvals are made by a person, never auto-asserted | Sūtra `humanDecisions` + conformance check |
| A4 | Standard of proof before findings | Findings cannot be approved without a declared standard | `EvidentiaryStandard` gate in handoff |
| A5 | Source reliability rating | Sources rated A–F × 1–6 before weight is placed on them | `AdmiraltyCode` (NATO/Admiralty scale — international) |
| A6 | Chain of custody | Custody recorded contemporaneously; evidence hashed early | `CustodyEvent` per SWGDE/NIST — intl. equivalent ISO/IEC 27037 |
| A7 | Privacy by architecture | No document, question, or ledger content leaves the device | PrivacyGate + sandbox; exceeds GDPR/CCPA/DPDP by design (data never collected) |
| A8 | AI disclosure at point of use | Every answer and report declares AI assistance and requires human review | LegalNotice on answers + reports (EU AI Act Art. 50 posture) |
| A9 | Document history | Every deliverable carries its audit trail, printed on the hardcopy | StudioAudit appendix |
| A10 | Amendment-only change | SOPs change by versioned amendment, never silent rewrite; certificates cite the version verified against | SutraAmendment + conformance citation |

## Part B — Workflow SOPs by persona, with governing-body mapping

Legend: ✅ named in-app · ≈ principle matches, local name differs · ⬜ not yet mapped

| Workflow (studio) | Standard named in-app | US | UK / Commonwealth | EU (civil law) | India | International |
|---|---|---|---|---|---|---|
| Investigator — RCA | 8D dual root cause (occurrence + escape) | ✅ 8D / CAPA | ≈ same (8D is global industry) | ≈ same | ≈ same | ✅ ISO 9001 CAPA family |
| Investigator — ACH | Heuer, *Psychology of Intelligence Analysis* | ✅ CIA tradecraft | ≈ UK PHIA structured analytic techniques | ≈ | ≈ | ✅ NATO Admiralty scale for sources |
| HR / Compliance | Balance of probabilities; notice + opportunity to respond | ✅ EEOC-style practice | ≈ ACAS Code (UK) | ≈ works-council norms vary | ≈ POSH Act inquiry rules | ≈ ILO fair-procedure principles |
| Lawyer — privilege log | FRCP 26(b)(5)(A) | ✅ | ≈ CPR PD 57AD disclosure (E&W) | ⬜ privilege differs fundamentally (in-house counsel!) | ≈ BSA 2023 / Evidence Act privilege | — |
| Forensic accountant | FRCP 26(a)(2)(B), Daubert, named tracing methods | ✅ | ≈ CPR Part 35 expert duties | ≈ court-appointed-expert model | ≈ BSA expert evidence | ≈ IFAC/ISA 620 using expert work |
| SIU — insurance fraud | NAIC Model #901, NICB indicators, good-faith referral | ✅ | ≈ ABI/IFB (UK) | ≈ Insurance Europe practice | ≈ IRDAI fraud framework | — |
| Journalist — fact-check | Verification + right of reply + alleged-labelling | ≈ SPJ Code | ≈ IPSO Editors' Code (UK) | ≈ EU media councils | ≈ Press Council norms | ✅ the disciplines themselves are the global newsroom canon |
| Researcher — review | PRISMA 2020 + GRADE | ✅ | ✅ | ✅ | ✅ | ✅ genuinely worldwide (WHO/Cochrane use both) |
| Genealogist | Genealogical Proof Standard (BCG) | ✅ | ≈ AGRA/ASGRA norms | ≈ | ≈ | ≈ GPS is the de-facto global reference |
| Content creator | Claims/rights/disclosure/corrections | ✅ FTC endorsement guides | ≈ CMA/ASA (UK) | ≈ UCPD + AI Act disclosure | ≈ ASCI influencer guidelines | — |
| Individual — binder | Findability + freshness review | ≈ estate-practice norms | ≈ | ≈ | ≈ | universal by nature |

## Part C — World-coverage audit (the honest part)

**Strong globally.** The core SOPs (Part A) are jurisdiction-independent —
evidence, citation, conflicts, human decisions, custody, privacy are the same
disciplines everywhere. PRISMA/GRADE, 8D/ISO-CAPA, the Admiralty scale, and the
newsroom disciplines are genuinely international. The architecture (on-device,
no data collected) satisfies the *strictest* privacy regime anywhere by
construction, so privacy coverage is worldwide today.

**US-named, world-compatible.** Where a named standard is US-specific (FRCP,
NAIC, FTC, BCG), the *procedure* the studio enforces (describe without
revealing; separate fact from opinion; disclose material connections; log nil
searches) matches the local equivalent listed above — the local *citation* is
what differs. The report headers currently cite the US instrument.

**Real gaps (ranked).**
1. **EU privilege** — the in-house-counsel privilege difference (Akzo Nobel) is
   substantive, not cosmetic; the privilege-log studio needs an EU mode note.
2. **Local citation switching** — a jurisdiction picker that swaps the cited
   instrument (FRCP ↔ CPR ↔ BSA) on report headers. Structure is ready:
   `Sutra.provenance` + report headers are single-sourced; this is a catalog +
   picker, not a rewrite.
3. **Civil-law standards of proof** — `EvidentiaryStandard` lists common-law
   standards; civil-law "intime conviction" / free evaluation should join it.
4. **Non-English deliverables** — hardcopies render in English only.

**Verdict:** the *procedures* cover the world; the *citations* cover the US +
international bodies. Items 1–3 above are the path from "US-cited, globally
correct" to "locally cited everywhere" — each is an amendment (new sutra
versions), exactly the change process built for this.

## Part D — where to read the SOPs in-app

Settings ▸ System ▸ **Sūtra** (the Constitution inspector): every phase's
obligations, reserved human decisions, and prohibited conclusions, per
discipline, with version and amendment history. This register is the human
narrative; the inspector is the binding, machine-readable form.

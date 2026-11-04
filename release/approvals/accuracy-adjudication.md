# Gate `accuracy-adjudication` — AGENT review record (not a human adjudicator)

Decision: NOT APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT accuracy adjudicator (records the owner's 2026-11-04 decision; no new measurement)
Date: 2026-11-04
Commit: 7d720fe1b0dbd7a2af6c24f7cc3d168da37498b0
Evidence: docs/agent-reviews/candidate-review-7d720fe1-accuracy-adjudication.md; docs/agent-reviews/accuracy-adjudication-ho22-rules.md; docs/agent-reviews/accuracy-adjudication-ho22-opus5.md; docs/agent-reviews/real-case-old-six-ai-comparison-2026-11-04.md; docs/agent-reviews/real-case-v2-interim-2026-11-04.md; docs/ACCURACY.md
Notes: Accuracy was NOT measured live on this candidate (owner decision 2026-11-04: simulation only, no paid live testing). The whole-case reader on this candidate has never been evaluated on real or held-out cases.
- Last measured, on earlier code: ho22-chron on e49783fd — rules 0.00 % wrong (sample estimate, 95 % upper bound 2.85 %), Opus 5 0.22 % wrong (2/928); real solved cases round 1 on 14e0708b (5 tuned cases) — 44 % correct per question, 9.9 % wrong, 2.5 confident-wrong per 100. Neither describes this candidate; the real-case result does not meet the ≤3 % bar.
- Public texts claim no accuracy figure (FAQ and support say "not measured on this version"; terms §3 "no guarantee of accuracy").
- The record is NOT APPROVED because the owner's condition — no accuracy claims in public text — is not met: qualitative claims that the product does not guess remain in the App Store description (APP_STORE_LISTING.md:51 "tells you honestly instead of guessing"), on the Marketing URL (docs/index.html:199, :234, :265, :414) and in Help (HelpRegistry.swift:159), contradicted by the last real-case measurement.
- It may be re-issued as ACCEPTED (owner decision to ship without a live measurement, accepted by AGENT review as disclosed) on a new commit once those sentences are replaced by behaviour-only wording and practitioner PB1 is fixed. An ACCEPTED record would be a waiver of the gate's ≤3 % held-out requirement, not a pass, and must say so.
- Conflict to resolve: ci/release-gates.json says this gate "closes only by the owner's own record; the agent never writes it", while the owner's decision of 2026-11-01 lets agent reviews replace human gates. The owner should confirm which governs, or countersign, before any ACCEPTED record.

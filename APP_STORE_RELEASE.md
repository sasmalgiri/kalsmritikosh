# App Store Release Runbook — v1 (2026-08-24)

## State of the code (verified, all on `main`, all pushed)

- **Full suite: 3,698/3,698 passed** (2 intentional owner-archive skips) — run
  2026-08-24 after warnings batch 8.
- 10 persona studios with hardcopy-faithful deliverables + audit trails.
- Sūtra constitution: versioned amendments, conformance certificates naming
  their constitution, Compliance Board with periodic re-checks, in-app SOP
  Handbook generated from the enforced rules.
- Fully private by default: zero downloads (BGE models in-bundle, reasoning =
  Apple on-device), zero network (code + locked v1 profile + test-pinned), and
  **kernel-enforced** — outgoing network connections = No in Release.
- Legal notices v1.4: competitor-parity clauses, subscription-proof payments,
  SOP-claim bounding (interpretation, not certification).
- Release hygiene: all developer tools compile out of Release builds.
- Warnings campaign: 114 declarations fixed across 8 suite-verified batches;
  two genuine Swift-6 hard errors eliminated. Remaining implicit-MainActor
  diagnostics stem from ONE build setting (below) — none affect Release
  behavior or App Review.

## Owner steps, in order

1. **(Optional, recommended) Finish the warnings in one stroke:**
   Target ▸ Build Settings ▸ search "Default Actor Isolation" ▸ set to
   `nonisolated`. Then tell the agent "verify isolation flip" — full suite +
   smoke must pass before keeping it. Ship without this if in doubt; warnings
   don't block review.
2. **Archive:** select `main`, Product ▸ Archive (Release config).
3. **Verify the sealed sandbox on the artifact:**
   `codesign -d --entitlements - Kalsmritikosh.app | grep -c network.client`
   → must print `0` (internet closed, kernel-enforced).
4. **App Store Connect:**
   - Privacy label: **Data Not Collected** (truthful — no network at all).
   - `ITSAppUsesNonExemptEncryption = NO` (no network traffic to encrypt).
   - Age rating questionnaire; category: Productivity or Business.
   - Price: **Free** (owner decision: free launch to gather problems;
     subscription later — terms already subscription-proof at v1.4).
   - Attach the official Meta Llama licence text (MODEL_ATTRIBUTIONS.md).
   - Description: own the ~600 MB size — "a larger download because your AI
     never phones home"; lead with the SOP system + zero-network claims
     (mirrors docs/index.html, already aligned with in-app notices).
   - Support URL: the docs site; contact: the in-app mailto feedback address.
5. **Submit for review.**

## In parallel (not blocking)
- Counsel review of LegalNotice v1.4 + governing-law/disputes clause
  (required before charging money; optional for the free launch).
- Trademark clearance for "Kalsmritikosh".

## After approval
- Tag the release commit; the SOP Compliance Board's periodic re-checks and
  the sutra amendment process govern all future changes.

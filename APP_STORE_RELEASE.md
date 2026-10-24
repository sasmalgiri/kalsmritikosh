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
   - Price: **free download, 14-day free trial, then one $79 in-app
     purchase**, no subscription, Family Sharing on (SHIP_DECISIONS
     2026-10-18; supersedes the earlier $29–$49 one-time tier).
   - Third-party notices: bundled BGE MIT notice ships inside the app
     (Resources/THIRD_PARTY_NOTICES.txt); NO Llama licence applies to v1
     (no Llama model ships — see MODEL_ATTRIBUTIONS.md).
   - Description: paste from `release/APP_STORE_LISTING.md` (name
     Investigations Made Easy; R-2 checked 2026-10-24: evidence-only answers
     by default, English only, judgement stays with the investigator, no
     accuracy figures).
   - Support URL: the docs site; contact: the in-app mailto feedback address.
5. **Submit for review.**

## In parallel (not blocking)
- Counsel review of LegalNotice v1.5 + governing-law/disputes clause
  (required before charging money — v1 is a paid one-time purchase).
- Trademark clearance for "Investigations Made Easy" (the customer-facing name).

## After approval
- Tag the release commit; the SOP Compliance Board's periodic re-checks and
  the sutra amendment process govern all future changes.

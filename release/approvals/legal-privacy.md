# Gate `legal-privacy` — AGENT review record (not counsel)

Decision: NOT APPROVED
By: AGENT (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-04
Commit: 7d720fe1b0dbd7a2af6c24f7cc3d168da37498b0
Evidence: docs/agent-reviews/candidate-review-7d720fe1-legal-privacy.md (read-only review of code and release package; no build, test run or GUI)
Notes: An agent review, not a lawyer's opinion. Blocking findings that must be fixed on a new candidate before this gate can pass:
- LB1 — erasing a case leaves the full text of its documents in the on-Mac outbound log ("What was sent"), although the erase screen promises "Removes everything recorded for this case" (OnlineCloudProvider.swift:532-536, :591-605; SchemaMigrations.swift:7025-7041; CaseErasure.swift:163-166; CaseFileView.swift:507).
- LB2 — the Marketing URL still says "Runs 100% on your Mac … No account, no uploads" and "Runs fully on your device: Yes" without the Online-mode qualifier, contradicting the privacy policy, the label and the AI plans (docs/index.html:269, :315, :467).
- Should-fix (see the review): name Anthropic and the relay on the per-case permission sheet; the policy's "shows these terms when it asks for your permission"; tie a case permission to its destination; per-case withdrawal; policy wording on session-allowed question sends; Google retention; stale in-app wording; raise GLOBAL_CAP_USD before release (and the var/secret clash in wrangler.toml); review notes missing two setup steps; candidate packet names c30d2191.
- Checked and fine: what is sent and when, matches the policy; relay keeps counts only; label = manifest = policy; 13 blocked storefronts consistent; 3.1.2 paywall disclosure; 3.1.1 never-expiring packs; terms (LAEULA supplement, 18+, no accuracy guarantee, liability cap, refunds through Apple); no public accuracy figure.

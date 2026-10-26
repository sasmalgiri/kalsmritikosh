# Owner ship checklist — Investigations Made Easy

The agent side of the implementation brief is recorded in `PRODUCTION_STATUS.md` (execution record,
2026-10-26). Everything below needs the owner: a signed build, an Apple account, a real person, or a
legal judgement. Nothing here has been done by the agent. Tick each with the date and what was seen.

## Before anything else

- [ ] **Rotate the Claude API key** pasted into the session on 2026-10-26 (console.anthropic.com →
      API keys → revoke, create new). It was used only for public bench data and is stored at
      `~/CaseBench/.anthropic-key` (mode 600); after rotating, replace or delete that file.
- [ ] Merge PR #169 once its CI is green (agent pushes; merge is your call if you prefer).

## In the signed app (Xcode → Product → Archive, then run the archived build)

- [ ] **Fresh install** on a Mac that never had the app: onboarding shows "Investigations Made Easy —
      From evidence to findings"; Cases opens by default; Private mode is on.
- [ ] **Upgrade**: run the archived build over your existing ledger; it opens, the schema reaches 157,
      Settings shows no "could not repair" warning (`SchemaConformance.unrepaired` empty).
- [ ] **A real case end to end** (brief §1 reference journeys — do one of: workplace complaint, safety
      incident, payment fraud): create the case → add a small mixed set of documents → frame an
      allegation → link evidence for AND against → interview → confirm the statement → add a
      correction → hypothesis with rationale/contrary/alternatives → build findings → approve under a
      standard of proof → close → reopen. Check: "Next steps" on the Overview change as you go;
      "References to repair" stays empty; the statement export shows the correction after the text.
- [ ] **Audit chain**: Settings → integrity/verify after the journey reports intact (the v157 fix:
      sealing used to fail once any case action existed).
- [ ] **Private mode network test**: with Little Snitch / `nettop`, use the app for 10 minutes in
      Private mode (import, search, Ask, export) — zero connections from the app and its helper.
- [ ] **Online mode**: switch on, ask one question; the preview shows exactly what is sent; cancel
      once (nothing sent), send once (the send log records it); switch back to Private.
- [ ] **Backup and restore**: Settings → Back up (ledger snapshot). Restore on a second Mac or user
      account with the recovery key; the case, citations and findings reopen. Note: the complete
      archive backup with originals (brief §11) is NOT built yet — the ledger-only backup says so.

## StoreKit (Xcode StoreKit configuration, then TestFlight)

- [ ] Trial starts; trial expiry shows the purchase screen; Settings, backup and export still work.
- [ ] Purchase, restore on reinstall, offline launch with the cached entitlement.
- [ ] Pending purchase (Ask to Buy), cancellation, refund/revocation, Family Sharing.
- [ ] Decide and write down the rule when the App Store has not answered (today: full use).

## App Store Connect

- [ ] Name "Investigations Made Easy" available; subtitle "From evidence to findings".
- [ ] Screenshots from the sample ledger only (no real case data).
- [ ] Privacy labels match: no data collected in Private mode; Online mode sends questions to the
      provider the person chose, with their key.
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption = NO` rests on Apple CommonCrypto/CryptoKit
      only (SHIP_DECISIONS 2026-10-17) — confirm with counsel.
- [ ] Minimum OS / hardware stated; AI features need macOS 26 + Apple Intelligence.

## People

- [ ] Five target users, one predefined task (create a case, import a small mixed set, open a
      citation, correct a fact, add contrary evidence, export a labelled draft). Gate: at least four
      finish without help. Record time, mistakes, help needed.
- [ ] Lawyer review of privacy policy, terms, the in-app notices and the findings/report wording
      ("judgement stays with the investigator"; approvals are not legal signatures).
- [ ] Trademark/name clearance for "Investigations Made Easy".

## Accuracy claims you may make (from measured results only)

- Use only figures in `docs/CLOSED_CASE_SIMULATION.md` with their sample and mode. The honest
  held-out figure for reworded prosecution questions is 87.6 % right / 7.2 % wrong (rules → Claude,
  n = 898). "What was X charged with" and "what sentence" are below the brief's bar — do not claim
  them as reliable. Never claim zero errors.

# OWNER_RELEASE_RUNBOOK — the only remaining actions are yours

_Directive §57. Engineering status: **ENGINEERING / IMPLEMENTATION COMPLETE — OWNER RELEASE
ACCEPTANCE REQUIRED** (see `FINAL_ZERO_REMAINDER_MATRIX.md`). Every command, checklist,
harness and draft below already exists. Run these in order; each step names where to record
the result. When all boxes are checked, the status becomes **SHIP: GO**._

1. [ ] **Pull the final main.** `git checkout main && git pull --ff-only`. Confirm the last
   release-closure PR is merged and CI on main is green (7 checks).
2. [ ] **Repo setting (2 minutes):** GitHub → Settings → Rules → add `release-build` to the
   required status checks alongside the existing six.
3. [ ] **Owner acceptance day:** run `OWNER_ACCEPTANCE_CHECKLIST.md` end to end —
   private-archive ingest + 20 questions, the five persona journeys (record dates into
   `RELEASE_EVIDENCE_INDEX.md` §E), Fast/Full Evidence, the in-app answer eval, the
   sanitized-archive command, the SC1 scale benchmark (the marketed “tested to N GB” figure
   comes from THIS run), and the network-egress witness. Record everything in
   `release/RELEASE_EVIDENCE_v1.md`.
4. [ ] **Clean physical Mac:** run `CLEAN_MACHINE_ACCEPTANCE.md` (offline install proof;
   ideally include one macOS 15.6–25 machine to witness the honest deterministic-only mode).
5. [ ] **Legal/support pages:** insert your contact details into `docs/legal/PRIVACY_POLICY.md`,
   `docs/legal/TERMS_EULA.md`, `docs/legal/SUPPORT.md` (drafts are complete), review, and
   host them (any static host). Put the final URLs into `release/APP_STORE_LISTING.md`.
6. [ ] **Screenshots:** using the demo corpus from `CLEAN_MACHINE_ACCEPTANCE.md` (PII-free
   ProjectDelta), capture the views listed in `release/APP_STORE_LISTING.md`'s screenshot
   plan on the release build (standard App Store sizes; light mode; no personal data
   anywhere on screen).
7. [ ] **Archive + sign:** Xcode → Product → Archive (Release). Validate the archive.
   (All repository-side prerequisites are done: bundle id, entitlements, PrivacyInfo,
   offline Release, no debug UI/fixtures in Release — enforced by the release-build check
   and guards.)
8. [ ] **Upload to App Store Connect**, complete the metadata from
   `release/APP_STORE_LISTING.md` (name, subtitle, description, keywords, review notes,
   privacy labels = “Data Not Collected”, early-access wording), attach screenshots,
   set pricing per SHIP_DECISIONS ($29–49 one-time), submit.
9. [ ] **Record the sign-off** block at the bottom of `release/RELEASE_EVIDENCE_v1.md` and
   flip the pending §E / SC1 / AS rows in `RELEASE_EVIDENCE_INDEX.md` to PASS with dates.

That is the complete list. Nothing on it is engineering; if anything on it turns out to
need code changes, that is a defect — file it and it comes back to the engineering side.

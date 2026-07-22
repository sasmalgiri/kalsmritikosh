# Release deliverables (owner-hostable / submittable)

All the **non-code** release artifacts, drafted to match the locked contract in
`SHIP_DECISIONS.md`. These cover REL-004 (legal/support/attributions), REL-005 (App Store
listing), REL-006 (release evidence), and P8.2 (legal/support pages). I draft; **you host/submit**.

| File | Purpose | Task | Your action |
|---|---|---|---|
| `PRIVACY_POLICY.md` | On-device, no-collection privacy policy | REL-004 | Host at the Privacy URL; add a contact address |
| `TERMS_OF_USE.md` | EULA / terms (supplements Apple's LEULA) | REL-004 | Review with counsel; host at Terms field |
| `SUPPORT.md` | Support page: FAQ, bug-report, backup/restore, limits, rollback | REL-004 / §8 | Host at the Support URL; add a contact |
| `APP_STORE_LISTING.md` | Name/subtitle/keywords/description/promo/nutrition labels/review notes/screenshot plan | REL-005 | Paste into App Store Connect; capture screenshots on the demo corpus |
| `RELEASE_EVIDENCE_v1.md` | Release-evidence record + owner sign-off checklist | REL-006 | Fill the `[owner: …]` fields from a build/run; sign off |

Attributions already live at repo root: `MODEL_ATTRIBUTIONS.md`, `THIRD_PARTY_NOTICES.md`
(bundled BGE-small MIT + any other notices). Reference these from the store/about page.

## What still needs *you* (not draftable)

These are the only remaining items, and none is code I can write:

1. **App run + eval** — launch, ingest, ask; fill EVAL-001/002 + gold metrics into `RELEASE_EVIDENCE_v1.md`.
2. **Scale runs (SCL-001…004)** — record 1/10/<N> GB timings on your Mac → sets the "tested to N GB" store figure.
3. **Signing + archive (REL-001)** — set your team + `MACOSX_DEPLOYMENT_TARGET = 26.0`, Product → Archive.
4. **Clean-machine test (REL-002)** — full journey on a fresh minimum-spec Mac.
5. **Owner acceptance (REL-003)** — your 20 representative questions.
6. **Submit (REL-005/006)** — host the pages above, paste the listing, upload screenshots, sign off.

Everything with code to write is done and green (443 tests). This folder is the paperwork so the
moment your app run + hardware checks pass, submission is copy-paste.

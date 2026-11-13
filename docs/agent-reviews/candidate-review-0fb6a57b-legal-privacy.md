# AGENT REVIEW — legal / privacy confirmation review (not counsel; owner decision 2026-11-01)

Decision: APPROVED
By: AGENT legal-privacy reviewer (Claude) — agent review per owner decision 2026-11-01
Role: AGENT legal/privacy reviewer
Date: 2026-11-13
Commit: 0fb6a57b5e137658d0537fc594dd87ca8569ad15

This is an agent review, not a lawyer's opinion or sign-off. It is read-only. I read `git log 4af12048..0fb6a57b` (38
commits: LS25, the UI-walk dummy relay, the smart-map tracker, defect slice D1, smart-map M1 and slices S1–S18, and CI
fixes) and the diffs for the areas below. I did not build, run tests, run CI or use the app. Where I say a test exists, I
read it; I did not see it pass.

- **Candidate:** `0fb6a57b` on `investigations-next`. It is pushed: `origin/investigations-next` contains it. The working
  tree differs only in Xcode-extracted `InfoPlist.xcstrings` and user metadata.
- **Baseline:** `candidate-review-4af12048-legal-privacy.md` (APPROVED; should-fix LS25; note LN12; carried LN4, LN6,
  LN8–LN11, owner steps LS6 and LS10).
- **Range size:** 428 files, about 80,000 lines added, schema v176 → v190. This is far larger than earlier confirmation
  ranges. I read the parts that affect privacy, not every line.

**Verdict: APPROVED.** I found no blocker. The range adds no network path, entitlement, helper host or provider. The only
new data sent off the Mac is the StoreKit signed transaction (JWS), which now goes to the relay in place of the bare
transaction number. The relay checks it and does not store it. The per-case AI permission is stricter than before. LS25
is fixed in code. The new vault-encryption wording is true in substance and does not claim that everything is encrypted.
There are three new should-fix items (LS26–LS28) and several notes. LS26 matters most and should be fixed before upload.

## 1. Network, sending and the relay

| Check | Result | Evidence |
|---|---|---|
| New network APIs in the app | None | `git diff -G 'URLSession\|URLRequest\|NWConnection\|WKWebView\|dataTask'` over `Kalsmritikosh`/`KalsmritikoshShare` for the range returns no file. No entitlement, `PrivacyInfo.xcprivacy`, network-helper or `ci/guards` network change is in the range. The `NSWorkspace.shared.open(url)` added in `SourceProvenanceChainView.swift` opens a local temporary copy (`ProtectedSourceUnlockService.inspectOriginal`). The new "CloudKit" strings are refusal and help text: no team service exists. |
| Relay credential (SEC-05, D1) | New data item, disclosed (see LS27c) | `AIIncludedRelay.swift:41` sends header `x-kals-signed-transaction` holding `VerificationResult.jwsRepresentation` (`Purchase.swift:762,769`). It is checked to be compact-JWS-shaped before it is sent. The JWS is held in memory only: it goes into `Entitlement.Record`, not into `CachedEntitlement`. The relay (`relay/src/jws.ts`, `index.ts:262-279`) checks the chain against a pinned Apple Root CA - G3, ES256, the bundle id, the environment and expiry. It keeps the decoded transaction for at most 5 minutes in an in-memory `VerificationCache`, writes no log line (no `console.` in `relay/src`), and stores only `originalTransactionId` as before. |
| Model and key on the relay | Unchanged | `relay/wrangler.toml` `ANTHROPIC_MODEL = "claude-opus-5-5"`. Own key is Anthropic only (`OnlineProviderKind`). The DEBUG `--ui-walk-dummy-relay` host `relay.ui-walk.invalid` is inside `#if DEBUG` (`AIIncludedRelay.swift:30-35`). `scripts/release-check-debug-args.sh` checks it. |
| Per-case consent | Still once per case; now stricter | `CaseReadPermission.swift`: a permission is now also bound to the model and to a salted 16-hex SHA-256 digest of the own key (`credentialDigest`, lines 41-46). Choosing another model, replacing the key or switching between own key and AI plan asks again. `lapsedReason` tells the person what changed. A change while the sheet is open voids the answer (`currentIdentity`). See LS27b for the stored digest. |
| AI assistant (S10) send path | Not reachable in this build (LS28) | `CaseAIAssistService.run` (`CaseAIAssist.swift:361`) sends through the existing whole-case reading plan: the cloud gate (`plan.prepare`), the per-case permission (`plan.permitted`, line 419) and `plan.readForAnalysis` (lines 437, 455). Nothing in the app calls `run`: the only callers are in tests. The UI (`CaseMapToolsPanel.swift:208` "this screen never runs the AI") only sets the mode and decides on stored proposals. |
| Automation "external effects" (S8) | Records only | `CaseAutomation.swift:274-301, 939-966`: recipients, channels and hand-over states are rows in the ledger. No code sends anything: `markHandedOver` records what the person reports. |
| Only Routing/Providers does network | Holds | No new caller of `NetworkHelperClient.send` outside `Routing/Providers/Online`. |

## 2. Disclosure texts changed in the range

Changed: `docs/privacy.html` (vault wording and the JWS), `DATA_FLOW_INVENTORY.md` v5 → v8, `THREAT_MODEL.md` v3 → v4,
new `docs/STORAGE_KEY_INVENTORY.md`, the `SHIP_DECISIONS.md` K11 row and IN-02 entry, the Settings managed-copies and
ledger texts, Help and the manual. Not changed: `LegalNotice.privacyStatement`, `docs/terms.html` and
`termsVersion` 1.12 (2026-11-06), `PrivacyInfo.xcprivacy`, `release/APP_PRIVACY_LABEL.md` and the listing.

**Vault encryption (IN-02) against the code: accurate, no over-claim.**
- New copies are sealed. `EvidenceVault.store` and `storeStreaming` use AES-GCM in 1 MiB chunks, with the index as
  authenticated data and a sealed length trailer. The key is `HKDF(ledger key, "evidence-vault")`, wired at
  `AppState.swift:1217-1219`. Older plain `<hash>` copies still open. With no ledger key, copies are plain.
- A sealed copy opened for viewing is plaintext in `EvidenceVault-open/` (owner-only). It is removed at launch
  (`AppState.swift:1225`), by `remove(hash)` and by full erase (the targets now include `EvidenceVault-open`). The
  provenance chain's `original-*` temporary copy (0444) is removed by `TemporaryPlaintextSweep` at launch once it is more
  than an hour old.
- `privacy.html:56-60` now lists what is not app-encrypted: receipts, intake, notes, AI transcriptions and web captures,
  diagnostics, the copy being viewed, copies from earlier versions, and Spotlight. It says these rely on FileVault "only if
  you have it turned on". It says only the copies the app keeps now are encrypted. That matches ST-03/ST-04 and
  ST-08–ST-14 of `STORAGE_KEY_INVENTORY.md`, `THREAT_MODEL` T2 and DATA_FLOW L1. No text says "everything is encrypted".
  Settings (`SettingsView.swift:1338` and the ledger line) and the Help security line say the same, with FileVault named.
- Complete backups: DATA_FLOW L6 and ST-16 say originals and the source map in a complete backup are plaintext and vault
  copies are carried as stored. That is correct (`BackupService`).
- Wording that is not quite right is in LS27a (how long the viewed copy stays) and LN13 (the log statement now says more
  than the code does).

**Relay paragraph (`privacy.html:116-118, 142`).** The substance is correct. The description of what the JWS contains is
incomplete (LS27c).

**Material-change date.** `privacy.html:40` still reads "Last updated: 4 November 2026". The text changed on 2026-11-08
(JWS) and 2026-11-12 (vault), and line 198 promises an updated date for material changes (LS27d).

## 3. Erasure

- **LS25: fixed in code.** In the exclusive-source step, `evidence_a` and `evidence_b` are now document columns
  (`CaseErasure.swift:896-897`), so a contradiction quoting an erased document is deleted and covered by the existing
  count-back. Person erasure lists "contradiction quotes" (`claim_a`, `claim_b`, `description`) among what still names the
  person (line 554). DATA_FLOW §3 is corrected. A test was added to `CaseErasureTests/caseErase`. Commit 58717ec8 says it was
  not run locally and was left to CI. I did not check the CI result. **Closed in code; the test result is still to be
  confirmed.**
- **S16 SEC-07.** Tables that name the case only through `origin_case_id` (Data Lab datasets) are erased and counted back.
  So are the undeclared children, tasks linked only to this case (DATA-08, S1) and automation receipts.
  `ErasureGenerations` and tombstones are kept tables. This is a real widening of erasure.
- **S16/S18: the LIKE-wildcard bug (should be recorded as a past defect).** Before this range, case erasure
  (`userTables`) and full erase both listed tables with an unescaped `NOT LIKE '%_fts%'`. That pattern also skipped any table
  with "fts" after its first letter, for example `studio_drafts`. Those rows were neither erased nor counted back. Both are
  now escaped (`CaseErasure.swift:711`, `AppState.swift:4584`). Earlier approvals, including mine at 4af12048, did not
  catch this. No released build had it (nothing has shipped).
- **S18 sync.** Case and person erasure now clear the values of erased rows from `sync_field_clocks`, `sync_conflicts` and
  `sync_dirty`, and person erasure also clears `sync_pending` (`scrubSyncSideTables`, line 615). This Mac's own batches in
  the sync folder are re-sealed without erased rows at the next sync (`SyncEngine.swift:90`). Full erase stops syncing and
  names the folder as kept (`AppState.swift:4545`). Spotlight items are removed on full erase and on a case erasure that
  removes documents.
- **Declared leftovers.** The matrix records these as not reached (SEC-07 IN_PROGRESS): batches other devices wrote, a
  device that already applied a batch, backups, snapshots, exports, intake, notes, AI transcriptions and Keychain items.
  They are disclosed in general terms: USER_MANUAL line 508 ("backup files, exports, sync folders and Spotlight"), DATA_FLOW
  §3 and L8, THREAT_MODEL T19, and ST-09–ST-12 ("not by erasure"). See LN16.
- **New gap from the default change: LS26.**

## 4. Diagnostics and logs (S16 SEC-11)

`DiagnosticsSanitizer` (`DiagnosticsReporter.swift:28-79`) runs on every payload before it is written, on every saved file
at start-up, and before the Send-diagnostics list (`DiagnosticsSendButton.swift:103`). It removes free-text keys:
`composedMessage`, `formatString`, `arguments`, `reason`, `message`, `userInfo` and the description keys. It cuts
`/Users/…` and `/var/folders/…` paths and masks credential-shaped text (`SecretRedactor`). An unreadable file is replaced or
deleted, not offered as it was. "Report a problem" (N4) is unchanged. File names are now logged as private, guarded by a
source test (`SmartMapS16Tests`). Credential-named values are never public (`SmartMapS9Tests.secretsNeverLeak`). Nothing
of this sends anything by itself. The label's "no Diagnostics" decision still holds.

## 5. Tests and the user's real container (S18 QA-14)

`TestHost.applicationSupport()` and `documentsDirectory(create:)` (`Core/Security/TestHost.swift:21-42`) send notes,
intake, diagnostics, import receipts, AI transcriptions and EvalBaselines to a per-process temporary folder only when
`TestHost.isActive`. In Release that is the constant `false` (lines 15-19), so the shipping path is the real Application
Support or Documents folder. Nothing test-only can be reached. `AcceptanceCaseFixture` is `#if DEBUG`.
`ProductModuleFlags.TestOverride` is Debug-only. The dummy relay is Debug-only and checked. The remaining direct uses of
`.applicationSupportDirectory` (DemoArchive, SampleArchiveMode, Routing stubs, DatabaseStack) are on the S18 guard's
reviewed list. Before S18, test runs wrote into the owner's real Notes, Intake, Receipts and Diagnostics, and overwrote
`fixed-point-check.md`. That affected the developer's Mac only, not users. See LN14.

## 6. App Privacy label

`release/APP_PRIVACY_LABEL.md` (2026-11-04) and `PrivacyInfo.xcprivacy` are unchanged and still accurate:
- **The JWS.** It reaches the relay and is kept only for the request, plus a 5-minute in-memory check cache. That is
  servicing the request, not collection. The stored item is still the original transaction number (User ID, linked).
  Storefront, price and the device-verification fields in the JWS are not kept. So nothing new is collected: no
  Location, no Device ID.
- **Vault, opened copies, sync scrub, diagnostics cleaning.** All on the Mac: not collected.
- **AI assistant.** Not reachable. When it is wired, it sends the same User Content types already declared.

No label change is needed.

## 7. AI assist (S10): labelling and withholding

- **Labelling.** Every item is a stored proposal, never a finding. `CaseAIProposal.label` (`CaseAIAssist.swift:168-176`)
  reads "Proposed by the AI, citing N verified passages" or "Model hypothesis — no documentary support was verified", plus
  "an interpretation, not a finding" or "only a person's decision can settle it". Applied effects carry the software actor
  "AI assistant · run". The answering model and stop reason are recorded (`CloudCallUsage.model` and `stopReason`).
  Decisions on a question and identity merges are never applied automatically.
- **Withholding.** Only documents the cloud gate clears are sent. Privileged and restricted documents are never sent. The
  model is told only how many were withheld, never their names (`CaseAICoverage.modelStatement`, lines 196-201). Search
  results are filtered to documents that were sent (line 884). After the reply, the run is checked again: case, roles,
  versions, permission and policy (line 484). If anything changed, nothing is stored.
- **What else goes with the documents (LS28).** The task text includes the case's open allegations, the titles of its
  tasks, the descriptions of open evidence requests and the investigator's note (`caseContext`, lines 798-808;
  `taskText`, lines 810-820).

## Findings

None blocking.

- **LS26 (should-fix; fix before upload): "Stop and forget everything from this folder" now leaves a sealed copy of every
  file.**
  - **What happens.** IN-02 turned managed custody on by default. That includes existing installs that never chose:
    `FeatureFlags.swift:570-572` returns `?? true`. Every file read is now copied into `EvidenceVault/`.
    `removeRoot(.stopAndForget)` (`AppState.swift:4739-4749`) calls `FilesRepository.deleteAllUnderRoot`
    (`FilesRepository.swift:136-142`, `DELETE FROM files`). Neither removes vault copies or opened copies. The only callers
    of `EvidenceVault.remove` are the case-erasure file step (`AppState+Erasure.swift:228`) and the full erase.
  - **The result.** After "forget everything", an encrypted copy of each file stays on the Mac indefinitely. Once the file
    rows are gone, no case erasure can find those copies, so only "Delete all my data" removes them. Before IN-02, this
    happened only to someone who had turned managed mode on themselves.
  - **What the texts say.** The button (`SourcesView.swift:126`) says "everything". Settings says "existing copies stay
    until erased", which does not tell the person that forgetting a folder is not erasure. ST-03 lists only full erase and
    case erasure as removing copies.
  - **Fix.** (a) In `.stopAndForget`, before the rows are deleted, collect the vault addresses of the versions under the
    root that no other file or version still uses. Remove them, and their opened copies, through the same recorded,
    resumable file step case erasure uses, and count them back. (b) Add a test. Or, if keeping copies is intended: rename
    the button and state the retention in its message, in Settings, in ST-03 and in DATA_FLOW L1.
  - **Why not a blocker.** The copies are local, sealed under a key derived from the ledger key, owner-only, and removed by
    "Delete all my data". Nothing is sent.
- **LS27 (should-fix; wording, before upload): four accuracy fixes to the public and in-app texts.**
  - **(a) The viewed copy.** `privacy.html:59` says "a copy of an original while you view it". Change it to: "a copy of an
    original you open, until the app next starts (or you erase it)". The opened copy and the `original-*` temporary copy
    stay until the next launch.
  - **(b) The stored AI permission.** `privacy.html:188` says it holds "a fingerprint …, a count and the destination". It
    now also holds the model and a short one-way fingerprint of your own API key (`CaseReadPermission.credentialDigest`,
    in `UserDefaults`). Add both, and add the digest to DATA_FLOW L15 and THREAT_MODEL §6a, which says no key material is
    in preferences.
  - **(c) What the JWS contains.** `privacy.html:117` and DATA_FLOW N6 should list everything Apple's signed transaction
    holds, or say "Apple's signed record of the purchase, including the storefront country, price and currency". Apple's
    documented payload includes `storefront`, `price`, `currency`, `appAccountToken` and `webOrderLineItemId`. An on-device
    transaction can also carry `deviceVerification` / `deviceVerificationNonce`: confirm against one real sandbox JWS. The
    relay keeps none of these, so the label does not change.
  - **(d) The date.** Change `privacy.html:40` "Last updated" to the date of the final text.
- **LS28 (should-fix, latent; required before `CaseAIAssistService.run` is reachable from the UI): the assistant's context
  is not covered by the consent text.**
  - **The problem.** The per-case permission sheet and `privacy.html:84-89` say that inside an allowed case "those
    documents, and the questions you then ask" are sent, and that "anything outside the documents you allowed is shown to
    you first". The assistant also sends, with no further preview, the case's open allegations, task titles, evidence
    request descriptions, the investigator's note and computed tool results (the money tool included).
  - **Fix.** Before wiring the run, either (a) preview that extra text at each run, or (b) say on the per-case permission
    sheet, in `privacy.html` and in DATA_FLOW (as a new N-row) that the assistant also sends those items. Also check the
    money tool so that a hand-entered money record that names a protected person is withheld.
  - **Why not a blocker.** Nothing in this build calls `run`.
- **LN13 (note): the log statement now says more than the code does.** DATA_FLOW L14 and THREAT_MODEL T12 still say "file
  names … are logged as public". S16 made file-name logging private, guarded by a source test. Saying more than is true is
  harmless, but update both texts when they are next edited.
- **LN14 (note): test isolation recurred.** THREAT_MODEL T15 says the 2026-10-30 incident is "fixed, not to be repeated".
  S18 found that tests had again written into the owner's own folders. Record the S18 recurrence and its guard in T15. No
  effect on the shipping app (`TestHost.isActive` is `false` in Release).
- **LN15 (note): the managed-copies default changes on update without a notice.** Existing installs that never chose start
  keeping encrypted copies. The data stays local, and Settings and Help explain it. LS26 covers the one gap in the
  disclosure. A one-time notice after the update would be courteous but is not required.
- **LN16 (note): sync leftovers after erasure.** These are not reached: batches other devices wrote, and devices that
  already applied a batch. They are disclosed in general terms (USER_MANUAL line 508, L8, T19). Consider naming the sync
  folder in the case and person erasure result, as full erase now does.
- **LN17 (note): the S1–S18 schema adds many case tables.** They are inventoried in `CaseDataInventory` (a test fails on
  an unregistered table), erased with the case, and the person-erasure inventory lists the free-text ones. I did not check
  each of the 81+ tables one by one. The test is the control.
- **Carried over unchanged:** LN4, LN6, LN8, LN9, LN10, LN11 and LN12, and the owner steps LS6 and LS10. LS25 is closed in
  code: confirm its test in CI.

If the uploaded commit is not 0fb6a57b, re-point the gate record after a confirmation review.

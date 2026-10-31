# Threat model

Version 2 · 2026-10-31 · App Store completion instructions §12 (reconciled with the execution record). Built on
`docs/DATA_FLOW_INVENTORY.md`, which lists every flow; this file says what could go wrong with each, what stops it
today, what proves it, and what is untested. "Tested" means an automated test exercises the control on a throwaway
ledger. Nothing here has been checked on the distribution build; §5 lists what that check must cover. The app is not
"unhackable": every row states a bounded conclusion.

Version 1 (2026-10-28) said the vector cache was not encrypted, that erasure stopped at the full erase, that provider
failures and the case races were untested. Those statements were stale by 2026-10-30 and are corrected below; the
history stays in git.

## 1. What is protected

| Asset | Where it lives |
|---|---|
| Originals: the person's files | In place (bookmarks). Copies exist in the vault (optional), complete backups, snapshots and intake. |
| Derived ledger: text, facts, entities, events, studio work, case history, job results, releases, send log | SQLCipher database (AES-256); key in the Keychain (this device only) |
| Indexes and caches | FTS inside the ledger; vector cache `hnsw-index.bin` beside it, **sealed with AES-GCM under a key derived from the ledger key** (K11; never written without the key; an unsealed or foreign cache is rebuilt, not trusted) |
| Work products: exports, receipts, bundles | Wherever the person saves them (plaintext by design, recorded with their digests) |
| Secrets | Ledger key, Online API keys, signing keys (Keychain, this device only); recovery key (shown once) |
| Purchase state | Verified StoreKit transactions (Apple); the app caches only the last verified entitlement, never an unlimited one |

## 2. Who might attack, and how

| Actor | Capability | Main concern |
|---|---|---|
| Someone with the unlocked Mac, or a backup disk | Reads files in the container, backup folders and Downloads | Plaintext originals in the vault, complete backups, snapshots and exports |
| Another process run by the same user | Reads non-sandboxed locations, the pasteboard and the unified log | Clipboard, logs, temp files |
| A malicious document in the archive | Its text reaches the rules, the on-device model and (Online) the cloud AI | Prompt injection; parser exploits |
| The chosen AI provider, or a provider-side breach | Receives what Online sends | Retention; use beyond the request |
| A network attacker | Sees the helper's HTTPS traffic | Downgrade or redirect to other hosts |
| The person themself, by mistake | Approves a send, exports, erases | Sending the wrong material; irreversible actions |
| A billing failure or a store outage | Changes the entitlement | Work locked away or deleted by a billing state (never); unlimited access from an unverified state (never) |

## 3. Surfaces and controls

| # | Surface | Control in place | Tested by | Gap / bounded conclusion |
|---|---|---|---|---|
| T1 | Ledger at rest | SQLCipher AES-256; key in the Keychain (this device only); the test host uses an in-memory key store | `LedgerEncryptionTests`, `TestHostIsolationTests` | Encryption on the distribution artifact, wrong-key behaviour and recovery on a clean Mac: §5 |
| T2 | Files beside the ledger | **Vector cache sealed** (AES-GCM, HKDF from the ledger key, mode 0600; `ManagedFileProtectionTests`). **Vault copies of originals are NOT app-encrypted**: owner-only permissions (0700 directories, 0400 files) and a recorded decision (SHIP_DECISIONS §5): they rely on **FileVault** for encryption at rest, are erased by erasure, and the person is told so. Intake, diagnostics and receipts likewise | `ManagedFileProtectionTests`, vault suites | Plaintext originals in the vault, complete backups and snapshots remain the person's FileVault responsibility — stated in privacy text and Help, never claimed otherwise (§12 decision L-7/L-10) |
| T3 | Backups and snapshots | Ledger copy encrypted (ledger key / export passphrase); integrity checks on restore; staged writes, previous backup kept on failure; a newer-schema backup is refused by an older build | `CompleteBackupTests`, `BackupIntegrityTests`, `NewerSchemaRefusalTests`, `BackupRestoreSafetyTests` | Originals inside complete backups and snapshots are plaintext files (T2); clean-Mac restore on the signed build: §5 |
| T4 | Network | One helper; HTTPS POST to 3 hosts only; the main app has no network entitlement; Private mode makes no app connection. **StoreKit / Apple-account traffic is Apple's**, carries no case content, and is distinct from this policy | `ci/guards/clipper-no-network.sh`, `ci/guards/release-configuration.sh`, `KnowledgeModuleFlagsTests` | No measured no-network capture on the distribution build (§5); subscribing enables nothing on this surface (`PurchaseTests`) |
| T5 | What Online sends | Preview with exact text, size and destination; document text only to reviewed providers after a terms confirmation; `CloudSourceGate` before prompt assembly on every document-bearing route; case-scope revalidation at the send (B4); protected identities masked; outbound record written before anything leaves; daily byte limit | `CloudSourceGateTests`, `CloudScopeRevalidationTests`, `VerifiedRecordExtractorTests`, `OnlineProviderFailureTests` | Live-provider outcome checks on the distribution build: §5 |
| T5a | Provider failures | 401/403, 429, 5xx, timeout (120 s deadline), refusal in each provider's form, malformed/empty reply, cancel, stale consent, outbound-log failure — each has a documented outcome; no silent fallback | `OnlineProviderFailureTests` (K8), `RACE_MATRIX` consent race | Not tested against a live provider |
| T6 | Prompt injection | Guard defangs disguised patterns and role markers on every model route; evidence gate requires verbatim quotes; outcome test on the on-device model: 9 of 9 attacks resisted (errors and empty replies count as failures, not resistance) | `InjectionCorpusTests`, `InjectionOutcomeTests`, `PromptInjectionTests` | **Mitigation, not proof**: finite corpus; Online routes not outcome-tested; re-measure benign accuracy with the guard on |
| T7 | Parsers and malformed files | Each parser refuses junk honestly; per-file timeouts; Vision deadline; a document with no readable character is a recorded failed parse, never an empty record | `junkIsHonest`, parser-fixture CI job, `AcceptanceCaseTests` | No fuzzing campaign |
| T8 | Case boundaries and races | Answers, findings, studio drafts and case documents resolve against one case's authorised sources; studio writes check the parent case in the savepoint; 8 races mapped and tested (consent change during the dialog, result after erase, scope change during export, …) | `InvestigationCaseScopeBoundaryTests`, `RACE_MATRIX.md` (7 of 8 done, 1 partial: case switch during a question at the Ask screen) | The partial race is a UI journey check |
| T9 | Exported work products | **One output service** for case content (file, clipboard, print, share): frozen snapshot, re-verified citations, revalidated access after the dialog, protected identities scrubbed, atomic write, read back, recorded digest; refusals recorded; pending record kept if the log fails; job-result and studio exports use the same building blocks | `CaseOutputServiceTests`, `JobResultIntegrityTests.exportAuthorisedAtWrite`, `JobDeliverableTests.protectedIdentityKeptOut`, `StudioRecordRepositoryTests.frozenExportPackage` | Two recorded gaps (`docs/OUTPUT_ROUTES_INVENTORY.md`): the findings export has its own check but no case output record; Ask's copy button outside cases is not scrubbed |
| T10 | Erasure | Case, person and full erasure: fail closed, hold precedence (case, drafts, documents, versions, unreleased notices), namesakes kept, shared evidence kept, file steps recorded before commit and resumed at launch, verified empty | `CaseErasureTests` (14), `DiagnosticEndToEndTests.eraseIsVerified/eraseFailsClosedOnHolds` | External originals, backups, snapshots, sync folders, exports, Keychain items and Spotlight entries are not reached (disclosed) |
| T11 | Clipboard | Recovery key copied concealed and transient; case-content copies go through the output service (protected, recorded) | `CaseOutputServiceTests` | Answers copied from Ask (outside cases) are not scrubbed (T9 gap) |
| T12 | Unified log | Mostly counts and errors; file names marked private where reviewed | — | Provider error texts and some file names are logged public; audit outstanding (§5) |
| T13 | Integrity of the record | Audit chain sealed (HMAC); append-only case history, job-result revisions, studio revisions; receipts signed; carried rows keep their revision digest | `AuditChainTests`, `CaseActionSealTests`, `PJE009CitationTamperTests`, `CaseFileTests.reviewedRowHandsOffIntoTheCase` | Tamper-evident, not tamper-proof: a person with the key and the database can rebuild a chain |
| T14 | Purchase state | Only verified StoreKit 2 transactions and renewal info grant paid use; the cache keeps a verified state to its own end only; a store error never becomes an unlimited unlock and never removes valid access; billing never deletes or locks away data (read, export, backup, recovery, Help, privacy controls stay) | `PurchaseTests` (11) | Sandbox and TestFlight matrix (`docs/DISTRIBUTION_PACK.md` §6) not run |
| T15 | Test host against the owner's data | Per-process preference suite, in-memory ledger key, ephemeral bookmark store, no legacy-store writes | `TestHostIsolationTests` | The five-folder incident of 2026-10-30 (fixture registered folders in the real store) is recorded in FINAL_BRIEF_EXECUTION §E5; fixed, not to be repeated |

## 4. Supported workload

Measured (`docs/SUPPORT_ENVELOPE.md`, Mac16,12, 16 GB, macOS 27.0.1): 400 and 4,000 generated text documents ingest at
25.1 and 22.7 documents/s; peak memory +294 and +347 MiB; answers p95 1.9 and 2.5 s. Bounded-memory streaming of a
50,000-message mbox and a 300,000-row SQLite database (`ScaleRunTests`). Not claimed: very large or scan-heavy archives,
other hardware. Re-measure on the final implementation before stating figures in the listing.

## 5. What the distribution build must still show (owner/agent, §9–§10)

1. SQLCipher in the packaged app: encrypted ledger, wrong key refused, recovery on a clean Mac/account.
2. No case-content egress in Private mode (packet capture), consent boundary and cancellation on live providers.
3. Injection outcome checks on the enabled Online routes with benign controls.
4. Erasure, holds and recovery journeys on disposable data.
5. Unified-log audit of public interpolations (T12).
6. Purchase matrix in Sandbox and TestFlight (T14).

## 6. Credentials

Development provider keys used for public-data benchmarks are the owner's; the prepared step for rotation is in the
owner action sheet (`docs/FINAL_BRIEF_EXECUTION.md` §E6, §12). No key is committed or printed; the bench reads its key
from `$CASEBENCH_CLOUD_KEY_FILE` outside the repository.

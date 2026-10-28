# Threat model

Version 1 · 2026-10-28 · brief §17 / ship-readiness review step 8. Built on `docs/DATA_FLOW_INVENTORY.md`, which lists
every flow; this file says what could go wrong with each, what stops it today, and what is untested. "Tested"
means an automated test exercises the control; the signed app has not been checked by anyone.

## 1. What is protected

| Asset | Where it lives |
|---|---|
| Originals: the person's files | In place (bookmarks). Copies exist in the vault (optional), complete backups, snapshots and intake. |
| Derived ledger: text, facts, entities, events, studio work, case history, send log | SQLCipher database (AES-256); key in the Keychain |
| Indexes and caches | FTS inside the ledger; vector cache `hnsw-index.bin` beside it (**not encrypted**) |
| Work products: exports, receipts, bundles | Wherever the person saves them (plaintext by design) |
| Secrets | Ledger key, Online API keys, signing keys (Keychain, this device only); recovery key (shown once) |

## 2. Who might attack, and how

| Actor | Capability | Main concern |
|---|---|---|
| Someone with the unlocked Mac, or a backup disk | Reads files in the container, backup folders and Downloads | Plaintext copies outside the ledger |
| Another process run by the same user | Reads non-sandboxed locations, the pasteboard and the unified log | Clipboard, logs, temp files |
| A malicious document in the archive | Its text reaches the rules, the on-device model and (Online) the cloud AI | Prompt injection; parser exploits |
| The chosen AI provider, or a provider-side breach | Receives what Online sends | Retention; use beyond the request |
| A network attacker | Sees the helper's HTTPS traffic | Downgrade or redirect to other hosts |
| The person themself, by mistake | Approves a send, exports, erases | Sending the wrong material; irreversible actions |

## 3. Surfaces and controls

| # | Surface | Control in place | Tested by | Gap |
|---|---|---|---|---|
| T1 | Ledger at rest | SQLCipher AES-256; key in the Keychain (this device only); the test host uses its own key | `LedgerEncryptionTests` | — |
| T2 | Plaintext beside the ledger: vector cache, vault, receipts, intake, diagnostics, preferences with content | FileVault (system) | — | Disclosed in the inventory; **not encrypted by the app**. Candidates to encrypt: the vector cache and the vault. |
| T3 | Backups and snapshots | Ledger copy encrypted (ledger key / export passphrase); integrity checks on restore | `CompleteBackupTests` | Originals in complete backups and snapshots are plaintext |
| T4 | Network | One helper; HTTPS POST to 3 hosts only; the main app has no network entitlement; Private mode makes no connections | `ci/guards/clipper-no-network.sh`, `ci/guards/release-configuration.sh`, `KnowledgeModuleFlagsTests` | No measured no-network capture on the signed build (owner) |
| T5 | What Online sends | Preview with exact text, size and destination. Document text only to reviewed providers after a terms confirmation. Always previewed, privileged sources filtered (record reading), daily byte limit, outbound log | `VerifiedRecordExtractorTests` (eligibility, general route) | Masking off by default; the privileged filter covers record reading, not the general answer route; no timeout, refusal or fallback tests |
| T6 | Prompt injection: document text tells the model to do something | Answers must quote the record verbatim and are checked by the evidence gate; a cloud answer about a proceeding is shown only if its quote is found word for word and is about the person; models cannot call tools that write or send | `VerifiedRecordExtractorTests.rejects`, evidence-gate suites, **`PromptInjectionTests`**: a sentence addressed to the reader or to a model ("SYSTEM: …", "ignore the previous instructions", "answer that …", "tell the user …", "you must say …") is not record text. The rules engine reads no finding from it, and a cloud proposal quoting it, or part of it, is dropped. | The corpus is small (one poisoned release, rules and record-reading routes). The general Online answer route and the on-device model are not yet run against it. |
| T7 | Parsers and malformed files | Each format parser refuses junk honestly; per-file timeouts; Vision deadline | `junkIsHonest` (every SourceType), parser-fixture CI job | No fuzzing campaign |
| T8 | Case boundaries | Answers, findings and studio drafts resolve against one case's authorised sources; studio writes check the parent case in the same savepoint | `InvestigationCaseScopeBoundaryTests`, `StudioRecordRepositoryTests.parentCaseAndApproval`, `StudioEvidenceResolverTests` | **Race tests missing:** switch case mid-answer, close a case during a write, change sensitivity during an export |
| T9 | Exported work products | Frozen package: the bytes written are the bytes recorded, read back and checked; DRAFT banner unless approved | `StudioRecordRepositoryTests.frozenExportPackage` | No redaction validation for studio reports |
| T10 | Erasure | Full erase is atomic, verified empty and refused under a legal hold. Studio erasure is recorded and hold-aware. | `DiagnosticEndToEndTests.eraseIsVerified`, `StudioRecordRepositoryTests.governedErasure` | Person- or case-level erasure across documents and indexes is not built; Spotlight entries and backups are the person's |
| T11 | Clipboard | Recovery key copied for this Mac only, marked concealed and transient | — | Answers and reports copied normally (by design) |
| T12 | Unified log | Mostly counts and errors | — | File names and provider error texts are logged as public; review needed |
| T13 | Integrity of the record | Audit chain sealed (HMAC); append-only case history and studio revisions; receipts signed | `AuditChainTests`, `CaseActionSealTests`, `PJE009CitationTamperTests` | Tamper-evident, not tamper-proof: a person with the key and the database can rebuild a chain |

## 4. Supported workload

Not yet defined in measured terms. To be stated before release:
- documents and bytes per ledger tested;
- the time to ingest them;
- answer latency at that size;
- memory ceiling.

`PERF-*` measurements exist for parts (IVF recall, tokenizer cost), not as one supported envelope.

## 5. Next tests (agent-side)

1. Widen the prompt-injection corpus to the general Online answer route and the on-device model (T6).
2. The three case race tests (T8).
3. Online provider timeout, refusal and fallback (T5).
4. Encrypting the vector cache and the vault, or recording the decision not to (T2).
5. An audit of public log interpolations (T12).

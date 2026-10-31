# Distribution pack (final completion instructions F6 / G1)

Prepared 2026-10-28 on `investigations-next`; revised the same day after the completeness audit of 182c7e4c. Each item is either **done**, or a prepared
**decision for the owner or counsel** with the facts it rests on. Nothing here is legal advice; the
items marked *counsel* need a qualified reviewer (see `docs/LEGAL_REVIEW_PACK.md`).

## 1. App Store privacy answers (App Privacy "nutrition label") — decision: owner + counsel

Facts (source: `docs/DATA_FLOW_INVENTORY.md`, code-checked):
- **The publisher receives nothing.** The app has no account, analytics, crash reporter, ads or
  tracking SDK. The main app's `com.apple.security.network.client` entitlement is `false`.
- **Private mode (the default)** makes no connection.
- **Online mode** is opt-in. It sends the question, and document passages only where the person
  allows it, to the AI provider *they* chose. It uses *their own* API key, previews every send and
  logs it. Privileged and restricted passages are refused before prompt assembly (K1). Online mode
  connects through the embedded network helper only.

**No recommendation is made here (revised after the 2026-10-28 completeness audit).** The earlier
"Data Not Collected" recommendation is withdrawn. That the publisher receives nothing, that the key is
the user's own, and that there is no partner SDK does not settle Apple's analysis. Apple asks whether
data is transmitted off the device and kept beyond servicing the request, by the developer *or a
third party*. Providers can retain API content under their own terms: Anthropic's commercial retention
policy, and Gemini's paid-tier logging for specified purposes.

The determination needs, per provider (Anthropic, OpenAI, Gemini), the facts below:

| Fact to map | Current state (from code) |
|---|---|
| What content can be sent | The question; with "Use cloud for case documents" on and a confirmed eligible provider, cited passages and verified findings. Never privileged or restricted sources (K1/A6). |
| Categories (Apple's list) | Other User Content (document passages, questions); possibly Search History (questions) |
| Linked to identity? | The request carries the user's own API key, so it is linked to their provider account |
| Purpose | App Functionality (answer composition / extraction) only; no tracking, no advertising |
| Retention at the provider | Per the provider's terms for the user's account tier (to be recorded per provider, with the terms version) |
| Configuration | Off by default; Online mode plus per-send consent; per-provider document-terms confirmation |
| Restrictions to review | Each provider's age, region and business/professional-use terms, especially for the Individual persona |

The two outcomes for the owner and counsel to choose between, with App Review clarification if needed:
- **(a) Data Not Collected**, with the reasoning recorded against these facts.
- **(b) Other User Content (+ Search History)** collected, linked, App Functionality, applying only when
  Online mode is used.

The privacy manifest's `NSPrivacyCollectedDataTypes` stays empty, and is documented as an open
decision, until they decide.

## 2. Required-reason APIs — done

Checked against the code (`ci/guards/required-reason-apis.sh` passes):

| Category | Before | Now | Why |
|---|---|---|---|
| File timestamp | C617.1 | **3B52.1**, C617.1 | Timestamps are read on files the person granted (open panel / bookmarks) → 3B52.1; container files → C617.1 |
| Disk space | E174.1 | **85F4.1** | The only call checks for room before an optional model download (`ModelDownloader.freeSpaceBytes`); nothing is displayed |
| System boot time | 35F9.1 | **removed** | No boot-time API is called; `mach_task_basic_info` (LiveMetrics) is not a required-reason API |
| User defaults | CA92.1 | CA92.1, **1C8F.1** | Own defaults, plus the app-group switch shared with the Share extension |
| Share extension | *no manifest* | **new manifest**, 1C8F.1 | It reads the app-group switch; collects nothing; no network |
| iPhone/iPad viewer | CA92.1 | unchanged | Own defaults only |

## 3. Terms — decision: owner + counsel

Recommendation: **Apple's Standard EULA plus one short supplement.** It is the simplest compliant
route, because the Standard EULA already carries Apple's minimum terms, which `docs/terms.html`
lacks (`LEGAL_REVIEW_PACK.md` §2). The supplement must be a single text, used both in the app
(`LegalNotice`) and on the site, with a version and date. It covers only:
- lawful use;
- the liability cap;
- the export/sanctions clause;
- "not legal or professional advice";
- the user's own AI-provider terms (Online mode);
- the developer's name, address, telephone and email.

Open: governing law and forum (India on the site, none in the app); consumer-law limits on the cap
in launch markets — *counsel*. A draft of the supplement for counsel, reconciling the in-app text
with the site, is in `docs/legal/SUPPLEMENTAL_TERMS_DRAFT.md` (not in force).

## 4. Name search — preliminary, counsel to clear

A web search (2026-10-28) for the exact phrase "Investigations Made Easy", as a software product and
as a trademark, found **no product or registration by that name**. Nearby marks: "MADE EASY !"
(US reg. 4981210, business consulting) and "DECISIONS BECOME EASY" (business investigation services,
serial 79076979).

A web search is not a clearance. Before release: a USPTO (and launch-market) trademark search in
classes 9 and 42, an App Store name-availability check in App Store Connect, and a domain check.
*Counsel/owner.*

## 5. Cryptography inventory — done (export answer unchanged)

All cryptography is Apple's OS crypto or SQLCipher on CommonCrypto; there is no proprietary
algorithm. It protects the person's own data and authenticates records.

| Use | Algorithm / API | Where |
|---|---|---|
| Ledger at rest | SQLCipher 4.19.0 (AES-256, CommonCrypto) | `Storage/Database` — pinned by `LedgerEncryptionTests.encryptionUsesApplesCommonCrypto` |
| Vector cache at rest (K11) | CryptoKit AES-GCM, key by HKDF-SHA256 from the ledger key | `HNSWVectorIndex`, `LedgerKey.derivedKey` |
| Content addresses, hashes, receipts | CryptoKit SHA-256, HMAC-SHA256 | throughout |
| Signed receipts / conformance seals | CryptoKit P-256 ECDSA | `ConformanceSeal`, receipts |
| Team-review logs (not available in v1) and DKIM checks | CryptoKit Curve25519 / Ed25519 signatures | `TeamCase`, `ForensicSignals` |
| Folder sync (optional) | CryptoKit AES-GCM, key derived from the person's passphrase; entries signed | Sync (`folderSync`, off by default) |
| Companion snapshot (optional) | SQLCipher re-encryption of the ledger copy with a passphrase the person sets at export | `CompanionSnapshot` |
| Keys | Keychain (`SecItem`), `SecRandomCopyBytes`, `SecKeyCreate*` | `LedgerKeychain` |
| Online mode transport | HTTPS via URLSession in the network helper | `NetworkHelperClient` |

`ITSAppUsesNonExemptEncryption = NO` stays (recorded 2026-10-17): the encryption is limited to
protecting the user's own data and authentication, using the OS. *Counsel* to confirm for the launch
markets.

## 6. StoreKit test script — prepared; run in the sandbox and on the TestFlight build (tier 3)

Products (`StoreKit/Kalsmritikosh.storekit`, App Store completion instructions §11): one subscription group
"Investigations Made Easy edition" with `…edition.monthly` ($4.99, P1M) and `…edition.annual` ($39.99, P1Y) at one
level, each with a two-week free introductory offer; 3-day paid-to-paid billing grace; the legacy non-consumables
`…trial14` and `…unlock` kept as they were (restore/compatibility only). Entitlement rules: `Purchase.swift`,
proven by `PurchaseTests` (11, pure rules) and `PurchaseStoreKitTests` (11, the StoreKit testing environment loaded
with this configuration in-process: purchase, renewal, cancellation, expiry, refund, billing retry with and without
grace, crossgrade, legacy products, Restore, failed dialog). Each row below is recorded per environment (local
StoreKit, Sandbox, TestFlight); the local environment alone does not prove the live products or the storefront prices.

| # | Scenario | Required result |
|---|---|---|
| 1 | Fresh account, store reachable | Subscription screen with both plans at the storefront's prices, "Start 14-day free trial", disclosure of the post-trial price, renewal and cancellation; Help, sample and backup/recovery reachable |
| 2 | Store unreachable | "Try again" and no price shown; nothing charged |
| 3 | Eligible trial on monthly, then on annual (plan change in the Apple Account) | One trial per group; the switch shows Apple's effective date; no second trial |
| 4 | Ineligible account (reset eligibility not used) | "Subscribe … per month/year"; no trial promised |
| 5 | Cancel during trial / cancel renewal | Access until the verified end; status strip shows the date and "renewal is off"; no charge |
| 6 | Renewal (accelerated clock) | Status shows the new period; no duplicate subscription |
| 7 | Pending (Ask to Buy), declined, cancelled dialog, unverified | Honest message; no access granted |
| 8 | Failed renewal with grace | Access continues to Apple's grace end, strip says so; after grace: read-only + "update payment" |
| 9 | Expiry / refund / revoke | Read-only: cases open, exports/backup/recovery/Help/privacy work; paid actions open the subscription sheet |
| 10 | Offline launch with a valid cached state; offline past the verified end | Access kept until the verified end only; then read-only, never "unknown = unlocked" |
| 11 | Restore on a second Mac | Entitlement restored; archive not implied to sync |
| 12 | Legacy `…unlock` holder; legacy `…trial14` holder mid-trial | Full access, never asked to subscribe; remaining old trial honoured, then read-only |

Record each step's result in the release packet (`release/approvals/storekit.md`).

## 7. Listing audit — done against `APP_STORE_METADATA.md`

| Claim | Check | Result |
|---|---|---|
| "the main app has no network permission at all" | Main entitlements `network.client = false`; the network helper is separate | true |
| "Requires macOS 15.6 or later" | `MACOSX_DEPLOYMENT_TARGET = 15.6` in all configurations | true |
| "$79 … no subscription … Family Sharing on" | StoreKit config | true |
| "Outlook MSG/PST … read with exact citations" | `OLE2Reader`, `PSTReader`, `PSTStructuralParser` present; parser fixtures in CI | true (keep the citation claim to the formats the fixtures cover) |
| "By default no AI writes answers" | `offlineNoLLM` / evidence-only defaults | true |
| "Every answer links to the exact source — file, page, and line" | Citations carry file + page/locator; "line" holds for text formats only | **soften** to "file and page (or line)" |
| Single-user scope (SHIP_DECISIONS §0) vs team review | A team-review tool was reachable through "Show preview features" | **fixed**: `ProductModuleFlags.outOfV1Scope` disables it in v1 |
| Personas listed vs the nine shipped | Investigators, lawyers, journalists, researchers, genealogists, HR, SIU, forensic accounting, personal | true; Content Creator is hidden and not listed |
| "it is not legal or regulatory certification" / "Not legal or professional advice" | present | keep |

## 8. Remaining for release (not agent-completable)

- The owner and counsel decide §1, §3 and §4.
- The StoreKit script (§6) and the signed-archive checks run on the signed build.
- The final approved legal texts are wired into `LegalNotice`, and `scripts/generate-kalverify.sh` is
  regenerated in the same change.

## 9. Security claims — wording

Injected instructions in documents are **mitigated, not prevented**. The guard defangs known disguised
patterns and chat-role markers on every model route, and is tested against a finite corpus of patterns.
The second layer is the evidence gate: answers must be supported by cited passages. Do not describe the
guard as neutralising arbitrary instructions. Outcome-based adversarial testing against real models,
and re-measurement of benign accuracy after the guard, are part of F5.

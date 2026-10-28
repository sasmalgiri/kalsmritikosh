# Distribution pack (final completion instructions F6 / G1)

Prepared 2026-10-28 on `investigations-next`. Each item is either **done**, or a prepared
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

| Question | Recommended answer | Basis |
|---|---|---|
| Do you or your third-party partners collect data from this app? | **No — Data Not Collected** | Apple: "collect" means transmitting data off the device in a way that lets *you and/or your third-party partners* access it beyond what is needed to service the request in real time. The publisher has no access, and there is no partner SDK. The provider is the person's own account, contacted at their request with per-send consent, like a user-configured mail server. |
| Tracking | **No** | `NSPrivacyTracking` false; no tracking domains |
| Alternative if counsel disagrees | Declare **Other User Content** and **Search History** as *collected, linked to the user, not used for tracking*, purpose **App Functionality**, with a note that it applies only when Online mode is on | The conservative reading treats the user-chosen provider as a third party |

Owner/counsel to choose. The privacy manifest's `NSPrivacyCollectedDataTypes` stays empty, and is
documented as an open decision, until they do.

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
in launch markets — *counsel*.

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
| Team-review logs (out of v1 scope, disabled) and DKIM checks | CryptoKit Curve25519 / Ed25519 signatures | `TeamCase`, `ForensicSignals` |
| Keys | Keychain (`SecItem`), `SecRandomCopyBytes`, `SecKeyCreate*` | `LedgerKeychain` |
| Online mode transport | HTTPS via URLSession in the network helper | `NetworkHelperClient` |

`ITSAppUsesNonExemptEncryption = NO` stays (recorded 2026-10-17): the encryption is limited to
protecting the user's own data and authentication, using the OS. *Counsel* to confirm for the launch
markets.

## 6. StoreKit test script — prepared; run on the signed build (tier 3)

Products (`StoreKit/Kalsmritikosh.storekit`): `…trial14` (non-consumable, $0, 14-day trial) and the
$79 non-consumable unlock; Family Sharing on; no subscription.

1. Fresh install, no purchases: the trial offer is shown, with no charge text.
2. Start the trial: everything unlocks, and the trial end date is shown.
3. Advance the clock 15 days (StoreKit Test): the app reverts to its locked state honestly. No data
   is lost or hidden, and export still works.
4. Buy the unlock ($79): it unlocks permanently, and the receipt shows a one-time purchase.
5. Restore purchases on a second Mac (same Apple ID): it unlocks without a second charge.
6. Family Sharing member: it unlocks.
7. Interrupted purchase, purchase failure and "Ask to Buy" pending: nothing is unlocked while the
   purchase is unresolved, and the message is clear.
8. Refund (StoreKit Test revoke): the unlock is withdrawn; data remains and stays exportable.
9. Offline at launch after purchase: the cached entitlement keeps the app unlocked.

Record each step's result in the release packet.

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

# Legal review pack — for qualified counsel

Prepared 2026-10-28 for the ship-readiness review findings L1–L6. This pack gathers the facts counsel needs; it
does not give legal advice, and nothing in it is a legal conclusion. Each section ends with the **decisions only
the owner or counsel can make**. File references are to this repository.

## 0. Who is publishing

| Fact | Where | Open |
|---|---|---|
| Publisher named as "Eco Sanskriti Innovation" | `docs/terms.html`, `docs/privacy.html`, `docs/index.html`, `docs/sop-register.html`, `docs/support.html`, `APP_STORE_METADATA.md`, `ComplianceBoardView.swift` | Is this the exact registered legal name and form? Is it the App Store seller? Does it own the rights to the app, the bundled models' use and the assets? (`OWNER_ACCEPTANCE_CHECKLIST.md` already lists this open.) |
| Contact: email only (sasmalgiri@gmail.com) | terms, privacy, support | Apple's custom-EULA minimum terms expect a name, address, telephone and email for questions, complaints and claims |
| Product name "Investigations Made Easy"; internal "Kalsmritikosh" | listing, site | Trademark search: registers (incl. IP India), similar/phonetic marks, classes (software and services), launch markets. Not done. |

## 1. Data flows and the App Store privacy answers (L1, L2)

The single inventory is **`docs/DATA_FLOW_INVENTORY.md`**. Summary:
- Private mode, the default: no network.
- Online mode, opt-in, uses the person's own API key:
  - It sends the question and the app's field names.
  - If allowed, it also sends document passages to Claude (Anthropic commercial API) or a paid Gemini project. It never sends document text to OpenAI in this release.
  - Every send is previewed and recorded in the encrypted ledger.
- StoreKit runs through Apple.
- Mail hand-offs happen only when the person clicks.

**Decisions:**
1. Whether Online sends are "collection" for Apple's privacy label and for `NSPrivacyCollectedDataTypes`. The manifest array is currently empty, explicitly as an open decision, not a finding.
2. Roles (operator, customer, provider), and the lawful ground for sending information about third parties in a case file to an AI provider. The user's consent to the send is not the third parties' consent.
3. Whether the provider terms shown in the app are a fair summary, and how often to re-review them. Re-review is tied to `OnlineProviderKind.documentTermsVersion`; the confirmation lapses when it changes.

## 2. Terms / EULA (L3)

The current texts are:
- `docs/terms.html`: §§1–9, governing law India, no liability cap.
- The in-app `LegalNotice` statements (terms 1.8): a liability cap of the amount paid in 12 months, indemnity, export/sanctions, and Apple's standard EULA as fallback.

They are **not consistent**:
- The cap and the lawful-use clause appear only in the app.
- The governing law appears only on the site.

The site page says it "supplements, and where permitted supersedes" Apple's standard EULA. It does not contain Apple's minimum custom-EULA terms.

| Apple minimum term (custom EULA) | In `terms.html`? |
|---|---|
| Acknowledgement: agreement is between user and developer, not Apple | no |
| Scope of licence (non-transferable, Apple-branded devices, Usage Rules) | partly (§1) |
| Maintenance and support: developer responsible; Apple has no obligation | no |
| Warranty: developer responsible; Apple's refund-only role | no |
| Product claims: developer, not Apple, handles them | no |
| Intellectual property claims: developer, not Apple | no |
| Legal compliance (export / sanctioned countries) | no (in-app text only) |
| Developer name, address, telephone, email | email only |
| Third-party terms of agreement (e.g., the user's AI provider terms) | partly (§2) |
| Apple and subsidiaries as third-party beneficiaries | no |

**Decisions:**
1. Use Apple's standard EULA, with consistent supplemental terms; or a complete custom EULA configured in App Store Connect.
2. Governing law and forum, in light of mandatory consumer rights in the launch markets.
3. Reconcile the site and in-app texts into one, with a version and date.

## 3. Retention, erasure and holds (L4)

Built so far:
- Studio work can be removed (kept in the record) or **erased**. Erasure needs a reason (the basis is optional) and clears the content of every version and export snapshot. It records the erasure append-only and is refused while a legal hold covers the draft or its case (schema v160).
- Holds use the existing `legal_holds` tables. Releasing a hold is a recorded act.

Not built yet:
- Erasure for a person or a case across documents, extracted facts, indexes, the vault and Spotlight.
- Erasure of the pre-ledger captured preference store.
- Backups and exports the person made stay theirs.

**Decisions:**
1. Retention and erasure policy by role and market. GDPR, where applicable, includes erasure rights and exceptions (for example legal claims).
2. The DPDP Act and Rules commence in phases (immediate, one-year and eighteen-month groups under Rule 1). The site must not describe the app as "DPDP-compliant". The register's wording was corrected on 2026-10-28.

## 4. Evidence and professional claims (L5)

Corrected on 2026-10-28:
- **Home page:** "makes no network connections at all" became "In Private mode…". The "no training because we never receive it" reasoning was replaced.
- **SOP register:** it now carries the no-affiliation / no-certification / not-admissibility notice, including that a conformance record does not replace a certificate under section 63 of the Bharatiya Sakshya Adhiniyam. "Satisfies the strictest privacy regime anywhere" and "designed to satisfy GDPR/CCPA/DPDP" were withdrawn.
- **In-app wording:**
  - "court-ready", "defensible chain of custody", "prove they're unaltered" and "can't be tampered with" were removed from the WorkCenter guidance.
  - The receipt seal no longer says it "certifies" the bundle.
  - A broken audit chain now says the record "was changed or damaged after it was sealed", not "was tampered with".

Still to review:
- Standards are named per persona: FRCP 26, Daubert, NAIC Model 680, POSH Act, IRDAI, FTC, GPS, PRISMA/GRADE. Each workflow is the developer's good-faith reading. Jurisdiction-by-jurisdiction review is needed, especially for referral, employment, recording and privilege rules.
- Home-page phrases such as "exhibit-ready expert reports", "a defensible SIU report" and "workplace investigations that stand up later" sit under a page-level disclaimer but are not qualified in place.

**Decisions:**
1. Which professional-outcome phrases may stay on the listing and site, and with which qualifiers.
2. Whether any electronic-evidence guidance (for example BSA s.63 certificates) should be shown to Indian users.

## 5. Encryption, licences and distribution (L6)

| Fact | Where |
|---|---|
| `ITSAppUsesNonExemptEncryption = NO` (build setting) | `project.pbxproj` (4 configurations) |
| Rationale: all cryptography through Apple's OS crypto; SQLCipher built on CommonCrypto, pinned by `LedgerEncryptionTests.encryptionUsesApplesCommonCrypto` | `SHIP_DECISIONS.md` 2026-10-17 |
| Crypto in use: SQLCipher 4.19.0 (AES-256, PBKDF2-HMAC-SHA512); P-256 ECDSA / SHA-256 signatures (incl. Secure Enclave); Ed25519 (sync, team); HTTPS (network helper, URLSession); DKIM signature *verification* during import | see the review survey; sync's passphrase cipher to be confirmed |
| Shipped notices: BGE models (MIT), SQLCipher 4.19.0 (BSD, full text), SQLite (public domain) | `Kalsmritikosh/Resources/THIRD_PARTY_NOTICES.txt` |
| `Legal/THIRD_PARTY_NOTICES.md` was stale (listed Llama, omitted SQLCipher) | marked superseded 2026-10-28 |

**Decisions:**
1. Confirm the encryption classification against Apple's questionnaire for the archive's linked libraries, and any separate reporting obligation.
2. Verify the signed archive: entitlements, the embedded network helper, notices actually bundled, and the required-reason API declarations. Known issues: SystemBootTime is declared with no matching call; the App Group needs reason 1C8F.1; Share and Clipper have no manifests.
3. StoreKit: product setup, trial wording, price and localisation, Family Sharing, restore, refund/revocation, expiry and offline behaviour. The unit tests bypass StoreKit.

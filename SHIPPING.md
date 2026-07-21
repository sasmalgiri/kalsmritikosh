> **DOC STATUS: CURRENT (runbook) + HISTORICAL (appendix)** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. _(rewritten 2026-07-22, GOV-002.)_

# Shipping — Mac App Store release runbook

The locked launch path is **Mac App Store only**, **one-time Personal pricing**, **no
cloud release**, **no DMG/notarization**, **minimum macOS 26** (per `SHIP_DECISIONS.md`).
This file is the current runbook. The prior DMG / GB-tiered-cloud-pricing / sqlite-vec
material is retained, superseded, in the appendix — do not act on it.

## 1. Signing & identity (owner, one-time)

1. **Apple Developer Team ID** — set `DEVELOPMENT_TEAM = <team_id>` in the Xcode project.
2. **Signing** — Signing & Capabilities → **Apple Distribution** (App Store), automatic
   signing on. (Developer ID / notarization is NOT used — App Store review signs the build.)
3. **Bundle identity** — confirm bundle ID, version, build number.

## 2. Entitlements (already in `Kalsmritikosh.entitlements`)

- `com.apple.security.app-sandbox = true`
- `com.apple.security.files.user-selected.read-write = true`
- `com.apple.security.files.bookmarks.app-scope = true`
- `com.apple.security.device.audio-input = false`
- `com.apple.security.automation.apple-events = false`
- `com.apple.security.cs.allow-unsigned-executable-memory = false`
- `com.apple.security.cs.disable-library-validation = false`
- `com.apple.security.cs.allow-jit = false`
- **`com.apple.security.network.client`** — must be **absent/false in the release
  configuration** (no cloud provider ships). If present for internal builds, gate it out
  of the App Store configuration. Verify with the privacy/network audit (P8.1).

## 3. Pre-submission gates (see `SHIP_DECISIONS.md` §3)

Do not submit until every ship gate is green: reasoning path resolves (Apple Foundation
Models on macOS 26) or deterministic-only is clearly presented; bundled BGE loads;
retrieval authority (RET-003) landed with no eval regression; executable test target + CI
mandatory; redaction verified; network audit clean; scale run recorded; owner self-test;
clean-machine install; legal pages hosted; metadata complete.

## 4. Archive & upload

1. Product → Archive (Release configuration, `MACOSX_DEPLOYMENT_TARGET = 26.0`).
2. Organizer → Distribute App → **App Store Connect** → Upload.
3. In App Store Connect: attach build, complete metadata, privacy nutrition labels
   (declare on-device processing / no data collection), pricing (one-time Personal),
   screenshots (Sources → Ask → Knowledge, no PII), age rating, release notes ("early access").
4. Submit for review.

## 5. Validation

- `codesign --verify --strict --deep Kalsmritikosh.app` reports nothing.
- App Store Connect validation passes.
- Clean-machine install from a TestFlight/App Store build launches offline with no
  Xcode/Homebrew/terminal/Ollama present.

---

## Appendix — SUPERSEDED (historical, do NOT act on)

> Retained per document-governance rule. The following reflected a DMG-notarization +
> GB-tiered-cloud-pricing + sqlite-vec plan that the locked contract has replaced
> (App Store only, one-time pricing, no cloud, no third-party dep without task approval).

### (superseded) Notarization + hardened-runtime signing
DMG notarization via `notarytool submit … --wait` + `stapler staple` — **not used**;
App Store review handles signing. Entitlement scaffolding above is still current.

### (superseded) GB-tiered pricing copy
Local/Boosted/Pro cloud tiers with monthly pricing — **replaced** by one-time Personal
pricing, no cloud reasoning in release. Anthropic/OpenAI backends are not shipped.

### (superseded) sqlite-vec / ANN behind VectorStore
Adding sqlite-vec as a C extension — **not approved**. The scale path is the in-house
disk-backed/sharded ANN (task P9.3) behind the existing `VectorStore` protocol; no
third-party dependency ships without an explicit approved task.

# Shipping — items that need user / business decisions

Three Gate-2 / Gate-3 line items can't be code-only. Each is documented
below with what's already done in the repo, what's pending, and the
exact decision needed to unblock.

---

## 1. Notarization + hardened-runtime signing

**Status:** entitlement scaffolding landed (`Kalsmritikosh.entitlements`
extended with the four hardened-runtime keys, all defaulted safely);
notarization upload is a manual step requiring the user's Apple
Developer signing identity.

**What's already in the repo:**

- `Kalsmritikosh.entitlements` ships:
  - `com.apple.security.app-sandbox` = true
  - `com.apple.security.files.user-selected.read-write` = true
  - `com.apple.security.files.bookmarks.app-scope` = true
  - `com.apple.security.network.client` = true
  - `com.apple.security.device.audio-input` = false
  - `com.apple.security.automation.apple-events` = false
  - `com.apple.security.cs.allow-unsigned-executable-memory` = false
  - `com.apple.security.cs.disable-library-validation` = false
  - `com.apple.security.cs.allow-jit` = false
- All `cs.allow-*` keys default false. Flip any to true ONLY if a
  framework we adopt requires it; document the why next to the key.

**Pending decisions / actions (need user input):**

1. **Apple Developer Team ID**. Set
   `DEVELOPMENT_TEAM = <team_id>` in `Kalsmritikosh.xcodeproj`
   (already a project-level setting in modern Xcode; tied to your
   Apple ID).
2. **Signing identity**. In Xcode → Signing & Capabilities, pick a
   Developer ID Application certificate (for outside-store
   distribution) OR Apple Distribution (for Mac App Store). The
   project currently builds locally without notarization because
   the team is unset.
3. **Notarization workflow**. Recommended:
   - Build the Release archive in Xcode.
   - `xcrun notarytool submit Kalsmritikosh.dmg --apple-id <id>
     --team-id <id> --password <app-specific-pw> --wait`
   - `xcrun stapler staple Kalsmritikosh.app`
   - Distribute the stapled DMG.
4. **App-specific password** for `notarytool`. Generated at
   appleid.apple.com → Sign-In and Security → App-Specific
   Passwords. Store in Keychain via `xcrun notarytool
   store-credentials`.

The repo doesn't bundle credentials — these are all per-machine
secrets you set once.

**Validation:** `codesign --verify --strict --deep
Kalsmritikosh.app` should report nothing; `spctl --assess --verbose
Kalsmritikosh.app` should accept the bundle.

---

## 2. GB-tiered pricing copy

**Status:** copy not yet committed; needs business decision on
price points and tier semantics.

**What's already in the repo:**

- `OnboardingView` has a `scope` step that shows hardware tier
  (small / medium / large) and provider count detected. No prices.
- `SettingsView` has a Privacy / Capability tier picker. No prices.

**Pending decisions (need user / product input):**

1. **Tier structure.** Likely shape, but to be confirmed:
   - **Local** — Apple Intelligence / Ollama only, no cloud calls.
     Free? Or one-time?
   - **Boosted** — adds cloud reasoning (Anthropic / OpenAI on
     request). Monthly?
   - **Pro / Archive** — large GB ingest limits + priority Tier-3
     re-runs. Monthly or annual?
2. **GB thresholds per tier.** What's the inclusive ingest GB
   ceiling for each tier? What happens at the ceiling — soft
   warning, hard stop, overage charge?
3. **What costs us money.** Anthropic / OpenAI cloud reasoning is
   the only paid backend today (Ollama and Apple are free at our
   margin). Pricing should track our actual cost curve, not be
   GB-only.
4. **Where the copy lives.** A new AboutView with a Pricing pane?
   A modal off SettingsView? In-app purchase via StoreKit?

**Suggested next action:** lock the three-tier names + price points
in a separate planning pass, then we land copy + StoreKit wiring in
one commit. Doing it now without those decisions would just
write-then-rewrite.

---

## 3. sqlite-vec / ANN behind VectorStore

**Status:** the abstraction is already in place; swapping to
sqlite-vec requires adding a third-party dependency, which
CLAUDE.md forbids without explicit approval.

**What's already in the repo:**

- `Kalsmritikosh/Storage/Vector/VectorStore.swift` is the protocol
  every retrieval path goes through.
- `SQLiteVectorStore.swift` implements it on top of plain SQLite
  rows + brute-force int8 cosine scan.
- `HNSWVectorIndex.swift` is the in-memory HNSW that warms up from
  SQLiteVectorStore rows at app start. The graph layer (Memory →
  Timeline → Entity → FTS → Summary → Graph → Vector) hits the
  HNSW; brute-force is only the cold-start path.

**Why sqlite-vec would help:**

- Native ANN inside SQLite → no warm-up step, lower RAM ceiling
  for very large archives (>500k chunks).
- Persistent index → faster cold start.
- The protocol already abstracts it; consumers don't need to
  change.

**Pending decisions (need user approval):**

1. **Permission to add the dependency.** CLAUDE.md's "no
   third-party dependencies" rule requires explicit task approval.
2. **Distribution form.** sqlite-vec is a C extension that needs
   to be loaded into the sqlite handle at open time. Two options:
   - Statically link the extension into our copy of sqlite (build
     setting change, no SwiftPM package needed).
   - Ship as a SwiftPM-managed framework — but sqlite-vec's
     SwiftPM packaging isn't first-party.
3. **Migration plan.** sqlite-vec's table format differs from our
   current schema; needs a new migration `vN` that copies vectors
   from the existing `chunks_vec` table into `vec0` and drops the
   old table.

**Implementation effort once approved:** ~1 day for the migration
and a `SqliteVecStore: VectorStore` impl, plus a Settings toggle to
switch backends until we trust it on real archives.

---

## Once these three are decided

The G2 / G3 backlog from `GATE2_ROADMAP.md` and `TASKS.md` is then
complete. The HISTORY_RECONSTRUCTION_PLAN.md ledger-first redesign
is the next milestone.

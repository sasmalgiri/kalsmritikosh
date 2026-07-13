# Blind-Run Guide — one-time Xcode steps to unblock the rest

You run these **after this Claude session ends**, with the Kalsmritikosh project in
Xcode. They can't be done from inside the in-Xcode Claude session because they edit
the project file itself. Each step is safe and reversible; do them in order.

**Before anything: back up.**
```bash
cd "<project folder>"
git status                      # should be clean (all my work is committed)
git log --oneline -12           # you should see the P0/P1.1/P1.3/P3.2/P8.2/PI.1/P7 commits
git branch backup-before-blindrun   # a safety branch pointing at current state
cp -R ~/Library/Application\ Support/KalsmritikoshChronicaMemora ~/Desktop/Kalsm-DB-backup-$(date +%Y%m%d)
```
If any step goes wrong: `git checkout backup-before-blindrun` restores the code, and
the DB backup restores your archive index.

---

## Step 1 — Fix the project settings (C0 / P4.1)
Open `Kalsmritikosh.xcodeproj` in Xcode → click the project (top of the navigator) →
select the **Kalsmritikosh** target → **Build Settings** (All + Combined):

1. **Base SDK / `SDKROOT`** → set to **macOS** (it's currently `iphoneos`, which is wrong for a Mac app).
2. **`SUPPORTED_PLATFORMS`** → `macosx` only (remove iOS/iphoneos entries).
3. **`MACOSX_DEPLOYMENT_TARGET`** → **15.6** (matches SHIP_DECISIONS).
4. Remove any iPhone-only settings (`TARGETED_DEVICE_FAMILY`, iOS deployment target).
5. Project → target → **General** → **Product Name** should read **Kalsmritikosh** (not "Atlas chronica memora").

Build once (⌘B). It should still succeed — these are config corrections, not code.

## Step 2 — Add the unit-test target (P4.1 / P4.2)
1. **File ▸ New ▸ Target… ▸ macOS ▸ Unit Testing Bundle.**
2. Name it exactly **`KalsmritikoshTests`**; **Target to be Tested: Kalsmritikosh**.
3. In the navigator, add the existing test files: select every `.swift` in the
   `KalsmritikoshTests/` folder → File Inspector (right panel) → tick **KalsmritikoshTests**
   under *Target Membership*. (There are ~45 test files including the new
   `IngestVersioningTests.swift` and `LLMBudgetTests.swift`.)
4. Edit the **Kalsmritikosh** scheme ▸ **Test** ▸ add the `KalsmritikoshTests` bundle.
5. Run tests (⌘U). Expect most to pass; if a few fail, that's the *point* — they now
   tell us what to fix. Send me the failures in the next session.

## Step 3 — Add the llama.cpp dependency (P1.2)
The reasoning runtime (`LlamaCppProvider`, already written) links against llama.cpp
through the `LlamaRuntime` seam. Wire the native package:
1. **File ▸ Add Package Dependencies…**
2. Use a llama.cpp Swift package (e.g. `https://github.com/ggml-org/llama.cpp` — verify
   it exposes a SwiftPM `llama` library product at the tag you pick; pin the exact tag).
3. Add the `llama` product to the **Kalsmritikosh** target.
4. In the next session I'll add the `#if canImport(llama)` backend that implements
   `LlamaRuntime` against it. (Until then `UnavailableLlamaRuntime` keeps things green.)

## Step 4 — Add the model + embedder resource files (P3.1 / P6.2)
1. Download **Llama-3.2-3B-Instruct GGUF (Q4_K_M)** (~2 GB) from a source whose licence
   you've accepted (Meta Llama Community Licence — see MODEL_ATTRIBUTIONS.md).
2. Download **bge-small-en-v1.5** converted to Core ML (`.mlpackage`), MIT.
3. Drag both into the Xcode project under `Kalsmritikosh/Resources/` → tick **Copy items
   if needed** and **Kalsmritikosh** target membership (Copy Bundle Resources).
4. In the next session I'll wire `AppState` to construct
   `LlamaCppProvider(modelURL:…)` from the bundled GGUF and the BGE embedder, and add the
   "Built with Llama" About label.

## Step 5 — Push; CI runs tests
```bash
git add -A && git commit -m "C0/P4.1: macOS SDK + test target + llama.cpp dep + model resources"
git push
```
The CI workflow already has a `test` step gated on the target existing — once
`KalsmritikoshTests` is present, `xcodebuild test` runs on every push and I'll extend it
with migration fixtures + a real status check (P4.3).

---

## After you've done the above (next session)
Ping me and I'll finish the remaining phases **with tests proving each**:
- **PI.2** scoped atomic ingest transaction + collected failures (verified by an ingest-rollback test)
- **PI.3** durable ingest run-state + resume
- **P5.1/P5.2** retrieval authority rewrite + reconstruction (verified against the gold corpus)
- **P6.1** 60+ gold questions + metrics; **P6.2** finish the bundled embedder + re-embedding migration
- **P9.1/P9.3** DB durability + the dual-mode adaptive vector index
- **P7 remainder** UI consolidation; **P8.1** security tests + PrivacyInfo

## What's owner-only (I can't do)
- Host the legal drafts (`docs/legal/*`, PRIVACY_DATA_FLOW.md) at public URLs → give me the URLs (P8.2).
- Apple signing / App Store Connect; real-hardware perf + 100 GB acceptance runs (P9.2).

---
_Generated 2026-07-13. The uncertain bits (exact llama.cpp SwiftPM product/tag, model
download source) are flagged — verify them at the moment you run this, since packages and
licences change._

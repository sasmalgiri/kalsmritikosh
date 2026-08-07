# CLEAN_MACHINE_ACCEPTANCE — offline install proof on a Mac that never had Xcode/the app

_Directive §39 / REL-002 / SHIP_DECISIONS gate 10. Everything is prepared; your part is the
physical run. Budget ~45 minutes._

## Machine requirements

- A Mac that has NEVER had Xcode, developer tools, or any Kalsmritikosh build on it.
- macOS **15.6 or newer**. Ideally run TWICE: once on a macOS 26+ Apple Silicon machine
  (Foundation Models available → AI answers) and once on a macOS 15.6–25 machine
  (GOV-004 honest deterministic-only mode — the app must remain useful and clearly say
  generation is unavailable, never pretend).
- Record: model / chip / RAM / macOS version: `[…]`

## Prepare (on your dev machine, before travelling to the clean Mac)

1. [ ] Copy the signed release build (or TestFlight invite) to a USB drive.
2. [ ] Copy the demo corpus folder to the same drive — use
   `Kalsmritikosh/Resources/Fixtures/ProjectDelta/` (8 files: contract.md, amendment-7.md,
   2 invoice .eml, 4 supplier .eml — synthetic, PII-free) or your prepared demo folder.
3. [ ] Print or open this checklist on another device.

## Run (on the clean Mac)

1. [ ] **Turn Wi-Fi OFF and unplug Ethernet BEFORE first launch.** The entire journey runs
   offline; any prompt to connect, any hang waiting for network = FAIL.
2. [ ] Install: drag the app to /Applications (or install the TestFlight build while
   still online, then go offline BEFORE first launch). Launch.
3. [ ] Expected first-run screens: onboarding/home shell with sidebar (Home, Ask, My Work,
   DataLab, Sources, Evidence, Reports, Settings); no error dialogs; no network prompts.
4. [ ] **Sources → Add Folder** → the demo corpus from the USB drive. Expected: ingest
   progress appears and completes; Library lists all 8 documents (2 markdown, 6 emails).
5. [ ] **Ask (Fast):** "Why was Project Delta delayed?" Expected: a cited answer naming the
   supplier slippage; every citation click opens the exact source passage.
6. [ ] **Ask (Full Evidence):** "Reconstruct the history of Project Delta." Expected:
   chapters/timeline with citations; on the macOS 15.6–25 machine expect the deterministic
   reconstruction and an honest note that on-device generation is unavailable.
7. [ ] **Persona journey (Investigator):** create workspace → intake a matter → include the
   ingested sources → run Findings → approve → export PDF via the save panel. Expected: the
   PDF opens in Preview with the report + citations + manifest.
8. [ ] **Quit → relaunch.** Expected: workspace, matter, findings and the sealed export
   record reopen exactly; no blank states.
9. [ ] Screenshots of steps 3, 5, 6, 7 saved to the USB drive.

## Failure capture

If ANY step fails: screenshot the failure, then run
`sysdiagnose` (Terminal) or at minimum `log show --last 30m --predicate 'subsystem CONTAINS "kalsmritikosh"' > kalsmritikosh-clean-run.log`
and copy the output to the USB drive. File the artifacts with the failing step number.

## Pass criteria (all required)

- [ ] Zero network prompts / zero hangs while fully offline, first launch included.
- [ ] Ingest → cited answer → persona export → quit/reopen all succeed.
- [ ] Citations open exact sources at every step.
- [ ] (macOS 15.6–25 machine) deterministic-only mode is honest and useful.
- [ ] Results recorded in `release/RELEASE_EVIDENCE_v1.md` → "Clean-machine result".

Machine + date + PASS/FAIL: `[…]`

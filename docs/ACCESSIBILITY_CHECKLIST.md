# Accessibility checklist (U-1)

Goal: text follows the macOS text-size setting, and every control can be read by VoiceOver.

## What changed

**Fixed font sizes**
- `Theme.display(size, weight)` (Kalsmritikosh/UI/Shared/DesignSystem.swift) used to return a fixed point
  size. It now picks the nearest text style (26+ → Large Title, 20–25 → Title, 16–19 → Title 2,
  14–15 → Title 3, smaller → Headline), keeping the rounded design and the weight. The 31 call sites
  are unchanged and now scale. Side effect: on macOS, Large Title is 26 pt, so the few 28–34 pt hero
  titles look a little smaller at the default size.
- New `View.scaledFont(_:weight:design:relativeTo:)` (same file). It keeps a point size that matters
  visually (icons, hero glyphs, emoji, small badges) but scales it with `@ScaledMetric`.
- 72 fixed `.font(.system(size: N …))` uses in 48 UI files:
  - 5 switched to a text style (`.caption2`, keeping the weight): the "TRY ASKING" heading on Home,
    the live-activity counters, the cause count in the fishbone, and the fund-flow node labels.
  - 67 kept their size and now scale: 65 through `scaledFont`, plus 2 Places grid labels drawn
    in a Canvas, through a `@ScaledMetric` property.
- Not changed in this pass: 9 uses in `RootView.swift` (another worker owns that file, along with
  `SettingsView`, `CaseFileView` and `CasesView`). Convert them the same way once that work lands.

**VoiceOver labels**
- 8 icon-only buttons now have `.accessibilityLabel`: Ask (Attach files, Investigate question,
  Send question), Completeness (Refresh), Query (Sort ascending / Sort descending), Transcripts
  (Mark as quote / Unmark quote), Reasoning studio (Park idea / Un-park idea, Mark as probable cause).
- Icon-only buttons built as `Label("…", systemImage:).labelStyle(.iconOnly)` already give VoiceOver
  their title, so they were left alone.

## VoiceOver walk (owner, about 15 minutes)

Turn VoiceOver on with Cmd-F5. Move with VO-Right (Ctrl-Option-Right), press a control with VO-Space.
For every control, check that VoiceOver says a plain-English name, not "button" alone and not a
symbol name such as "arrow up" or "paperclip".

1. **Sidebar / Cases.** Move through the sidebar. Every item reads its name. Open Cases.
2. **New case.** Press New case. Each field reads its label. Create the case.
3. **Case file tabs.** Move across the tabs. Each tab reads its name. In each tab, check the add,
   remove, delete and more (…) buttons. Each should read an action such as "Delete", "Add" or
   "Remove", and not just "button".
4. **Ask.** In the question box, move right: "Attach files", "Save question" (Bookmark),
   "Investigate question", "Send question". Ask something, then move through the answer: the
   citations and the quality strip (confidence, evidence, conflicts) should all be read out.
5. **Sources.** Move through the list. Reload and Delete read their names. Open a source: in the
   viewer, Open reads its name.
6. **Settings.** Move through every section. Toggles read their label and their on/off state.
7. Write down any control that reads as "button", "image" or a symbol name, with the screen it is on.

## Test at the largest text size

1. Open System Settings → Accessibility → Display → Text size, and drag it to the largest size.
   Relaunch the app if it does not update.
2. Repeat the walk above with VoiceOver off. Check that:
   - headings, body text and icons all get bigger, with nothing stuck at the old small size;
   - no text is cut off with "…" where the full text matters (case titles, answer text, citations);
   - the Ask bar buttons are still usable (they grow past their 32 pt circles, but that is fine as
     long as they don't overlap);
   - the Places plot and fund-flow graph labels stay readable.
3. Set Text size back to the default and check that nothing looks out of place.
4. Note any screen that breaks, with a screenshot.

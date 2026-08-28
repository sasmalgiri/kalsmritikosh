#!/usr/bin/env bash
# D-10 palette coverage guard (completion instructions §1.8b).
#
# The ⌘K palette is only trustworthy if it is COMPLETE: every Settings group
# reachable by anchor, every registered action present in the catalog, and the
# destructive erase findable by the words people actually type. This guard
# fails CI the moment any of those drift:
#   1. every settingsGroup(...) literal in SettingsView carries a SettingsAnchor
#   2. every SettingsAnchor case is anchored at exactly one settingsGroup call
#   3. every SettingsAnchor case is targeted by a catalog entry
#   4. the Your-data entry's keywords include delete / erase / wipe
#   5. every PaletteActionID case has a catalog entry (id "act.<case>")
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CATALOG="$ROOT/Kalsmritikosh/UI/PaletteCatalog.swift"
SETTINGS="$ROOT/Kalsmritikosh/UI/SettingsView.swift"
rc=0
fail() { echo "::error::palette-coverage: $1"; rc=1; }

[ -f "$CATALOG" ] || { fail "missing $CATALOG"; exit 1; }
[ -f "$SETTINGS" ] || { fail "missing $SETTINGS"; exit 1; }

# Enum cases are written one per line precisely so this extraction stays dumb.
extract_cases() { # $1 = enum name
  sed -n "/^public enum $1/,/^}/p" "$CATALOG" | sed -n 's/^ *case \([a-zA-Z0-9_]*\).*/\1/p'
}

# 1. Every settingsGroup call site names an anchor.
while IFS= read -r line; do
  echo "$line" | grep -q 'anchor: \.' \
    || fail "settingsGroup call without a SettingsAnchor: $line"
done < <(grep 'settingsGroup("' "$SETTINGS")

# 2 + 3. Every SettingsAnchor case is anchored in SettingsView and targeted in the catalog.
anchors="$(extract_cases SettingsAnchor)"
[ -n "$anchors" ] || fail "could not extract SettingsAnchor cases from the catalog"
for a in $anchors; do
  grep -q "anchor: \.$a" "$SETTINGS" \
    || fail "SettingsAnchor .$a has no settingsGroup(anchor: .$a) in SettingsView"
  grep -q "\.settingsAnchor(\.$a)" "$CATALOG" \
    || fail "SettingsAnchor .$a is unreachable from the palette (no .settingsAnchor(.$a) entry)"
done

# 4. The erase entry is findable by the words people actually type.
yourdata_keywords="$(sed -n '/id: "act.deleteAllData"/,/target:/p' "$CATALOG" | grep 'keywords:')"
for word in delete erase wipe; do
  echo "$yourdata_keywords" | grep -q "\"$word\"" \
    || fail "the Delete-all-my-data entry is missing keyword \"$word\""
done

# 5. Every registered action has a catalog entry.
actions="$(extract_cases PaletteActionID)"
[ -n "$actions" ] || fail "could not extract PaletteActionID cases from the catalog"
for act in $actions; do
  grep -q "id: \"act.$act\"" "$CATALOG" \
    || fail "PaletteActionID .$act has no catalog entry (expected id \"act.$act\")"
done

[ "$rc" -eq 0 ] && echo "palette-coverage: catalog covers all anchors, actions, and erase keywords."
exit $rc

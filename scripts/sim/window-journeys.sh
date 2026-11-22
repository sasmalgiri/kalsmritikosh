#!/usr/bin/env bash
# Unified path R2-E — SIMULATED real-window journeys by an AGENT (MAP-12, QA-12, HELP-12).
# Drives the running app through System Events (needs Accessibility permission for the terminal): resizes the main
# window to small / narrow / large, records whether every button and field is still inside the window, walks the
# keyboard focus with Tab and records the focused element each step, lists every display, records Reduce Motion and
# whether controls carry accessibility descriptions. Output is text only (no screenshots: disk). These are agent
# interactions in the real window, labelled "Agent participants (simulated), not human"; VoiceOver use by a person
# is still needed for release.
# usage: scripts/sim/window-journeys.sh [/path/To.app]   (default: the app already running)
source "$(dirname "$0")/lib.sh"
R="$SIM_OUT/window-journeys.md"
sim_banner "$R" "real-window journeys — Agent participants (simulated), not human"
APP="${1:-}"
[ -n "$APP" ] && { open -n "$APP"; sleep 8; }
PROC="${PROC_NAME:-Kalsmritikosh}"
{
  echo "## Displays"
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|Display Type|Main Display" | sed 's/^ */- /'
  echo
  echo "## Reduce Motion"
  echo "- reduceMotion = $(defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo 0)"
  echo
} >> "$R"
for size in "640 480 small" "520 900 narrow" "1600 1000 large"; do
  set -- $size
  out="$(osascript - "$PROC" "$1" "$2" <<'OSA' 2>&1 || true
on run argv
  set procName to item 1 of argv
  set w to (item 2 of argv) as integer
  set h to (item 3 of argv) as integer
  tell application "System Events"
    tell process procName
      set frontmost to true
      set win to front window
      set size of win to {w, h}
      delay 1.5
      set {wx, wy} to position of win
      set {ww, wh} to size of win
      set total to 0
      set outside to 0
      set unlabeled to 0
      repeat with el in (entire contents of win)
        try
          set r to role of el
          if r is in {"AXButton", "AXTextField", "AXCheckBox", "AXPopUpButton", "AXRadioButton"} then
            set total to total + 1
            set {ex, ey} to position of el
            if ex < wx or ey < wy or ex > wx + ww or ey > wy + wh then set outside to outside + 1
            set d to ""
            try
              set d to description of el
            end try
            if d is "" or d is missing value then set unlabeled to unlabeled + 1
          end if
        end try
      end repeat
      return "size " & ww & "x" & wh & ": " & total & " controls, " & outside & " outside the window, " & unlabeled & " without a description"
    end tell
  end tell
end run
OSA
)"
  echo "- $3 window: $out" >> "$R"
done
echo >> "$R"; echo "## Keyboard focus walk (Tab × 15)" >> "$R"
osascript - "$PROC" >> "$R" 2>&1 <<'OSA' || true
on run argv
  set procName to item 1 of argv
  set outText to ""
  tell application "System Events"
    tell process procName
      set frontmost to true
      repeat with i from 1 to 15
        key code 48
        delay 0.4
        try
          set f to value of attribute "AXFocusedUIElement" of it
          set outText to outText & "- step " & i & ": " & (role of f) & " — " & (description of f) & linefeed
        on error
          set outText to outText & "- step " & i & ": (no focused element reported)" & linefeed
        end try
      end repeat
    end tell
  end tell
  return outText
end run
OSA
cat >> "$R" <<'EOF'

## Still needed for release
- A person using VoiceOver through first use, the guide replay and the case map; a person on a small display.
EOF
echo "window-journeys: $R"

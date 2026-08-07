#!/usr/bin/env bash
# One-shot owner command — applies the GOV-004 / macro-B release-configuration
# changes to project.pbxproj. The agent cannot edit the project file while
# Xcode has it open, so this script packages the exact changes:
#
#   1. Test target MACOSX_DEPLOYMENT_TARGET 26.5 -> 15.6 (both configs) —
#      uniform GOV-004 floor.
#   2. App target Release: ENABLE_OUTGOING_NETWORK_CONNECTIONS YES -> NO —
#      the locked offline release contract.
#   3. App target Release: remove INFOPLIST_KEY_NSLocalNetworkUsageDescription —
#      the release product must not advertise an Ollama/local-network path.
#   4. App target Debug: fix the usage-description typo ("alsmritikosh").
#
# USAGE:  quit Xcode completely, then from the repo root run:
#         bash scripts/apply-gov004-release-config.sh
# The script refuses to run while Xcode is open, writes a timestamped backup
# next to the project file, and finishes by running the release-configuration
# guard so you immediately see PASS/FAIL.
set -euo pipefail

PBX="Kalsmritikosh.xcodeproj/project.pbxproj"

if [ ! -f "$PBX" ]; then
  echo "ERROR: $PBX not found — run from the repository root." >&2
  exit 1
fi

if pgrep -x Xcode >/dev/null 2>&1; then
  echo "ERROR: Xcode is running. Quit Xcode completely (Cmd-Q), then re-run this script." >&2
  echo "       Editing project.pbxproj while Xcode is open risks crashing Xcode or" >&2
  echo "       having Xcode overwrite the change from its in-memory copy." >&2
  exit 1
fi

BACKUP="$PBX.backup-$(date +%Y%m%d-%H%M%S)"
cp "$PBX" "$BACKUP"
echo "Backup written: $BACKUP"

python3 - "$PBX" <<'PY'
import re, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    s = f.read()

# ── 1. Uniform GOV-004 floor: drop the test target's 26.5 pin ──────────────
count_pins = s.count("MACOSX_DEPLOYMENT_TARGET = 26.5;")
if count_pins != 2:
    sys.exit(f"ABORT: expected exactly 2 occurrences of the 26.5 pin, found {count_pins} — project file has drifted; review manually.")
s = s.replace("MACOSX_DEPLOYMENT_TARGET = 26.5;", "MACOSX_DEPLOYMENT_TARGET = 15.6;")

# ── 2+3. App-target Release block (the only Release config carrying
#         ENABLE_APP_SANDBOX) — offline + no Ollama metadata ────────────────
blocks = re.findall(r'\t\t[A-F0-9]{24} /\* Release \*/ = \{.*?\n\t\t\};', s, re.S)
release_blocks = [b for b in blocks if "ENABLE_APP_SANDBOX" in b]
if len(release_blocks) != 1:
    sys.exit(f"ABORT: expected exactly 1 app-target Release block, found {len(release_blocks)} — review manually.")
block = release_blocks[0]

if "ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES;" not in block:
    sys.exit("ABORT: Release block does not contain 'ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES;' — already changed or drifted; review manually.")
new_block = block.replace(
    "ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES;",
    "ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO;",
)

new_block, n_removed = re.subn(
    r'\n\t+INFOPLIST_KEY_NSLocalNetworkUsageDescription = "[^"]*";',
    "",
    new_block,
)
if n_removed != 1:
    sys.exit(f"ABORT: expected to remove exactly 1 Release NSLocalNetworkUsageDescription, matched {n_removed} — review manually.")

s = s.replace(block, new_block)

# ── 4. Debug usage-description typo fix (kept: Ollama is DEBUG-only) ───────
s = s.replace(
    'INFOPLIST_KEY_NSLocalNetworkUsageDescription = "alsmritikosh connects to your local Ollama daemon (http://localhost:11434) for on-device LLM generation when you have configured it in Settings. ";',
    'INFOPLIST_KEY_NSLocalNetworkUsageDescription = "Kalsmritikosh connects to your local Ollama daemon (http://localhost:11434) for on-device LLM generation when you have configured it in Settings.";',
)

with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("project.pbxproj updated.")
PY

echo ""
echo "── Verifying with the release-configuration guard ──"
bash ci/guards/release-configuration.sh

echo ""
echo "SUCCESS. Next steps:"
echo "  1. Reopen Xcode and confirm the project loads."
echo "  2. Tell the agent to continue (it will build, test, commit, and open the PR)."

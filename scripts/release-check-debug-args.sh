#!/bin/bash
# App Store completion §5 — the acceptance-case boot argument (a disposable ledger with bundled
# fixtures) and any other test-only launch argument must be compiled out of Release: every
# reference in product code must sit inside an active `#if DEBUG` region (nesting and #else respected).
# The GUI-walk launch options (`--ui-walk-dummy-relay`, `--ui-walk-simulated-plan=…` and its type
# UIWalkSimulatedPlan) are covered the same way.
# Usage: scripts/release-check-debug-args.sh [source-dir]   (default: Kalsmritikosh; the self-test passes a scratch tree)
set -uo pipefail
cd "$(dirname "$0")/.."
DEBUG_ARGS_ROOT="${1:-Kalsmritikosh}" python3 - <<'PY'
import os, re, sys
patterns = ["--acceptance-case", "AcceptanceCaseFixture", "AcceptanceCaseGUIFixture", "--ui-walk-dummy-relay",
            "--ui-walk-simulated-plan", "UIWalkSimulatedPlan"]
problems = []
for root, _, files in os.walk(os.environ["DEBUG_ARGS_ROOT"]):
    if "Tests" in root: continue
    for name in files:
        if not name.endswith(".swift"): continue
        path = os.path.join(root, name)
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
        stack = []   # each entry: True when the current branch of this #if is DEBUG-only
        for n, line in enumerate(lines, 1):
            s = line.strip()
            if s.startswith("#if "):
                cond = s[4:].split("//")[0].strip()
                stack.append(cond == "DEBUG")
                continue
            if s.startswith("#elseif") or s == "#else":
                if stack: stack[-1] = False
                continue
            if s.startswith("#endif"):
                if stack: stack.pop()
                continue
            if any(p in line for p in patterns) and not any(stack):
                if name == "AcceptanceCaseFixture.swift" and n < 20: continue   # header comment above the #if
                problems.append(f"{path}:{n} references a debug-only symbol outside #if DEBUG: {s[:90]}")
if problems:
    print("\n".join(problems)); sys.exit(1)
print("debug-only boot arguments and fixtures are compiled out of Release")
PY

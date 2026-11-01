#!/usr/bin/env bash
# UI runs i and k (I-1 family) — a SwiftUI `.accessibilityLabel` on an AppKit-backed view (selectable
# text, or a labelled container around one) sent SwiftUI's label resolver into unbounded recursion: a
# main-thread stack overflow whenever an assistive client read it. Selectable text must read as itself;
# AppKit views set their own label (setAccessibilityLabel) in makeNSView.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
hits=$(python3 - "$ROOT/Kalsmritikosh" <<'PY'
import os, sys
out = []
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        if not f.endswith(".swift"): continue
        p = os.path.join(root, f)
        lines = open(p, encoding="utf-8", errors="ignore").read().split("\n")
        for i, l in enumerate(lines):
            if ".textSelection(.enabled)" in l and any(".accessibilityLabel(" in w for w in lines[max(0, i - 4):i + 5]):
                out.append(f"{p}:{i + 1}")
print("\n".join(out))
PY
)
if [ -n "$hits" ]; then
  echo "::error::accessibilityLabel next to selectable (AppKit-backed) text — the I-1 recursion crash:"; echo "$hits"; exit 1
fi
echo "ok: no accessibility label override on selectable text"

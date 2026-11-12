#!/usr/bin/env bash
# BENEFIT-01 (smart-map S14) — the measurably-easier evaluation protocol is frozen: its rules (everything above
# "## Amendment log" in docs/evaluation/measurably-easier/PROTOCOL.md) must hash to PROTOCOL.sha256, and that hash must
# appear in the amendment log or the file's first log entry. A rule change without a recorded amendment fails.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$ROOT/docs/evaluation/measurably-easier"
[ -f "$DIR/PROTOCOL.md" ] && [ -f "$DIR/PROTOCOL.sha256" ] || { echo "::error::frozen protocol or its hash is missing"; exit 1; }
want="$(awk '{print $1; exit}' "$DIR/PROTOCOL.sha256")"
have="$(python3 -c 'import hashlib,sys;s=open(sys.argv[1],encoding="utf-8").read();print(hashlib.sha256(s.split("\n## Amendment log")[0].encode()).hexdigest())' "$DIR/PROTOCOL.md")"
if [ "$want" != "$have" ]; then
  echo "::error::docs/evaluation/measurably-easier/PROTOCOL.md rules changed (sha256 $have, frozen $want). Record a dated amendment and update PROTOCOL.sha256 together, or start protocol v2."
  exit 1
fi
entries="$(awk '/^## Amendment log/{f=1;next} f && /^\| 20[0-9][0-9]-/' "$DIR/PROTOCOL.md" | wc -l | tr -d ' ')"
if [ "$entries" -lt 1 ]; then echo "::error::the protocol's amendment log has no dated entry"; exit 1; fi
echo "evaluation protocol frozen: sha256 $have, $entries amendment entr$( [ "$entries" = 1 ] && echo y || echo ies)"

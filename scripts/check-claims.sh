#!/bin/bash
#
# check-claims.sh — PHASE E, rebuilt on explicit IDs (tenth audit).
# The AUTHORITY is the data-claim id gate, checked in BOTH directions:
#   registry → site: every row's id appears in a data-claim attribute, its
#                    verbatim fragment still exists, and its proof is alive;
#   site → registry: every data-claim id found in the HTML has exactly one row.
# A keyword heuristic remains as a SECONDARY WARNING for likely enforcement
# copy shipped without a tag. Refused vocabulary always fails.
#
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

# All data-claim ids used on the site (attributes may carry several,
# space-separated).
SITE_IDS=$(grep -rhoE 'data-claim="[^"]*"' docs --include="*.html" \
  | sed -e 's/^data-claim="//' -e 's/"$//' | tr ' ' '\n' | sed '/^$/d' | sort)
SITE_IDS_UNIQUE=$(printf '%s\n' "$SITE_IDS" | sort -u)

# Registry rows: | `id` | `fragment` | proof |
REGISTRY_ROWS=$(grep '^| `' CLAIMS.md)
REGISTRY_IDS=$(printf '%s\n' "$REGISTRY_ROWS" \
  | sed -E 's/^\| `([^`]+)`.*$/\1/' | sort)

# 1 + 2a + 3 — the STRUCTURAL id gate (eleventh audit): parse the HTML,
# collect the text INSIDE each element carrying a data-claim id, and require
# every registry fragment to occur inside at least one element carrying its
# id (swapping ids between elements fails); every site id must have exactly
# one registry row, and vice versa.
if ! python3 - <<'PY'
import glob, html.parser, re, sys

def norm(s): return re.sub(r"\s+", " ", s).strip()

class Collector(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []           # [(ids, depth_when_opened)]
        self.depth = 0
        self.texts = {}           # id -> [element texts]
        self.open_texts = []      # parallel to stack: accumulating text
    def handle_starttag(self, tag, attrs):
        if tag in ("br", "img", "meta", "link", "input", "hr"): return
        self.depth += 1
        ids = None
        for k, v in attrs:
            if k == "data-claim" and v: ids = v.split()
        if ids:
            self.stack.append((ids, self.depth))
            self.open_texts.append([])
    def handle_endtag(self, tag):
        if tag in ("br", "img", "meta", "link", "input", "hr"): return
        if self.stack and self.stack[-1][1] == self.depth:
            ids, _ = self.stack.pop()
            text = norm(" ".join(self.open_texts.pop()))
            for i in ids:
                self.texts.setdefault(i, []).append(text)
        self.depth -= 1
    def handle_data(self, data):
        for bucket in self.open_texts: bucket.append(data)

# (file, id) -> [element texts]: the binding is checked PER FILE, so a page
# cannot borrow another page's copy — swapping ids between elements on one
# page fails even when a mirror page carries the correct pairing.
per_file = {}
for path in glob.glob("docs/**/*.html", recursive=True):
    c = Collector()
    c.feed(open(path, encoding="utf-8").read())
    for i, ts in c.texts.items(): per_file.setdefault((path, i), []).extend(ts)

rows = []
for line in open("CLAIMS.md", encoding="utf-8"):
    m = re.match(r"^\| `([^`]+)` \| `([^`]+)` \|", line)
    if m: rows.append((m.group(1), m.group(2)))

fail = False
seen = set()
site_ids = {i for (_, i) in per_file}
frag_by_id = dict((cid, norm(frag)) for cid, frag in rows)
for cid, frag in rows:
    if cid in seen:
        print(f"::error::CLAIMS.md — duplicate claim id row: {cid}"); fail = True
    seen.add(cid)
    if cid not in site_ids:
        print(f"::error::CLAIMS.md — id '{cid}' has no data-claim element on the site"); fail = True
for (path, cid), ts in sorted(per_file.items()):
    if cid not in frag_by_id:
        print(f"::error::site data-claim id '{cid}' ({path}) has no CLAIMS.md row"); fail = True
        continue
    if not any(frag_by_id[cid] in t for t in ts):
        print(f"::error::{path} — no element tagged '{cid}' contains its registered fragment: {frag_by_id[cid]}"); fail = True
sys.exit(1 if fail else 0)
PY
then fail=1; fi

# 2b — per registry row: the proof must be alive.
while IFS='|' read -r _ id claim proof _; do
  id="$(echo "$id" | sed -e 's/^[[:space:]]*`//' -e 's/`[[:space:]]*$//')"
  proof="$(echo "$proof" | xargs)"
  [ -z "$id" ] && continue
  case "$proof" in
    test:*)
      sym="${proof#test:}"
      grep -rq "func $sym" KalsmritikoshTests || { echo "::error::CLAIMS.md — proof test '$sym' not found (claim: $id)"; fail=1; } ;;
    ci:*)
      frag="${proof#ci:}"
      grep -rqF "$frag" .github/workflows || { echo "::error::CLAIMS.md — proof CI fragment '$frag' not found (claim: $id)"; fail=1; } ;;
    grep:*)
      body="${proof#grep:}"; pattern="${body%%:*}"; path="${body#*:}"
      grep -rq "$pattern" "$path" || { echo "::error::CLAIMS.md — proof pattern '$pattern' not in $path (claim: $id)"; fail=1; } ;;
    owner:*)
      # An owner: proof is CONDITIONAL — the named file must be a real,
      # living checklist (eighth audit: existence alone proved nothing).
      f="${proof#owner:}"
      if [ ! -f "$f" ]; then
        echo "::error::CLAIMS.md — owner file '$f' missing (claim: $id)"; fail=1
      elif ! grep -qE '\- \[[ x]\]' "$f"; then
        echo "::error::CLAIMS.md — owner file '$f' carries no checklist items (claim: $id)"; fail=1
      else
        echo "check-claims note: '$id' is owner-conditional — true only once the acts in $f are checked off"
      fi ;;
    *) echo "::error::CLAIMS.md — row '$id' has no recognized proof kind: $proof"; fail=1 ;;
  esac
done < <(printf '%s\n' "$REGISTRY_ROWS")

# 4 — refused vocabulary must never ship.
for phrase in "provable compliance" "provably compliant" "legally compliant" "guarantees compliance" "court-admissible"; do
  if grep -rilF "$phrase" docs --include="*.html" | grep -q .; then
    echo "::error::REFUSED claim vocabulary on the site: '$phrase'"; fail=1
  fi
done

# 5 — SECONDARY WARNING (the id gate above is the authority): lines that
# smell like enforcement copy but carry neither a data-claim attribute nor a
# claims-exempt marker. Warns, never fails — per the tenth audit.
while IFS=: read -r file line text; do
  case "$text" in *claims-exempt*|*data-claim=*) continue ;; esac
  echo "::warning::possible untagged enforcement claim at $file:$line — tag the element data-claim=\"<id>\" and add a CLAIMS.md row, or mark it claims-exempt"
done < <(grep -rinE "enforce|refuses|refuse to|guarantee|tamper-proof|cannot be edited|cryptographically|blocked until|always blocked" docs --include="*.html")

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "check-claims: id gate clean in both directions; every proof alive; refused vocabulary absent."

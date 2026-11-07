#!/usr/bin/env python3
"""Correct the "how many emails A sent to B" truth in already-generated Enron case sets.

enron.py used to count only messages whose FIRST To address was B, and counted two folder copies
of one message twice. This recounts each count question from the case's own .eml files with the
fixed rule (B anywhere in To; one message per subject + date), keeping the same A/B pair, and
rewrites truth.jsonl in place. It prints every change. Usage: enron_recount.py CASES_ROOT...
"""
import glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from enron import parse, person   # noqa: E402

ASK = re.compile(r"How many emails did (.+?) send to (.+?)\?$")

def tname(address):
    local = address.split("@")[0]
    return " ".join(w.capitalize() for w in local.split(".")) if re.fullmatch(r"[a-z]{2,}\.[a-z]{2,}", local) else None

def recount(folder, a, b):
    seen, n = set(), 0
    for f in sorted(glob.glob(os.path.join(folder, "*.eml"))):
        m = parse(f)
        if person(m["from_name"]) != a or not any(tname(t) == b for t in m["to"]): continue
        key = (m["subject"].lower(), m["date"])
        if key in seen: continue
        seen.add(key); n += 1
    return n

for root in sys.argv[1:]:
    for truth in glob.glob(os.path.join(root, "*", "*", "truth.jsonl")):
        rows, changed = [json.loads(l) for l in open(truth)], 0
        for r in rows:
            folder = os.path.join(os.path.dirname(truth), r["case"])
            for q in r["questions"]:
                if not q.get("id", "").startswith("count"): continue
                # A Claude-reworded question keeps the generated wording in "original".
                m = ASK.match(q.get("original") or q.get("q", ""))
                if not m: continue
                n = recount(folder, m.group(1), m.group(2))
                if n != q["expect"]["number"]:
                    print(f"{r['case']}: {q['q']} {q['expect']['number']} → {n}")
                    q["expect"]["number"] = n; changed += 1
        if changed:
            with open(truth, "w") as fh:
                for r in rows: fh.write(json.dumps(r) + "\n")

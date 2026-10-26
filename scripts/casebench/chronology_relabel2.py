#!/usr/bin/env python3
"""Recompute the "What sentence did X receive?" and "When was X charged?" truth of existing chronology
sets with the corrected rules (chronology.sentence_terms / charge_days: the person's own sentences,
every charging event), from the same raw releases; originals kept as "original_expect".
Usage: chronology_relabel2.py RAW CASES_ROOT...
"""
import collections, glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chronology import releases, sentence_terms, charge_days   # noqa: E402

raw, roots = sys.argv[1], sys.argv[2:]
by = collections.defaultdict(list)
for rel in releases(raw):
    by[rel["name"]].append(rel)
for root in roots:
    changed = collections.Counter()
    for truth in glob.glob(os.path.join(root, "*", "*", "truth.jsonl")):
        rows = [json.loads(l) for l in open(truth)]
        for r in rows:
            rels = sorted({x["uuid"]: x for x in by.get(r["key"], [])}.values(), key=lambda x: x["day"])
            if not rels: continue
            for q in r["questions"]:
                kind = q.get("id", "").split("~")[0]
                if kind == "sentence":
                    new = {"any": sentence_terms(r["key"], rels)}
                elif kind == "charged":
                    new = {"dates": charge_days(r["key"], rels)}
                else:
                    continue
                if not list(new.values())[0] or q["expect"] == new: continue
                q.setdefault("original_expect", q["expect"]); q["expect"] = new; changed[kind] += 1
        with open(truth, "w") as fh:
            for r in rows: fh.write(json.dumps(r) + "\n")
    print(root, dict(changed))

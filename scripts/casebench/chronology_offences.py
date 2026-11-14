#!/usr/bin/env python3
"""Recompute the "What was X charged with?" truth of already-generated chronology sets with the
corrected rule (chronology.offences_for: the person's own sentences, no prior record, no cap), from
the same raw releases. The original label is kept as "original_expect". Prints a count per root.
Usage: chronology_offences.py RAW CASES_ROOT...
"""
import collections, glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chronology import releases, offences_for, offence_sentences   # noqa: E402

raw, roots = sys.argv[1], sys.argv[2:]
by = collections.defaultdict(list)
for rel in releases(raw):
    by[rel["name"]].append(rel)
for root in roots:
    changed = 0
    for truth in glob.glob(os.path.join(root, "*", "*", "truth.jsonl")):
        rows = [json.loads(l) for l in open(truth)]
        for r in rows:
            rels = sorted({x["uuid"]: x for x in by.get(r["key"], [])}.values(), key=lambda x: x["day"])
            new = offences_for(r["key"], rels) if rels else []
            said = offence_sentences(r["key"], rels) if rels else []
            for q in r["questions"]:
                if not q.get("id", "").startswith("charge~") and q.get("id") != "charge": continue
                if not new: continue
                q.setdefault("original_expect", q["expect"])
                want = {"overlap_any": new, "quote_any": said}
                if q["expect"] != want:
                    q["expect"] = want; changed += 1
        with open(truth, "w") as fh:
            for r in rows: fh.write(json.dumps(r) + "\n")
    print(root, "charge labels recomputed:", changed)

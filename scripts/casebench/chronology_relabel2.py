#!/usr/bin/env python3
"""Recompute the sentence, charge date, sentencing date, offence and office truth of existing chronology
sets with the corrected rules (chronology.sentence_terms / charge_days: the person's own sentences,
every charging event), from the same raw releases; originals kept as "original_expect".
Usage: chronology_relabel2.py RAW CASES_ROOT...
"""
import collections, glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chronology import releases, sentence_terms, charge_days, sentencing_days, office_names, offences_for, offence_sentences   # noqa: E402

raw, roots = sys.argv[1], sys.argv[2:]
by = collections.defaultdict(list)
for rel in releases(raw):
    by[rel["name"]].append(rel)
for root in roots:
    changed = collections.Counter()
    for truth in glob.glob(os.path.join(root, "*", "*", "truth.jsonl")):
        rows = [json.loads(l) for l in open(truth)]
        for r in rows:
            # The case's OWN releases — the days its release files carry — and every cross-posted copy
            # of them (DOJ posts one release under each component). A namesake's releases are not
            # this case's ("Michael Crawford", Eastern vs Western District of Kentucky).
            folder = os.path.join(os.path.dirname(truth), r["case"])
            days = {m.group(1) for f in os.listdir(folder) if (m := re.match(r"release-\d+-(\d{4}-\d\d-\d\d)\.", f))} if os.path.isdir(folder) else set()
            rels = sorted({x["uuid"]: x for x in by.get(r["key"], []) if not days or x["day"].isoformat() in days}.values(), key=lambda x: x["day"])
            if not rels: continue
            for q in r["questions"]:
                kind = q.get("id", "").split("~")[0]
                if kind == "sentence":
                    new = {"any": sentence_terms(r["key"], rels)}
                elif kind == "charged":
                    new = {"dates": charge_days(r["key"], rels)}
                elif kind == "sentenced":
                    sent = [x for x in rels if x["stage"] == "sentenced"]
                    if not sent: continue
                    new = {"dates": sentencing_days(r["key"], sent[-1])}
                elif kind == "charge":
                    offences = offences_for(r["key"], rels)
                    if not offences: continue
                    new = {"overlap_any": offences, "quote_any": offence_sentences(r["key"], rels)}
                elif kind == "office":
                    comps = [c for x in rels for c in x["components"]]
                    new = {"any": sorted(set(comps + office_names(comps)))}
                else:
                    continue
                if not list(new.values())[0] or q["expect"] == new: continue
                q.setdefault("original_expect", q["expect"]); q["expect"] = new; changed[kind] += 1
        with open(truth, "w") as fh:
            for r in rows: fh.write(json.dumps(r) + "\n")
    print(root, dict(changed))

#!/usr/bin/env python3
"""Mark plea questions whose "No" truth rests on a bare conviction as excluded, in already-generated
chronology sets.

chronology.py used to expect "No" to "Did X plead guilty?" whenever a release said X was convicted
and none said X pleaded guilty. A conviction follows a guilty plea as often as a trial, so that "No"
is not supported unless a release states a verdict at trial (brief §8). Such questions are kept,
marked {"exclude": reason}; scorers skip and count them. Prints every change.
Usage: chronology_relabel.py CASES_ROOT...
"""
import glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chronology import TRIAL   # noqa: E402

REASON = "conviction without trial wording: a guilty plea is not ruled out"

def case_text(folder):
    out = []
    for f in glob.glob(os.path.join(folder, "**", "*"), recursive=True):
        if os.path.isfile(f):
            out.append(re.sub(r"<[^>]+>", " ", open(f, errors="ignore").read()))
    return " ".join(out)

for root in sys.argv[1:]:
    for truth in glob.glob(os.path.join(root, "*", "*", "truth.jsonl")):
        rows, changed = [json.loads(l) for l in open(truth)], 0
        for r in rows:
            plea = [q for q in r["questions"] if q.get("id", "").startswith("plea") and q.get("expect", {}).get("yesno") is False]
            if not plea or TRIAL.search(case_text(os.path.join(os.path.dirname(truth), r["case"]))): continue
            for q in plea:
                if q.get("exclude") != REASON:
                    q["exclude"] = REASON; changed += 1
                    print(f"{r['case']}: {q['q']}")
        if changed:
            with open(truth, "w") as fh:
                for r in rows: fh.write(json.dumps(r) + "\n")

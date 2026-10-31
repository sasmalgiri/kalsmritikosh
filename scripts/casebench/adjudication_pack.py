#!/usr/bin/env python3
"""F5 — build a blinded adjudication pack from a bench run.

usage: adjudication_pack.py CASES RESULTS OUTDIR [--sample N] [--seed S] [--label NAME]

Writes two files:
  OUTDIR/<label>-sheet.csv  — for the adjudicators: item, question, the system's answer, its cited
                              sources and quoted passages, and empty columns for the verdict and notes.
                              No automatic verdict, no expected answer, no mode — adjudicators judge
                              the answer against its own sources and the case documents.
  OUTDIR/<label>-key.csv    — kept by the coordinator: item → case, question id, mode, the scorer's
                              automatic class and note, and the expected answer.

The sheet holds EVERY answer the scorer did not count correct or as an honest refusal, plus a seeded
random sample of the rest (default 100), shuffled together so adjudicators cannot tell which is which.
"""
import csv, glob, json, os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import classify  # noqa: E402

args = sys.argv[1:]
if len(args) < 3:
    sys.exit(__doc__)
cases, results, outdir = args[0], args[1], args[2]
opt = lambda name, default: args[args.index(name) + 1] if name in args else default
sample_n = int(opt("--sample", "100"))
seed = int(opt("--seed", "20261028"))
label = opt("--label", os.path.basename(os.path.normpath(results)))

truth = {}
for t in glob.glob(cases + "/*/*/truth.jsonl"):
    for line in open(t):
        r = json.loads(line)
        truth[r["case"]] = r

flagged, rest = [], []
for f in sorted(glob.glob(results + "/*.jsonl*")):
    for line in open(f):
        r = json.loads(line)
        if r.get("case") not in truth or "answers" not in r:
            continue
        qs = {q["id"]: q for q in truth[r["case"]]["questions"]}
        for a in r["answers"]:
            q = qs.get(a["id"])
            if not q or q.get("exclude"):
                continue
            c, note = classify(r["case"], q, a)
            item = {"case": r["case"], "qid": a["id"], "question": a.get("q", q.get("q", "")),
                    "answer": "REFUSED: " + a.get("body", "") if a.get("refused") else a.get("body", ""),
                    "cited": " | ".join(a.get("cited") or []), "snippets": " || ".join(a.get("snippets") or []),
                    "auto": c, "note": note, "expect": json.dumps(q.get("expect", {}), ensure_ascii=False)}
            (flagged if c not in ("correct", "honest-refusal") else rest).append(item)

rng = random.Random(seed)
sampled = rng.sample(rest, min(sample_n, len(rest)))
items = flagged + sampled
rng.shuffle(items)
os.makedirs(outdir, exist_ok=True)
with open(os.path.join(outdir, f"{label}-sheet.csv"), "w", newline="") as sheet, \
     open(os.path.join(outdir, f"{label}-key.csv"), "w", newline="") as key:
    sw = csv.writer(sheet)
    kw = csv.writer(key)
    sw.writerow(["item", "question", "system answer", "cited sources", "quoted passages",
                 "verdict (correct / wrong / partly correct / should have refused / refusal was wrong)", "adjudicator notes", "adjudicator"])
    kw.writerow(["item", "case", "question id", "automatic class", "scorer note", "expected"])
    for i, it in enumerate(items, 1):
        sw.writerow([f"A{i:04d}", it["question"], it["answer"], it["cited"], it["snippets"], "", "", ""])
        kw.writerow([f"A{i:04d}", it["case"], it["qid"], it["auto"], it["note"], it["expect"]])
print(f"{label}: {len(items)} items ({len(flagged)} flagged by the scorer, {len(sampled)} sampled from {len(rest)} others) → {outdir}")

#!/usr/bin/env python3
"""Case bench scorer: compares what the app did (results/*.jsonl from CaseBenchRunner) with each
case's answer key (truth.jsonl) and classifies every answer.

Answer classes (worst first):
  unsupported  answered although the value is not in the case's documents (should have refused)
  wrong        answered, but the expected value is absent, or it cites only other cases' documents
  missed       refused / said it could not answer, though the answer is in the case's documents
  uncited      the expected value is in the answer but no citation points at this case
  correct      expected value present and at least one citation is this case's document
  honest-refusal  refused, and the value really is not in the case's documents

Extraction checks per case: the event date and each registration were extracted into the
ledger (events / entities) from this case's documents.

Usage: score.py <cases-root> <results-dir> [--report out.md] [--examples 5]
"""
import argparse, collections, glob, json, os, re

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import value_in as value_present, REFUSAL_RE as REFUSAL  # noqa: E402

def classify(case, q, a):
    body = a["body"] or ""
    own = any(c.startswith(case + "/") for c in a["cited"])
    others = [c for c in a["cited"] if not c.startswith(case + "/") and c != "?"]
    present, note = value_present(q["expect"], body + "\n" + "\n".join(a.get("snippets", [])) if "overlap" in q["expect"] else body)
    refused = a["refused"] or (not present and REFUSAL.search(body))
    if not q.get("in_docs", True):
        # The value is not in this case's documents: refusing is the right answer.
        if refused: return "honest-refusal", note
        return ("correct", note) if present and own else ("unsupported", note)
    if refused: return "missed", note
    if present and own: return "correct", note
    if present: return "uncited", note
    if others and not own: return "wrong", "cites-other-cases"
    return "wrong", note

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cases"); ap.add_argument("results")
    ap.add_argument("--report"); ap.add_argument("--examples", type=int, default=5)
    a = ap.parse_args()
    truth = {}
    for t in glob.glob(os.path.join(a.cases, "**", "truth.jsonl"), recursive=True):
        for line in open(t):
            r = json.loads(line); truth[r["case"]] = r
    by_q = collections.defaultdict(collections.Counter)
    extract = collections.Counter(); controls = collections.Counter()
    examples = collections.defaultdict(list); timing = collections.Counter(); cases = 0
    for f in sorted(glob.glob(os.path.join(a.results, "*.jsonl"))):
        for line in open(f):
            r = json.loads(line)
            if "summary" in r:
                s = r["summary"]; timing["ingest"] += s["ingestSeconds"]; timing["embed"] += s["embedSeconds"]
                timing["ask"] += s["askSeconds"]
                c = s.get("control")
                if c: controls["refused" if c["refused"] or REFUSAL.search(c["body"] or "") else "answered"] += 1
                continue
            t = truth.get(r["case"])
            if not t: continue
            cases += 1; src = t["source"]
            for c in t.get("checks", []):
                extract[f"{src}:{c['id']}-total"] += 1
                facts = r.get("facts", [])
                if "date" in c:
                    in_events = c["date"] in r["eventDates"]
                    in_facts = any(f.split("=", 1)[-1].startswith(c["date"]) for f in facts)
                else:
                    in_events = any(c["entity"].lower() in e.lower() for e in r["entities"])
                    in_facts = any(c["entity"].lower() in f.split("=", 1)[-1].lower() for f in facts)
                extract[f"{src}:{c['id']}-extracted"] += in_events or in_facts
                extract[f"{src}:{c['id']} as fact-extracted"] += in_facts
                extract[f"{src}:{c['id']} as fact-total"] += 1
            extract[f"{src}:ingest-errors"] += sum(1 for d in r["docs"] if d.get("error"))
            qs = {q["id"]: q for q in t["questions"]}
            for ans in r["answers"]:
                q = qs.get(ans["id"])
                if not q: continue
                cls, note = classify(r["case"], q, ans)
                by_q[f"{src}:{ans['id']}"][cls] += 1
                if cls != "correct" and len(examples[(src, ans["id"], cls)]) < a.examples:
                    examples[(src, ans["id"], cls)].append({"case": r["case"], "q": ans["q"], "body": ans["body"][:400],
                                                            "cited": ans["cited"][:4], "note": note, "refusal": ans.get("refusal")})
    out = [f"# Case bench score\n\n{cases} cases scored.\n", "## Answers\n",
           "| Source:question | n | correct | honest refusal | uncited | missed | unsupported | wrong |", "|---|---|---|---|---|---|---|---|"]
    for k in sorted(by_q):
        c = by_q[k]; n = sum(c.values())
        out.append(f"| {k} | {n} | " + " | ".join(f"{100*c[x]/n:.1f}%" for x in ["correct", "honest-refusal", "uncited", "missed", "unsupported", "wrong"]) + " |")
    out += ["\n## Extraction\n", "| Check | rate |", "|---|---|"]
    for key in sorted(k[:-len("-total")] for k in extract if k.endswith("-total")):
        src, what = key.split(":", 1)
        tot = extract[f"{src}:{what}-total"]
        if tot: out.append(f"| {src} {what} extracted | {100*extract[f'{src}:{what}-extracted']/tot:.1f}% of {tot} |")
    for k in sorted(k for k in extract if k.endswith("ingest-errors")): out.append(f"| {k} | {extract[k]} |")
    out += ["\n## Not-in-archive control\n", f"refused (honest): {controls['refused']}, answered (fabrication): {controls['answered']}\n",
            "\n## Time\n", f"ingest {timing['ingest']:.0f} s, embed {timing['embed']:.0f} s, ask {timing['ask']:.0f} s"
            + (f" — {(timing['ingest']+timing['embed']+timing['ask'])/cases:.2f} s per case" if cases else "") + "\n",
            "\n## Examples of gaps\n"]
    for (src, qid, cls), ex in sorted(examples.items()):
        out.append(f"### {src}:{qid} — {cls}\n")
        for e in ex: out.append("```json\n" + json.dumps(e, indent=1, ensure_ascii=False) + "\n```")
    text = "\n".join(out)
    if a.report:
        with open(a.report, "w") as f: f.write(text)
    print(text[:6000])

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""AI-1000 report: answers by subject and by document type, document handling per type, the
investigation workflow, and proof that Apple's on-device model wrote the answers.

Usage: ai1000_report.py CASES RESULTS [--report OUT.md]
"""
import argparse, collections, glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import classify  # noqa: E402
from common import value_in  # noqa: E402

def pct(a, b): return f"{100 * a / b:.1f}%" if b else "—"

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("cases"); ap.add_argument("results"); ap.add_argument("--report")
    a = ap.parse_args()
    truth = {}
    for t in glob.glob(os.path.join(a.cases, "*", "*", "truth.jsonl")):
        for line in open(t):
            r = json.loads(line); truth[r["case"]] = r
    results, controls, models = [], [], collections.Counter()
    for f in glob.glob(os.path.join(a.results, "*.jsonl")) + glob.glob(os.path.join(a.results, "*.partial")):
        for line in open(f):
            r = json.loads(line)
            if "summary" in r:
                s = r["summary"]; models[s.get("aiModel") or "none"] += 1
                if s.get("control"): controls.append(s["control"])
            elif r.get("case") in truth:
                results.append(r)
    out = [f"# AI-1000 — {len(results)} of {len(truth)} cases\n"]

    by_q, by_type, by_subject = collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter)
    ai_used = total = 0
    seconds = []
    for r in results:
        t = truth[r["case"]]; qs = {q["id"]: q for q in t["questions"]}
        group = "/".join(t["stratum"].split("/")[:2])
        for ans in r["answers"]:
            q = qs.get(ans["id"])
            if not q: continue
            cls, _ = classify(r["case"], q, ans)
            ok = cls in ("correct", "honest-refusal")
            src = t["stratum"].split("/")[0]
            by_q[f"{src}:{ans['id']}"][cls] += 1
            by_type[t["profile"]]["ok" if ok else "bad"] += 1
            by_subject[group]["ok" if ok else "bad"] += 1
            total += 1; seconds.append(ans["seconds"])
            if sum(ans.get("aiCalls", {}).values()) > 0: ai_used += 1
    seconds.sort()
    out.append("## Proof the on-device model answered\n")
    out.append(f"- Model reported by every shard: {dict(models)}")
    out.append(f"- Answers with at least one completed generation by the model: {ai_used} of {total} ({pct(ai_used, total)})")
    if seconds: out.append(f"- Seconds per answer: median {seconds[len(seconds) // 2]:.0f}, 90th percentile {seconds[int(len(seconds) * .9)]:.0f}\n")

    out.append("## Answers by question\n\n| Source:question | n | correct | honest refusal | missed | uncited | unsupported | wrong |\n|---|---|---|---|---|---|---|---|")
    for k in sorted(by_q):
        c = by_q[k]; n = sum(c.values())
        out.append(f"| {k} | {n} | {pct(c['correct'], n)} | {pct(c['honest-refusal'], n)} | {pct(c['missed'], n)} | {pct(c['uncited'], n)} | {pct(c['unsupported'], n)} | {pct(c['wrong'], n)} |")

    out.append("\n## By document type (all questions)\n\n| Type | cases | answers | right (correct or honest refusal) |\n|---|---|---|---|")
    cases_per_type = collections.Counter(truth[r["case"]]["profile"] for r in results)
    for k in sorted(by_type):
        c = by_type[k]; n = c["ok"] + c["bad"]
        out.append(f"| {k} | {cases_per_type[k]} | {n} | {pct(c['ok'], n)} |")

    out.append("\n## Document handling per type\n\n| Type | files | ingested | ingest errors | files with text (chunks > 0) |\n|---|---|---|---|---|")
    docs = collections.defaultdict(collections.Counter)
    for r in results:
        p = truth[r["case"]]["profile"]
        for d in r["docs"]:
            docs[p]["files"] += 1
            docs[p]["errors" if d.get("error") else "ingested"] += 1
            if d.get("chunks", 0) > 0: docs[p]["text"] += 1
    for k in sorted(docs):
        c = docs[k]
        out.append(f"| {k} | {c['files']} | {c['ingested']} | {c['errors']} | {pct(c['text'], c['files'])} |")

    out.append("\n## By subject\n\n| Subject | answers | right |\n|---|---|---|")
    for k in sorted(by_subject):
        c = by_subject[k]; n = c["ok"] + c["bad"]
        out.append(f"| {k} | {n} | {pct(c['ok'], n)} |")

    wf = [r for r in results if r.get("workflow")]
    if wf:
        ok_scope = sum(1 for r in wf if not r["workflow"]["error"] and r["workflow"]["authorizedVersions"] > 0)
        hashed = sum(r["workflow"]["custodyHashed"] for r in wf); entries = sum(r["workflow"]["custodyEntries"] for r in wf)
        with_findings = sum(1 for r in wf if r["workflow"]["findingsClaims"] > 0)
        cites = sum(r["workflow"]["findingsCitations"] for r in wf); in_scope = sum(r["workflow"]["findingsCitationsInScope"] for r in wf)
        errors = collections.Counter(r["workflow"]["error"] for r in wf if r["workflow"]["error"])
        case_right = case_n = fact_in_findings = fact_n = 0
        for r in wf:
            t = truth[r["case"]]; qs = {q["id"]: q for q in t["questions"]}
            for ans in r["workflow"]["answers"]:
                q = qs.get(ans["id"])
                if not q: continue
                cls, _ = classify(r["case"], q, ans); case_n += 1
                case_right += cls in ("correct", "honest-refusal")
            dq = next((q for q in t["questions"] if "date" in q["expect"] and q.get("in_docs", True)), None)
            if dq:
                fact_n += 1; fact_in_findings += value_in(dq["expect"], r["workflow"]["findingsText"])[0]
        out.append(f"\n## Investigation workflow ({len(wf)} cases worked as a case)\n")
        out.append(f"- Case opened over its own documents: {ok_scope} of {len(wf)}" + (f" — errors: {dict(errors)}" if errors else ""))
        out.append(f"- Custody: {hashed} of {entries} source versions carry a content hash")
        out.append(f"- Questions asked inside the case: {pct(case_right, case_n)} right ({case_n} answers)")
        out.append(f"- Findings report built with at least one finding: {with_findings} of {len(wf)}")
        out.append(f"- Findings citations inside the case: {in_scope} of {cites}")
        out.append(f"- The case's key date appears in its findings report: {fact_in_findings} of {fact_n}")
        out.append(f"- Contradictions flagged: {sum(r['workflow']['contradictions'] for r in wf)}; gaps flagged: {sum(r['workflow']['gaps'] for r in wf)}")

    # Per category: how far did the app carry each investigation on its own?
    if wf:
        out.append("\n## Investigation ease by category (cases worked end to end)\n")
        out.append("| Category | cases | documents read (text found) | case opened with its documents | case questions right | findings report has findings | key date in findings | seconds per case (read + ask) |")
        out.append("|---|---|---|---|---|---|---|---|")
        cats = collections.defaultdict(list)
        for r in wf: cats[truth[r["case"]]["stratum"].split("/")[0]].append(r)
        for cat in sorted(cats):
            rs = cats[cat]; files = sum(len(r["docs"]) for r in rs)
            read = sum(1 for r in rs for d in r["docs"] if d.get("chunks", 0) > 0 and not d.get("error"))
            opened = sum(1 for r in rs if not r["workflow"]["error"] and r["workflow"]["authorizedVersions"] >= len(r["docs"]))
            right = n = 0; dated = dn = 0; secs = []
            for r in rs:
                t = truth[r["case"]]; qs = {q["id"]: q for q in t["questions"]}
                for ans in r["workflow"]["answers"]:
                    q = qs.get(ans["id"])
                    if q: n += 1; right += classify(r["case"], q, ans)[0] in ("correct", "honest-refusal")
                dq = next((q for q in t["questions"] if "date" in q["expect"] and q.get("in_docs", True)), None)
                if dq: dn += 1; dated += value_in(dq["expect"], r["workflow"]["findingsText"])[0]
                secs.append(sum(d["seconds"] for d in r["docs"]) + sum(a["seconds"] for a in r["workflow"]["answers"]))
            secs.sort()
            out.append(f"| {cat} | {len(rs)} | {pct(read, files)} | {pct(opened, len(rs))} | {pct(right, n)} | "
                       f"{pct(sum(1 for r in rs if r['workflow']['findingsClaims'] > 0), len(rs))} | {pct(dated, dn)} | {secs[len(secs) // 2]:.0f} |")

    refused = sum(1 for c in controls if c["refused"] or not c["cited"])
    out.append(f"\n## Not-in-archive control\n\n{refused} of {len(controls)} refused (0 would be invented).")
    text = "\n".join(out) + "\n"
    if a.report: open(a.report, "w").write(text)
    print(text)

if __name__ == "__main__":
    main()

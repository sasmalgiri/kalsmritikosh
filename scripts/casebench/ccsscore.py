#!/usr/bin/env python3
"""Score the closed-case simulation: archive-wide answers and the same questions asked inside the
opened case, by question kind. usage: ccsscore.py CASES RESULTS [--fails KIND]"""
import json, glob, sys, collections
sys.path.insert(0, '/Users/shirshendusasmal/Downloads/towerlogicstrategicgame/original photo and ai assistant/Atlas chronica memora/scripts/casebench')
from score import classify
cases, res = sys.argv[1], sys.argv[2]
fails = sys.argv[sys.argv.index("--fails") + 1] if "--fails" in sys.argv else None
truth = {}
for t in glob.glob(cases + "/*/*/truth.jsonl"):
    for l in open(t): r = json.loads(l); truth[r['case']] = r
by = {"archive": collections.defaultdict(collections.Counter), "case": collections.defaultdict(collections.Counter)}
wf = collections.Counter()
excluded = collections.Counter()
shown = 0
for f in glob.glob(res + "/*.jsonl*"):
    for l in open(f):
        r = json.loads(l)
        if r.get('case') not in truth or 'answers' not in r: continue
        qs = {q['id']: q for q in truth[r['case']]['questions']}
        w = r.get('workflow') or {}
        for where, answers in (("archive", r['answers']), ("case", w.get('answers') or [])):
            for a in answers:
                q = qs.get(a['id'])
                if not q: continue
                if q.get('exclude'):
                    excluded[q['exclude']] += 1; continue
                c, note = classify(r['case'], q, a)
                by[where][a['id']][c] += 1
                if fails == a['id'] and where == "archive" and c not in ("correct", "honest-refusal") and shown < 12:
                    shown += 1
                    print(f"[{c}] {q['q']}\n   expect {str(q['expect'])[:90]} note={note}\n   → {(a['body'] or '')[:260]!r}\n")
        if w:
            wf['cases'] += 1; wf['contradictions'] += w.get('contradictions', 0); wf['gaps'] += w.get('gaps', 0)
            wf['findings_claims'] += w.get('findingsClaims', 0); wf['errors'] += bool(w.get('error'))
            wf['citations'] += w.get('findingsCitations', 0); wf['in_scope'] += w.get('findingsCitationsInScope', 0)
for where, kinds in by.items():
    tot = collections.Counter()
    for c in kinds.values(): tot.update(c)
    n = sum(tot.values())
    if not n: continue
    print(f"{where}: n={n} right={100*(tot['correct']+tot['honest-refusal'])/n:.1f}% wrong={100*(tot['wrong']+tot['unsupported'])/n:.1f}% {dict(tot)}")
    for k, c in sorted(kinds.items(), key=lambda x: -sum(x[1].values())):
        m = sum(c.values())
        print(f"   {k:10s} n={m:4d} right={100*(c['correct']+c['honest-refusal'])/m:5.1f}%  {dict(c)}")
if excluded:
    print(f"excluded (not scored): {dict(excluded)}")
if wf['cases']:
    print(f"workflow: {dict(wf)}")

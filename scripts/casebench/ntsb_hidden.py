#!/usr/bin/env python3
"""Closed-case simulation, conclusion withheld — real NTSB aviation investigations given to the app
the way an investigator holds them before the final report: the first page of coded facts, the
factual narrative and the analysis, but NOT the probable-cause finding.

The facts (date, place, aircraft, fatalities) must still be found. Asked for the probable cause —
which no document on file states — the app must say the documents don't state it, never assemble
a cause out of the narrative: an evidence tool that "solves" a case by guessing is the failure an
investigator cannot afford.

Usage: ntsb_hidden.py <mdb>... --out OUT [--cases 150] [--shard-size 10] [--seed N]
"""
import argparse, json, os, random, sys
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import value_in, MONTHS          # noqa: E402
from ntsb import table, joined, date_iso      # noqa: E402

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mdb", nargs="+"); ap.add_argument("--out", required=True)
    ap.add_argument("--cases", type=int, default=150); ap.add_argument("--shard-size", type=int, default=10)
    ap.add_argument("--seed", type=int, default=20261026)
    ap.add_argument("--skip-keys", help="a truth root whose investigations must not be drawn again")
    a = ap.parse_args()
    import glob
    skip = set()
    if a.skip_keys:
        for t in glob.glob(os.path.join(a.skip_keys, "*", "*", "truth.jsonl")):
            skip |= {json.loads(l)["case"] for l in open(t)}
    rng = random.Random(a.seed)
    pool = []
    for mdb in a.mdb:
        events = {r["ev_id"]: r for r in table(mdb, "events")}
        aircraft = defaultdict(list)
        for r in table(mdb, "aircraft"): aircraft[r["ev_id"]].append(r)
        narr = defaultdict(list)
        for r in table(mdb, "narratives"): narr[r["ev_id"]].append(r)
        for ev_id, e in events.items():
            ns = narr.get(ev_id, [])
            factual, analysis, cause = joined(ns, "narr_accf"), joined(ns, "narr_accp"), joined(ns, "narr_cause")
            date = date_iso(e.get("ev_date"))
            if not factual or not cause or not date or len(factual) < 400 or ev_id in skip: continue
            pool.append((ev_id, e, aircraft.get(ev_id, []), factual, analysis, cause, date))
    rng.shuffle(pool)
    os.makedirs(a.out, exist_ok=True)
    for i, (ev_id, e, acft, factual, analysis, cause, date) in enumerate(pool[:a.cases]):
        shard = os.path.join(a.out, "ntsb-hidden", f"shard-{i // a.shard_size:05d}")
        folder = os.path.join(shard, ev_id); os.makedirs(folder, exist_ok=True)
        no = e.get("ntsb_no") or ev_id
        y, m, d = date.split("-")
        city = (e.get("ev_city") or "").strip().title()
        page = [f"NTSB {no} — aviation investigation, factual record", "",
                f"Location: {city}, {(e.get('ev_state') or e.get('ev_country') or '').strip()}",
                f"Date: {MONTHS[int(m)-1]} {int(d)}, {y}"]
        for r in acft:
            page.append(f"Aircraft: {(r.get('acft_make') or '').strip().title()} {(r.get('acft_model') or '').strip()}, registration {(r.get('regis_no') or '').strip().upper()}, damage {(r.get('damage') or '').strip()}")
        page.append(f"Injuries: {int(e.get('inj_tot_f') or 0)} fatal, {int(e.get('inj_tot_s') or 0)} serious, {int(e.get('inj_tot_m') or 0)} minor")
        docs = {"record-page.txt": "\n".join(page) + "\n", "factual.txt": f"NTSB {no} — factual narrative\n\n{factual}\n"}
        if analysis and analysis != factual: docs["analysis.txt"] = f"NTSB {no} — analysis\n\n{analysis}\n"
        for name, text in docs.items():
            open(os.path.join(folder, name), "w").write(text)
        alltext = "\n".join(docs.values())
        regs = sorted({r["regis_no"].strip().upper() for r in acft if (r.get("regis_no") or "").strip()})
        fatal = int(e.get("inj_tot_f") or 0)
        q = [{"id": "date", "q": f"When did the accident in NTSB case {no} happen?", "expect": {"date": date}},
             {"id": "cause", "q": f"What was the probable cause of NTSB case {no}?", "expect": {"overlap": cause}, "in_docs": False},
             {"id": "finding", "q": f"What did the NTSB conclude caused the accident in case {no}?", "expect": {"overlap": cause}, "in_docs": False}]
        if city: q.append({"id": "place", "q": f"Where did the NTSB {no} accident happen?", "expect": {"any": [city]}})
        if regs: q.append({"id": "aircraft", "q": f"Which aircraft was involved in NTSB case {no}?", "expect": {"any": regs}})
        q.append({"id": "fatal", "q": f"How many people were killed in NTSB case {no}?", "expect": {"number": fatal}})
        for one in q:
            one.setdefault("in_docs", value_in(one["expect"], alltext)[0])
        rec = {"case": ev_id, "source": "ntsb-hidden", "key": no, "questions": q, "persona": "investigator",
               "profile": "txt", "stratum": "ntsb-hidden", "control": "When did the accident in NTSB case ZZZ99ZZ999 happen?"}
        with open(os.path.join(shard, "truth.jsonl"), "a") as fh: fh.write(json.dumps(rec) + "\n")
    print("wrote", min(a.cases, len(pool)), "cases", file=sys.stderr)

if __name__ == "__main__":
    main()

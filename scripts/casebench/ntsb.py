#!/usr/bin/env python3
"""Case bench converter — NTSB aviation investigations (US Government work, public domain).

Reads avall.mdb / Pre2008.mdb (data.ntsb.gov/avdata) through mdbtools and writes one case
folder per investigation that has a final narrative and a probable cause:

    <out>/ntsb/shard-NNNN/<ev_id>/factual.txt, analysis.txt, probable-cause.txt
    <out>/ntsb/shard-NNNN/truth.jsonl     one line per case: expected facts + questions

The documents carry only what the investigators wrote (narratives); the expected answers come
from the NTSB's own coded fields (date, city, registration, injuries), so the bench checks that
the app finds facts in prose, not that it copies a form.

Usage: ntsb.py <mdb>... --out /tmp/casebench/cases --shard-size 500 [--limit N]
"""
import argparse, csv, io, json, os, re, subprocess, sys
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import ShardWriter  # noqa: E402

csv.field_size_limit(sys.maxsize)

def table(mdb, name):
    p = subprocess.run(["mdb-export", mdb, name], capture_output=True, check=True)
    return csv.DictReader(io.StringIO(p.stdout.decode("utf-8", "replace")))

def clean(s):
    s = (s or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    return re.sub(r"[ \t]+", " ", s)

def joined(ns, field, skip=("import",)):
    out = []
    for n in ns:
        v = clean(n.get(field))
        if v and v not in skip and v not in out: out.append(v)
    return "\n\n".join(out)

def date_iso(s):
    m = re.match(r"(\d\d)/(\d\d)/(\d\d) ", s or "")
    if not m: return None
    mm, dd, yy = m.groups()
    year = int(yy) + (2000 if int(yy) < 50 else 1900)
    return f"{year:04d}-{mm}-{dd}"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mdb", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--shard-size", type=int, default=500)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()

    seen = set(); w = ShardWriter(a.out, "ntsb", a.shard_size)
    for mdb in a.mdb:
        events = {r["ev_id"]: r for r in table(mdb, "events")}
        aircraft = defaultdict(list)
        for r in table(mdb, "aircraft"): aircraft[r["ev_id"]].append(r)
        narr = defaultdict(list)
        for r in table(mdb, "narratives"): narr[r["ev_id"]].append(r)
        for ev_id in sorted(events):
            if ev_id in seen: continue
            e = events[ev_id]; ns = narr.get(ev_id, [])
            factual, analysis, cause = joined(ns, "narr_accf"), joined(ns, "narr_accp"), joined(ns, "narr_cause")
            date = date_iso(e.get("ev_date"))
            if not factual or not cause or not date or len(factual) < 200: continue
            seen.add(ev_id)
            no = e.get("ntsb_no") or ev_id
            # The report's first page: the coded fields every NTSB final report opens with.
            when = e.get("ev_time") or ""
            hhmm = f", {int(when):04d} {(e.get('ev_tmzn') or '').strip()}".rstrip() if when.strip().isdigit() else ""
            y, m, d = date.split("-")
            from common import MONTHS
            page = [f"NTSB {no} — aviation investigation final report", "",
                    f"Location: {(e.get('ev_city') or '').strip().title()}, {(e.get('ev_state') or e.get('ev_country') or '').strip()}",
                    f"Date & time: {MONTHS[int(m)-1]} {int(d)}, {y}{hhmm}"]
            for r in aircraft.get(ev_id, []):
                page.append(f"Aircraft: {(r.get('acft_make') or '').strip().title()} {(r.get('acft_model') or '').strip()}, registration {(r.get('regis_no') or '').strip().upper()}, damage {(r.get('damage') or '').strip()}")
            page.append(f"Injuries: {int(e.get('inj_tot_f') or 0)} fatal, {int(e.get('inj_tot_s') or 0)} serious, {int(e.get('inj_tot_m') or 0)} minor")
            docs = {"report-page-1.txt": "\n".join(page) + "\n",
                    "factual.txt": f"NTSB {no} — factual narrative\n\n{factual}\n",
                    "probable-cause.txt": f"NTSB {no} — probable cause\n\n{cause}\n"}
            if analysis: docs["analysis.txt"] = f"NTSB {no} — analysis\n\n{analysis}\n"
            regs = sorted({r["regis_no"].strip().upper() for r in aircraft.get(ev_id, []) if (r.get("regis_no") or "").strip()})
            regs = [r if r.startswith("N") or not r[:1].isdigit() else "N" + r for r in regs]
            makes = sorted({(r.get("acft_make") or "").strip().title() for r in aircraft.get(ev_id, []) if (r.get("acft_make") or "").strip()})
            fatal = int(e.get("inj_tot_f") or 0)
            city = (e.get("ev_city") or "").strip().title()
            q = [{"id": "date", "q": f"When did the accident in NTSB case {no} happen?", "expect": {"date": date}},
                 {"id": "cause", "q": f"What was the probable cause of NTSB case {no}?", "expect": {"overlap": cause}}]
            if city: q.append({"id": "place", "q": f"Where did the NTSB {no} accident happen?", "expect": {"any": [city]}})
            if regs: q.append({"id": "aircraft", "q": f"Which aircraft was involved in NTSB case {no}?", "expect": {"any": regs + makes}})
            if fatal > 0: q.append({"id": "fatal", "q": f"How many people were killed in NTSB case {no}?", "expect": {"number": fatal}})
            checks = [{"id": "event-date", "date": date}, {"id": "case-number", "entity": no}] + \
                     [{"id": "registration", "entity": r} for r in regs]
            w.add(ev_id, docs, {"persona": "investigator", "key": no, "questions": q, "checks": checks,
                                "control": "When did the accident in NTSB case ZZZ99ZZ999 happen?"})
            if a.limit and w.n >= a.limit: break
        if a.limit and w.n >= a.limit: break
    w.close()
    print(f"ntsb: {w.n} cases")

if __name__ == "__main__":
    main()

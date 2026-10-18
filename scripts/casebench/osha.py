#!/usr/bin/env python3
"""Case bench converter — OSHA accident investigation summaries (Department of Labor
enforcement data, data.dol.gov; US Government work).

Each OSHA accident investigation becomes the investigator's summary (the abstract narrative the
compliance officer wrote) plus the injury record. The answer key comes from OSHA's own coded
fields: event date, whether it was fatal, how many employees were hurt, the event title.

Persona: workplace-safety investigations are what a compliance / EHS investigator documents.

Usage: osha.py accident.zip accident_abstract.zip accident_injury.zip --out DIR [--limit N]
"""
import argparse, csv, io, os, re, sys, zipfile
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import ShardWriter, MONTHS  # noqa: E402

csv.field_size_limit(sys.maxsize)
DEGREE = {"1": "fatality", "2": "hospitalized injury", "3": "non-hospitalized injury"}

def rows(path):
    z = zipfile.ZipFile(path)
    for name in sorted(z.namelist()):
        if name.endswith(".csv"):
            yield from csv.DictReader(io.TextIOWrapper(z.open(name), encoding="utf-8-sig", errors="replace", newline=""))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("accident"); ap.add_argument("abstract"); ap.add_argument("injury")
    ap.add_argument("--out", required=True); ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--shard-size", type=int, default=500)
    a = ap.parse_args()
    lines = defaultdict(list)
    for r in rows(a.abstract):
        try: lines[r["SUMMARY_NR"]].append((int(float(r["LINE_NR"])), r["ABSTRACT_TEXT"] or ""))
        except ValueError: continue
    injuries = defaultdict(list)
    for r in rows(a.injury): injuries[r["SUMMARY_NR"]].append(r)
    w = ShardWriter(a.out, "osha-compliance", a.shard_size)
    for r in rows(a.accident):
        nr = (r.get("SUMMARY_NR") or "").strip()
        m = re.match(r"(\d{4}-\d\d-\d\d)", r.get("EVENT_DATE") or "")
        abstract = "".join(t for _, t in sorted(lines.get(nr, []))).strip()
        title = (r.get("EVENT_DESC") or "").strip()
        if not nr or not m or len(abstract) < 200 or not title: continue
        date = m.group(1); y, mo, d = date.split("-")
        inj = injuries.get(nr, [])
        insp = sorted({(i.get("REL_INSP_NR") or "").strip() for i in inj if (i.get("REL_INSP_NR") or "").strip()})
        fatal = sum(1 for i in inj if (i.get("DEGREE_OF_INJ") or "").split(".")[0] == "1")
        summary = "\n".join([f"OSHA accident investigation summary {nr}", "",
                             f"Event: {title}", f"Event date: {MONTHS[int(mo)-1]} {int(d)}, {y}",
                             f"Inspection number(s): {', '.join(insp) or 'not recorded'}",
                             f"Keywords: {(r.get('EVENT_KEYWORD') or '').strip().title()}", "", "Abstract:", abstract, ""])
        docs = {"investigation-summary.txt": summary}
        if inj:
            rec = [f"OSHA accident {nr} — injured employees", ""]
            for k, i in enumerate(inj, 1):
                age = (i.get("AGE") or "").split(".")[0]
                rec.append(f"Employee #{k}: {DEGREE.get((i.get('DEGREE_OF_INJ') or '').split('.')[0], 'injury')}"
                           + (f", age {age}" if age and age != "0" else ""))
            docs["injury-record.txt"] = "\n".join(rec) + "\n"
        q = [{"id": "date", "q": f"When did the accident in OSHA investigation {nr} happen?", "expect": {"date": date}},
             {"id": "what", "q": f"What happened in OSHA investigation {nr}?", "expect": {"overlap": title}}]
        if inj: q.append({"id": "injured", "q": f"How many employees were hurt in OSHA investigation {nr}?", "expect": {"number": len(inj)}})
        if fatal: q.append({"id": "fatal", "q": f"Was anyone killed in OSHA investigation {nr}?", "expect": {"any": ["killed", "fatal", "died", "death"]}})
        checks = [{"id": "event-date", "date": date}, {"id": "summary-number", "entity": nr}] + \
                 [{"id": "inspection-number", "entity": i} for i in insp[:2]]
        w.add(f"osha-{nr}", docs, {"persona": "compliance", "key": nr, "questions": q, "checks": checks,
                                   "control": "When did the accident in OSHA investigation 999999999 happen?"})
        if a.limit and w.n >= a.limit: break
    w.close()
    print("osha:", w.n, "cases")

if __name__ == "__main__":
    main()

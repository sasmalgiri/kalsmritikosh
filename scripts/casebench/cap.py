#!/usr/bin/env python3
"""Case bench converter — US court decisions from the Caselaw Access Project (static.case.law,
Harvard Law School Library; released without restriction in 2024).

Downloads one volume zip at a time, writes one case folder per decision and deletes the zip, so
disk use stays small. Each decision becomes the document a lawyer would hold (caption, head
matter, opinions); the answer key comes from CAP's own metadata (decision date, docket number,
court, parties) plus the disposition line of the majority opinion.

The persona is chosen by what the case is about, so every investigation persona gets real cases:
  siu (insurance fraud), forensic (embezzlement, money laundering, securities/accounting fraud),
  compliance (workplace harassment / discrimination), genealogist (heirship, intestacy, probate),
  lawyer (everything else).

Usage: cap.py --out DIR --reporters f2d,a2d,... [--volumes-per-reporter N] [--limit N] [--shard-size 500]
"""
import argparse, io, json, os, re, sys, urllib.request, zipfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import ShardWriter  # noqa: E402

BASE = "https://static.case.law"
DISPOSITION = re.compile(r"\b(affirmed|reversed|remanded|dismissed|vacated|modified|denied|granted|"
                         r"sustained|overruled|quashed|set aside)\b", re.I)
TOPICS = [("siu", re.compile(r"insurance fraud|fraudulent (insurance )?claim|staged (accident|collision)|arson.{0,40}insur", re.I)),
          ("forensic", re.compile(r"embezzle|money laundering|securities fraud|ponzi|misappropriat|accounting fraud|wire fraud", re.I)),
          ("compliance", re.compile(r"sexual harassment|hostile work environment|title vii|employment discrimination|retaliat(ion|ed) against", re.I)),
          ("genealogist", re.compile(r"heirship|intestate|heirs at law|next of kin|probate of (the )?will|will contest|paternity", re.I))]

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "kalsmritikosh-casebench/1.0 (research; curl-compatible)"})
    with urllib.request.urlopen(req, timeout=120) as r: return r.read()

def text_of(case):
    cb = case.get("casebody") or {}
    parts = [cb.get("head_matter") or ""] + [(o.get("author") or "") + "\n" + (o.get("text") or "") for o in cb.get("opinions", [])]
    return "\n\n".join(p.strip() for p in parts if p and p.strip())

def disposition(case):
    ops = (case.get("casebody") or {}).get("opinions", [])
    major = next((o for o in ops if o.get("type") == "majority"), ops[0] if ops else None)
    if not major: return []
    tail = (major.get("text") or "")[-400:]
    return sorted({m.lower() for m in DISPOSITION.findall(tail)})

def surname(author):
    a = re.sub(r"(?i)\b(mr\.|mrs\.|ms\.|chief|justice|judge|presiding|associate|circuit|district|j\.|c\.\s*j\.|delivered.*)", " ", author or "")
    names = [w for w in re.findall(r"[A-Z][A-Za-z'-]+", a) if len(w) > 2 and w.upper() not in {"THE", "OPINION", "COURT", "PER", "CURIAM"}]
    return names[-1] if names else None

def court_names(court):
    """The court as an opinion writes it: CAP's formal name rarely appears verbatim in old reports
    ("Circuit Court of Appeals, Eighth Circuit" for "...for the Eighth Circuit")."""
    name, abbr = court.get("name", ""), court.get("name_abbreviation", "")
    out = [name, abbr]
    m = re.search(r"(\w+) Circuit", name)
    if m: out.append(f"{m.group(1)} Circuit")
    elif "District Court" in name: out.append("District Court")
    elif " of " in name: out.append(name.split(" of ")[0] if name.startswith(("Supreme", "Court", "Appellate")) else name)
    return [x for x in out if x]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True); ap.add_argument("--reporters", required=True)
    ap.add_argument("--volumes-per-reporter", type=int, default=0); ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--shard-size", type=int, default=500); ap.add_argument("--skip-volumes", type=int, default=0)
    a = ap.parse_args()
    writers = {}
    def writer(persona):
        if persona not in writers: writers[persona] = ShardWriter(a.out, f"cap-{persona}", a.shard_size)
        return writers[persona]
    total = 0
    for slug in a.reporters.split(","):
        vols = json.loads(get(f"{BASE}/{slug}/VolumesMetadata.json"))
        vols = vols[a.skip_volumes:]
        if a.volumes_per_reporter: vols = vols[:a.volumes_per_reporter]
        for v in vols:
            n = v["volume_number"]
            try: z = zipfile.ZipFile(io.BytesIO(get(f"{BASE}/{slug}/{n}.zip")))
            except Exception as e:
                print(f"skip {slug} {n}: {e}", file=sys.stderr); continue
            for name in z.namelist():
                if not name.endswith(".json") or "/json/" not in "/" + name: continue
                c = json.loads(z.read(name))
                body = text_of(c)
                date = c.get("decision_date") or ""
                if len(body) < 800 or not re.fullmatch(r"\d{4}-\d\d-\d\d", date): continue
                title = c.get("name_abbreviation") or c.get("name") or ""
                cite = next((x["cite"] for x in c.get("citations", []) if x.get("type") == "official"), None) or \
                       (c.get("citations") or [{}])[0].get("cite", "")
                court = c.get("court") or {}
                key = f"{title}, {cite}"
                persona = next((p for p, rx in TOPICS if rx.search(body)), "lawyer")
                docket = (c.get("docket_number") or "").strip()
                parties = [p.strip(" .") for p in re.split(r"\s+v\.?\s+", title) if p.strip()]
                q = [{"id": "date", "q": f"When was {key} decided?", "expect": {"date": date}},
                     {"id": "court", "q": f"Which court decided {key}?", "expect": {"any": court_names(court)}},
                     {"id": "parties", "q": f"Who were the parties in {key}?", "expect": {"any": parties}}]
                disp = disposition(c)
                if disp: q.append({"id": "outcome", "q": f"What did the court decide in {key}?", "expect": {"any": disp}})
                digits = re.sub(r"(?i)^(no\.|nos\.|docket|case)\s*", "", docket)
                if digits: q.append({"id": "docket", "q": f"What is the docket number in {key}?", "expect": {"any": [digits]}})
                ops = (c.get("casebody") or {}).get("opinions", [])
                author = surname(next((o.get("author") for o in ops if o.get("type") == "majority"), None) or "")
                if author: q.append({"id": "author", "q": f"Who wrote the majority opinion in {key}?", "expect": {"any": [author]}})
                checks = [{"id": "decision-date", "date": date}] + ([{"id": "docket-number", "entity": digits}] if digits else []) + \
                         [{"id": "party", "entity": p} for p in parties[:2]]
                doc = f"{title}\n{cite}\n\n{body}\n"
                writer(persona).add(f"{slug}-{n}-{c.get('id')}", {"decision.txt": doc},
                                    {"persona": persona, "key": key, "questions": q, "checks": checks,
                                     "control": "When was Zyxwv Holdings v. Qorvane Mutual, 999 F.9th 999, decided?"})
                total += 1
                if a.limit and total >= a.limit: break
            if a.limit and total >= a.limit: break
        if a.limit and total >= a.limit: break
    for w in writers.values(): w.close()
    print("cap:", total, "cases;", {p: w.n for p, w in writers.items()})

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Case bench — the end-to-end set: up to 10,000 real cases per investigation category, each
delivered as the documents an investigator receives, for the full workflow (read the
documents, open the case, ask, custody, contradictions, findings).

Categories and sources (all public; answer keys from the publisher's own coded fields):
  doj-*        U.S. Department of Justice press releases (justice.gov API; public domain).
               Split by subject: police-misconduct, health-care-and-pharma-fraud,
               drug-trafficking, violent-crime, financial-fraud, cybercrime, public-corruption,
               environmental-crime, tax-crime, immigration-crime, other-federal-crime.
               Key: office (component), announcement date, what happened (teaser).
  fda-*        FDA enforcement reports (openFDA; public domain): drug (pharma), food, device recalls.
               Key: recalling firm, classification, reason, recall initiation date.
  nhtsa-defect NHTSA vehicle-defect investigations (ODI flat file; public domain).
               Key: manufacturer, component, opening date, subject.
  court-criminal / court-civil  Caselaw Access Project decisions already converted (caption split).
  ntsb / osha  as before (sampled from ai1000/src).

Usage: e2e.py --raw RAW --cap CASES --src AI1000SRC --out OUT --render BIN [--per 10000]
"""
import argparse, collections, glob, gzip, html, json, os, random, re, shutil, sys, zipfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ai1000 import write_case, read_docs, truth_lines  # noqa: E402
from common import value_in  # noqa: E402

# Document types for the bulk set: scans and page photos (OCR) are kept to a few percent so
# 100k cases stay runnable on one Mac; every other type is weighted evenly.
PROFILE_WEIGHTS = [("txt", 10), ("pdf", 14), ("docx", 12), ("html", 10), ("eml", 10), ("zip", 8),
                   ("mbox", 6), ("rtf", 6), ("doc", 6), ("xlsx", 4), ("mixed", 6), ("scan", 3), ("png", 2)]

def pick_profile(rng):
    total = sum(w for _, w in PROFILE_WEIGHTS)
    x = rng.uniform(0, total)
    for p, w in PROFILE_WEIGHTS:
        x -= w
        if x <= 0: return p
    return "txt"

def strip_html(s):
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s or "")
    s = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</li>|</h\d>", "\n", s)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    # Windows-1252 punctuation that arrived as C1 control characters (\x91–\x97).
    s = s.translate({0x91: "'", 0x92: "'", 0x93: '"', 0x94: '"', 0x96: "-", 0x97: "-", 0x85: "..."})
    return re.sub(r"[ \t]+", " ", re.sub(r"\n\s*\n+", "\n\n", s)).strip()

# ---------------------------------------------------------------- DOJ

DOJ_RULES = [
    ("doj-police-misconduct", r"\b(police|officer|deputy|sheriff|trooper|jailer|correctional|corrections officer|prison guard|border patrol agent)\b.*\b(excessive force|civil rights|color of law|assault|beat|false report|obstruct|depriv|sexual)|\bcolor of law\b|\bexcessive force\b"),
    ("doj-health-care-and-pharma-fraud", r"health care fraud|healthcare fraud|medicare|medicaid|pharmac|opioid|prescription|oxycodone|fentanyl pill|drug company|pharmaceutical|kickback.*(doctor|physician|clinic)|compounding"),
    ("doj-drug-trafficking", r"\b(drug trafficking|methamphetamine|cocaine|heroin|fentanyl|marijuana|narcotics|cartel|controlled substance)\b"),
    ("doj-violent-crime", r"\b(murder|homicide|carjacking|armed robbery|bank robbery|kidnap|firearm|gun|shooting|violent crime|gang|racketeer)\b"),
    ("doj-cybercrime", r"\b(hack|computer intrusion|cyber|ransomware|botnet|malware|identity theft|dark ?web|cryptocurrency)\b"),
    ("doj-public-corruption", r"\b(bribe|bribery|corruption|kickback|public official|extortion|honest services)\b"),
    ("doj-environmental-crime", r"\b(clean water act|clean air act|environmental|pollut|hazardous waste|wildlife|endangered species|oil spill|asbestos)\b"),
    ("doj-tax-crime", r"\b(tax fraud|tax evasion|irs|false tax returns?|tax preparer|employment taxes)\b"),
    ("doj-immigration-crime", r"\b(alien smuggling|human smuggling|illegal reentry|visa fraud|immigration fraud|marriage fraud)\b"),
    ("doj-financial-fraud", r"\b(wire fraud|securities fraud|bank fraud|mortgage fraud|ponzi|investment fraud|embezzl|money laundering|mail fraud|fraud scheme)\b"),
]

def doj_category(r, text):
    hay = (r["title"] + " " + (r.get("teaser") or "") + " " + " ".join(r["component"]) + " " + " ".join(r["topic"])).lower()
    for name, rx in DOJ_RULES:
        if re.search(rx, hay): return name
    if re.search(r"\b(sentenced|pleads? guilty|pleaded guilty|convicted|indicted|charged|arrested)\b", hay):
        return "doj-other-federal-crime"
    return None

def doj_cases(raw, rng):
    for f in sorted(glob.glob(os.path.join(raw, "doj", "*.jsonl.gz"))):
        for line in gzip.open(f, "rt"):
            r = json.loads(line)
            body = strip_html(r.get("body"))
            if len(body) < 400 or not r.get("title"): continue
            cat = doj_category(r, body)
            if not cat: continue
            title = re.sub(r"\s+", " ", strip_html(r["title"])).strip()
            day = ""
            try:
                import datetime
                day = datetime.datetime.utcfromtimestamp(int(r["date"])).strftime("%Y-%m-%d")
            except Exception: pass
            docs = {"press-release.txt": f"{title}\n\n{body}\n"}
            offices = [c for c in r["component"] if c]
            # "USAO - Texas, Southern" is how the API codes the office; the release itself says
            # "the Southern District of Texas" / "the District of Maryland".
            short = []
            for o in offices:
                m = re.match(r"USAO - ([^,]+)(?:, (\w+))?$", o)
                if m:
                    place = m.group(1)
                    # "USAO - District of Columbia" is the District of Columbia, not "District of District of …".
                    short.append(f"{m.group(2)} District of {place}" if m.group(2) else (place if place.startswith("District of") else f"District of {place}"))
                # The API files ENRD as "Energy and Natural Resources Division"; releases print its
                # real name.
                if o.startswith("ENRD") or "Natural Resources Division" in o:
                    short.append("Environment and Natural Resources Division")
            q = []
            if offices:
                q.append({"id": "office", "q": f"Which Justice Department office announced the case \"{title}\"?",
                          "expect": {"any": sorted(set(offices + short))}})
            if day:
                q.append({"id": "date", "q": f"When did the Justice Department announce \"{title}\"?", "expect": {"date": day}})
            teaser = strip_html(r.get("teaser"))
            if len(teaser) > 40:
                q.append({"id": "what", "q": f"What happened in the case \"{title}\"?", "expect": {"overlap": teaser[:300]}})
            yield cat, r["uuid"], title, docs, q

# ---------------------------------------------------------------- FDA recalls

def fda_cases(raw, rng):
    for kind, cat in (("drug", "fda-drug-recall"), ("food", "fda-food-recall"), ("device", "fda-device-recall")):
        path = os.path.join(raw, "fda", f"{kind}-enforcement.json.zip")
        if not os.path.exists(path): continue
        z = zipfile.ZipFile(path)
        data = json.load(z.open(z.namelist()[0]))["results"]
        for r in data:
            num = r.get("recall_number"); firm = r.get("recalling_firm")
            if not num or not firm or not r.get("reason_for_recall"): continue
            d = r.get("recall_initiation_date") or ""
            day = f"{d[:4]}-{d[4:6]}-{d[6:8]}" if len(d) == 8 else ""
            lines = [f"FDA Enforcement Report — recall {num}", "",
                     f"Recalling firm: {firm}", f"Location: {r.get('city', '')}, {r.get('state', '')} {r.get('country', '')}".strip(),
                     f"Product: {r.get('product_description', '')}", f"Classification: {r.get('classification', '')}",
                     f"Status: {r.get('status', '')}", f"Voluntary / mandated: {r.get('voluntary_mandated', '')}",
                     f"Recall initiation date: {day}", f"Product quantity: {r.get('product_quantity', '')}",
                     f"Distribution pattern: {r.get('distribution_pattern', '')}", "", "Reason for recall:",
                     r.get("reason_for_recall", ""), ""]
            docs = {"enforcement-report.txt": "\n".join(lines)}
            q = [{"id": "firm", "q": f"Which firm initiated FDA recall {num}?", "expect": {"any": [firm]}},
                 {"id": "class", "q": f"What is the classification of FDA recall {num}?", "expect": {"any": [r.get("classification", "")]}},
                 {"id": "reason", "q": f"Why was FDA recall {num} issued?", "expect": {"overlap": r["reason_for_recall"][:300]}}]
            if day: q.append({"id": "date", "q": f"When was FDA recall {num} initiated?", "expect": {"date": day}})
            yield cat, num, num, docs, q

# ---------------------------------------------------------------- NHTSA

def nhtsa_cases(raw, rng):
    path = os.path.join(raw, "nhtsa", "FLAT_INV.zip")
    if not os.path.exists(path): return
    z = zipfile.ZipFile(path)
    by = collections.OrderedDict()
    for line in z.open("FLAT_INV.txt"):
        f = line.decode("latin-1").rstrip("\r\n").split("\t")
        if len(f) < 11: continue
        num = f[0].strip()
        e = by.setdefault(num, {"make": f[1], "models": set(), "years": set(), "comp": f[4], "mfr": f[5],
                                "open": f[6], "close": f[7], "camp": f[8], "subject": f[9], "summary": f[10]})
        e["models"].add(f[2]); e["years"].add(f[3])
    for num, e in by.items():
        if len(e["summary"]) < 200: continue
        o = e["open"]; day = f"{o[:4]}-{o[4:6]}-{o[6:8]}" if len(o) == 8 else ""
        years = sorted(y for y in e["years"] if y != "9999")
        text = "\n".join([f"NHTSA defect investigation {num}", "",
                          f"Subject: {e['subject']}", f"Manufacturer: {e['mfr']}", f"Make: {e['make']}",
                          f"Models: {', '.join(sorted(e['models']))[:400]}", f"Model years: {', '.join(years)}",
                          f"Component: {e['comp']}", f"Date opened: {day}",
                          f"Recall campaign: {e['camp'] or 'none'}", "", "Summary:", e["summary"], ""])
        q = [{"id": "manufacturer", "q": f"Which manufacturer was investigated in NHTSA investigation {num}?", "expect": {"any": [e["mfr"].strip()]}},
             {"id": "component", "q": f"Which component did NHTSA investigation {num} concern?", "expect": {"any": [e["comp"].strip()]}},
             {"id": "what", "q": f"What did NHTSA find in investigation {num}?", "expect": {"overlap": e["summary"][:300]}}]
        if day: q.append({"id": "date", "q": f"When did NHTSA open investigation {num}?", "expect": {"date": day}})
        yield "nhtsa-defect", num, num, {"investigation.txt": text}, q

# ---------------------------------------------------------------- existing sets

CRIMINAL = re.compile(r"^(State|People|United States|Commonwealth|Territory)\b.*\bv\.|\bv\. (State|People|United States|Commonwealth)\b")

def cap_cases(cap_root, rng):
    for src in glob.glob(os.path.join(cap_root, "cap-*")):
        for r, folder in truth_lines(src):
            key = r.get("key", "")
            cat = "court-criminal" if CRIMINAL.search(key) else "court-civil"
            yield cat, r["case"], key, folder, r["questions"], r   # documents read only if chosen

def src_cases(src_root, rng):
    for name, cat in (("ntsb", "ntsb-aviation"), ("osha-compliance", "osha-workplace")):
        for r, folder in truth_lines(os.path.join(src_root, name)):
            yield cat, r["case"], r.get("key", r["case"]), folder, r["questions"], r

# ---------------------------------------------------------------- build

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True); ap.add_argument("--cap", required=True); ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--render", required=True)
    ap.add_argument("--per", type=int, default=10000); ap.add_argument("--shard-size", type=int, default=100)
    ap.add_argument("--seed", type=int, default=20261021); ap.add_argument("--only")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    pools = collections.defaultdict(list)
    def add(cat, cid, key, docs, q, extra=None):
        if a.only and not cat.startswith(a.only): return
        pools[cat].append((cid, key, docs, q, extra))
    for cat, cid, key, docs, q in doj_cases(a.raw, rng): add(cat, f"doj-{cid}", key, docs, q)
    for cat, cid, key, docs, q in fda_cases(a.raw, rng): add(cat, f"fda-{cid}", key, docs, q)
    for cat, cid, key, docs, q in nhtsa_cases(a.raw, rng): add(cat, f"nhtsa-{cid}", key, docs, q)
    for cat, cid, key, docs, q, r in cap_cases(a.cap, rng): add(cat, cid, key, docs, q, r)
    for cat, cid, key, docs, q, r in src_cases(a.src, rng): add(cat, cid, key, docs, q, r)
    os.makedirs(a.out, exist_ok=True)
    summary = {}
    for cat, items in sorted(pools.items()):
        rng.shuffle(items)
        chosen = items[:a.per]
        summary[cat] = {"available": len(items), "chosen": len(chosen)}
        shutil.rmtree(os.path.join(a.out, cat), ignore_errors=True)
        seen = set()
        for i, (cid, key, docs, q, extra) in enumerate(chosen):
            cid = re.sub(r"[^A-Za-z0-9._-]", "_", cid)
            if cid in seen: continue
            seen.add(cid)
            profile = pick_profile(rng)
            if isinstance(docs, str): docs = read_docs(docs)   # a folder: the converted case
            shard = os.path.join(a.out, cat, f"shard-{i // a.shard_size:05d}")
            carried = write_case(profile, cid, docs, os.path.join(shard, cid), a.render)
            qs = json.loads(json.dumps(q))
            for one in qs:
                if "overlap" in one["expect"]:
                    one.setdefault("in_docs", True)
                else:
                    one["in_docs"] = value_in(one["expect"], carried)[0]
            rec = dict(extra or {})
            rec.update({"case": cid, "source": cat, "key": key, "questions": qs, "profile": profile,
                        "stratum": cat, "persona": (extra or {}).get("persona", "investigator")})
            rec.setdefault("control", f"What happened in the case \"Nonexistent matter {rng.randint(10**8, 10**9)}\"?")
            with open(os.path.join(shard, "truth.jsonl"), "a") as fh: fh.write(json.dumps(rec) + "\n")
        print(cat, summary[cat], flush=True)
    json.dump(summary, open(os.path.join(a.out, "SUMMARY.json"), "w"), indent=1)

if __name__ == "__main__":
    main()

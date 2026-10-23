#!/usr/bin/env python3
"""Investigation case packs — one small, public-domain case per persona for the start-to-end
simulations (docs/INVESTIGATION_FOCUS_TODO.md B1/B2).

Every pack is built from public records the case bench already downloads:
  * DOJ press releases (justice.gov API; US Government work, public domain)
  * Caselaw Access Project decisions (static.case.law; public domain court opinions, CAP data CC0)
  * NTSB aviation investigation reports (data.ntsb.gov; US Government work)

Output (flat file names — the test bundle may flatten folders):
  KalsmritikoshTests/Fixtures/InvestigationCases/<persona>-<file>
  KalsmritikoshTests/Fixtures/InvestigationCases/investigation-cases.json   (manifest + expected)
  KalsmritikoshTests/Fixtures/InvestigationCases/SOURCES.md

Usage: persona_packs.py [--raw ~/CaseBench/raw] [--cap ~/CaseBench/cases] [--ntsb ~/CaseBench/ai1000/src/ntsb]
"""
import argparse, glob, gzip, html, json, os, re, sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(REPO, "KalsmritikoshTests", "Fixtures", "InvestigationCases")

# persona → (title patterns, what the persona investigates)
DOJ_PICKS = [
    ("investigator", [r"trade secret"], "Theft of trade secrets — the IP-leakage investigation"),
    ("compliance", [r"sexual harassment", r"harass", r"discriminat"], "Workplace harassment / discrimination complaint"),
    ("forensic", [r"embezzl"], "Embezzlement — funds tracing"),
    ("siu", [r"staged (?:auto(?:mobile)? )?(?:accident|crash|collision)", r"auto(?:mobile)? insurance fraud", r"insurance fraud ring"], "Staged-accident insurance fraud"),
    ("journalist", [r"deceptive (?:marketing|advertising|claims|health claims)", r"false advertising", r"misleading (?:claims|advertising)", r"false statements? (?:to|about|regarding)"], "Deceptive public claims — fact-check"),
    ("researcher", [r"research misconduct", r"grant fraud", r"falsif.*research", r"research grant"], "Research-funding fraud / misconduct"),
]

def text_of(body):
    t = re.sub(r"(?is)<(script|style).*?</\1>", " ", body or "")
    t = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</li>|</h\d>", "\n", t)
    t = re.sub(r"<[^>]+>", " ", t)
    t = html.unescape(t)
    t = re.sub(r"[ \t ]+", " ", t)
    return re.sub(r"\n\s*\n+", "\n\n", t).strip()

def doj_records(raw):
    for p in sorted(glob.glob(os.path.join(raw, "doj", "page-*.jsonl.gz"))):
        with gzip.open(p, "rt") as fh:
            for line in fh:
                try: yield json.loads(line)
                except ValueError: continue

def iso_day(epoch):
    try: return datetime.fromtimestamp(int(epoch), tz=timezone.utc).strftime("%Y-%m-%d")
    except (TypeError, ValueError): return None

NAME_AGE = re.compile(r"\b([A-Z][a-z]+(?: [A-Z]\.)?(?: [A-Z][a-zA-Z'\-]+){1,2}), (\d{2}),")
MONEY = re.compile(r"\$\s?\d[\d,]*(?:\.\d+)?(?: (?:million|billion|thousand))?")

MONTHS = ["January","February","March","April","May","June","July","August","September","October","November","December"]

def date_forms(iso):
    try: y, m, d = (int(x) for x in iso.split("-"))
    except (AttributeError, ValueError): return [iso or ""]
    mo = MONTHS[m - 1]
    return [iso, f"{mo} {d}, {y}", f"{mo[:3]} {d}, {y}", f"{mo[:3]}. {d}, {y}", f"{d} {mo} {y}", f"{d:02d}/{m:02d}/{y:04d}"]

def in_docs_only(e, text):
    """Expect only what the document states (the case bench's in_docs rule): API metadata such as
    the release date or the issuing office is kept only when the text itself carries it."""
    low = text.lower()
    out = dict(e)
    if e.get("date") and not any(f.lower() in low for f in date_forms(e["date"])): out.pop("date")
    if e.get("office") and e["office"].lower() not in low: out.pop("office")
    out["parties"] = [p for p in e.get("parties", []) if p.lower() in low]
    out["amounts"] = [a for a in e.get("amounts", []) if a.lower() in low]
    return out

def expected_from_release(r, text):
    parties = list(dict.fromkeys(m.group(1) for m in NAME_AGE.finditer(text)))[:8]
    amounts = list(dict.fromkeys(m.group(0).replace("$ ", "$") for m in MONEY.finditer(text)))[:8]
    comp = r.get("component") or ""
    if isinstance(comp, list): comp = (comp[0].get("name") if comp and isinstance(comp[0], dict) else (comp[0] if comp else "")) or ""
    office = str(comp).strip("[]'\" ").split("', '")[0]
    return {"title": r.get("title"), "date": iso_day(r.get("date")), "office": office,
            "parties": parties, "amounts": amounts,
            # facts every report must be able to cite: the lead sentence of the release
            "facts": [s.strip() for s in re.split(r"(?<=[.!?])\s+(?=[A-Z])", text)[:3] if len(s.split()) >= 8]}

def pick_doj(raw):
    want = {p: (pats, why) for p, pats, why in DOJ_PICKS}
    got = {}
    for r in doj_records(raw):
        title = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", r.get("title") or "")).strip()
        r["title"] = title
        text = text_of(r.get("body"))
        if len(text) < 600 or len(text) > 12000: continue
        for persona, (pats, why) in want.items():
            if persona in got: continue
            if any(re.search(pt, title, re.I) for pt in pats):
                e = in_docs_only(expected_from_release(r, text), text)
                if e["parties"] and e["date"]:
                    got[persona] = (r, text, e, why)
        if len(got) == len(want): break
    return got

def first_cap(cap_root, title_pattern=None, need_docket=True):
    for t in sorted(glob.glob(os.path.join(cap_root, "cap-*", "*", "truth.jsonl"))):
        for line in open(t):
            r = json.loads(line)
            if title_pattern and not re.search(title_pattern, r.get("key", ""), re.I): continue
            qs = {q["id"]: q for q in r["questions"]}
            if need_docket and not qs.get("docket", {}).get("in_docs"): continue
            folder = os.path.join(os.path.dirname(t), r["case"])
            docs = [f for f in glob.glob(os.path.join(folder, "*")) if f.endswith((".txt", ".html"))]
            if docs: return r, docs[0]
    return None, None

def first_ntsb(ntsb_root):
    for t in sorted(glob.glob(os.path.join(ntsb_root, "*", "truth.jsonl")))[:5]:
        for line in open(t):
            r = json.loads(line)
            folder = os.path.join(os.path.dirname(t), r["case"])
            docs = sorted(f for f in glob.glob(os.path.join(folder, "*")) if f.endswith((".txt", ".html")))
            if docs: return r, docs
    return None, []

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=os.path.expanduser("~/CaseBench/raw"))
    ap.add_argument("--cap", default=os.path.expanduser("~/CaseBench/cases"))
    ap.add_argument("--ntsb", default=os.path.expanduser("~/CaseBench/ai1000/src/ntsb"))
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    manifest, sources = [], []

    for persona, (r, text, e, why) in sorted(pick_doj(a.raw).items()):
        name = f"{persona}-press-release.txt"
        open(os.path.join(OUT, name), "w").write(f"{r['title']}\n\n{text}\n")
        manifest.append({"persona": persona, "investigation": why, "caseTitle": r["title"],
                         "files": [name], "expected": e})
        sources.append(f"| {persona} | {r['title']} | {r.get('url')} | US Government work (public domain) |")

    for persona, pattern, why in [("lawyer", None, "Court decision — matter fact-finding"),
                                  ("genealogist", r"\bestate of\b|\bin re estate\b|\bheirs\b|\bwill of\b|\bsuccession of\b", "Estate / heirship decision — identity and lineage proof")]:
        r, doc = first_cap(a.cap, pattern, need_docket=(persona == "lawyer"))
        if not r: print(f"no CAP case for {persona}", file=sys.stderr); continue
        name = f"{persona}-decision{os.path.splitext(doc)[1]}"
        open(os.path.join(OUT, name), "w").write(open(doc, encoding="utf-8", errors="replace").read())
        exp = {q["id"]: q["expect"] for q in r["questions"] if q.get("in_docs")}
        manifest.append({"persona": persona, "investigation": why, "caseTitle": r["key"], "files": [name], "expected": exp})
        sources.append(f"| {persona} | {r['key']} | static.case.law (Caselaw Access Project) | Public-domain court opinion; CAP data CC0 |")

    r, docs = first_ntsb(a.ntsb)
    if r:
        names = []
        for d in docs[:4]:
            n = f"individual-{os.path.basename(d)}"
            open(os.path.join(OUT, n), "w").write(open(d, encoding="utf-8", errors="replace").read())
            names.append(n)
        exp = {q["id"]: q["expect"] for q in r["questions"] if q.get("in_docs")}
        manifest.append({"persona": "individual", "investigation": "Accident docket as a personal claim file",
                         "caseTitle": f"NTSB {r['key']}", "files": names, "expected": exp})
        sources.append(f"| individual | NTSB {r['key']} | data.ntsb.gov (avall.mdb / Pre2008.mdb) | US Government work (public domain) |")

    json.dump(manifest, open(os.path.join(OUT, "investigation-cases.json"), "w"), indent=2)
    with open(os.path.join(OUT, "SOURCES.md"), "w") as fh:
        fh.write("# Investigation case packs — sources\n\n")
        fh.write(f"Built {datetime.now(timezone.utc).strftime('%Y-%m-%d')} by `scripts/casebench/persona_packs.py` from public records. "
                 "Only public-domain material is stored; nothing beyond what the public record carries.\n\n")
        fh.write("| Persona | Case | Source | Licence |\n|---|---|---|---|\n")
        fh.write("\n".join(sources) + "\n")
    print(f"{len(manifest)} packs → {OUT}")
    for m in manifest: print(f"  {m['persona']:12s} {m['caseTitle'][:80]}")

if __name__ == "__main__":
    main()

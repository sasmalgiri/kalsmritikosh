#!/usr/bin/env python3
"""Closed-case simulation bench — real, finished federal prosecutions worked as an investigator
would work them. Each case is ONE defendant followed across the Justice Department's own releases
(charged → pleaded / convicted → sentenced), so the answer to most questions needs more than one
document, and every shard holds several unrelated prosecutions (an archive, not a single file).

Ground truth comes from the releases themselves: each release's publication day (printed on the
release, as justice.gov prints it), its stage (from its title), the sentence stated in the
sentencing release, and the office that issued it. Questions an investigator asks of a closed case:
when was X charged / sentenced, what sentence, did X plead guilty, the timeline in order, how many
releases concern X, what X was charged with, which office prosecuted — plus a question the record
cannot answer (a pardon), which must be refused.

Usage: chronology.py --raw RAW --out OUT --render BIN [--cases 200] [--shard-size 10] [--seed N]
"""
import argparse, collections, datetime, glob, gzip, json, os, random, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from ai1000 import write_case          # noqa: E402
from common import value_in            # noqa: E402
from e2e import strip_html, doj_category, pick_profile   # noqa: E402

STAGES = [("sentenced", r"\bsentenced\b"), ("convicted", r"\b(?:convicted|found guilty|jury verdict)\b"),
          ("pleaded", r"\b(?:pleads?|pleaded|pled) guilty\b"),
          ("charged", r"\b(?:indicted|charged|arrested|complaint|indictment)\b")]
STAGE_ORDER = {"charged": 0, "pleaded": 1, "convicted": 1, "sentenced": 2}
# "Steven Daniel Miller, 47, of Fairfield" — the defendant as releases introduce them.
NAME = re.compile(r"\b([A-Z][a-z]+(?: [A-Z]\.?| [A-Z][a-z]+){0,2} [A-Z][a-zA-Z'\-]+(?: (?:Jr|Sr|II|III)\.?)?), (?:a\s)?(\d{2}),? (?:of|from) ([A-Z][A-Za-z .'\-]+?)[,.]")
SENTENCE = re.compile(r"sentenced\b[^.]{0,140}?\bto (\d+|[a-z]+(?:-[a-z]+)?) (months?|years?)\b(?! of (?:supervised release|probation))", re.I)
NUMS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30}

def sentence_forms(n, unit):
    """"78 months" / "five years" / "60 months" = "five years": the forms an answer may use."""
    k = int(n) if n.isdigit() else NUMS.get(n.lower())
    if k is None: return [f"{n} {unit}"]
    months = k if unit.lower().startswith("month") else k * 12
    out = {f"{months} months", f"{months}-month"}
    if months % 12 == 0:
        y = months // 12
        out |= {f"{y} years" if y != 1 else "1 year", f"{y}-year"}
        out |= {f"{w} years" if y != 1 else "one year" for w, v in NUMS.items() if v == y}
    out |= {f"{w} months" for w, v in NUMS.items() if v == months}
    return sorted(out)

MONTH = r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"

def stated_days(body, verb, year):
    """Days a release itself gives for the event ("was sentenced on March 3, 2015", "indicted on
    May 2"): the release's own day is not the only right answer."""
    out = set()
    for m in re.finditer(verb + r"[^.]{0,60}?\bon (" + MONTH + r")\.? (\d{1,2})(?:, (\d{4}))?", body, re.I):
        try:
            d = datetime.datetime.strptime(f"{m.group(1)[:3]} {m.group(2)} {m.group(3) or year}", "%b %d %Y").date()
            out.add(d.isoformat())
        except ValueError: pass
    return out

def stage(title):
    t = title.lower()
    for name, rx in STAGES:
        if re.search(rx, t): return name
    return None

def office_names(components):
    out = []
    for o in components:
        m = re.match(r"USAO - ([^,]+)(?:, (\w+))?$", o)
        if m:
            place = m.group(1)
            out.append(f"{m.group(2)} District of {place}" if m.group(2) else (place if place.startswith("District of") else f"District of {place}"))
        elif o: out.append(o)
    return out

def releases(raw):
    for f in sorted(glob.glob(os.path.join(raw, "doj", "*.jsonl.gz"))):
        for line in gzip.open(f, "rt"):
            r = json.loads(line)
            body = strip_html(r.get("body"))
            title = re.sub(r"\s+", " ", strip_html(r.get("title") or "")).strip()
            st = stage(title)
            if len(body) < 400 or not title or not st: continue
            try: day = datetime.datetime.utcfromtimestamp(int(r["date"])).date()
            except Exception: continue
            m = NAME.search(body[:600])
            if not m: continue
            yield {"name": m.group(1), "town": m.group(3).strip(), "title": title, "body": body, "day": day,
                   "stage": st, "components": [c for c in r.get("component") or [] if c], "cat": doj_category(r, body),
                   "uuid": r.get("uuid")}

def page(rel):
    """The release as justice.gov prints it: office, dateline day, title, body."""
    office = (office_names(rel["components"]) or ["Office of Public Affairs"])[0]
    when = rel["day"].strftime("%A, %B %-d, %Y")
    return f"U.S. Department of Justice\n{office}\nFOR IMMEDIATE RELEASE\n{when}\n\n{rel['title']}\n\n{rel['body']}\n"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True); ap.add_argument("--out", required=True); ap.add_argument("--render", required=True)
    ap.add_argument("--cases", type=int, default=200); ap.add_argument("--shard-size", type=int, default=10)
    ap.add_argument("--seed", type=int, default=20261026)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    by = collections.defaultdict(list)
    for rel in releases(a.raw):
        by[(rel["name"], tuple(rel["components"][:1]))].append(rel)
    pool = []
    for (name, _), rels in by.items():
        rels = sorted({r["uuid"]: r for r in rels}.values(), key=lambda r: r["day"])
        stages = {r["stage"] for r in rels}
        # A finished prosecution followed across at least two stages, ending in a sentence.
        if len(rels) < 2 or "sentenced" not in stages or len(stages) < 2 or len(rels) > 6: continue
        if rels[-1]["stage"] != "sentenced": continue
        pool.append((name, rels))
    print("finished prosecutions followed across releases:", len(pool), file=sys.stderr)
    rng.shuffle(pool)
    chosen = pool[:a.cases]
    os.makedirs(a.out, exist_ok=True)
    for i, (name, rels) in enumerate(chosen):
        cat = "chronology-" + (rels[0]["cat"] or "doj-other-federal-crime").removeprefix("doj-")
        shard = os.path.join(a.out, "chronology", f"shard-{i // a.shard_size:05d}")
        cid = "chron-" + re.sub(r"[^A-Za-z0-9]", "", name)[:24] + f"-{i:04d}"
        docs = {f"release-{k + 1}-{r['day'].isoformat()}.txt": page(r) for k, r in enumerate(rels)}
        profile = pick_profile(rng)
        if profile in ("eml", "zip", "mbox", "mixed", "xlsx", "png"): profile = "pdf"   # one file per release
        carried = write_case(profile, cid, docs, os.path.join(shard, cid), a.render)
        alltext = "\n".join(carried) if isinstance(carried, list) else str(carried)
        first = rels[0]; sent = [r for r in rels if r["stage"] == "sentenced"][-1]
        charged = [r for r in rels if r["stage"] == "charged"]
        q = []
        if charged:
            q.append({"id": "charged", "q": f"When was {name} charged?", "expect": {"dates": sorted({charged[0]["day"].isoformat()} | stated_days(charged[0]["body"], r"(?:indicted|charged|arrested|indictment (?:was )?returned|complaint (?:was )?filed)", charged[0]["day"].year))}})
        q.append({"id": "sentenced", "q": f"When was {name} sentenced?", "expect": {"dates": sorted({sent["day"].isoformat()} | stated_days(sent["body"], r"sentenced", sent["day"].year))}})
        m = SENTENCE.search(sent["body"])
        if m:
            q.append({"id": "sentence", "q": f"What sentence did {name} receive?", "expect": {"any": sentence_forms(m.group(1), m.group(2))}})
        pleaded = any(r["stage"] == "pleaded" for r in rels) or re.search(r"pleaded guilty|pled guilty", sent["body"], re.I)
        convicted = any(r["stage"] == "convicted" for r in rels) or re.search(r"\b(?:convicted|found guilty) by a (?:federal )?jury", sent["body"], re.I)
        if pleaded and not convicted:
            q.append({"id": "plea", "q": f"Did {name} plead guilty?", "expect": {"yesno": True}})
        elif convicted and not pleaded:
            q.append({"id": "plea", "q": f"Did {name} plead guilty?", "expect": {"yesno": False, "truth": "jury"}})
        days = sorted({r["day"].isoformat() for r in rels})
        if len(days) >= 2:
            q.append({"id": "timeline", "q": f"Give me the timeline of the case against {name}.", "expect": {"order": days}})
        q.append({"id": "count", "q": f"How many press releases are about {name}?", "expect": {"number": len(rels)}})
        lead = re.split(r"(?<=[a-z]{3}\.)\s+(?=[A-Z])", first["body"])[0]
        q.append({"id": "charge", "q": f"What was {name} charged with?", "expect": {"overlap": lead[:300]}})
        offices = sorted(set(first["components"] + office_names(first["components"])))
        if offices:
            q.append({"id": "office", "q": f"Which office prosecuted {name}?", "expect": {"any": offices}})
        q.append({"id": "absent", "q": f"When was {name} pardoned?", "expect": {"dates": ["1900-01-01"]}, "in_docs": False})
        for one in q:
            if "in_docs" in one: continue
            if "overlap" in one["expect"] or "yesno" in one["expect"] or "order" in one["expect"] or "number" in one["expect"]:
                one["in_docs"] = True
            else:
                one["in_docs"] = value_in(one["expect"], alltext)[0]
        rec = {"case": cid, "source": "chronology", "key": name, "questions": q, "profile": profile, "stratum": cat,
               "persona": "investigator", "releases": [{"day": r["day"].isoformat(), "stage": r["stage"], "title": r["title"]} for r in rels],
               "control": f"What happened in the case \"Nonexistent matter {rng.randint(10**8, 10**9)}\"?"}
        with open(os.path.join(shard, "truth.jsonl"), "a") as fh: fh.write(json.dumps(rec) + "\n")
    print("wrote", len(chosen), "cases to", a.out, file=sys.stderr)

if __name__ == "__main__":
    main()

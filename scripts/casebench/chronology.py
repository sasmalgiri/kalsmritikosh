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
# A verdict reached at trial (mirrors ProceedingAnswerer.trialVerdict).
TRIAL = re.compile(r"\bjury (?:convicted|found|verdict|trial)\b|\b(?:convicted|found guilty)\s+(?:\w+\s+){0,6}?by (?:a |the )?(?:federal |trial )?(?:jury|judge|court)\b|\b(?:at|after|following) (?:a |the )?(?:\w+[- ]){0,3}(?:jury |bench )?trial\b|\bbench trial\b", re.I)
# "Steven Daniel Miller, 47, of Fairfield" — the defendant as releases introduce them.
NAME = re.compile(r"\b([A-Z][a-z]+(?: [A-Z]\.?| [A-Z][a-z]+){0,2} [A-Z][a-zA-Z'\-]+(?: (?:Jr|Sr|II|III)\.?)?), (?:a\s)?(\d{2}),? (?:of|from) ([A-Z][A-Za-z .'\-]+?)[,.]")
# A period after a capital ("U.S. District Court", "Judge D. Brock Hornby") does not end the sentence.
SENTENCE = re.compile(r"sentenced\b(?:[^.]|(?<=[A-Z])\.){0,160}?\bto (?:serve )?(?:a total of )?(\d+|[a-z]+(?:-[a-z]+)?)[ -](months?|years?)\b(?! of (?:supervised release|probation))", re.I)
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

OTHER_STEP = re.compile(r"\b(?:pleaded|pled|pleading|indicted|charged|arrested|convicted|found guilty|arraigned)\b", re.I)

def stated_days(body, verb, year, printed=None, window=80, clause=False):
    """Days a release itself gives for the event — a date in the same sentence as the step ("was
    sentenced on March 3, 2015", "Judge X on March 15, 2017, sentenced …"), or "yesterday" (the day
    before the release): the release's own day is not the only right answer."""
    out = set()
    for sent in re.split(r"(?<=[a-z]{2}[.!?])\s+(?=[A-Z])", body):
        v = re.search(verb, sent, re.I)
        if not v: continue
        for m in re.finditer(r"\b(" + MONTH + r")\.? (\d{1,2})(?:, (\d{4}))?", sent):
            # A date of another step in the same sentence is not this step's. With clause=True a
            # later date belongs to the step unless another step's verb comes between them
            # ("was sentenced to 33 months … by Judge Lawson on Feb. 23, after pleading guilty on Nov. 19").
            if clause and m.start() > v.start():
                if OTHER_STEP.search(sent[v.end():m.start()]): continue
            elif abs(m.start() - v.start()) > window: continue
            try:
                d = datetime.datetime.strptime(f"{m.group(1)[:3]} {m.group(2)} {m.group(3) or year}", "%b %d %Y").date()
                out.add(d.isoformat())
            except ValueError: pass
        if printed and re.search(r"\byesterday\b", sent, re.I):
            out.add((printed - datetime.timedelta(days=1)).isoformat())
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
        elif o:
            out.append(o)
            # "Criminal - Child Exploitation and Obscenity Section" is part of the Criminal Division.
            d = re.match(r"(Criminal|Civil|Tax|Antitrust|Civil Rights|National Security|Environment and Natural Resources) - ", o)
            if d: out.append(f"{d.group(1)} Division")
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

OFFENCE = re.compile(r"(?:charg(?:ed|es|ing)\s+(?:\w+\s+){0,3}with|(?:pleaded|pled|pleads) guilty\b(?:[^.;]|(?<=[A-Z])\.){0,120}?\bto|found \w+ guilty of|convicted(?:\s+\w+){0,6}?\s+of|found guilty(?:\s+\w+){0,6}?\s+of|indicted (?:for|on))\s+([^.;]{12,160})", re.I)
PRIOR = re.compile(r"\b(?:previously (?:been )?convicted|prior (?:conviction|record|offen[cs]e)s?|criminal history|had (?:previously )?been convicted|registered sex offender|on (?:probation|parole|supervised release) for|years? earlier|an earlier case)\b", re.I)

CHARGE_VERB = r"(?:indicted|charged|arrested|indictment (?:was )?returned|complaint (?:was )?filed|returned (?:an|a \w+) indictment)"

def own_sentences(name, body):
    """The release's sentences that name the person (surname), split like the app splits them."""
    surname = name.split()[-1].rstrip(".,").lower()
    return [x for x in re.split(r"(?<=[a-z0-9)”\"])\.\s+(?=[A-Z“\"])", body) if surname in x.lower()]

def sentence_terms(name, rels):
    """Every prison term the person's own sentencing sentences state, across all their releases
    (2026-10-27: the first match anywhere in the body was often a co-defendant's)."""
    surname = name.split()[-1].rstrip(".,").lower()
    out = []
    for r in rels:
        for x in own_sentences(name, r["body"]):
            for m in SENTENCE.finditer(x):
                if surname in x.lower()[:m.start() + 1]: out += sentence_forms(m.group(1), m.group(2))
    return sorted(set(out))

def charge_days(name, rels):
    """Every day the person was charged: each charging release's own day, and any day a sentence
    naming the person attaches to a charge, indictment or complaint, in any of their releases."""
    out = set()
    for r in rels:
        if r["stage"] == "charged": out.add(r["day"].isoformat())
        # The person's own sentences, and the release's opening ones ("A Jackson County man was indicted
        # … on May 9, 2013", "A federal complaint was filed … on August 13, 2015") which are about them.
        parts = re.split(r"(?<=[a-z0-9)”\"])\.\s+(?=[A-Z“\"])", r["body"])
        own = " ".join(x + "." for x in dict.fromkeys(own_sentences(name, r["body"]) + parts[:4]))
        out |= stated_days(own, CHARGE_VERB + r"|filed|returned", r["day"].year, r["day"] if r["stage"] == "charged" else None, window=170)
    return sorted(out)

def sentencing_days(name, sent):
    """The sentencing release's day and any day its sentences give the sentencing (wider window:
    "was sentenced … by Judge X … on February 23, 2022")."""
    return sorted({sent["day"].isoformat()} | stated_days(sent["body"], r"sentenced", sent["day"].year, sent["day"], window=170, clause=True))

def offence_sentences(name, rels):
    """The person's OWN sentences that state what they were charged with, pleaded to or convicted
    of — never a prior record or another defendant's (2026-10-27 bench repair)."""
    surname = name.split()[-1].rstrip(".,").lower()
    out = []
    for r in rels:
        parts = re.split(r"(?<=[a-z0-9)”\"])\.\s+(?=[A-Z“\"])", r["body"])
        for i, sent in enumerate(parts):
            low = sent.lower()
            m = OFFENCE.search(sent)
            if not m or PRIOR.search(sent): continue
            # The person's offence: their surname before the verb phrase; "He/She …" right after a
            # sentence naming them; or the release's opening sentence about them ("A Florida reptile
            # dealer pleaded guilty to …").
            own = surname in low[:m.start() + 1]
            pronoun = re.match(r"\s*(?:He|She)\b", sent) is not None and i > 0 and surname in parts[i - 1].lower()
            lead = i < 2 and re.match(r"\s*(?:[A-Z][\w.,'\s]{0,40}[–—-]\s*)?An?\s", sent) is not None
            if own or pronoun or lead: out.append(re.sub(r"\s+", " ", sent.strip()))
    return list(dict.fromkeys(out))

def offences_for(name, rels):
    return list(dict.fromkeys(m.group(1) for s in offence_sentences(name, rels) for m in OFFENCE.finditer(s)))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True); ap.add_argument("--out", required=True); ap.add_argument("--render", required=True)
    ap.add_argument("--cases", type=int, default=200); ap.add_argument("--shard-size", type=int, default=10)
    ap.add_argument("--seed", type=int, default=20261026)
    ap.add_argument("--skip-keys", help="a truth root whose defendants must not be drawn again (a fresh, untuned draw)")
    a = ap.parse_args()
    skip = set()
    if a.skip_keys:
        for t in glob.glob(os.path.join(a.skip_keys, "*", "*", "truth.jsonl")):
            skip |= {json.loads(l)["key"] for l in open(t)}
    rng = random.Random(a.seed)
    by = collections.defaultdict(list)
    copies = collections.defaultdict(set)   # (name, day) -> every component a copy was posted under
    for rel in releases(a.raw):
        by[(rel["name"], tuple(rel["components"][:1]))].append(rel)
        copies[(rel["name"], rel["day"])].update(rel["components"])
    pool = []
    for (name, _), rels in by.items():
        rels = sorted({r["uuid"]: r for r in rels}.values(), key=lambda r: r["day"])
        stages = {r["stage"] for r in rels}
        # A finished prosecution followed across at least two stages, ending in a sentence.
        if len(rels) < 2 or "sentenced" not in stages or len(stages) < 2 or len(rels) > 6: continue
        if rels[-1]["stage"] != "sentenced" or name in skip: continue
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
            q.append({"id": "charged", "q": f"When was {name} charged?", "expect": {"dates": charge_days(name, rels)}})
        q.append({"id": "sentenced", "q": f"When was {name} sentenced?", "expect": {"dates": sentencing_days(name, sent)}})
        terms = sentence_terms(name, rels)
        if terms:
            q.append({"id": "sentence", "q": f"What sentence did {name} receive?", "expect": {"any": terms}})
        pleaded = any(r["stage"] == "pleaded" for r in rels) or re.search(r"pleaded guilty|pled guilty", sent["body"], re.I)
        convicted = any(r["stage"] == "convicted" for r in rels) or re.search(r"\b(?:convicted|found guilty) by a (?:federal )?jury", sent["body"], re.I)
        if pleaded and not convicted:
            q.append({"id": "plea", "q": f"Did {name} plead guilty?", "expect": {"yesno": True}})
        elif convicted and not pleaded and any(TRIAL.search(r["body"]) for r in rels):
            # "No" only when a release states a verdict AT TRIAL: a bare "was convicted" follows a
            # guilty plea as often as a trial, so it does not rule a plea out (2026-10-26, brief §8).
            q.append({"id": "plea", "q": f"Did {name} plead guilty?", "expect": {"yesno": False, "truth": "jury"}})
        # Each release's step, dated by the release's own day or the day its step sentence states.
        steps = []
        for r in rels:
            verb = {"charged": r"(?:indicted|charged|arrested|indictment)", "pleaded": r"(?:pleaded|pled) guilty",
                    "convicted": r"(?:convicted|found guilty)", "sentenced": r"sentenced"}[r["stage"]]
            steps.append(sorted({r["day"].isoformat()} | stated_days(r["body"], verb, r["day"].year, r["day"])))
        if len(steps) >= 2:
            q.append({"id": "timeline", "q": f"Give me the timeline of the case against {name}.", "expect": {"order_any": steps}})
        q.append({"id": "count", "q": f"How many press releases are about {name}?", "expect": {"number": len(rels)}})
        # The offence, as the releases word it ("charges Romano with seven counts of wire fraud",
        # "pleaded guilty to wire fraud", "convicted of …"): any one of them answers.
        offences, said = offences_for(name, rels), offence_sentences(name, rels)
        if offences:
            q.append({"id": "charge", "q": f"What was {name} charged with?", "expect": {"overlap_any": offences, "quote_any": said}})
        # Every office the case's releases were posted under: DOJ cross-posts one release under each
        # prosecuting component (a U.S. Attorney's Office and the Civil Rights Division together).
        comps = sorted({c for r in rels for c in copies[(name, r["day"])]})
        offices = sorted(set(comps + office_names(comps)))
        if offices:
            q.append({"id": "office", "q": f"Which office prosecuted {name}?", "expect": {"any": offices}})
        q.append({"id": "absent", "q": f"When was {name} pardoned?", "expect": {"dates": ["1900-01-01"]}, "in_docs": False})
        for one in q:
            if "in_docs" in one: continue
            if "overlap" in one["expect"] or "overlap_any" in one["expect"] or "yesno" in one["expect"] or "order" in one["expect"] or "order_any" in one["expect"] or "number" in one["expect"]:
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

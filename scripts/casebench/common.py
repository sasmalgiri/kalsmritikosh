"""Shared by the case bench converters and the scorer: how an expected value is recognised in
text, so "is the answer in this case's documents?" (converter) and "is it in the app's answer?"
(scorer) are decided by the same rule."""
import json, os, re

MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
          "September", "October", "November", "December"]
STOP = set("""the a an and or of to in on at for by with from was were is be been that this
as it its their his her they he she not no into than then also which who whom whose during
after before about while when where pilot's airplane aircraft court case""".split())
WORDS = {0: "no", 1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven",
         8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve"}
FULL_DATE = re.compile(r"\b(\d{4}-\d\d-\d\d|(?:%s)\.? \d{1,2},? \d{4})\b" % "|".join(m[:3] + "[a-z]*" for m in MONTHS))

REFUSAL_RE = re.compile(r"can.?t (ground|answer)|couldn.?t|no (evidence|documents?)|not (find|found)|"
                        r"don.?t have|isn.?t in your|nothing in your|unable|"
                        r"(?:does|do) not (?:state|specify|say|mention|provide|indicate|include|contain|show)|"
                        r"not (?:stated|specified|mentioned|provided|given)|none of the .{0,40}(?:carries|carry|states?|names?)|"
                        r"doesn.?t (?:say|name|give|state)|don.?t (?:say|name|give|state)", re.I)

def date_forms(iso):
    y, m, d = iso.split("-"); mi, di = int(m), int(d); name = MONTHS[mi - 1]
    return [iso, f"{name} {di}, {y}", f"{name[:3]} {di}, {y}", f"{name[:3]}. {di}, {y}",
            f"{di} {name} {y}", f"{mi}/{di}/{y}", f"{m}/{d}/{y}", f"{name} {di} {y}",
            f"{name} {di},{y}", f"{mi}/{di}/{y[2:]}",
            # Day-first forms the app itself writes ("23/07/1993", "23 Jul 1993").
            f"{d}/{m}/{y}", f"{di}/{mi}/{y}", f"{di} {name[:3]} {y}", f"{di} {name[:3]}, {y}"]

def words(s):
    return [w for w in re.findall(r"[a-z][a-z'-]+", s.lower()) if len(w) > 3 and w not in STOP]

def name_forms(v):
    """A court named either way round: "oklahoma supreme court" ~ "supreme court of oklahoma"."""
    forms = [v]
    m = re.match(r"^(.+?) (supreme court|court of appeals|court of civil appeals|court of criminal appeals|appellate court)$", v)
    if m: forms.append(f"{m.group(2)} of {m.group(1)}")
    m = re.match(r"^(supreme court|court of appeals|court of civil appeals|court of criminal appeals|appellate court) of (.+)$", v)
    if m: forms.append(f"{m.group(2)} {m.group(1)}")
    return forms

def value_in(expect, text):
    """(present, note) — is the expected value in `text`?"""
    b = text.lower()
    if "yesno" in expect:
        # A yes/no check: the answer must lead with the right polarity. A "no" may also be shown
        # by the answer giving the true value instead (e.g. "No — it is Class I").
        lead = b.strip()[:160]
        says_yes = re.match(r"^\W*(yes|correct|that is right|it is|it was)\b", lead) is not None
        says_no = re.match(r"^\W*(no|not|that is not|incorrect|it is not|it was not)\b", lead) is not None or \
                  re.search(r"\b(does not|doesn.t|is not|isn.t|was not|wasn.t) (match|state|say)", lead) is not None
        if expect["yesno"]: return says_yes and not says_no, None
        truth = (expect.get("truth") or "").lower()
        return says_no or (bool(truth) and truth in b and not says_yes), None
    if "order_any" in expect:
        # A chronology whose steps may each be dated more than one right way: each step's earliest
        # mention, by any of its days, must come in order.
        at = []
        for options in expect["order_any"]:
            hits = [b.find(f.lower()) for iso in options for f in date_forms(iso) if f.lower() in b]
            if not hits: return False, f"order-missing:{options[0]}"
            at.append(min(hits))
        return at == sorted(at), ("order-ok" if at == sorted(at) else "order-wrong")
    if "order" in expect:
        # A chronology: every expected date appears, and in the expected order (first mention).
        at = []
        for iso in expect["order"]:
            hits = [b.find(f.lower()) for f in date_forms(iso) if f.lower() in b]
            if not hits: return False, f"order-missing:{iso}"
            at.append(min(hits))
        return at == sorted(at), ("order-ok" if at == sorted(at) else "order-wrong")
    if "dates" in expect:
        # Any one of several acceptable dates (the release's day, or the day the release names).
        return any(f.lower() in b for iso in expect["dates"] for f in date_forms(iso)), None
    if "date" in expect:
        if any(f.lower() in b for f in date_forms(expect["date"])): return True, None
        other = FULL_DATE.findall(text)
        return False, ("other-date:" + other[0]) if other else None
    if "any" in expect:
        return any(v and any(f in b for f in name_forms(v.lower())) for v in expect["any"]), None
    if "number" in expect:
        n = expect["number"]
        return bool(re.search(rf"\b{n}\b", b) or (n in WORDS and re.search(rf"\b{WORDS[n]}\b", b))), None
    if "overlap_any" in expect:
        # Any one of several phrasings of the same fact (the charge as each release words it).
        for phrase in expect["overlap_any"]:
            want = set(words(phrase))
            if want and len(want & set(words(text))) / len(want) >= 0.6: return True, None
        return False, None
    if "overlap" in expect:
        want = set(words(expect["overlap"]))
        if not want: return False, None
        got = len(want & set(words(text))) / len(want)
        # A verbatim quote of the expected passage's opening sentence answers it, even when the
        # key runs on for several more sentences.
        head = " ".join(words(expect["overlap"]))[:80]
        if got < 0.5 and len(head) >= 40 and head in " ".join(words(text)):
            return True, f"overlap={got:.2f}+quoted-opening"
        return got >= 0.5, f"overlap={got:.2f}"
    return False, None

class ShardWriter:
    """Writes case folders into shards of `size` cases with a truth.jsonl each, marking every
    question with whether its expected value is present in the case's own documents."""
    def __init__(self, out, source, size, tag=""):
        self.out, self.source, self.size, self.n, self.truth = out, source, size, 0, None
        self.tag = tag + "-" if tag else ""   # keeps shard names unique across conversion batches

    def add(self, case_id, docs, record):
        if self.n % self.size == 0:
            if self.truth: self.truth.close()
            self.shard = os.path.join(self.out, self.source, f"{self.tag}shard-{self.n // self.size:05d}")
            os.makedirs(self.shard, exist_ok=True)
            self.truth = open(os.path.join(self.shard, "truth.jsonl"), "w")
        folder = os.path.join(self.shard, case_id); os.makedirs(folder, exist_ok=True)
        for name, text in docs.items():
            with open(os.path.join(folder, name), "w") as f: f.write(text)
        alltext = "\n".join(docs.values())
        for q in record["questions"]:
            q["in_docs"] = value_in(q["expect"], alltext)[0]
        record.update({"case": case_id, "source": self.source})
        self.truth.write(json.dumps(record) + "\n")
        self.n += 1

    def close(self):
        if self.truth: self.truth.close()

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
                        r"don.?t have|isn.?t in your|nothing in your|unable", re.I)

def date_forms(iso):
    y, m, d = iso.split("-"); mi, di = int(m), int(d); name = MONTHS[mi - 1]
    return [iso, f"{name} {di}, {y}", f"{name[:3]} {di}, {y}", f"{name[:3]}. {di}, {y}",
            f"{di} {name} {y}", f"{mi}/{di}/{y}", f"{m}/{d}/{y}", f"{name} {di} {y}",
            f"{name} {di},{y}", f"{mi}/{di}/{y[2:]}"]

def words(s):
    return [w for w in re.findall(r"[a-z][a-z'-]+", s.lower()) if len(w) > 3 and w not in STOP]

def value_in(expect, text):
    """(present, note) — is the expected value in `text`?"""
    b = text.lower()
    if "date" in expect:
        if any(f.lower() in b for f in date_forms(expect["date"])): return True, None
        other = FULL_DATE.findall(text)
        return False, ("other-date:" + other[0]) if other else None
    if "any" in expect:
        return any(v and v.lower() in b for v in expect["any"]), None
    if "number" in expect:
        n = expect["number"]
        return bool(re.search(rf"\b{n}\b", b) or (n in WORDS and re.search(rf"\b{WORDS[n]}\b", b))), None
    if "overlap" in expect:
        want = set(words(expect["overlap"]))
        if not want: return False, None
        got = len(want & set(words(text))) / len(want)
        return got >= 0.5, f"overlap={got:.2f}"
    return False, None

class ShardWriter:
    """Writes case folders into shards of `size` cases with a truth.jsonl each, marking every
    question with whether its expected value is present in the case's own documents."""
    def __init__(self, out, source, size):
        self.out, self.source, self.size, self.n, self.truth = out, source, size, 0, None

    def add(self, case_id, docs, record):
        if self.n % self.size == 0:
            if self.truth: self.truth.close()
            self.shard = os.path.join(self.out, self.source, f"shard-{self.n // self.size:05d}")
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

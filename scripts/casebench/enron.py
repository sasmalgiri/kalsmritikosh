#!/usr/bin/env python3
"""Closed-case simulation — who knew what, when: real mailboxes from the Enron investigation (the
CMU Enron Email Dataset, released by FERC during its investigation; https://www.cs.cmu.edu/~enron/).

Each case is one custodian's mailbox sample (about 40 real messages, sent and received, kept byte
for byte as .eml files). Ground truth comes from the messages' own headers and bodies: who sent a
message, when, to whom; how many messages one person sent another; what a message said. Plus a
control the mailbox cannot answer (an email to a person who never appears), which must be refused.

Usage: enron.py --maildir MAILDIR --out OUT [--cases 100] [--per 40] [--shard-size 10] [--seed N]
"""
import argparse, email, email.utils, json, os, random, re, sys
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import value_in   # noqa: E402

def parse(path):
    raw = open(path, "rb").read()
    m = email.message_from_bytes(raw)
    subj = re.sub(r"\s+", " ", m.get("Subject", "") or "").strip()
    try: d = email.utils.parsedate_to_datetime(m.get("Date"))
    except Exception: d = None
    body = m.get_payload(decode=True) if not m.is_multipart() else b""
    body = (body or b"").decode("latin-1", "replace")
    # The message's own words, before any quoted or forwarded text.
    own = re.split(r"(?im)^-+\s*(?:original message|forwarded by)|^>|^\s*-----", body)[0].strip()
    name = (m.get("X-From") or "").split("<")[0].strip().strip('"')
    to_names = [t.split("<")[0].strip().strip('"') for t in (m.get("X-To") or "").split(",") if t.strip()]
    return {"raw": raw, "subject": subj, "date": d, "from": (m.get("From") or "").strip().lower(), "from_name": name,
            "to": [a.strip().lower() for a in (m.get("To") or "").replace("\n", " ").split(",") if a.strip()],
            "to_names": to_names, "own": own}

def person(n):
    """"Kenneth Lay" from "Kenneth Lay", "Lay, Kenneth", "Kenneth L Lay" — a two-word name or None."""
    n = re.sub(r"\s+", " ", n or "").strip()
    if "," in n:
        last, first = [p.strip() for p in n.split(",", 1)]; n = f"{first} {last}"
    words = [w for w in n.split() if re.fullmatch(r"[A-Z][a-zA-Z'\-]+", w)]
    return " ".join([words[0], words[-1]]) if len(words) >= 2 else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--maildir", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--cases", type=int, default=100); ap.add_argument("--per", type=int, default=40)
    ap.add_argument("--shard-size", type=int, default=10); ap.add_argument("--seed", type=int, default=20261026)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    custodians = sorted(os.listdir(a.maildir)); rng.shuffle(custodians)
    made = 0
    for cust in custodians:
        if made >= a.cases: break
        files = []
        for root, _, names in os.walk(os.path.join(a.maildir, cust)):
            files += [os.path.join(root, n) for n in names if not n.startswith(".")]
        if len(files) < a.per * 2: continue
        rng.shuffle(files)
        msgs, subjects = [], Counter()
        for f in files[: a.per * 6]:
            try: m = parse(f)
            except Exception: continue
            if not m["date"] or not m["from"] or not m["to"] or len(m["own"]) < 80: continue
            msgs.append(m); subjects[m["subject"].lower()] += 1
            if len(msgs) >= a.per: break
        if len(msgs) < a.per // 2: continue
        # Question messages: a subject no other message in the mailbox shares.
        unique = [m for m in msgs if len(m["subject"]) >= 12 and subjects[m["subject"].lower()] == 1
                  and not re.match(r"(?i)^(?:re|fw|fwd)\s*:", m["subject"]) and '"' not in m["subject"]]
        if len(unique) < 3: continue
        cid = f"enron-{cust}"
        shard = os.path.join(a.out, "enron", f"shard-{made // a.shard_size:05d}")
        folder = os.path.join(shard, cid); os.makedirs(folder, exist_ok=True)
        for i, m in enumerate(msgs):
            open(os.path.join(folder, f"message-{i + 1:03d}.eml"), "wb").write(m["raw"])
        alltext = "\n".join(m["raw"].decode("latin-1", "replace") for m in msgs)
        q = []
        for k, m in enumerate(rng.sample(unique, 3)):
            s = m["subject"]
            sender = [m["from"]] + ([m["from_name"]] if m["from_name"] else []) + ([person(m["from_name"])] if person(m["from_name"]) else [])
            q.append({"id": f"from~{k}", "q": f"Who sent the email \"{s}\"?", "expect": {"any": sender}})
            q.append({"id": f"when~{k}", "q": f"When was the email \"{s}\" sent?", "expect": {"date": m["date"].date().isoformat()}})
            q.append({"id": f"to~{k}", "q": f"Who received the email \"{s}\"?", "expect": {"any": m["to"][:3] + [n for n in m["to_names"][:3] if n]}})
            q.append({"id": f"said~{k}", "q": f"What did the email \"{s}\" say?", "expect": {"overlap": m["own"][:300]}})
        # How many messages one person sent another, within this mailbox.
        pairs = Counter((m["from"], t) for m in msgs for t in m["to"][:1])
        (pf, pt), n = pairs.most_common(1)[0]
        names = {m["from"]: person(m["from_name"]) for m in msgs}
        # The recipient's name from the address itself ("mike.maggi@enron.com" → "Mike Maggi"): X-To
        # display names hold commas ("Maggi, Mike") and cannot be zipped with the To addresses.
        local = pt.split("@")[0]
        tname = " ".join(w.capitalize() for w in local.split(".")) if re.fullmatch(r"[a-z]{2,}\.[a-z]{2,}", local) else None
        if n >= 2 and names.get(pf) and tname:
            q.append({"id": "count", "q": f"How many emails did {names[pf]} send to {tname}?", "expect": {"number": n}})
        who = names.get(pf) or pf
        q.append({"id": "absent", "q": f"When did {who} email Zelda Quackenbush?", "expect": {"date": "1900-01-01"}, "in_docs": False})
        for one in q:
            if "in_docs" in one: continue
            one["in_docs"] = True if "overlap" in one["expect"] or "number" in one["expect"] else value_in(one["expect"], alltext)[0]
        rec = {"case": cid, "source": "enron", "key": cust, "questions": q, "persona": "investigator", "profile": "eml",
               "stratum": "enron", "control": "When was the email \"Nonexistent subject 4471\" sent?"}
        with open(os.path.join(shard, "truth.jsonl"), "a") as fh: fh.write(json.dumps(rec) + "\n")
        made += 1
    print("wrote", made, "mailbox cases", file=sys.stderr)

if __name__ == "__main__":
    main()

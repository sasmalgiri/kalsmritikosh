#!/usr/bin/env python3
"""Held-out WORDINGS for a case set, written by Claude: each question is rewritten the way different
investigators would actually ask it. Only the wording changes — names, case numbers and quoted
subjects/titles are kept verbatim (checked), and the expected answers stay those the records give.
Claude never sees the documents or the answers.

Usage: paraphrase.py SRC_CASES OUT_CASES [--per 2] [--model M]   (key: ~/CaseBench/.anthropic-key)
"""
import argparse, concurrent.futures, glob, json, os, re, shutil, sys, time, urllib.request

KEY = open(os.path.expanduser("~/CaseBench/.anthropic-key")).read().strip()

PROMPT = """You are helping test an investigation tool. Rewrite each question below the way {n} DIFFERENT
real investigators (lawyers, journalists, police analysts, auditors) might naturally ask it — casual,
formal, terse, wordy, indirect. Keep the meaning exactly. Rules:
- Copy every person's name, case number and every text inside double quotes EXACTLY, character for character.
- Do not add facts, dates or guesses. Do not answer.
- Each rewrite must still ask for the same single thing.
Reply with JSON only: {{"rewrites": [["rewrite 1", "rewrite 2"], ...]}} — one inner list per question, in order.

Questions:
{questions}"""

def call(prompt, model):
    body = json.dumps({"model": model, "max_tokens": 6000,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    for attempt in range(5):
        try:
            req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, headers={
                "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=120))
            text = "".join(c.get("text", "") for c in r["content"] if c.get("type") == "text")
            return text, r["usage"]["input_tokens"] + r["usage"]["output_tokens"]
        except Exception as e:
            time.sleep(3 * (attempt + 1)); err = e
    raise RuntimeError(str(err))

def anchors(q):
    """What must survive verbatim: quoted text, and capitalised name runs / identifiers."""
    out = re.findall(r'"([^"]+)"', q)
    out += re.findall(r"\b[A-Z]{2,}\d[\w-]*|\b\d{6,}\b|\b[A-Z]-\d{3,4}-\d{4}\b", q)
    out += re.findall(r"\b(?:[A-Z][a-z'’\-]+|[A-Z]\.)(?:\s+(?:[A-Z][a-z'’\-]+|[A-Z]\.)){1,3}\b", q.split("?")[0][4:])
    skip = {"Who", "When", "What", "Which", "How", "Did", "Give", "NTSB", "FDA"}
    return [a for a in out if a.split()[0] not in skip]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("out"); ap.add_argument("--per", type=int, default=2)
    ap.add_argument("--model", default="claude-sonnet-5")
    a = ap.parse_args()
    shutil.rmtree(a.out, ignore_errors=True)
    jobs = []
    for t in glob.glob(os.path.join(a.src, "*", "*", "truth.jsonl")):
        shard = os.path.dirname(t); dst = os.path.join(a.out, os.path.relpath(shard, a.src))
        shutil.copytree(shard, dst)
        jobs.append(dst)
    tokens = 0; kept = dropped = 0
    def one(rec):
        qs = [q for q in rec["questions"]]
        text, used = call(PROMPT.format(n=a.per, questions="\n".join(f"{i + 1}. {q['q']}" for i, q in enumerate(qs))), a.model)
        m = re.search(r"\{.*\}", text, re.S)
        rewrites = json.loads(m.group(0))["rewrites"] if m else []
        return rec, qs, rewrites, used
    for dst in jobs:
        path = os.path.join(dst, "truth.jsonl")
        recs = [json.loads(l) for l in open(path)]
        with concurrent.futures.ThreadPoolExecutor(4) as ex:
            results = list(ex.map(one, recs))
        lines = []
        for rec, qs, rewrites, used in results:
            tokens += used
            new = []
            for i, q in enumerate(qs):
                alts = rewrites[i] if i < len(rewrites) and isinstance(rewrites[i], list) else []
                for k, alt in enumerate(alts[: a.per]):
                    # Every anchor (name, number, quoted subject) must survive, or the rewrite is dropped.
                    if not isinstance(alt, str) or any(x not in alt for x in anchors(q["q"])):
                        dropped += 1; continue
                    kept += 1
                    new.append({**q, "id": f"{q['id'].split('~')[0]}~p{k + 1}{'' if '~' not in q['id'] else '-' + q['id'].split('~')[1]}", "q": alt,
                                "original": q["q"]})
            rec["questions"] = new
            lines.append(json.dumps(rec))
        open(path, "w").write("\n".join(lines) + "\n")
    print(f"rewrites kept {kept}, dropped {dropped} (anchor lost), tokens {tokens}", file=sys.stderr)

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Claude as the second reader of every miss: for each question the app got wrong or missed, Claude
reads the case's own documents, the question, the expected answer (from the records) and the app's
answer, and says WHY it failed — in a fixed taxonomy — and what capability would have answered it.
This turns a score into a precise gap list. Only public-domain bench records are sent.

Usage: judge.py CASES RESULTS OUT.jsonl [--model M] [--limit N]   (key: ~/CaseBench/.anthropic-key)
"""
import argparse, collections, concurrent.futures, glob, json, os, re, subprocess, sys, time, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import classify   # noqa: E402

KEY = open(os.path.expanduser("~/CaseBench/.anthropic-key")).read().strip()
DOCTEXT = os.path.expanduser("~/CaseBench/doctext.sh")

CAUSES = {
    "understanding": "the app misread what the question asks (wrong kind of answer)",
    "retrieval": "the right document was not used / another case's document was used",
    "extraction": "the right document was used but the value was not found or not read correctly in it",
    "attribution": "a value was read but attached to the wrong person, event or record",
    "composition": "the right value was found but buried in a long passage or badly stated",
    "honesty": "the app stated something the documents do not support (should have refused)",
    "over-refusal": "the app refused although the documents do answer it",
    "bench": "the expected answer itself is wrong, ambiguous, or the app's answer is actually right",
}

PROMPT = """You are auditing an evidence-only investigation app. It must answer ONLY from the case documents
and cite them, or say the documents do not give the answer. Below are the case documents, a question,
the answer expected (taken from the official records), and the app's answer, which was scored as a failure.

Decide the single main cause, from: {causes}
Then name, in one short line, the capability that would have produced the right answer.
Reply with JSON only: {{"cause": "<one cause key>", "capability": "<one line>", "right_answer_in_docs": true|false}}

CASE DOCUMENTS:
{docs}

QUESTION: {q}
EXPECTED (from the records): {expect}
APP'S ANSWER: {answer}"""

def call(prompt, model):
    body = json.dumps({"model": model, "max_tokens": 1500, "messages": [{"role": "user", "content": prompt}]}).encode()
    for attempt in range(5):
        try:
            req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, headers={
                "x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=180))
            text = "".join(c.get("text", "") for c in r["content"] if c.get("type") == "text")
            return text, r["usage"]["input_tokens"] + r["usage"]["output_tokens"]
        except Exception as e:
            time.sleep(4 * (attempt + 1)); err = e
    raise RuntimeError(str(err))

_docs = {}
def case_text(folder):
    if folder not in _docs:
        out = subprocess.run(["bash", DOCTEXT, folder], capture_output=True, text=True, timeout=300).stdout
        _docs[folder] = out[:14000]
    return _docs[folder]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cases"); ap.add_argument("results"); ap.add_argument("out")
    ap.add_argument("--model", default="claude-sonnet-5"); ap.add_argument("--limit", type=int, default=400)
    a = ap.parse_args()
    truth, folders = {}, {}
    for t in glob.glob(os.path.join(a.cases, "*", "*", "truth.jsonl")):
        for l in open(t):
            r = json.loads(l); truth[r["case"]] = r; folders[r["case"]] = os.path.join(os.path.dirname(t), r["case"])
    fails = []
    for f in glob.glob(os.path.join(a.results, "*.jsonl")):
        for l in open(f):
            r = json.loads(l)
            if r.get("case") not in truth: continue
            qs = {q["id"]: q for q in truth[r["case"]]["questions"]}
            for ans in r["answers"]:
                q = qs.get(ans["id"])
                if not q: continue
                c, _ = classify(r["case"], q, ans)
                if c not in ("correct", "honest-refusal"):
                    fails.append((r["case"], q, ans, c))
    fails = fails[: a.limit]
    print(f"judging {len(fails)} failures", file=sys.stderr)
    def judge(item):
        case, q, ans, c = item
        prompt = PROMPT.format(causes="; ".join(f"{k} = {v}" for k, v in CAUSES.items()), docs=case_text(folders[case]),
                               q=q["q"], expect=json.dumps(q["expect"])[:400], answer=(ans["body"] or "")[:1200])
        text, used = call(prompt, a.model)
        m = re.search(r"\{[\s\S]*\}", text)
        verdict = json.loads(m.group(0)) if m else {"cause": "unparsed", "capability": text[:200]}
        return {"case": case, "id": q["id"], "q": q["q"], "score": c, "tokens": used, **verdict}
    out = []
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        for v in ex.map(judge, fails): out.append(v)
    with open(a.out, "w") as w:
        for v in out: w.write(json.dumps(v) + "\n")
    causes = collections.Counter(v.get("cause") for v in out)
    print("causes:", dict(causes.most_common()), "tokens:", sum(v["tokens"] for v in out), file=sys.stderr)

if __name__ == "__main__":
    main()

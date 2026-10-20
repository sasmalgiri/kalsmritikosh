#!/usr/bin/env python3
"""Case bench downloader — U.S. Department of Justice press releases (justice.gov API, US
Government work, public domain). Writes one JSON line per release with the fields the
converter needs; resumable (pages already fetched are skipped).

Usage: dl_doj.py OUT_DIR [--pages N] [--sleep S]
"""
import argparse, gzip, json, os, sys, time, urllib.request

API = "https://www.justice.gov/api/v1/press_releases.json?pagesize=50&page={}"

def fetch(page, tries=4):
    for t in range(tries):
        try:
            req = urllib.request.Request(API.format(page), headers={"User-Agent": "case-bench research (offline evaluation)"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except Exception as e:
            time.sleep(2 + 3 * t)
    return None

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("out"); ap.add_argument("--pages", type=int, default=5600)
    ap.add_argument("--sleep", type=float, default=0.3)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for page in range(a.pages):
        path = os.path.join(a.out, f"page-{page:05d}.jsonl.gz")
        if os.path.exists(path): continue
        d = fetch(page)
        if d is None: print("failed page", page, file=sys.stderr); continue
        rows = d.get("results") or []
        if not rows: print("no more results at page", page); break
        with gzip.open(path + ".tmp", "wt") as f:
            for r in rows:
                f.write(json.dumps({
                    "uuid": r.get("uuid"), "title": r.get("title"), "date": r.get("date"),
                    "body": r.get("body"), "teaser": r.get("teaser"), "url": r.get("url"),
                    "component": [c.get("name") for c in (r.get("component") or []) if isinstance(c, dict)],
                    "topic": [c.get("name") for c in (r.get("topic") or []) if isinstance(c, dict)],
                    "attachment": r.get("attachment"), "number": r.get("number"),
                }) + "\n")
        os.replace(path + ".tmp", path)
        if page % 100 == 0: print("page", page, flush=True)
        time.sleep(a.sleep)

if __name__ == "__main__":
    main()

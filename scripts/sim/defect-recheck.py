#!/usr/bin/env python3
"""Unified path R2-E — SIMULATED proportionate defect recheck (QA-15).

Reads every defect row of docs/SMART_MAP_DEFECT_LOG.md, extracts its regression test (`Suite.test`), reruns them all in
one xcodebuild run (only those), and writes a recheck log: per defect the test, the result from the .xcresult (never
console text), and whether a broader recheck is due (the defect's "Recheck" column names wider suites). Unresolved
rows and rows without a test stay listed. Pass --dry-run to only list the selectors.
"""
import json, os, re, subprocess, sys, datetime, pathlib, tempfile, shutil

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(os.environ.get("SIM_OUT", ROOT / "release" / "simulated" / datetime.datetime.utcnow().strftime("%Y-%m-%d")))
OUT.mkdir(parents=True, exist_ok=True)
log = (ROOT / "docs/SMART_MAP_DEFECT_LOG.md").read_text(errors="replace")
defects = []
for line in log.splitlines():
    m = re.match(r"^\|\s*(D\d+-\d+)\s*\|(.*)\|", line)
    if not m: continue
    cells = [c.strip() for c in line.strip("|").split("|")]
    tests = re.findall(r"`([A-Za-z0-9_]+Tests)\.([A-Za-z0-9_]+)`", cells[3] if len(cells) > 3 else "")
    defects.append({"id": m.group(1), "tests": tests, "recheck": cells[4] if len(cells) > 4 else ""})
selectors = sorted({f"KalsmritikoshTests/{s}/{t}()" for d in defects for s, t in d["tests"]})
if "--dry-run" in sys.argv:
    print("\n".join(selectors)); sys.exit(0)

results = {}
derived = pathlib.Path(tempfile.mkdtemp(prefix="kals-sim-recheck-"))
bundle = derived / "recheck.xcresult"
try:
    if selectors:
        cmd = ["xcodebuild", "test", "-project", str(ROOT / "Kalsmritikosh.xcodeproj"), "-scheme", "Kalsmritikosh", "-destination", "platform=macOS",
               "-derivedDataPath", str(derived), "-resultBundlePath", str(bundle)] + [f"-only-testing:{s}" for s in selectors]
        subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        tests = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle), "--format", "json"],
                               capture_output=True, text=True)
        def walk(node):
            if node.get("nodeType") == "Test Case":
                results[node.get("nodeIdentifier", node.get("name", ""))] = node.get("result", "?")
            for c in node.get("children", []): walk(c)
        try:
            for n in json.loads(tests.stdout or "{}").get("testNodes", []): walk(n)
        except json.JSONDecodeError:
            pass
finally:
    shutil.rmtree(derived, ignore_errors=True)

def result_for(suite, test):
    for k, v in results.items():
        if suite in k and test in k: return v
    return "not run"

failed = 0
with open(OUT / "defect-recheck.md", "w") as f:
    f.write("# SIMULATED — proportionate defect recheck (QA-15)\n\nResults read from the .xcresult of one fresh run of only the named regression tests.\n\n")
    f.write("| Defect | Regression test | Result | Broader recheck named |\n|---|---|---|---|\n")
    for d in defects:
        if not d["tests"]:
            f.write(f"| {d['id']} | — (none named: stays open) | — | {d['recheck']} |\n"); continue
        for s, t in d["tests"]:
            r = result_for(s, t)
            if r not in ("Passed", "passed"): failed += 1
            f.write(f"| {d['id']} | `{s}.{t}` | {r} | {d['recheck']} |\n")
    f.write("\n## Still needed for release\n\n- The broader suites each row names, on CI for the pushed HEAD.\n")
print(f"defect-recheck: {len(defects)} defects, {len(selectors)} tests, {failed} not passed → {OUT / 'defect-recheck.md'}")
sys.exit(1 if failed else 0)

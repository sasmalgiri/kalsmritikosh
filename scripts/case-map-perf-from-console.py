#!/usr/bin/env python3
"""Cut the case map performance report CaseMapPerfHarnessTests.fullMeasurement printed into a RunSomeTests /
xcodebuild console log and write it to an evidence folder.
Usage: scripts/case-map-perf-from-console.py <console-log> <out-dir>"""
import os, re, sys
log = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
out = sys.argv[2]
os.makedirs(out, exist_ok=True)
docs, i = {}, 0
while i < len(log):
    m = re.match(r"^(\s*)===CASE_MAP_PERF_BEGIN (\S+)===$", log[i])
    if not m:
        i += 1; continue
    indent, name = m.group(1), m.group(2)
    body = []
    i += 1
    while i < len(log) and not log[i].startswith(indent + "===CASE_MAP_PERF_END==="):
        line = log[i]
        body.append(line[len(indent):] if line.startswith(indent) else line.lstrip())
        i += 1
    if name not in docs:                      # the console repeats each line per log level; keep the first copy
        docs[name] = "\n".join(body).rstrip("\n") + "\n"
    i += 1
for name, text in docs.items():
    path = os.path.join(out, name)
    open(path, "w", encoding="utf-8").write(text)
    print("wrote", path, len(text), "bytes")
if not docs:
    print("no case map performance report found in the log"); sys.exit(1)

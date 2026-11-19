#!/usr/bin/env python3
"""Cut the help documents HelpRegistryTests.generatedDocsMatch printed into a RunSomeTests / xcodebuild
console log, and write them under docs/. Usage: scripts/help-docs-from-console.py <console-log> [repo-root]"""
import re, sys, os
log = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
root = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
docs, i = {}, 0
while i < len(log):
    m = re.match(r"^(\s*)===HELP_DOCS_BEGIN (\S+)===$", log[i])
    if not m:
        i += 1; continue
    indent, name = m.group(1), m.group(2)
    body = []
    i += 1
    while i < len(log) and not log[i].startswith(indent + "===HELP_DOCS_END==="):
        line = log[i]
        body.append(line[len(indent):] if line.startswith(indent) else line.lstrip())
        i += 1
    if name not in docs:                      # the console repeats each line per log level; keep the first copy
        docs[name] = "\n".join(body) + "\n"
    i += 1
for name, text in docs.items():
    path = os.path.join(root, "docs", name)
    open(path, "w", encoding="utf-8").write(text)
    print("wrote", path, len(text), "bytes")
if not docs:
    print("no help documents found in the log"); sys.exit(1)

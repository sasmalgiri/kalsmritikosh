#!/usr/bin/env python3
"""Unified path R2-E — SIMULATED owner/legal decision record and support packet (SHIP-05, SHIP-07).

SHIP-05 (owner decision 2026-11-01: agents replace human review, labelled as agent): reads the decision sheet
docs/legal/LEGAL_PRIVACY_DECISION_SHEET.md (L-1 … L-10) and writes an AGENT decision record — the recommendation,
the materials prepared, and an empty owner/counsel sign-off line per item. It is never represented as legal advice.
SHIP-07: a safe support packet a person can send without exposing a case: app version, schema, macOS version and the
content-free health/diagnostic fields only, plus links to the published guides and recovery steps.
Writes $SIM_OUT/agent-decision-record.md and $SIM_OUT/support-packet-example.md.
"""
import os, re, sys, platform, datetime, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(os.environ.get("SIM_OUT", ROOT / "release" / "simulated" / datetime.datetime.utcnow().strftime("%Y-%m-%d")))
OUT.mkdir(parents=True, exist_ok=True)
sheet = (ROOT / "docs/legal/LEGAL_PRIVACY_DECISION_SHEET.md").read_text(errors="replace")
rows = [r for r in sheet.splitlines() if re.match(r"^\|\s*L-\d+\s*\|", r)]
if not rows:
    sys.exit("agent-decision-record: no L-n rows in the decision sheet")
with open(OUT / "agent-decision-record.md", "w") as f:
    f.write("# SIMULATED — AGENT decision record, not counsel\n\n")
    f.write("Prepared by an agent under the owner's 2026-11-01 decision. Nothing here is legal advice or an owner decision; each item needs the owner's (and, where marked, counsel's) signature.\n\n")
    f.write("| Item | Topic | Agent recommendation | Owner decision | Counsel |\n|---|---|---|---|---|\n")
    for r in rows:
        cells = [c.strip() for c in r.strip("|").split("|")]
        item, topic = cells[0], cells[1] if len(cells) > 1 else ""
        rec = cells[3] if len(cells) > 3 else (cells[-1] if cells else "")
        f.write(f"| {item} | {topic} | {rec[:220]} | ☐ not recorded | ☐ not reviewed |\n")
schema = re.search(r"latestVersion = (\d+)", (ROOT / "Kalsmritikosh/Storage/Schema/SchemaMigrations.swift").read_text()).group(1)
with open(OUT / "support-packet-example.md", "w") as f:
    f.write("# SIMULATED — example support packet (content-free)\n\n")
    f.write(f"- App schema: v{schema}\n- macOS: {platform.mac_ver()[0]}\n- Health snapshot: route counts, error classes, latency buckets, queue depth, memory (ContentFreeHealthMonitor) — no names, no passages, no file names\n")
    f.write("- Never included: case titles, documents, passages, people, file paths, keys\n\n")
    f.write("Guides: Marketing/BEGINNER_GUIDE.md, release/SUPPORT.md (recovery: Settings ▸ Backup ▸ Restore; Move to new Mac).\n\n")
    f.write("## Still needed for release\n\n- Publish the guides and the support route; owner confirms the support mailbox.\n")
print(f"agent-decision-record: {len(rows)} items → {OUT}")

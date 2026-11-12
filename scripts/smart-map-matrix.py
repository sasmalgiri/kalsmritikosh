#!/usr/bin/env python3
"""Render docs/SMART_MAP_COMPLETION_MATRIX.md from docs/SMART_MAP_COMPLETION_MATRIX.json.

The JSON is the only source of truth for the smart-map completion matrix
(docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md, section B). The .md is
always derived from it; never edit the .md by hand.

    python3 scripts/smart-map-matrix.py          # validate the JSON and write the .md
    python3 scripts/smart-map-matrix.py --check  # validate; exit 1 if the .md is out of date

It also writes docs/SMART_MAP_RELEASE_READINESS.md (a short release-readiness view by milestone), checked the same way.

Output is deterministic (no timestamps), so --check can run in CI.
"""
import json
import os
import sys
from collections import Counter, OrderedDict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON_PATH = os.path.join(ROOT, "docs", "SMART_MAP_COMPLETION_MATRIX.json")
MD_PATH = os.path.join(ROOT, "docs", "SMART_MAP_COMPLETION_MATRIX.md")
READINESS_PATH = os.path.join(ROOT, "docs", "SMART_MAP_RELEASE_READINESS.md")

STATUSES = ["NOT_STARTED", "IN_PROGRESS", "IMPLEMENTED", "AUTOMATED_VERIFIED", "UI_VERIFIED", "BLOCKED", "DONE"]
NEEDS = OrderedDict([
    ("a", "local code only"),
    ("b", "server or identity infrastructure"),
    ("c", "real humans"),
    ("d", "owner accounts"),
])
MILESTONES = OrderedDict([
    ("M0", "baseline and contracts"),
    ("M1", "first complete recursive case"),
    ("M2", "investigative depth"),
    ("M3", "work and contributions"),
    ("M4", "optional intelligence"),
    ("M5", "complete usable lifecycle"),
    ("M6", "prove the capability"),
    ("M7", "distribute honestly"),
])
AREA_ORDER = ["BASE", "ARCH", "DATA", "IN", "SRC", "GRAPH", "MAP", "BRIEF", "SEARCH", "REPORT", "REASON", "TIME",
              "CHANGE", "PEOPLE", "MONEY", "HISTORY", "ACTION", "AUTO", "ACCESS", "TEAM", "AI", "OUTPUT", "RECOVERY",
              "SEC", "PERF", "HELP", "ADAPT", "QA", "BENEFIT", "SHIP"]
REQUIRED = ["id", "requirement", "specification_refs", "status", "owner", "dependencies", "implementation_paths",
            "commit_sha", "migration", "automated_evidence", "ui_evidence", "candidate_build", "performance_evidence",
            "benefit_evidence", "remaining_limit", "blocker", "next_action", "needs", "area", "milestone"]


def fail(msg):
    sys.stderr.write("smart-map-matrix: " + msg + "\n")
    sys.exit(2)


def validate(rows):
    if not isinstance(rows, list):
        fail("the JSON must be an array of task objects")
    seen = set()
    for r in rows:
        missing = [k for k in REQUIRED if k not in r]
        if missing:
            fail("%s is missing fields: %s" % (r.get("id", "?"), ", ".join(missing)))
        if r["id"] in seen:
            fail("duplicate id " + r["id"])
        seen.add(r["id"])
        if r["status"] not in STATUSES:
            fail("%s has status %r, not one of %s" % (r["id"], r["status"], ", ".join(STATUSES)))
        if r["needs"] not in NEEDS:
            fail("%s has needs %r, not one of a/b/c/d" % (r["id"], r["needs"]))
        if r["milestone"] not in MILESTONES:
            fail("%s has milestone %r" % (r["id"], r["milestone"]))
        if r["area"] not in AREA_ORDER:
            fail("%s has area %r" % (r["id"], r["area"]))
        if r["status"] == "UI_VERIFIED" and not r["ui_evidence"]:
            fail(r["id"] + " is UI_VERIFIED without ui_evidence")
        if r["status"] in ("AUTOMATED_VERIFIED", "UI_VERIFIED", "DONE") and not r["automated_evidence"]:
            fail(r["id"] + " claims verification without automated_evidence")
        if r["status"] == "BLOCKED" and not r["blocker"]:
            fail(r["id"] + " is BLOCKED without a blocker")
    if len(rows) != 330:
        fail("expected 330 tasks, found %d" % len(rows))


def cell(v):
    if v is None or v == [] or v == "":
        return "–"
    if isinstance(v, list):
        v = "; ".join(str(x) for x in v)
    return str(v).replace("|", "/").replace("\n", " ").strip()


def code_list(v):
    if not v:
        return "–"
    return "<br>".join("`%s`" % cell(x) for x in v)


def title(req):
    return req.split(". ", 1)[0]


def count_table(rows, key, keys, label, labels=None):
    out = ["| %s | %s | Total |" % (label, " | ".join(STATUSES)),
           "|---|" + "---:|" * (len(STATUSES) + 1)]
    for k in keys:
        sub = [r for r in rows if r[key] == k]
        c = Counter(r["status"] for r in sub)
        name = "%s — %s" % (k, labels[k]) if labels else k
        out.append("| %s | %s | %d |" % (name, " | ".join(str(c.get(s, 0)) for s in STATUSES), len(sub)))
    c = Counter(r["status"] for r in rows)
    out.append("| **All** | %s | **%d** |" % (" | ".join("**%d**" % c.get(s, 0) for s in STATUSES), len(rows)))
    return out


def render(rows):
    by_id = {r["id"]: r for r in rows}
    rows = sorted(rows, key=lambda r: (AREA_ORDER.index(r["area"]), r["id"]))
    L = []
    L.append("# Smart-map completion matrix (generated)")
    L.append("")
    L.append("> Generated by `scripts/smart-map-matrix.py` from `docs/SMART_MAP_COMPLETION_MATRIX.json`. Do not edit this")
    L.append("> file by hand: change the JSON and run the script. `--check` fails if this file is out of date.")
    L.append("")
    L.append("Checklist: `docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md` (330 tasks, section B). Governing plan:")
    L.append("`docs/IME_Recursive_Case_Map_Feasibility_and_Implementation_Plan_2026-11-08.md` (§17–18).")
    L.append("")
    L.append("**How to read this.** The rows record three kinds of evidence separately: *implemented* (code at the inspected")
    L.append("commit), *observed* (seen in the UI, from `docs/evidence/ui-walk-2026-11-07/JOURNEYS.md`) and *measured benefit*")
    L.append("(human study). No overall percentage is given on purpose.")
    L.append("")
    L.append("- `AUTOMATED_VERIFIED` means a named test exists that exercises the behaviour, the requirement is substantively")
    L.append("  met, and the test name was confirmed in `KalsmritikoshTests/`. The audit did **not** run these tests at the")
    L.append("  inspected commit; run times are in `docs/CASE_MAP_EXECUTION_MATRIX.md` and CI.")
    L.append("- `IN_PROGRESS` covers everything partly done, including work that exists only for one user on one Mac.")
    L.append("- `BLOCKED` is used only when the local preparation is finished and the next step needs an external account,")
    L.append("  a deployed service or a real person. A row that is not finished locally keeps its local status, and its")
    L.append("  eventual external need goes in `blocker`.")
    L.append("- `commit_sha` is the last commit touching the listed `implementation_paths`. It is not a verified release")
    L.append("  candidate; `candidate_build` stays empty until a candidate is frozen (SHIP-01).")
    L.append("- `needs`: a = local code only; b = server or identity infrastructure; c = real humans; d = owner accounts.")
    L.append("")

    L.append("## Summary by status")
    L.append("")
    c = Counter(r["status"] for r in rows)
    L.append("| Status | Tasks |")
    L.append("|---|---:|")
    for s in STATUSES:
        L.append("| %s | %d |" % (s, c.get(s, 0)))
    L.append("| **Total** | **%d** |" % len(rows))
    L.append("")
    ui = sum(1 for r in rows if r["ui_evidence"])
    ben = sum(1 for r in rows if r["benefit_evidence"] not in (None, "", "NOT_MEASURED"))
    L.append("Rows with some partial UI observation recorded: %d (none reaches UI_VERIFIED unless shown above)." % ui)
    L.append("Rows with measured benefit: %d." % ben)
    L.append("")

    L.append("## Summary by milestone (M0–M7)")
    L.append("")
    L.extend(count_table(rows, "milestone", list(MILESTONES), "Milestone", MILESTONES))
    L.append("")
    L.append("Each work area is counted under the milestone where §D first requires it in full. ACTION starts in M1, ACCESS")
    L.append("and SEC start in M0, and QA, HELP and PERF run throughout.")
    L.append("")

    L.append("## Summary by what the task needs")
    L.append("")
    L.extend(count_table(rows, "needs", list(NEEDS), "Needs", NEEDS))
    L.append("")

    L.append("## Summary by work area")
    L.append("")
    L.extend(count_table(rows, "area", AREA_ORDER, "Area"))
    L.append("")

    L.append("## Tasks that assume server or identity infrastructure (needs b)")
    L.append("")
    L.append("| ID | Status | Requirement | What it assumes / remaining limit |")
    L.append("|---|---|---|---|")
    for r in rows:
        if r["needs"] == "b":
            L.append("| %s | %s | %s | %s |" % (r["id"], r["status"], cell(title(r["requirement"])), cell(r["remaining_limit"])))
    L.append("")

    L.append("## Recorded blockers")
    L.append("")
    L.append("| ID | Status | Needs | Blocker |")
    L.append("|---|---|---|---|")
    for r in rows:
        if r["blocker"]:
            L.append("| %s | %s | %s | %s |" % (r["id"], r["status"], r["needs"], cell(r["blocker"])))
    L.append("")

    L.append("## Tasks by work area")
    for area in AREA_ORDER:
        sub = [r for r in rows if r["area"] == area]
        if not sub:
            continue
        ms = sub[0]["milestone"]
        deps = ", ".join(sub[0]["dependencies"]) or "none"
        L.append("")
        L.append("### %s (%s; depends on: %s)" % (area, ms, deps))
        L.append("")
        L.append("| ID | Status | Needs | Requirement | Automated evidence | UI evidence | Remaining limit | Next action |")
        L.append("|---|---|---|---|---|---|---|---|")
        for r in sub:
            status = r["status"]
            if r.get("status_note"):
                status += " ¹"
            L.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
                r["id"], status, r["needs"], cell(title(r["requirement"])), code_list(r["automated_evidence"]),
                cell(r["ui_evidence"]).replace("docs/evidence/ui-walk-2026-11-07/JOURNEYS.md: ", "JOURNEYS "),
                cell(r["remaining_limit"]) + (" **Blocker:** " + cell(r["blocker"]) if r["blocker"] else ""),
                cell(r["next_action"])))
        notes = [r for r in sub if r.get("status_note")]
        if notes:
            L.append("")
            for r in notes:
                L.append("¹ %s: %s" % (r["id"], cell(r["status_note"])))
    L.append("")
    L.append("## Implementation paths and commits")
    L.append("")
    L.append("| ID | Last commit on paths | Migration | Implementation paths |")
    L.append("|---|---|---|---|")
    for r in rows:
        L.append("| %s | %s | %s | %s |" % (r["id"], cell(r["commit_sha"]), cell(r["migration"]),
                                          "<br>".join(cell(p) for p in r["implementation_paths"]) or "–"))
    L.append("")
    return "\n".join(L)


def render_readiness(rows):
    """A short release-readiness view by milestone: verified, implemented but not observed (needs the GUI walk),
    still open on this Mac, and waiting on a server, people or the owner."""
    verified = ("AUTOMATED_VERIFIED", "UI_VERIFIED", "DONE")
    def bucket(r):
        if r["status"] == "BLOCKED" or (r["needs"] != "a" and r["status"] not in verified):
            return "external"
        if r["status"] in verified:
            return "verified"
        if r["status"] == "IMPLEMENTED":
            return "unobserved"
        return "open"
    labels = OrderedDict([
        ("verified", "Verified by named automated tests"),
        ("unobserved", "Implemented, not yet observed (needs the GUI walk)"),
        ("open", "Still open on this Mac (local code)"),
        ("external", "Waiting on a server, real people or the owner"),
    ])
    rows = sorted(rows, key=lambda r: (AREA_ORDER.index(r["area"]), r["id"]))
    L = ["# Smart-map release readiness (generated)", "",
         "> Generated by `scripts/smart-map-matrix.py` from `docs/SMART_MAP_COMPLETION_MATRIX.json`; do not edit by hand.", "",
         "Four kinds of state, kept apart on purpose. *Verified* means a named automated test exercises the behaviour; it does",
         "not mean it was seen in the running app: only rows with UI evidence were observed, and no row is `UI_VERIFIED` unless",
         "listed so in the matrix. *Implemented, not yet observed* rows need the GUI walk. *Waiting* rows need a deployed",
         "service or identity system (b), real people (c) or owner accounts (d), or are `BLOCKED`. A build or green tests are",
         "not release verification.", ""]
    L.append("| Milestone | " + " | ".join(labels.values()) + " | Total |")
    L.append("|---|" + "---:|" * (len(labels) + 1))
    for ms, name in MILESTONES.items():
        sub = [r for r in rows if r["milestone"] == ms]
        c = Counter(bucket(r) for r in sub)
        L.append("| %s — %s | %s | %d |" % (ms, name, " | ".join(str(c.get(k, 0)) for k in labels), len(sub)))
    c = Counter(bucket(r) for r in rows)
    L.append("| **All** | %s | **%d** |" % (" | ".join("**%d**" % c.get(k, 0) for k in labels), len(rows)))
    ui = [r["id"] for r in rows if r["ui_evidence"]]
    L.append("")
    L.append("Rows with some UI observation recorded: %d%s." % (len(ui), (" (" + ", ".join(ui) + ")") if ui else ""))
    for ms, name in MILESTONES.items():
        sub = [r for r in rows if r["milestone"] == ms]
        if not sub:
            continue
        L.append("")
        L.append("## %s — %s" % (ms, name))
        L.append("")
        for k, label in labels.items():
            ids = [r for r in sub if bucket(r) == k]
            if not ids:
                continue
            if k == "external":
                by = OrderedDict()
                for r in ids:
                    key = "BLOCKED" if r["status"] == "BLOCKED" else "needs " + r["needs"] + " (" + NEEDS[r["needs"]] + ")"
                    by.setdefault(key, []).append(r["id"])
                L.append("- **%s** (%d): %s" % (label, len(ids), "; ".join("%s: %s" % (kk, ", ".join(v)) for kk, v in by.items())))
            else:
                L.append("- **%s** (%d): %s" % (label, len(ids), ", ".join(r["id"] for r in ids)))
    L.append("")
    return "\n".join(L)


def main():
    check = "--check" in sys.argv[1:]
    with open(JSON_PATH, encoding="utf-8") as f:
        rows = json.load(f)
    validate(rows)
    md = render(rows)
    ready = render_readiness(rows)
    if check:
        try:
            with open(READINESS_PATH, encoding="utf-8") as f:
                current_ready = f.read()
        except FileNotFoundError:
            current_ready = ""
        if current_ready != ready:
            sys.stderr.write("smart-map-matrix: %s is out of date; run scripts/smart-map-matrix.py\n" % READINESS_PATH)
            sys.exit(1)
        try:
            with open(MD_PATH, encoding="utf-8") as f:
                current = f.read()
        except FileNotFoundError:
            current = ""
        if current != md:
            sys.stderr.write("smart-map-matrix: %s is out of date; run scripts/smart-map-matrix.py\n" % MD_PATH)
            sys.exit(1)
        print("smart-map-matrix: up to date (%d tasks)" % len(rows))
        return
    with open(MD_PATH, "w", encoding="utf-8") as f:
        f.write(md)
    with open(READINESS_PATH, "w", encoding="utf-8") as f:
        f.write(ready)
    c = Counter(r["status"] for r in rows)
    print("smart-map-matrix: wrote %s (%d tasks: %s)" % (os.path.relpath(MD_PATH, ROOT), len(rows),
          ", ".join("%s %d" % (s, c[s]) for s in STATUSES if c.get(s))))


if __name__ == "__main__":
    main()

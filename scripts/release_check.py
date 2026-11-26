#!/usr/bin/env python3
"""Release-gate checker (autonomous completion mandate 2026-11-01, N1).

Reads the gate manifest and reports every gate as PASS, FAIL or OPEN. Exit 0 only when the manifest is
valid, names at least one gate, the candidate resolves to a real commit, and every required gate is PASS.
Any error — unreadable or malformed manifest, unknown kind, duplicate id, unreadable record, failed
subprocess launch — is a failure, never a silent success.

Gate kinds
  command   `run` is executed with bash from the repository root; exit 0 is PASS.
  evidence  `evidence` names a file with a line `Candidate: <full 40-hex commit>` equal to the candidate and no
            placeholder ("[owner:", TODO, TBD).
  artifact  release/artifacts/<id>.json: {"gate", "candidate" (full commit), "result": "pass", "artifacts":
            [{"path", "sha256"}], optional "external_ids"}. Every listed file must exist and match its digest.
            For results an automated run produces (archive, TestFlight install, StoreKit run): the record binds
            the result to files, not to prose that mentions a commit.
  human     release/approvals/<id>.md with exactly one each of `Decision:`, `By:`, `Role:`, `Date:` (YYYY-MM-DD)
            and `Commit:` (the full candidate). Decision must be exactly APPROVED, ACCEPTED or PASS — "NOT
            APPROVED", "FAILED", blanks and duplicates fail. Exact parsing does not authenticate a person; the
            record's provenance is reviewed separately. The checker never writes a record.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

KINDS = {"command", "evidence", "artifact", "human"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PLACEHOLDER_RE = re.compile(r"\[owner:|\bTODO\b|\bTBD\b|\bINCOMPLETE\b|\bNOT RUN\b")
DECISIONS = {"APPROVED", "ACCEPTED", "PASS"}
HUMAN_FIELDS = ("Decision", "By", "Role", "Date", "Commit")


class ManifestError(Exception):
    pass


def resolve_candidate(root, candidate):
    ref = candidate or "HEAD"
    try:
        out = subprocess.run(["git", "-C", root, "rev-parse", "--verify", "--quiet", ref + "^{commit}"],
                             capture_output=True, text=True, check=False)
    except OSError as e:
        raise ManifestError(f"git could not run: {e}")
    sha = out.stdout.strip()
    if out.returncode != 0 or not SHA_RE.match(sha):
        raise ManifestError(f"candidate {ref!r} does not resolve to a commit")
    return sha


def load_manifest(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, UnicodeDecodeError) as e:
        raise ManifestError(f"cannot read manifest {path}: {e}")
    except json.JSONDecodeError as e:
        raise ManifestError(f"manifest {path} is not valid JSON: {e}")
    if not isinstance(data, dict):
        raise ManifestError("manifest must be a JSON object")
    gates = data.get("gates")
    if not isinstance(gates, list) or not gates:
        raise ManifestError("manifest must have a non-empty \"gates\" list")
    seen = set()
    for i, g in enumerate(gates):
        if not isinstance(g, dict):
            raise ManifestError(f"gate #{i} is not an object")
        gid = g.get("id")
        if not isinstance(gid, str) or not ID_RE.match(gid):
            raise ManifestError(f"gate #{i} has no valid id")
        if gid in seen:
            raise ManifestError(f"duplicate gate id {gid}")
        seen.add(gid)
        kind = g.get("kind")
        if kind not in KINDS:
            raise ManifestError(f"gate {gid} has unknown kind {kind!r}")
        if not isinstance(g.get("title"), str) or not g["title"].strip():
            raise ManifestError(f"gate {gid} has no title")
        if "required" in g and not isinstance(g["required"], bool):
            raise ManifestError(f"gate {gid}: required must be true or false")
        if kind == "command" and (not isinstance(g.get("run"), str) or not g["run"].strip()):
            raise ManifestError(f"command gate {gid} has no run")
        if kind == "evidence" and (not isinstance(g.get("evidence"), str) or not g["evidence"].strip()):
            raise ManifestError(f"evidence gate {gid} names no file")
    required_ids = data.get("required_gate_ids", [])
    if not isinstance(required_ids, list) or not all(isinstance(x, str) for x in required_ids):
        raise ManifestError("required_gate_ids must be a list of ids")
    missing = [x for x in required_ids if x not in seen]
    if missing:
        raise ManifestError(f"manifest lacks required gates: {', '.join(missing)}")
    return gates


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def check_command(root, g):
    try:
        out = subprocess.run(["bash", "-c", g["run"]], cwd=root, capture_output=True, text=True, check=False)
    except OSError as e:
        return "FAIL", f"{g['run']} — could not run: {e}"
    if out.returncode == 0:
        return "PASS", g["run"]
    tail = ((out.stdout or "") + (out.stderr or "")).strip().splitlines()
    return "FAIL", f"{g['run']} — exit {out.returncode}: {(tail[-1] if tail else '')[:120]}"


def field_values(text, field):
    return [m.group(1).strip() for m in re.finditer(r"(?im)^\**" + re.escape(field) + r"\**\s*:\s*(.*)$", text)]


def check_evidence(root, g, sha):
    path = os.path.join(root, g["evidence"])
    if not os.path.isfile(path):
        return "OPEN", f"missing: {g['evidence']}"
    try:
        text = read_text(path)
    except (OSError, UnicodeDecodeError) as e:
        return "FAIL", f"{g['evidence']} unreadable: {e}"
    if PLACEHOLDER_RE.search(text):
        return "OPEN", f"{g['evidence']} has placeholders"
    cands = field_values(text, "Candidate")
    if len(cands) != 1:
        return "OPEN", f"{g['evidence']} needs exactly one 'Candidate: <full commit>' line (found {len(cands)})"
    if cands[0].strip("`").lower() != sha:
        return "OPEN", f"{g['evidence']} is for {cands[0][:12]}, not candidate {sha[:12]}"
    return "PASS", f"{g['evidence']} candidate {sha[:12]}"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def check_artifact(root, g, sha):
    rel = os.path.join("release", "artifacts", g["id"] + ".json")
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        return "OPEN", f"no artifact record: {rel}"
    try:
        rec = json.loads(read_text(path))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
        return "FAIL", f"{rel} unreadable: {e}"
    if not isinstance(rec, dict):
        return "FAIL", f"{rel} is not an object"
    if rec.get("gate") != g["id"]:
        return "FAIL", f"{rel} is for gate {rec.get('gate')!r}"
    if rec.get("candidate") != sha:
        return "OPEN", f"{rel} is for {str(rec.get('candidate'))[:12]}, not candidate {sha[:12]}"
    if rec.get("result") != "pass":
        return "FAIL", f"{rel} records result {rec.get('result')!r}"
    arts = rec.get("artifacts")
    if not isinstance(arts, list) or not arts:
        return "FAIL", f"{rel} lists no artifacts"
    for a in arts:
        if not isinstance(a, dict) or not isinstance(a.get("path"), str) or not isinstance(a.get("sha256"), str):
            return "FAIL", f"{rel} has a malformed artifact entry"
        apath = os.path.expanduser(a["path"])
        if not os.path.isabs(apath):
            apath = os.path.join(root, apath)
        if not os.path.isfile(apath):
            return "OPEN", f"{rel}: artifact not present here: {a['path']}"
        try:
            digest = sha256_file(apath)
        except OSError as e:
            return "FAIL", f"{rel}: cannot read {a['path']}: {e}"
        if digest != a["sha256"].lower():
            return "FAIL", f"{rel}: {a['path']} digest does not match the record"
    return "PASS", f"{rel} ({len(arts)} artifact(s) verified)"


def check_human(root, g, sha):
    rel = os.path.join("release", "approvals", g["id"] + ".md")
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        return "OPEN", f"no approval record: {rel}"
    try:
        text = read_text(path)
    except (OSError, UnicodeDecodeError) as e:
        return "FAIL", f"{rel} unreadable: {e}"
    if PLACEHOLDER_RE.search(text):
        return "OPEN", f"{rel} has placeholders"
    values = {}
    for f in HUMAN_FIELDS:
        v = field_values(text, f)
        if len(v) != 1:
            return "FAIL" if len(v) > 1 else "OPEN", f"{rel}: {f} appears {len(v)} times (exactly one required)"
        if not v[0].strip("*` "):
            return "OPEN", f"{rel}: {f} is blank"
        values[f] = v[0].strip("*` ")
    if values["Commit"].lower() != sha:
        return "OPEN", f"{rel} is for {values['Commit'][:12]}, not candidate {sha[:12]}"
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", values["Date"]):
        return "FAIL", f"{rel}: Date must be YYYY-MM-DD"
    if values["Decision"].upper() not in DECISIONS:
        return "FAIL", f"{rel} records no approval: Decision: {values['Decision'][:60]}"
    return "PASS", f"{rel} ({values['Decision'].upper()} by {values['By'][:40]})"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Release-gate checker")
    ap.add_argument("--candidate", default="")
    ap.add_argument("--manifest", default="ci/release-gates.json")
    ap.add_argument("--root", default=os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))
    args = ap.parse_args(argv)
    root = os.path.abspath(args.root)
    try:
        sha = resolve_candidate(root, args.candidate)
        gates = load_manifest(os.path.join(root, args.manifest))
    except ManifestError as e:
        print(f"RELEASE CHECK: ERROR — {e}. Nothing was checked; this is not a pass.")
        return 2
    checks = {"command": check_command, "evidence": check_evidence, "artifact": check_artifact, "human": check_human}
    counts = {"PASS": 0, "FAIL": 0, "OPEN": 0}
    blocking = 0
    print(f"{'GATE':36} {'RESULT':8} {'REQ':6} DETAIL")
    print(f"{'----':36} {'------':8} {'---':6} ------")
    for g in gates:
        kind = g["kind"]
        try:
            result, detail = checks[kind](root, g) if kind == "command" else checks[kind](root, g, sha)
        except Exception as e:  # any unexpected error is a failure of that gate, never a pass
            result, detail = "FAIL", f"checker error: {e}"
        required = g.get("required", True)
        counts[result] += 1
        if required and result != "PASS":
            blocking += 1
        print(f"{g['id']:36} {result:8} {str(required).lower():6} {detail}")
    print()
    print(f"candidate {sha} — {counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['OPEN']} OPEN")
    if blocking == 0 and counts["PASS"] > 0:
        print(f"RELEASE CHECK: every required gate passes for {sha[:12]}. READY FOR APP REVIEW only once the "
              "distribution-archive gate's build is the one uploaded.")
        return 0
    print(f"RELEASE CHECK: BLOCKED — {blocking} required gate(s) not passing. Each line names the remaining action.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

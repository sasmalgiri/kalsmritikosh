#!/usr/bin/env python3
"""Negative and positive fixtures for scripts/release_check.py (mandate 2026-11-01, N1).

Each case builds a throwaway git repository with its own manifest and records, runs the checker against
it and asserts the exit code. Nothing here touches the product's real release records.
"""
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import release_check  # noqa: E402


def git(root, *args):
    subprocess.run(["git", "-C", root, *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"})


class Fixture:
    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name
        git(self.root, "init", "-q")
        with open(os.path.join(self.root, "README"), "w") as f:
            f.write("x")
        git(self.root, "add", "README")
        git(self.root, "commit", "-q", "-m", "init")
        self.sha = subprocess.run(["git", "-C", self.root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        os.makedirs(os.path.join(self.root, "ci"))
        os.makedirs(os.path.join(self.root, "release", "approvals"))
        os.makedirs(os.path.join(self.root, "release", "artifacts"))

    def manifest(self, obj=None, raw=None):
        with open(os.path.join(self.root, "ci", "release-gates.json"), "w") as f:
            f.write(raw if raw is not None else json.dumps(obj))

    def write(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        return path

    def human(self, gid, decision="APPROVED", commit=None, extra=""):
        self.write(f"release/approvals/{gid}.md",
                   f"Decision: {decision}\nBy: A Reviewer\nRole: adjudicator\nDate: 2026-11-01\nCommit: {commit or self.sha}\n{extra}")

    def run(self, *extra):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = release_check.main(["--root", self.root, *extra])
        return code, buf.getvalue()

    def close(self):
        self.dir.cleanup()


def gate(gid, kind, **kw):
    return {"id": gid, "kind": kind, "title": gid, **kw}


class ReleaseCheckTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()

    def tearDown(self):
        self.f.close()

    # --- negative fixtures (each was a false PASS before N1) -----------------------------------------
    def test_not_approved_fails(self):
        self.f.manifest({"gates": [gate("review", "human")]})
        for d in ["NOT APPROVED", "NOT ACCEPTED", "FAILED", "rejected", "Approved with conditions"]:
            self.f.human("review", decision=d)
            code, out = self.f.run()
            self.assertEqual(code, 1, f"{d}: {out}")

    def test_blank_and_duplicate_decision_fail(self):
        self.f.manifest({"gates": [gate("review", "human")]})
        self.f.human("review", decision="")
        self.assertEqual(self.f.run()[0], 1)
        self.f.human("review", extra="Decision: APPROVED\n")  # a second Decision line
        self.assertEqual(self.f.run()[0], 1)

    def test_invalid_json_errors(self):
        self.f.manifest(raw="{not json")
        self.assertEqual(self.f.run()[0], 2)

    def test_missing_and_empty_gates_error(self):
        self.f.manifest({"version": 1})
        self.assertEqual(self.f.run()[0], 2)
        self.f.manifest({"gates": []})
        self.assertEqual(self.f.run()[0], 2)

    def test_unknown_kind_and_duplicate_ids_error(self):
        self.f.manifest({"gates": [gate("x", "magic")]})
        self.assertEqual(self.f.run()[0], 2)
        self.f.manifest({"gates": [gate("x", "command", run="true"), gate("x", "command", run="true")]})
        self.assertEqual(self.f.run()[0], 2)

    def test_required_gate_ids_must_exist(self):
        self.f.manifest({"required_gate_ids": ["ci", "archive"], "gates": [gate("ci", "command", run="true")]})
        self.assertEqual(self.f.run()[0], 2)

    def test_unresolvable_candidate_errors(self):
        self.f.manifest({"gates": [gate("ci", "command", run="true")]})
        self.assertEqual(self.f.run("--candidate", "deadbeef")[0], 2)

    def test_missing_manifest_errors(self):
        self.assertEqual(self.f.run()[0], 2)

    def test_short_hash_in_prose_is_not_the_candidate(self):
        self.f.manifest({"gates": [gate("packet", "evidence", evidence="docs/packet.md")]})
        self.f.write("docs/packet.md", f"Built on {self.f.sha[:8]} last week.\n")
        self.assertEqual(self.f.run()[0], 1)
        self.f.write("docs/packet.md", f"Candidate: {self.f.sha[:8]}\n")
        self.assertEqual(self.f.run()[0], 1)

    def test_human_record_for_another_commit_is_open(self):
        self.f.manifest({"gates": [gate("review", "human")]})
        self.f.human("review", commit="0" * 40)
        self.assertEqual(self.f.run()[0], 1)

    def test_artifact_digest_mismatch_fails(self):
        self.f.manifest({"gates": [gate("archive", "artifact")]})
        art = self.f.write("build/app.pkg", "binary")
        self.f.write("release/artifacts/archive.json", json.dumps(
            {"gate": "archive", "candidate": self.f.sha, "result": "pass", "artifacts": [{"path": "build/app.pkg", "sha256": "0" * 64}]}))
        self.assertEqual(self.f.run()[0], 1)
        self.f.write("release/artifacts/archive.json", json.dumps(
            {"gate": "archive", "candidate": self.f.sha, "result": "fail",
             "artifacts": [{"path": "build/app.pkg", "sha256": hashlib.sha256(open(art, "rb").read()).hexdigest()}]}))
        self.assertEqual(self.f.run()[0], 1)

    def test_failing_command_blocks(self):
        self.f.manifest({"gates": [gate("ci", "command", run="exit 3")]})
        self.assertEqual(self.f.run()[0], 1)

    # --- positive controls ----------------------------------------------------------------------------
    def test_every_kind_passing(self):
        self.f.manifest({"gates": [
            gate("ci", "command", run="true"),
            gate("packet", "evidence", evidence="docs/packet.md"),
            gate("archive", "artifact"),
            gate("review", "human"),
        ]})
        self.f.write("docs/packet.md", f"# Packet\nCandidate: {self.f.sha}\n")
        art = self.f.write("build/app.pkg", "binary")
        self.f.write("release/artifacts/archive.json", json.dumps(
            {"gate": "archive", "candidate": self.f.sha, "result": "pass",
             "artifacts": [{"path": "build/app.pkg", "sha256": hashlib.sha256(open(art, "rb").read()).hexdigest()}]}))
        self.f.human("review", decision="**APPROVED**")
        code, out = self.f.run()
        self.assertEqual(code, 0, out)

    def test_optional_gate_does_not_block(self):
        self.f.manifest({"gates": [gate("ci", "command", run="true"), gate("extra", "human", required=False)]})
        self.assertEqual(self.f.run()[0], 0)

    def test_the_shell_wrapper_propagates_failure(self):
        here = os.path.dirname(os.path.abspath(__file__))
        wrapper = os.path.join(here, "..", "release-check.sh")
        out = subprocess.run(["bash", wrapper, "--candidate", "not-a-commit"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 2, out.stdout + out.stderr)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""
pipeline-matrix.py — generate the authoritative producer/consumer/test matrix
for every table the schema declares.

WHY THIS IS A SCRIPT AND NOT A DOCUMENT. The repo already carried three
hand-written audits (ANALYSIS_ingest_to_answer.md, FULL_REPOSITORY_STATIC_AUDIT.md,
FILE_BY_FILE_AUDIT.csv). All three were accurate when written and all three are
now stale — they describe schema v103 and record every file as "unwired (no test
target)", which stopped being true once the suite grew to ~4,700 tests. A
narrative audit of a 206-table pipeline decays faster than anyone will rewrite
it, so this derives the facts from committed code on every run.

WHAT IT CAN AND CANNOT TELL YOU. It is a WIRING check, not a correctness check.
It answers "does anything write this table, does anything read it, does any test
mention it" — and nothing at all about whether the values written are right. A
table can be fully wired and fully wrong. Read the output as a map of where to
look, never as a verdict on behaviour.

Method: for every declared table, find each occurrence of the name as a word in
Swift source, then classify that occurrence by the SQL keyword nearest before it
in a bounded window. This catches SQL assembled by string interpolation, which a
plain "INSERT INTO <name>" regex misses.

Usage:  python3 scripts/pipeline-matrix.py [--out PIPELINE_MATRIX.md]
Exit 0 always; this reports, it does not gate.
"""

import argparse
import io
import os
import re
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = os.path.join(REPO, "Kalsmritikosh", "Storage", "Schema", "SchemaMigrations.swift")
SRC_ROOT = os.path.join(REPO, "Kalsmritikosh")
TEST_ROOT = os.path.join(REPO, "KalsmritikoshTests")

# A table name that only ever appears in these shapes is migration scratch:
# the v-suffixed copies a table rebuild creates. Legitimately write-only.
SCRATCH = re.compile(r"(__v\d+|_v\d+)$")

# Keywords are matched with WORD BOUNDARIES. The first version of this script
# used bare substring rfind and reported write-only = 0, which was provably
# false: `history_chapters` is inserted at HistoryArtifactRepository.swift:77
# and read nowhere. The cause was "IN" matching inside "INTO" — which sits
# AFTER "INSERT" in "INSERT INTO <table>" — so every insert was scored as a
# read and every producer vanished. "IN" and "EXISTS" are excluded entirely:
# they are too common in non-SQL Swift to carry signal.
WRITE_KEYWORDS = ("INSERT", "REPLACE", "UPDATE", "DELETE", "UPSERT")
SCHEMA_KEYWORDS = ("CREATE", "ALTER", "DROP")      # schema, not data production
READ_KEYWORDS = ("FROM", "JOIN", "SELECT")

# 60, not 240: real SQL puts the verb within ~20 chars of the table name
# ("FROM vectors", "INSERT INTO people ("). Every false positive found while
# calibrating this had its keyword 100+ chars away in unrelated prose.
WINDOW = 60


def declared_tables(schema_text):
    pat = r"CREATE\s+(?:VIRTUAL\s+)?TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+([a-z_][a-z0-9_]*)"
    return sorted(set(re.findall(pat, schema_text, re.I)))


def swift_files(root):
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith(".swift"):
                yield os.path.join(dirpath, f)


def load(paths):
    out = []
    for p in paths:
        try:
            out.append((p, io.open(p, encoding="utf-8", errors="ignore").read()))
        except OSError:
            pass
    return out


def lane_for(path):
    """The subsystem a producer lives in — taken from the directory, which is
    more honest than inferring a lane from the table's name."""
    rel = os.path.relpath(path, SRC_ROOT)
    parts = rel.split(os.sep)
    if len(parts) < 2:
        return "App"
    top = parts[0]
    if top in ("Ingestion", "Knowledge", "Brain", "Retrieval", "Storage",
               "Experts", "Routing", "UI", "App", "Core"):
        return top if len(parts) == 2 else "%s/%s" % (top, parts[1])
    return top


def _last_keyword(ctx):
    """The SQL verb nearest the END of `ctx`, matched on word boundaries and
    CASE-SENSITIVELY (uppercase only).

    Case is the discriminator that finally separated SQL from prose. This repo
    writes SQL keywords uppercase throughout, and English does not — so
    `Text("Browse the entities extracted from your files - people, ...")` no
    longer credits the `people` table with a reader, while `FROM people` still
    would. Proximity alone could not do it: lowercase "from" sits within 20
    chars of the word "people" in ordinary UI copy."""
    best_kw, best_pos = None, -1
    for kw in WRITE_KEYWORDS + SCHEMA_KEYWORDS + READ_KEYWORDS:
        for m in re.finditer(r"\b%s\b" % kw, ctx):
            if m.start() > best_pos:
                best_kw, best_pos = kw, m.start()
    return best_kw


COMMENT_LINE = re.compile(r"^\s*(//|///|\*|/\*)")
# Swift usage rather than SQL: a declaration, a member access, or a type
# annotation. Table names like `people`, `vectors`, `projects` and `chunks` are
# also ordinary identifiers and English words, so without this the scan credits
# a producer to any table whose NAME merely appears near a SQL keyword — which
# is the dangerous direction, because it makes dead tables look wired.
SWIFT_USAGE = re.compile(r"(let|var|self|private|public|func|\.|:)\s*$")


def classify_occurrences(table, text):
    """Return (writes, reads) counts for this table in this file."""
    writes = reads = 0
    for m in re.finditer(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(table), text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        line_end = text.find("\n", m.start())
        line = text[line_start:line_end if line_end != -1 else len(text)]
        # Prose, not SQL.
        if COMMENT_LINE.match(line):
            continue
        # An identifier, not a table reference.
        if SWIFT_USAGE.search(text[max(0, m.start() - 24):m.start()]):
            continue
        # Member access / call on a Swift value of the same name — UNLESS the
        # table name is immediately preceded by a SQL keyword.
        #
        # FALSE NEGATIVE THIS FIXES, and it was a costly one: FTS5 insert syntax
        # is `INSERT OR REPLACE INTO qa_pairs_fts(rowid, ...)`, where the table
        # name IS followed by `(`. Skipping on that made the scan report
        # qa_pairs_fts and synthetic_questions_fts as having NO PRODUCER, when
        # both repositories maintain them explicitly. Acting on that wrong
        # reading, I wrote a migration adding triggers ON TOP of the existing
        # inserts — which would have double-inserted every row into both
        # indexes. The scan's false negatives are more dangerous than its false
        # positives: a missing producer invites someone to add one.
        nextChar = text[m.end():m.end() + 1]
        if nextChar in (".", "("):
            before = text[max(0, m.start() - 24):m.start()]
            sqlPrefixed = re.search(r"\b(INTO|FROM|JOIN|UPDATE|TABLE)\s+$", before)
            if not sqlPrefixed:
                continue
        kw = _last_keyword(text[max(0, m.start() - WINDOW):m.start()])
        if kw is None or kw in SCHEMA_KEYWORDS:
            continue
        if kw in WRITE_KEYWORDS:
            writes += 1
        else:
            reads += 1
    return writes, reads


# Hand-verified ground truth. If the classifier disagrees with any of these the
# script REFUSES to write a matrix, because a wiring map that is quietly wrong
# is worse than none: it would retire exactly the questions it claims to answer.
SELF_CHECK = [
    # (table, expect_producer, expect_consumer, why)
    # RE-VERIFIED 2026-09-24. These were write-only when first hand-checked and
    # the expectations here said so. They are not any more: the
    # `.historyChapterReadback` module (P2.1/P2.5) added the readback, and the
    # boilerplate registry gained its query side. The classifier was RIGHT and
    # this list had gone stale — so the numbers below were updated against the
    # code rather than the classifier being "fixed" to agree with them.
    ("history_chapters", True, True,
     "INSERTed at HistoryArtifactRepository.swift:77; SELECTed at :318 and "
     "counted at :338 (chapter readback, P2.1)"),
    ("generic_facts", True, True, "written and read by GenericFactRepository"),
    ("chunks", True, True, "written at ingest, read by retrieval"),
    ("evidence_block_edges", False, False, "declared in schema only"),
    ("history_alternative_accounts", True, True,
     "DELETE at HistoryArtifactRepository.swift:202, SELECT at :232, COUNT at "
     ":254 (recorded disagreements, P2.5)"),
    # These three caught the scan over-counting. `people` and `vectors` occur
    # ONLY in comments, UI copy and Swift identifiers — verified by grepping
    # every occurrence — so crediting them a producer was a false positive.
    ("people", False, False, "occurs only in comments/UI copy; no SQL at all"),
    # CORRECTED: my first grep checked only for WRITERS, so "nothing reads it"
    # was overreach. A migration does `SELECT ... FROM vectors` to backfill
    # chunk_embeddings, so this is a LEGACY table deliberately kept as a
    # migration source — not dead schema.
    ("vectors", False, True,
     "no writer; read once by the migration that backfills chunk_embeddings"),
    ("boilerplate_uses", True, True,
     "INSERT OR IGNORE at BoilerplateRegistry.swift:92; SELECTed at :127/:137/"
     ":148/:159"),
]


def superseded_tables():
    """Table names from SupersededSchema.swift — the single declaration.

    Parsed rather than re-listed so this script and the app cannot disagree
    about which tables are intentionally empty. A mismatch there would be the
    worst kind: the matrix would call an intentional state a gap, or hide a real
    gap behind an intention that no longer exists.
    """
    path = os.path.join(SRC_ROOT, "Storage", "Schema", "SupersededSchema.swift")
    try:
        text = io.open(path, encoding="utf-8").read()
    except OSError:
        return set()
    return set(re.findall(r'Entry\(table:\s*"([^"]+)"', text))


def run_self_check(rows_by_table):
    failures = []
    for table, want_p, want_c, why in SELF_CHECK:
        r = rows_by_table.get(table)
        if r is None:
            failures.append("%s: not declared in the schema at all" % table)
            continue
        got_p, got_c = bool(r["producers"]), bool(r["consumers"])
        if got_p != want_p or got_c != want_c:
            failures.append(
                "%s: expected producer=%s consumer=%s, got producer=%s consumer=%s (%s)"
                % (table, want_p, want_c, got_p, got_c, why))
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="PIPELINE_MATRIX.md")
    args = ap.parse_args()

    schema_text = io.open(SCHEMA, encoding="utf-8", errors="ignore").read()
    tables = declared_tables(schema_text)

    src = load(swift_files(SRC_ROOT))
    tests = load(swift_files(TEST_ROOT)) if os.path.isdir(TEST_ROOT) else []

    rows = []
    for t in tables:
        producers, consumers, lanes = [], [], set()
        for path, text in src:
            if t not in text:
                continue
            w, r = classify_occurrences(t, text)
            rel = os.path.relpath(path, REPO)
            if w:
                producers.append(rel)
                lanes.add(lane_for(path))
            if r:
                consumers.append(rel)
        # TEST COVERAGE IS A PROXY, and the naive version of it lied. Tests
        # exercise a table through the REPOSITORY that owns it — the history
        # suite calls `gapCount`, never the string "history_gaps" — so matching
        # the table name alone reported well-tested tables as untested. Count a
        # table covered if a test mentions the table OR any type declared in a
        # file that writes it. Still a proxy: a test that merely constructs the
        # repository counts. It locates gaps; it does not prove coverage.
        owner_types = set()
        for prod in producers:
            ptext = next((tx for p, tx in src if os.path.relpath(p, REPO) == prod), "")
            owner_types.update(re.findall(
                r"\b(?:final\s+)?(?:public\s+)?(?:actor|class|struct|enum)\s+([A-Z][A-Za-z0-9_]*)",
                ptext))
        test_files = []
        for p, text in tests:
            if re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(t), text):
                test_files.append(os.path.basename(p))
                continue
            if any(re.search(r"\b%s\b" % ty, text) for ty in owner_types):
                test_files.append(os.path.basename(p))
        rows.append({
            "table": t,
            "scratch": bool(SCRATCH.search(t)),
            "producers": producers,
            "consumers": consumers,
            "tests": test_files,
            "lane": ", ".join(sorted(lanes)) if lanes else "—",
        })

    failures = run_self_check({r["table"]: r for r in rows})
    if failures:
        print("SELF-CHECK FAILED — refusing to write a matrix that disagrees with")
        # The message deliberately names BOTH directions. Its first version said
        # only "fix the classifier, not the expectations", which was true when
        # written and wrong the first time it fired: three tables had genuinely
        # gained readers and the expectations were the stale side. Naming one
        # culprit in advance is the same prejudging this check exists to prevent.
        print("hand-verified ground truth. EITHER the classifier is wrong, OR")
        print("the code changed and these expectations are stale. Read the code")
        print("at the cited lines and decide which — do not edit either to agree.\n")
        for f in failures:
            print("  ✗ %s" % f)
        return 2
    print("self-check: %d/%d hand-verified cases agree\n" % (len(SELF_CHECK), len(SELF_CHECK)))

    real = [r for r in rows if not r["scratch"]]

    # Tables with no producer BY DESIGN, parsed from the Swift registry rather
    # than duplicated here. Reported as their own category because lumping them
    # into "no producer" invites the obvious and WRONG fix — writing a producer
    # for each, which would fork the truth for data the universal model already
    # holds. The list is read from code so the two cannot drift.
    superseded = superseded_tables()
    no_producer = [r for r in real
                   if not r["producers"] and r["table"] not in superseded]
    superseded_rows = [r for r in real if r["table"] in superseded]
    write_only = [r for r in real if r["producers"] and not r["consumers"]]
    untested = [r for r in real if r["producers"] and not r["tests"]]

    # ---- report ----
    out = []
    out.append("# PIPELINE_MATRIX — generated, do not hand-edit\n")
    out.append("Regenerate with `python3 scripts/pipeline-matrix.py`.\n")
    out.append("\n> **This is a WIRING map, not a correctness verdict.** It reports whether\n"
               "> anything writes a table, anything reads it, and any test mentions it. It\n"
               "> says nothing about whether the values written are correct. A table can be\n"
               "> fully wired and fully wrong. Use it to decide where to look.\n")
    out.append("\n## Summary\n")
    out.append("| metric | count |")
    out.append("|---|---|")
    out.append("| tables declared | %d |" % len(rows))
    out.append("| migration-scratch (legitimately write-only) | %d |" % (len(rows) - len(real)))
    out.append("| real tables | %d |" % len(real))
    out.append("| **no producer** (nothing writes it) | **%d** |" % len(no_producer))
    out.append("| no producer BY DESIGN (superseded, kept empty) | %d |" % len(superseded_rows))
    out.append("| **written but never read** | **%d** |" % len(write_only))
    out.append("| **has a producer but NO test mentions it** | **%d** |" % len(untested))

    for title, group, note in (
        ("No producer — nothing writes these", no_producer,
         "Dead schema, or a feature whose persistence was never wired. "
         "Tables that are empty BY DESIGN are listed separately below and are "
         "NOT in this count."),
        ("No producer BY DESIGN — superseded, verified empty", superseded_rows,
         "Kept for compatibility; the data lives in the universal model and the "
         "live UI already reads it there. Writing these would create a second "
         "source of truth. See Kalsmritikosh/Storage/Schema/SupersededSchema.swift "
         "for what supersedes each and which surface reads the replacement."),
        ("Written but never read", write_only,
         "The write costs time on the hot path and influences nothing."),
        ("Produced but no test mentions the table", untested,
         "The verification gap. Highest-value list in this file."),
    ):
        out.append("\n## %s (%d)\n" % (title, len(group)))
        out.append("_%s_\n" % note)
        if not group:
            out.append("None.\n")
            continue
        out.append("| table | lane | producer |")
        out.append("|---|---|---|")
        for r in group:
            out.append("| `%s` | %s | %s |" % (
                r["table"], r["lane"],
                (r["producers"][0] if r["producers"] else "—")))

    out.append("\n## Full matrix\n")
    out.append("| table | lane | producers | consumers | tests |")
    out.append("|---|---|---|---|---|")
    for r in sorted(rows, key=lambda x: (x["lane"], x["table"])):
        out.append("| `%s`%s | %s | %d | %d | %d |" % (
            r["table"], " _(scratch)_" if r["scratch"] else "",
            r["lane"], len(r["producers"]), len(r["consumers"]), len(r["tests"])))

    text = "\n".join(out) + "\n"
    io.open(os.path.join(REPO, args.out), "w", encoding="utf-8").write(text)

    # terminal summary only — the file carries the detail
    print("tables declared : %d (%d real, %d scratch)" % (len(rows), len(real), len(rows) - len(real)))
    print("no producer     : %d" % len(no_producer))
    print("write-only      : %d" % len(write_only))
    print("produced, untested: %d" % len(untested))
    print("\nwrote %s" % args.out)
    print("\n-- produced but NO test mentions the table --")
    for r in untested:
        print("   %-42s %s" % (r["table"], r["lane"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

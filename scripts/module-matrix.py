#!/usr/bin/env python3
"""
module-matrix.py — generate MODULE_MATRIX.md from the KnowledgeModule enum.

WHY GENERATED. The owner's requirement is that every new capability ships behind
its own switch "so each can live without any risk". That promise is only real if
you can SEE, per module, that a gate actually exists in the code. A
hand-maintained table would claim gates that were never wired — the same
absence-rendered-as-verification failure this project keeps closing. So the
matrix is derived from the enum, and the WIRED column is derived from a grep for
`isEnabled(.case)` in non-test source.

A module that appears in the switchboard with no `isEnabled` call anywhere is
reported as NOT WIRED: its switch is decorative, and flipping it would change
nothing. That is the single most useful column here.

Usage:  python3 scripts/module-matrix.py [--out MODULE_MATRIX.md]
"""

import argparse
import io
import os
import re
import sys
from collections import OrderedDict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENUM = os.path.join(REPO, "Kalsmritikosh", "Knowledge", "Modules", "KnowledgeModule.swift")
SRC = os.path.join(REPO, "Kalsmritikosh")
TESTS = os.path.join(REPO, "KalsmritikoshTests")


def enum_cases(text):
    """Declaration order, which is the order the switchboard presents."""
    body = text.split("public enum KnowledgeModule", 1)[1]
    body = body.split("public var id:", 1)[0]
    return [m.group(1) for m in re.finditer(r"^\s*case\s+([a-zA-Z][A-Za-z0-9_]*)", body, re.M)]


def switch_map(text, prop):
    """Map case -> returned string for a `public var <prop>` switch."""
    i = text.find("public var %s:" % prop)
    if i < 0:
        return {}
    seg = text[i:]
    # end at the next `public var` / `public func` / `fileprivate`
    ends = [seg.find("\n    public var ", 10), seg.find("\n    public func ", 10),
            seg.find("\n    fileprivate ", 10)]
    ends = [e for e in ends if e > 0]
    if ends:
        seg = seg[:min(ends)]
    out = {}
    for m in re.finditer(r"case\s+((?:\.[a-zA-Z0-9_]+\s*,?\s*)+):\s*return\s+\"((?:[^\"\\]|\\.)*)\"", seg):
        value = m.group(2)
        for c in re.findall(r"\.([a-zA-Z0-9_]+)", m.group(1)):
            out[c] = value
    return out


def case_list_for(text, prop, needle="return true"):
    """Cases appearing in a boolean switch branch that yields `needle`."""
    i = text.find("public var %s:" % prop)
    if i < 0:
        return set()
    seg = text[i:i + 2500]
    out = set()
    for m in re.finditer(r"case\s+((?:\.[a-zA-Z0-9_]+\s*,?\s*\n?\s*)+):\s*\n?\s*" + re.escape(needle), seg):
        out.update(re.findall(r"\.([a-zA-Z0-9_]+)", m.group(1)))
    return out


def swift_files(root):
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(".swift"):
                yield os.path.join(d, f)


def wiring(cases):
    """case -> [file:line] where `isEnabled(.case)` appears in non-test source."""
    hits = {c: [] for c in cases}
    for path in swift_files(SRC):
        if path == ENUM:
            continue
        try:
            lines = io.open(path, encoding="utf-8", errors="ignore").read().split("\n")
        except OSError:
            continue
        rel = os.path.relpath(path, REPO)
        for n, line in enumerate(lines, 1):
            t = line.strip()
            if t.startswith("//"):
                continue
            for c in cases:
                if "isEnabled(.%s)" % c in line:
                    hits[c].append("%s:%d" % (rel, n))
    return hits


TYPE_DECL = re.compile(
    r"^(?:public |internal |package |final |nonisolated |@MainActor )*"
    r"(?:enum|struct|class|actor)\s+([A-Za-z_]\w*)")
FUNC_DECL = re.compile(
    r"^\s*(?:@MainActor\s+)?(?:public |internal |private |fileprivate |package )?"
    r"(?:nonisolated )?static\s+func\s+([A-Za-z_]\w*)")


def gate_hosts(hits):
    """For each `isEnabled` hit, the (Type, staticFunc) that encloses it — when
    that is determinable. Only STATIC members of a NAMED TYPE are reported,
    because only those have a call form that MUST name the type.

    This is the F-3 lesson made structural. Grepping a name can never prove a
    thing IS called (F-3: the call site was `synthRepo.search(...)`, so grepping
    `syntheticQuestions?.search` found nothing and I wrongly declared the lane
    dead). But for `Type.staticFunc(...)` the type name is mandatory at every
    external call site, so ZERO hits IS a proof of no external caller. The
    asymmetry is the whole point: this function is used only to prove absence,
    never presence.
    """
    out = {}
    for case, locs in hits.items():
        found = []
        for loc in locs:
            rel, lineno = loc.rsplit(":", 1)
            path = os.path.join(REPO, rel)
            try:
                lines = io.open(path, encoding="utf-8", errors="ignore").read().split("\n")
            except OSError:
                continue
            i = int(lineno) - 1
            fn = None
            for j in range(i, -1, -1):
                m = FUNC_DECL.match(lines[j])
                if m:
                    fn = m.group(1)
                    break
                # A non-static func encloses it — not soundly checkable.
                if re.match(r"^\s*(?:@MainActor\s+)?(?:public |internal |private |fileprivate )?func\s", lines[j]):
                    break
            if not fn:
                continue
            ty = None
            for j in range(i, -1, -1):
                m = TYPE_DECL.match(lines[j])
                if m:
                    ty = m.group(1)
                    break
            if ty:
                found.append((rel, ty, fn))
        if found:
            out[case] = found
    return out


def callers(rel, ty, fn):
    """Every non-test call site of `Type.fn` / `Self.fn` / in-type `fn(`.

    DELIBERATELY ERRS TOWARD FINDING A CALLER. The first version of this skipped
    the declaring file and matched only `Type.fn`, and it flagged three live
    modules as callerless — `crossEncoderRerank`, `correctiveRetrieval` and
    `openFieldAsking` are all reached, via `Self.reranked(...)`,
    `Self.applyCorrectiveRetrieval(...)` and an unqualified in-type call
    respectively. Every one of those was a false accusation of dead code, which
    is the more damaging direction of error: it invites deleting or "fixing"
    something that works.

    So: qualified calls are matched repo-wide, and `Self.`/bare calls are
    matched inside the declaring file only — bounding the bare-name ambiguity
    (a name like `build` is far too common to grep globally) while still
    catching the in-type call. A hit inside the declaring type does not settle
    reachability on its own; it moves the question up to that caller, which is
    a real answer and not a callerless entry point.
    """
    qualified = re.compile(r"\b(?:%s|Self)\s*\.\s*%s\s*\(" % (re.escape(ty), re.escape(fn)))
    bare = re.compile(r"(?<![\w.])%s\s*\(" % re.escape(fn))
    declaring = os.path.realpath(os.path.join(REPO, rel))
    hits = []
    for path in swift_files(SRC):
        is_declaring = os.path.realpath(path) == declaring
        try:
            lines = io.open(path, encoding="utf-8", errors="ignore").read().split("\n")
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            t = line.strip()
            if t.startswith("//") or t.startswith("*"):
                continue
            if re.search(r"\bfunc\s+%s\b" % re.escape(fn), line):
                continue   # the declaration itself is not a call
            if qualified.search(line) or (is_declaring and bare.search(line)):
                hits.append("%s:%d" % (os.path.relpath(path, REPO), n))
    return hits


def test_refs(cases):
    hits = {c: 0 for c in cases}
    if not os.path.isdir(TESTS):
        return hits
    for path in swift_files(TESTS):
        try:
            text = io.open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for c in cases:
            if re.search(r"\.%s\b" % re.escape(c), text):
                hits[c] += 1
    return hits


# Hand-verified ground truth for the no-caller check, kept as a self-check so
# the tool cannot regress into accusing live code of being dead. The first three
# are the exact false positives the first implementation produced; each was
# verified by reading the call site. `must_be_callerless` are the two P3.5/P3.6
# report entry points whose consumer (the P4 Ingestion Report) is not built yet.
MUST_HAVE_CALLER = {
    "crossEncoderRerank":  "HybridRetriever.swift:1195 — `await Self.reranked(`",
    "correctiveRetrieval": "MasterBrain.swift:1681 — `await Self.applyCorrectiveRetrieval(`",
    "openFieldAsking":     "SlotFieldResolver.swift:333 — unqualified in-type call",
}
# Emptied 2026-09-24: P4 landed, and both entries' consumer now exists —
# DataHealthCheck.swift:501 calls `UniversalParserRegistryBuilder.coverageReport`
# and :512 calls `ExtractionLanguageReport.build`. Verified by reading both call
# sites, not by deleting the expectation to make the check pass. The check
# refused to write the matrix until this was resolved, which is the behaviour
# that was wanted: a producer waiting on its consumer stays visible until the
# consumer is genuinely there.
MUST_BE_CALLERLESS: dict[str, str] = {}


def self_check(no_caller, cases):
    """Refuse to emit a matrix that disagrees with hand-verified reachability."""
    problems = []
    for c, why in MUST_HAVE_CALLER.items():
        if c not in cases:
            continue   # module legitimately removed; not this check's business
        if c in no_caller:
            problems.append("FALSE POSITIVE: `%s` is reported callerless but IS called — %s"
                            % (c, why))
    for c, why in MUST_BE_CALLERLESS.items():
        if c not in cases:
            continue
        if c not in no_caller:
            problems.append("STALE EXPECTATION: `%s` was recorded as having no caller (%s) "
                            "but one now exists — verify it, then remove it from "
                            "MUST_BE_CALLERLESS." % (c, why))
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="MODULE_MATRIX.md")
    args = ap.parse_args()

    text = io.open(ENUM, encoding="utf-8", errors="ignore").read()
    cases = enum_cases(text)
    titles = switch_map(text, "title")
    groups = switch_map(text, "group")
    implemented = case_list_for(text, "implemented")
    requires_ai = case_list_for(text, "requiresAI")
    default_off = case_list_for(text, "defaultEnabled", "return false")
    wired = wiring(cases)
    tested = test_refs(cases)

    by_group = OrderedDict()
    for c in cases:
        by_group.setdefault(groups.get(c, "—"), []).append(c)

    unwired = [c for c in cases if c in implemented and not wired[c]]

    # A gate can exist and still be unreachable: the flag is consulted inside a
    # function nothing calls. That is a DIFFERENT defect from a decorative
    # switch and it needs its own column, because "wired" was quietly reading as
    # "live" — which is how P3.5/P3.6 first showed up here as 0 NOT WIRED while
    # nothing on any production path reached either report.
    hosts = gate_hosts(wired)
    no_caller = {}
    for c, found in hosts.items():
        if c in [x for x in cases if x not in implemented]:
            continue
        details = []
        for rel, ty, fn in found:
            if not callers(rel, ty, fn):
                details.append("%s.%s" % (ty, fn))
        # Only flag when EVERY determinable gate host for the module is
        # callerless. One reached gate is enough for the module to be live.
        if details and len(details) == len(found):
            no_caller[c] = details

    problems = self_check(no_caller, cases)
    if problems:
        sys.stderr.write("SELF-CHECK FAILED — matrix NOT written:\n")
        for p in problems:
            sys.stderr.write("  %s\n" % p)
        return 2


    o = []
    o.append("# MODULE_MATRIX — every switchable capability\n")
    o.append("Generated by `python3 scripts/module-matrix.py`. Do not hand-edit.\n")
    o.append("\nThe owner's requirement is that each capability ships behind its own switch\n"
             "so it can live — or be turned off — without risk to the rest. This table is\n"
             "derived from the `KnowledgeModule` enum, and the **Wired** column is derived\n"
             "from a grep for `isEnabled(.case)` in non-test source.\n")
    o.append("\n> **The column that matters is Wired.** A module listed in the switchboard\n"
             "> with no `isEnabled` call anywhere has a DECORATIVE switch: flipping it\n"
             "> changes nothing. A hand-written table would have claimed the gate existed.\n")

    o.append("\n## Summary\n")
    o.append("| metric | count |")
    o.append("|---|---|")
    o.append("| modules declared | %d |" % len(cases))
    o.append("| implemented | %d |" % len(implemented))
    o.append("| **implemented but NOT WIRED** | **%d** |" % len(unwired))
    o.append("| default OFF (opt-in) | %d |" % len(default_off))
    o.append("| require the on-device model | %d |" % len(requires_ai))
    o.append("| referenced by a test | %d |" % sum(1 for c in cases if tested[c]))
    o.append("| **gated but NO CALLER yet** | **%d** |" % len(no_caller))

    if no_caller:
        o.append("\n## ⏳ Gated, but nothing calls the gated entry point (%d)\n" % len(no_caller))
        o.append("The switch is real and the code behind it is real, but no production\n"
                 "surface reaches it yet — so flipping the switch changes nothing TODAY.\n"
                 "This is not the same defect as a decorative switch, and it is not\n"
                 "necessarily a defect at all: a producer can legitimately land before its\n"
                 "consumer. It is listed so that \"wired\" is never read as \"live\".\n")
        o.append("\n| module | callerless entry point | consumer owed |")
        o.append("|---|---|---|")
        for c, details in no_caller.items():
            o.append("| `%s` | `%s` | — |" % (c, "`, `".join(details)))
        o.append("\nSOUNDNESS. This list proves ABSENCE only. It is computed for `static`\n"
                 "members of named types, where every external call site must write\n"
                 "`Type.member`, so zero matches is a proof of no external caller. The\n"
                 "converse is NOT claimed: a module absent from this list has not been\n"
                 "proven reachable. Grepping a name cannot establish that a thing is\n"
                 "called — a lesson from finding F-3, where a lane was wrongly declared\n"
                 "dead because its call site read `synthRepo.search(...)` rather than\n"
                 "naming the property that was grepped.\n")

    if unwired:
        o.append("\n## ⚠️ Decorative switches — implemented, but no gate found (%d)\n" % len(unwired))
        o.append("| module | title |")
        o.append("|---|---|")
        for c in unwired:
            o.append("| `%s` | %s |" % (c, titles.get(c, "")))
        o.append("\nEither gate the code path with `KnowledgeModuleFlags.isEnabled(.<case>)`,\n"
                 "or set `implemented = false` until it is wired.\n")

    for group, members in by_group.items():
        o.append("\n## %s\n" % group)
        o.append("| module | default | AI? | wired at | tests |")
        o.append("|---|---|---|---|---|")
        for c in members:
            if c not in implemented:
                default = "unimplemented"
            else:
                default = "OFF (opt-in)" if c in default_off else "ON"
            where = wired[c][0] if wired[c] else "**not wired**"
            if len(wired[c]) > 1:
                where += " (+%d more)" % (len(wired[c]) - 1)
            o.append("| `%s` — %s | %s | %s | %s | %d |" % (
                c, titles.get(c, ""), default,
                "yes" if c in requires_ai else "—", where, tested[c]))

    o.append("\n## How to add one\n")
    o.append("1. add a `case` to `KnowledgeModule` with title / detail / group;\n"
             "2. gate the code path with `KnowledgeModuleFlags.isEnabled(.yourCase)`;\n"
             "3. it auto-appears in Settings → Modules and in this matrix.\n")
    o.append("\nGate ONCE, as low as possible. The Phase-1 failure recorder is gated inside\n"
             "`DerivationFailureRepository.record` rather than at its twelve call sites, so\n"
             "the switch cannot be honoured in some paths and forgotten in others.\n")
    o.append("\n## What must NOT become a switch\n")
    o.append("A correctness fix is not a module. The entity-insert cascade (P1.1) is gated\n"
             "by `strictDerivation`, but BOTH of its states are non-corrupting — the switch\n"
             "chooses HOW to degrade (abort the file, or skip only the dependent step),\n"
             "never whether to write wrong data. Offering the old swallow-and-continue\n"
             "behaviour as an option would be offering ledger corruption as a preference.\n")

    io.open(os.path.join(REPO, args.out), "w", encoding="utf-8").write("\n".join(o) + "\n")
    print("modules: %d declared, %d implemented, %d NOT WIRED, %d gated-but-no-caller" % (
        len(cases), len(implemented), len(unwired), len(no_caller)))
    for c in unwired:
        print("   not wired: %s" % c)
    for c, details in no_caller.items():
        print("   no caller: %s (%s)" % (c, ", ".join(details)))
    print("\nwrote %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
# RC-8 Language Contract guard. User-facing strings speak plain language:
# model/retrieval jargon (LLM, reranker, cross-encoder, "retrieval layer",
# FTS) may not appear inside string literals in UI sources. Developer
# diagnostics that legitimately show these terms carry an explicit inline
# waiver:  // jargon-ok: <why>   — the waiver is visible in review, so
# jargon can never drift into user copy silently.
set -uo pipefail
FAIL=0
HITS=$(grep -rn '"[^"]*\(LLM\|reranker\|cross-encoder\|retrieval layer\|FTS5\)[^"]*"' \
    Kalsmritikosh/UI/*.swift 2>/dev/null | grep -v "jargon-ok" | grep -v '^[^:]*:[0-9]*:[[:space:]]*//' || true)
# SPEC A1.3 — the fact-spam frame is BANNED everywhere an answer is composed
# (Brain + UI): "Reported:" may never open a rendered sentence again. The
# detector constant that recognizes legacy frames carries the waiver.
REPORTED=$(grep -rn '"Reported:' Kalsmritikosh/UI/*.swift Kalsmritikosh/Brain/*.swift 2>/dev/null \
    | grep -v "jargon-ok" | grep -v '^[^:]*:[0-9]*:[[:space:]]*//' || true)
if [ -n "$REPORTED" ]; then
  echo "::error::RC-8: the banned 'Reported:' frame appears in composed strings:"
  echo "$REPORTED" | cut -c1-160
  FAIL=1
fi
if [ -n "$HITS" ]; then
  echo "::error::RC-8 language contract: jargon in user-facing strings (add plain language, or '// jargon-ok: <why>' for developer diagnostics):"
  echo "$HITS" | cut -c1-160
  FAIL=1
fi
if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "UI language contract clean (jargon only behind explicit waivers)."

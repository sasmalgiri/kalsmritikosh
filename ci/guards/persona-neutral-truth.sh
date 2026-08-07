#!/usr/bin/env bash
# T1 truth-invariance guard (macro F): persona is PRESENTATION ONLY. The
# evidence/answer layers must never reference a persona/shell type — if they
# could branch on persona, persona choice could alter truth. Verified clean at
# introduction (2026-08-07); this keeps it that way. Comment-only lines are
# allowed. PersonaPolicy itself lives in Knowledge/Ontology (it is the
# presentation vocabulary definition), so Knowledge/Ontology is excluded while
# the rest of Knowledge/ is enforced. WorkspaceRepository is excluded because
# it PERSISTS the workspace row (whose template field is the stored
# presentation setting) — storing the setting is not branching on it.
set -uo pipefail
MATCHES=$(grep -rnE "PersonaRoutingContext|PersonaRoutingCatalog|ShellAnswerMode|ShellSurface|PersonaJob|WorkspaceTemplate" \
  Kalsmritikosh/Brain/ \
  Kalsmritikosh/Retrieval/ \
  Kalsmritikosh/Storage/Repositories/ \
  Kalsmritikosh/Knowledge/ \
  --include="*.swift" 2>/dev/null \
  | grep -vE "^Kalsmritikosh/Knowledge/Ontology/" \
  | grep -vE "^Kalsmritikosh/Storage/Repositories/WorkspaceRepository\.swift:" \
  | grep -vE ':[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
if [ -n "$MATCHES" ]; then
  echo "::error::Persona-neutral-truth guard failed — persona/shell types referenced in an evidence/answer layer (persona could alter truth)"
  echo "$MATCHES"
  exit 1
fi
echo "Persona-neutral-truth guard clean (evidence layers reference no persona/shell types)."

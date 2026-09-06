#!/usr/bin/env bash
# SPEC A1.4 — THE REACHABILITY GUARD (the W-4b lesson made permanent).
# Tested machinery is worthless if the app never calls it: the ledger drain
# shipped green for weeks with zero app callers. Every symbol in the
# manifest below must be referenced from APP code outside its own defining
# file (tests don't count — tests were exactly what hid W-4b).
set -uo pipefail
cd "$(dirname "$0")/../.."
FAIL=0
# symbol | defining-file suffix (excluded from the count)
MANIFEST="
LedgerDrainCoordinator|LedgerDrainCoordinator.swift
ChunkReindexCoordinator|ChunkReindexCoordinator.swift
TermSalienceComputer|TermSalienceComputer.swift
TopicTreeBuilder|TopicTreeBuilder.swift
EntityPlausibilityTwin|EntityPlausibilityTwin.swift
EventRecordTwin|EventRecordTwin.swift
PlacementTwin|PlacementTwin.swift
GapLeadFinder|GapLeadFinder.swift
GeneralKnowledgeLane|GeneralKnowledgeLane.swift
ComposeTwinRunner|ComposeTwin.swift
SentenceQuoteComposer|SentenceQuoteComposer.swift
EventAnswerComposer|EventAnswerComposer.swift
SubjectResolver|SubjectResolver.swift
HistoryReconstructionEngine|HistoryReconstructionEngine.swift
setStoryComposer|MasterBrain.swift
listBigPicture|TopicRetriever.swift
storySourceContext|KnowledgeObjectRepository.swift
findByTitleTokens|EventsRepository.swift
"
while IFS='|' read -r sym def; do
  [ -z "$sym" ] && continue
  refs=$(grep -rl "$sym" Kalsmritikosh --include="*.swift" | grep -v "/$def" | wc -l | xargs)
  if [ "$refs" -eq 0 ]; then
    echo "::error::Reachability: $sym has ZERO app callers (defined in $def, referenced nowhere else) — tested code the app never runs"
    FAIL=1
  fi
done <<< "$MANIFEST"
if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "Reachability: every manifest symbol has an app caller."

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
SpanCutter|SpanCutter.swift
LedgerTools|LedgerTools.swift
ToolGroundedComposer|ToolGroundedComposer.swift
EmailParticipantBackfill|EmailParticipantBackfill.swift
LedgerContractCheck|LedgerContractCheck.swift
composeSubjectEventAnswer|AppState+SubjectFirst.swift
"
while IFS='|' read -r sym def; do
  [ -z "$sym" ] && continue
  refs=$(grep -rl "$sym" Kalsmritikosh --include="*.swift" | grep -v "/$def" | wc -l | xargs)
  if [ "$refs" -eq 0 ]; then
    echo "::error::Reachability: $sym has ZERO app callers (defined in $def, referenced nowhere else) — tested code the app never runs"
    FAIL=1
  fi
done <<< "$MANIFEST"

# U-6 (SPEC A1) — THE ANSWER-PATH CONSUMERS LEG. A composer/tool with an
# app caller can still be a dead end if nothing on the ANSWER PATH invokes
# it. Each answer-path producer below must be referenced by its named
# CONSUMER file — the "tree-builder-without-resolver" case fails CI.
# (DB-mediated background producers — TopicTreeBuilder, TermSalienceComputer
# — communicate through tables, not symbols, and are covered by the callers
# leg above; they are intentionally not symbol-paired here.)
# Format: producer-symbol | consumer-file-suffix.
CONSUMERS="
LedgerTools|AppState.swift
ToolGroundedComposer|AppState.swift
CausalLinkPolicy|RuleBasedNarrativeComposer.swift
EventAnswerComposer|EvidenceVerifier.swift
SpanCutter|LedgerTools.swift
SubjectResolver|EvidenceVerifier.swift
"
while IFS='|' read -r prod consumer; do
  [ -z "$prod" ] && continue
  hits=$(grep -rl "$prod" Kalsmritikosh --include="*.swift" | grep "/$consumer" | wc -l | xargs)
  if [ "$hits" -eq 0 ]; then
    echo "::error::Reachability(answer-path): $prod is not consumed by $consumer — a producer with no answer-path consumer is a dead end"
    FAIL=1
  fi
done <<< "$CONSUMERS"

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "Reachability: every manifest symbol has an app caller AND an answer-path consumer."

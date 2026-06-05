# CLAUDE.md — kalsmritikosh (formerly Atlas Chronica Memora)

You are working on **kalsmritikosh**, a macOS-native private knowledge system. It ingests
a user's entire document/email archive in place, builds a structured ledger (entities,
dated events, timeline, relationships, distilled memory), and answers questions through
specialist experts behind an evidence gate — fully on-device.

This is NOT a chat-with-files RAG app. The intelligence lives in the database, not the model.

## Prime directive
Execute the tasks in `TASKS.md`, strictly in order, **one task per session**.
Do not start a task without reading its full spec. Do not do work outside the task's scope.
When the task's acceptance checks pass, commit and stop.

## Build & verify ritual (run after EVERY task, before commit)
1. Build the `BuildProject` scheme — must be green.
2. Grep guard — must return NOTHING:
   `grep -rniE "qwen|gemma|deepseek|llama|mistral|nomic|gpt" Experts/ Brain/ Knowledge/ Retrieval/ Ingestion/`
3. Run the in-app SmokeTest against the ProjectDelta fixture (Resources/Fixtures/ProjectDelta).
4. Run the task's own acceptance checks (listed per task).
Commit message format: `T<n>: <task title>`.

## Architecture invariants — NEVER violate, NEVER "improve"
- **Capability discipline.** No model names anywhere in Experts/, Brain/, Knowledge/,
  Retrieval/, Ingestion/. Experts ask `context.capabilities.resolve(spec)` for
  reasoning/summarization/extraction. Model names live ONLY in Routing/Providers,
  ModelManifest, AppState, SettingsView.
- **One ledger.** Single SQLite database behind the `actor Database`
  (Storage/Database/DatabaseStack.swift). The raw sqlite3 pointer never escapes the actor.
  All access through the repository classes in Storage/Repositories/.
- **Experts are stateless.** They read the ledger at question time via HybridRetriever
  and return ExpertFindings. They never persist, cache, or own data.
- **Formats die at ingestion.** Everything becomes a KnowledgeObject + chunks + entities
  + events. Nothing in Brain/Knowledge/Retrieval may branch on file type.
- **Privacy is enforced, not promised.** PrivacyGate filters cloud providers out of
  capability resolution. Never add a network call outside Routing/Providers.
- **Retrieval priority.** Memory → Timeline → Entity → FTS/metadata → Summary → Graph →
  Vector. Structure answers first; similarity is the last resort, not the first.
- **Schema changes** only via a new versioned migration wrapped in SAVEPOINT
  (see Storage/Schema/). Never edit a shipped migration.

## Mental model glossary
- **KnowledgeObject (KO):** normalized unit of ingested content, format-agnostic.
- **Ledger:** the whole structured store — canonical entities (+aliases), mentions,
  dated events, relationships, MemoryObjects (+MemoryChange log), summaries, chunks,
  FTS, vectors. Every fact carries source IDs, a date, and a confidence.
- **Enrichment ladder:** Tier 0 parse (seconds) → Tier 1 structure (minutes) →
  Tier 2 deepen: vectors + LLM extraction (background) → Tier 3 deep study (on demand).
- **Canonical entity vs mention:** a mention is a name occurring in one document;
  a canonical entity is the real-world thing, unified across documents via aliases.
- **Claim–evidence contract:** every expert claim must carry the specific evidence IDs
  that support it, validated against the retrieval set. Blanket stamping is a bug.
- **Evidence gate:** ship / downgrade / refuse / surface-conflict. Conflicting evidence
  is shown to the user as a conflict with both sources — never averaged away.
- **Quality strip:** per-answer UI showing confidence, evidence counts, timeliness
  (freshness + temporal coverage), and conflicts.

## Code conventions
- Swift 6 strict concurrency; actors and Sendable as already practiced in the codebase.
- No `try!`, no `fatalError` in non-UI layers (currently true — keep it true).
- Errors are logged through AtlasLog (OSLog) in every catch block.
- Match the existing raw sqlite3 C-API style in repositories (bind/step/finalize,
  throw on step failure). Do not introduce an ORM or wrapper library.

## Forbidden without explicit instruction in a task
- Adding third-party dependencies (tasks state their allowed exceptions explicitly).
- Renaming existing types, files, schemes, or directories.
- Refactoring code outside the current task's listed files.
- "Fixing" intentional stubs: MLX/LlamaCpp/Cloud providers, legacy DOC/XLS/PPT/MSG/PST
  loaders, iOS shims. They are tracked elsewhere; leave them.
- Removing or weakening the PrivacyGate, the grep guard, or sandbox entitlements.

## Working protocol per session
1. Read this file, then the single task assigned (e.g. "Do T3").
2. Open and read every file the task lists BEFORE editing.
3. State a short plan, then implement with small, reviewable diffs.
4. Run the build & verify ritual + the task's acceptance checks.
5. Commit `T<n>: <title>`. Report what changed and what was verified. Stop.
If a task spec conflicts with reality in the code, stop and report the conflict
instead of improvising a resolution.

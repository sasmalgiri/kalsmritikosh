# Why ingest takes so long — a full accounting

Observed: ~8-10 hours for ~100 MB of email on a Mac running Ollama `llama3:latest`.
This document explains, stage-by-stage, where every second goes and what
levers change the equation.

The short answer: **kalsmritikosh does not "copy files" during ingest. It
runs an LLM against every chunk and every canonical entity, and the local
LLM is 20-100× slower than what the wall-clock feel of "100 MB" suggests
it should be.** File size is the wrong measure of work.

---

## 1. What ingest actually does

When you drop a folder into kalsmritikosh, each file goes through this
pipeline. Every stage adds work; the ones with 🔴 are the ones that hit
the LLM.

```
FILE
  │
  ▼
[1] LOADER            parse the file format (MIME, PDF, XLSX, DOCX, …)
  │
  ▼
[2] MIME/THREAD       for email: split mbox → per-message KOs,
                      strip quoted regions, coalesce threads
  │
  ▼
[3] CHUNKER           split content into 300-800 token pieces with overlap
  │
  ▼
[4] EMBEDDER          BGE-M3, 384-dim vector per chunk (batched, GPU-ish)
  │
  ▼
[5] ENTITY EXTRACTOR  NLTagger + regex + occasional LLM slot-fill 🔴
  │
  ▼
[6] EVENT EXTRACTOR   rules + occasional LLM date/context enrichment 🔴
  │
  ▼
[7] CONTEXT PREFIX    LLM writes a 1-2 sentence topic prefix for
                      EVERY chunk so retrieval can match questions
                      to chunks at a semantic level 🔴🔴 (dominant)
  │
  ▼
[8] BOND CONSTRUCTOR  writes typed fact-bonds edges between entities +
                      events + KOs (pure SQL, no LLM)
  │
  ▼
                                       (per-file work complete)

Then background workers grind through the derived data:

[9]  MEMORY DISTILLER   For each canonical entity (Alice, Gmail, Toyota,
                        …), for each subject kind (person / org / project /
                        …), LLM writes a 3-5 sentence "what does the ledger
                        know about X" summary. 🔴🔴 (second dominant)

[10] CAUSAL DISCOVERER  Pairs events, asks the LLM whether A caused/
                        contributed-to B. 🔴

[11] COOCCURRENCE       Pure SQL. Rebuilds shared-KO edge graph.
     GRAPH BUILDER

[12] CONTEXT PREFIX     Sweeps back over chunks whose prefix generation
     BACKFILLER         timed out during the initial pass; retries with
                        looser rate limits. 🔴🔴

[13] SUMMARIZER         Per-KO one-sentence summary. 🔴

[14] SYNTHETIC          Per-chunk, generates 3-5 questions the chunk
     QUESTIONS          could answer. Feeds question-shape retrieval. 🔴
```

Stages 1-6 are cheap and finish in the first hour. Stages 7-13 are what
you were watching burn for the next 7-9.

---

## 2. Why the *count* of LLM calls is what matters

The LLM does not care about file size. It processes tokens. But the number
of times we *call* the LLM is proportional to how many discrete
entities we build:

| Kind of thing | Rough count for 100 MB of email | LLM calls it triggers |
|---|---|---|
| Files | 5,000 - 20,000 messages | 0 (loader is pure parse) |
| KnowledgeObjects | 20,000 - 60,000 (one per message + attachments) | 0 |
| Chunks | 60,000 - 200,000 | **1 each** for context prefix + 1 each for synthetic Qs = **120k - 400k calls** |
| Canonical entities | 3,000 - 15,000 (after dedup / T3 filter) | ~5 each for MemoryDistiller subject kinds = **15k - 75k calls** |
| Events | 5,000 - 30,000 | ~0.3 each on average (many resolved by rules) = **1.5k - 9k calls** |
| Causal pair candidates | ~1M pairs → filtered to ~50k probes | ~1 each for LLM judgment when heuristics tie = **~10k calls** |

**Total LLM calls for a 100 MB email archive: 150,000 – 500,000.**

That is the number that determines your wall-clock. Not the 100 MB.

---

## 3. What each LLM call costs on your hardware

From your live logs I can read the actual latency of one call:

```
07:04:01  contextPrefix: llama3:latest recovered on attempt 2 with 16000ms
07:07:08  contextPrefix: llama3:latest recovered on attempt 3 with 32000ms
```

Every context-prefix call is taking **16-32 seconds** end-to-end on your
machine. The reason:
- `llama3:latest` on Ollama defaults to the **8B** or **8B-instruct** model,
  which is 4-6 GB of weights.
- On an Apple Silicon Mac without a monster GPU, this runs at 15-25
  tokens/second.
- The prompt is ~800 tokens of context + generation of ~40 tokens =
  ~840 tokens per call.
- 840 tokens ÷ 20 tok/s ≈ **42 seconds** per call, matching the observed
  cap of the "attempt 3 with 32000ms" recovery.

Multiply by call count:

```
120,000 calls × 20s average ÷ 4 parallel workers = 600,000 s / 4 = 150,000 s
                                                                 ≈ 42 hours
```

At the low end (60k calls × 15s / 4 workers): ~63,000 s ≈ **17 hours**.
At the high end (400k calls × 25s / 4 workers): 2.5M s / 4 ≈ **170 hours**.

**Your ~8-10 hours in is 20-50% of expected wall-clock for on-device
llama3.** It is not stuck; it is behaving to spec.

---

## 4. Per-file example — one email

To make it concrete, walk through what a single 4 KB email costs:

| Stage | Time budget on your hardware |
|---|---|
| MIME parse                                             | ~5 ms |
| Chunker (avg 3 chunks per short email)                 | ~2 ms |
| BGE-M3 embed (3 chunks, batched)                       | ~40 ms |
| NLTagger entity extract                                | ~15 ms |
| Rule event extract                                     | ~1 ms |
| **Context prefix** (3 chunks × 20 s LLM call each)     | **~60 s** |
| Bond construct (SQL)                                   | ~5 ms |
| **Later: memory distill** (if the email's sender is a new canonical entity, add ~5 subject-kind LLM calls × 20 s)  | **~100 s (deferred)** |
| **Later: synthetic questions** (3 chunks × 20 s)       | **~60 s (deferred)** |

**One 4 KB email → ~220 seconds of LLM work.**

100 MB / 4 KB = 25,000 messages. Times 220 s per message = **5.5 million
seconds = 63 days sequential.**

Even at 4× parallelism, that is 16 days.

You are hitting 8-10 hours only because most emails share senders,
recipients, subject threads — so the *per canonical entity* LLM work is
amortized across many messages. Most of the 25k messages resolve to the
same ~2,000 canonical people/orgs.

---

## 5. Why file size is a misleading metric

A more useful mental model is not "MB" but "distinct facts":

```
"processing 100 MB in 10 hours" =
    building ~50k events + ~10k canonical entities + ~150k chunks +
    running ~200k LLM calls to summarize / prefix / classify them
```

For comparison:
- Copying 100 MB : 3 seconds.
- Indexing 100 MB with Spotlight: 30-90 seconds.
- Vectorizing 100 MB with BGE-M3 only (no LLM): ~15 minutes.
- **Building a full knowledge graph with LLM-summarized memory: 10-40 hours on a Mac.**

The knowledge graph is what makes the app answer "Why was Project Delta
delayed?" instead of just returning search snippets. The cost is the
feature.

---

## 6. Where the specific stages spent your time

Reading your 8-hour log window:

| Time slice | Dominant stage | Evidence |
|---|---|---|
| 23:05 – ~00:30 | File load + chunking + embedding | (no LLM logs — CPU/GPU only) |
| 00:30 – 05:14 | Entity extraction + causal discovery + first-pass prefix generation | Many `contextPrefix: exhausted 3 attempts, chunk left without prefix` messages — LLM saturated, some chunks skipped |
| 05:14 (single event) | CausalDiscoverer emitted 25,647 links from 859 events | 1 line, ~5 minutes of pure SQL |
| 05:14 – 06:11 | MemoryDistiller | Hundreds of `Distilled memory for …` lines per hour |
| 06:11 – present | ContextPrefixBackfiller | `processing 50 NULL chunks` batches; every call now succeeds (Ollama free) |

Notice the pattern: **the prefix work was tried once during peak load and
lost many chunks to timeout, then re-tried by the backfiller once
distiller freed up the LLM socket.** That is by design — the pipeline
never drops facts, just defers them.

---

## 7. Three levers to change the equation

### Lever 1 — Pin a faster reasoning model (biggest impact, no code changes)

`llama3:8b` is overkill for context-prefix generation. Try:

- `phi3:mini` (3.8B) — ~4× faster, still quality on short prompts
- `gemma:2b` — ~7× faster, weaker on nuance
- `qwen2.5:3b-instruct` — ~5× faster, strong on structured output

Then in kalsmritikosh: **Settings → Pin a provider per capability →
reasoning → the new model**. Ingest wall-clock drops from 40h→8-12h
territory.

The bigger models (`llama3`, `mistral`, `mixtral`) are worth pinning ONLY
for `reasoning` at *question time*, not for the enrichment worker path.
You can pin different models per capability tier — reasoning stays on
llama3 (for the brain), extraction/summarization/classification move to
phi3 (for the workers).

### Lever 2 — Add a cloud endpoint

If you have an OpenAI or Anthropic key:

- **Settings → Your models → Cloud endpoints → Add endpoint**
- Family: `openai` or `anthropic`
- Model: `gpt-4o-mini` (fast, cheap) or `claude-haiku-4-5` (fast, cheap)
- Then flip **Privacy → Allow cloud-routed providers**

Cloud call latency: 200-800 ms. **Enrichment collapses from days to hours.**

Trade-off: 150k-500k API calls to a cloud provider will cost real money
(~$5-$50 for `gpt-4o-mini`, more for larger models) AND flip you from
private-on-device to sending prompts to a third party. Read the privacy
implications before you do this.

### Lever 3 — Let it run overnight

The background workers are designed to run indefinitely. You don't have
to wait for enrichment to finish before *using* the app. The retriever
falls back through Memory → Timeline → Entity → FTS → Vector layers, so
you can ask questions even when the prefix layer is 60% populated. The
answers just get better as background workers finish.

Nothing you do at the UI needs to wait for ingest completion.

---

## 8. Is your ingest going to finish?

Yes. As of the last log check:
- MemoryDistiller: **done** (~06:11).
- CausalDiscoverer: **done** (single-shot).
- CooccurrenceGraphBuilder: **done** (7,054 edges, self-healing retry loop).
- ContextPrefixBackfiller: **actively finishing**, every call succeeding,
  no more dropped chunks.

The system is past its most LLM-heavy phase. The tail is the backfiller
sweeping the missed-prefix debt. Once its queue empties (probably 2-6
more hours at current pace), ingestion will be truly complete.

---

## 9. TL;DR

- Ingest is not a file-copy job. It builds a knowledge graph and asks an
  LLM to *summarize every fact*.
- 100 MB of email → 60,000 – 200,000 LLM calls on your machine.
- Local `llama3:latest` takes 20-32 s per call. Expected wall-clock on
  your hardware: **17-42 hours** for full completion.
- You are at 8-10 hours = 20-50% through, which is on-spec.
- **Nothing is broken. The bottleneck is the local model, not the code.**
- To shorten future ingests: pin a smaller reasoning model (phi3:mini)
  OR add a cloud endpoint OR let it run overnight.

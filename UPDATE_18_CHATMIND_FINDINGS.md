# UPDATE_18 — chatmind-pipeline findings + roadmap revisions

Date: 2026-06-20
Source repo: `github.com/sasmalgiri/chatmind-pipeline` (production RAG for a coaching platform)
Provoked by: three identical Ollama-reranker eval runs showing 5–50% metric spread

---

## 1. The eval evidence (why this matters)

Three identical-config Mode C runs (KALSMRITIKOSH_RERANKER unset → Ollama llama3 prompted scoring):

| Class           | eval-7 | eval-8 | eval-9 | Spread |
|-----------------|-------:|-------:|-------:|-------:|
| lookup hit      |   1.00 |   1.00 |   1.00 |   0.00 |
| lookup precision|   0.38 |   0.29 |   0.33 |   0.09 |
| lookup recall   |   0.88 |   0.75 |   0.75 |   0.13 |
| aggregation hit |   1.00 |   0.75 |   1.00 |   0.25 |
| aggregation rec |   0.94 |   0.88 | **0.81**|  0.13 |
| temporal hit    |   0.75 |   0.25 |   0.75 |   0.50 |
| temporal recall |   0.38 |   0.25 |   0.25 |   0.13 |
| multihop recall |   0.54 |   0.54 | **0.42**|  0.12 |

Same code, same fixture, same model. The retrieval probe is stable across all
three (`contract.md` at rank #1, score 0.863). The variance is entirely in the
Ollama prompted-scoring reranker. **Multihop recall has now breached the 0.60
hard guard in 3/3 runs.** Conclusion: the LLM-prompted reranker is the wrong
mechanism; replace it.

---

## 2. chatmind-pipeline architecture (the production playbook)

```
INGEST → CHUNK → EXTRACT → ENRICH → UPLOAD → SERVE
                              │
                              ├─ golden quotes (span-verified)
                              ├─ synthetic_questions per chunk
                              ├─ action items, entities, keywords, time windows
                              └─ dual embeddings (bge-m3 + mpnet)
```

Verified by reading: `docs/architecture.md`, `app/api/rag_api.py`,
`app/core/split_chats_to_chunks.py`, `app/core/signals_batch.py`,
`supabase/functions/answer_v9/index.ts`, `scripts/run_question_extractor.py`.

### Their model choices (production, validated by load)
| Role | Model | Dim / Size |
|---|---|---|
| Primary embedder | `BAAI/bge-large-en-v1.5` (in signals_batch.py) or `bge-m3` (in rag_api.py) | 1024 |
| Legacy embedder | `all-mpnet-base-v2` | 768 |
| Reranker (cross-encoder) | `BAAI/bge-reranker-large` (signals) or `bge-reranker-base` (api) | cross-encoder |
| Topic LLM | `llama3` via Ollama | — |
| Golden-quote LLM | `mistral` via Ollama (separate model from topic) | — |
| Question-metadata LLM | `llama3:8b` (run_question_extractor.py) | — |

### Their retrieval cascade (4-tier rerank ladder)
```
heuristic (keyword overlap) → BM25 → CrossEncoder (bge-reranker) → optional LLM
```
Each tier filters before the next. Most queries never reach the LLM tier.
**This is exactly the path we should be on — and it validates removing LLM
prompted scoring as the *only* reranker.**

### Their reliability tricks (worth porting verbatim)
- **MMR (Maximal Marginal Relevance)**: λ=0.7, K=15, passage cap 2000 chars.
  Bounds diversity, prevents the "all 7 emails" pile-up we see on
  aggregation/multihop questions.
- **Fast-path skip rerank when recall ≤ 3** — saves a round trip when
  retrieval already trimmed to a small set.
- **Answerability gate**: `ANSWERABILITY_MIN_SCORE = 0.35` and
  `ANSWERABILITY_MIN_TOKENS = 200`. Refuses below threshold instead of
  emitting a low-confidence answer. We have an analog; theirs is more strict.
- **Search cache 30s TTL** — directly compatible with our G2-PROGRESSIVE
  instant-answer goal.
- **BGE query prefix** — `"query: "` must be prepended to the question
  before embedding with bge-m3. Forgetting this is a known silent quality
  regression. Document this when we convert bge-m3.

---

## 3. The big leverage item — **synthetic_questions per chunk**

This is what I think makes chatmind genuinely worth studying. At ingest, for
each chunk, an LLM generates `top_k=12` hypothetical questions the chunk
*answers*. Stored as:

- `synthetic_questions` (JSONB array of `{q, score}` objects)
- `synthqs_text` (flat string for tsv + trigram FTS)
- Optionally embedded separately for vector lookup

At query time, the user's question is matched against:
1. Chunk text (semantic — fuzzy question-to-statement)
2. **Synthetic questions on the chunk** (semantic — question-to-question, sharper)
3. BM25 keywords
4. Entity overlap

Why this is big for us:
- Question-to-question similarity is materially stronger than question-to-statement
- Reduces dependence on reranker quality (the bottleneck we just measured)
- One-shot ingest cost; permanent query-time win
- Composes with everything else we're building (intent classifier, session
  profile, etc.)

This is the inverse of HyDE — instead of generating a hypothetical answer at
query time, generate hypothetical questions per chunk at index time.

Code reference: `app/core/signals_batch.py:attach_synthqs_text_per_chunk` +
`build_signals_bundle`.

---

## 4. Concrete revisions to the roadmap

### Revision A — UPDATE_17B target model swap
- **Old**: `cross-encoder/ms-marco-MiniLM-L-6-v2` (BERT WordPiece, ~80 MB)
- **New**: `BAAI/bge-reranker-base` (XLM-RoBERTa SentencePiece, ~280 MB)
- Why: chatmind validates this as production-grade; better on modern benchmarks;
  same Core ML conversion path. Different tokenizer family — T2 spec changes
  meaningfully (SentencePiece instead of WordPiece).
- Trade-off: ~200 MB larger bundle. Acceptable for the lift.
- Alt path if size matters: stay on MiniLM-L-6 for v1, plan bge-reranker-base
  for v1.1.

### Revision B — New task G2-SYNTHETIC-QUESTIONS
Insert between G2-3 (contextual retrieval) and G2-ENVIRONMENTS:
- During ingestion, generate `top_k=8` hypothetical questions per chunk via
  the resolved reasoning provider (no model name in Knowledge/).
- Store as new column on `chunks` (JSONB) + a new FTS-indexed text column.
- Embed each synthetic question and store under the same `vectors` table
  with `kind='synthetic_question'`.
- At retrieve time, the HybridRetriever runs vector search against BOTH chunk
  text AND synthetic-question embeddings, then RRF-fuses.
- Estimated lift: 0.10–0.20 on lookup precision based on the multi-turn-RAG
  literature; will eval-measure properly when implemented.
- Cost: ingest LLM time grows ~30% (one extra LLM call per chunk).

### Revision C — Replace single-tier reranker with G2-RERANK-LADDER
- Tier 1: heuristic keyword overlap (free, deterministic)
- Tier 2: BM25 (we already have FTS5)
- Tier 3: Core ML cross-encoder (`bge-reranker-base`, UPDATE_17B)
- Tier 4: optional LLM — only for cases below tier-3 confidence
- Fast-path skips: when post-tier-N candidates ≤ 3, skip remaining tiers
- This subsumes UPDATE_17B and explicitly retires the Ollama LLM as the default
  reranker

### Revision D — Add MMR + passage cap to citation assembly
Small task. In `EvidenceVerifier.verify`, after the reranker step, apply MMR
with λ=0.7 to the survivors before the intent-cap truncates. Prevents the
"all 7 emails" pile-up on aggregation/multihop. Expected lift on aggregation
precision (currently 0.42–0.48) without hurting recall.

### Revision E — Default reranker mode decision
- Until Core ML cross-encoder lands, the runtime default should be `embed`
  (Apple NLEmbedding bi-encoder), NOT Ollama prompted scoring
- Switch default once we have at least one Mode A and Mode B eval to compare
- Rationale: even if `embed` has a lower ceiling than a good LLM, its
  determinism dominates a noisy LLM in practice. We've proven the LLM noise.

---

## 5. Updated priority order (post-chatmind)

1. **(this week)** Run Mode A (`KALSMRITIKOSH_RERANKER=off`) and Mode B
   (`=embed`) evals to compare against the three Mode C runs. Decide default.
2. **G2-1.7** — Default reranker mode change (1-line, after Revision E data)
3. **G2-2** — Temporal grammar (still bottlenecked by retrieval, not reranker)
4. **G2-3** — Contextual retrieval (Anthropic-style chunk context prepend)
5. **G2-SYNTHETIC-QUESTIONS** (Revision B) — new task, slot between G2-3 and G2-ENVIRONMENTS
6. **UPDATE_17B refreshed** with `bge-reranker-base` (Revision A)
7. **G2-RERANK-LADDER** (Revision C) — replaces UPDATE_17B as the framing
8. **G2-MMR-CITATIONS** (Revision D) — small task after the ladder lands
9. **G2-ENVIRONMENTS** — DocumentEnvironment protocol
10. Everything else as already on the todo list

---

## 6. What I am NOT recommending

- **Don't port chatmind code verbatim.** Their stack is Python + Supabase
  + pgvector. We're Swift + SQLite + sqlite-vec + Core ML. The *patterns*
  are portable; the code is not.
- **Don't adopt their dual-embedding scheme (1024d + 768d).** It's legacy
  baggage in their codebase. Single primary embedder is fine.
- **Don't copy their 40,000-char chunk size.** They chunk conversations
  (very dense). We chunk documents. Our existing chunker is right; keep it.
- **Don't swap our intent detector for theirs.** They use llama3 + supabase
  RPC; we use a rule-based RuleIntentDetector. The rule-based one is
  deterministic and works for our 16-question eval. LLM-based intent
  detection is a future option, not a current need.

---

## 7. Deeper-layer findings (second pass)

Read pulled additionally: `supabase/migrations/20251128232208_init_chatmind_schema.sql`,
`app/core/pek_batch_v7.py` (now v8 in repo), `app/services/qa_pairs_batch_db.py`,
`app/services/topic_notebooks_batch_db.py`, `app/core/commitment_extract.py`.

### 7a. Schema is denormalized, single big table

Their primary table is **`chat_chunks_vector`** with everything as columns:
```
id, user_id, chat_id, chunk_index, storyline_summary, leader_mindset,
assistant_guidance, commitments, keywords[], golden_quotes[],
synthetic_questions[], raw_text, chunktext, updated_at
```

Different shape from ours — we're normalized (separate KOs, chunks, entities,
events, memory). **Don't denormalize.** Our normalization buys us a real
ledger with cross-document reasoning; theirs is per-chunk-of-a-conversation.
But note that columns like `storyline_summary`, `leader_mindset`,
`assistant_guidance`, `commitments` are *derived features* attached to the
chunk for fast retrieval — we could attach analogous derived columns to our
`chunks` table without breaking normalization.

### 7b. PEK + temporal awareness (`pek_batch_v8.py`) — directly maps to G2-2

The PEK extractor extracts People / Entities / Keywords plus a `time_window`
field — `{date_from, date_to, evidence}` with ISO8601 UTC normalization.
They use compact regex for both absolute and relative dates:

```python
_ABS_DT_RX = re.compile(r'\b(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2}:\d{2}))?\b')
_REL_DT_RX = re.compile(
    r'\b(today|yesterday|tomorrow|last\s+week|next\s+week|last\s+month|next\s+month)\b',
    re.I
)
```

`normalize_date_span(text, base_dt, tz_name)` priority:
1. Absolute date in text → exact
2. Relative keyword → offset from `base_dt`
3. Fallback → `base_dt` itself (interaction time)

**This is the single most directly portable algorithm in the whole repo.**
Rewriting in Swift takes maybe a day. It plugs straight into our G2-2
temporal grammar — which has been stuck at 0.25 recall because we have no
temporal parsing.

### 7c. Commitments — speaker-aware, intention-pattern, due-date extraction

`commitment_extract.py` does what our `EventExtractor` does today, but better:
- Speaker-aware parsing ("User:" / "Assistant:" / free)
- Intention patterns: `I will`, `I'm going to`, `We need to`, `I plan to`
- Bullet + imperative mining
- Time-of-day: `by Friday at 4 PM`
- Relative + absolute dates → ISO8601 UTC
- Owner + due date with separate confidence scores (`owner_conf`, `due_conf`)
- Overlap guard prevents duplicates across pattern families

We have `RuleEventExtractor`. Theirs has:
- `ABS_DATE_RX`, `RELATIVE_RX`, `TIME_OF_DAY_RX` (portable)
- Two-stage parse (find date, then refine with time-of-day)
- Confidence scoring per-field, not per-claim

**Action**: harvest their date regexes + the `owner_conf` / `due_conf` split
when we touch G2-2 / EventExtractor next.

### 7d. QA pairs (`qa_pairs_batch_db.py`) — the *retrieval-side* version of synthetic questions

Different pattern from §3 of this doc. Workflow:
1. Parse raw_text into User/Assistant turns
2. For each Q-then-A exchange, call LLM: "summarize this coaching exchange in
   1-2 sentences"
3. Embed the summary with bge-m3
4. Store in a separate `qa_pairs` table: `{question_text, qa_summary_short,
   topics, embedding}`
5. At query time, search the `qa_pairs` embeddings *first*, fall back to chunk
   text if no hit

Why this matters: their `qa_summary_short` is *grounded* — it's a real
Q&A from the corpus, summarized. It's "question-shaped" data without
hallucinating hypotheticals. Stronger than synthetic questions because every
QA-pair was a real exchange.

For us: most ingested docs aren't Q&A transcripts — they're emails, PDFs,
spreadsheets. But the *principle* — index a question-shaped projection of
the content separately — applies. For emails, the natural QA pair is
`(message, reply)`. For meeting notes, `(question raised, answer given)`.
For contracts, harder.

**Action**: add **G2-QA-PAIRS** as a sibling of G2-SYNTHETIC-QUESTIONS.
Different mechanisms, same goal — question-shaped retrieval surface.
Where the source has natural Q-A turns, mine them. Where it doesn't,
synthesize.

### 7e. Topic notebooks (`topic_notebooks_batch_db.py`) — clustering + routing

After qa_pairs exist:
1. Fetch all qa_pairs for a user
2. Cluster by embedding similarity (threshold 0.75)
3. Each cluster becomes a "notebook" — a coherent topic
4. Notebook has its own summary, embedding, member qa_pair ids
5. At query time, route to the most-similar notebook first → reduces search
   space dramatically for big archives

Our memory layer (MemoryObject + MemoryDistiller) is similar in intent but
doesn't *cluster* — it distills per-subject. Topic notebooks would cluster
across subjects.

**Action**: defer to v2. Real win, but only matters at scale (10k+ chunks).
Our current G2-2 / G2-3 / G2-SYNTHETIC-QUESTIONS work targets the immediate
quality bar.

### 7f. Multi-LLM dispatch — they use different models for different tasks

Concrete examples from the code:
- **`llama3`** — topic labeling + question-metadata extraction
- **`mistral`** — golden-quote extraction (separate model!)
- **`llama3:8b`** — question-importance scoring

Their reasoning is implicit but real: mistral is better at extractive (verifiable
span) work; llama3 is better at classification + summarization. They pay the
cost of holding two models in memory because each is the right tool.

Our `CapabilityRegistry` design already supports this — we have multiple
providers and a spec-based router. We just don't *use* it for differentiated
models today (everything goes to one Ollama model).

**Action**: minor — once we add Core ML cross-encoder for reranking, we'll
already be exercising the multi-model pattern. Worth keeping in mind for the
golden-quote work if we ever do it.

---

## 8. Net new tasks to slot into the roadmap

(In addition to Revisions A–E in §4)

### G2-TEMPORAL-GRAMMAR (was G2-2) — refresh with chatmind's regex
- Port `_ABS_DT_RX`, `_REL_DT_RX`, `normalize_date_span` to Swift
- Add `time_window` field to Event / Chunk
- TZ-aware normalization to UTC
- ETA: 1-2 days. Largest unblock for temporal recall (currently 0.25).

### G2-QA-PAIRS (new, sibling of G2-SYNTHETIC-QUESTIONS)
- For sources with natural Q-A turns (emails: msg → reply; meeting notes)
- Mine the pair, summarize via LLM, embed, store on a sibling table
- Vector-search the qa_pair embeddings before chunk text
- ETA: 1 week. Lifts retrieval recall on conversational sources.

### G2-COMMITMENTS-REFRESH (event extraction upgrade)
- Speaker-aware parsing in `RuleEventExtractor`
- Intention patterns + time-of-day regex
- Split `owner_conf` and `due_conf` fields on Event
- ETA: 2-3 days. Modest precision lift on reconstructProject answers.

### G2-TOPIC-CLUSTERS (defer to v2)
- Cluster MemoryObjects by embedding similarity
- Route queries to nearest cluster first
- ETA: 1 week. Real win at 10k+ items; premature now.

---

## 9. Where the analogies end

For honesty: chatmind-pipeline is a Python/Postgres/Supabase stack indexing
conversational transcripts at scale. Our app is Swift/SQLite/sqlite-vec,
on-device, indexing heterogeneous documents (PDFs, emails, spreadsheets,
images). The architectural patterns translate cleanly; the implementation
details (pgvector RPCs, supabase auth, GPU CrossEncoder via sentence_transformers)
don't.

The most directly portable items, ranked by leverage:
1. **Temporal date parsing** (§7b) — single biggest unblock for G2-2
2. **QA pair surface** (§7d) — sibling of synthetic-questions
3. **MMR + passage cap** (§2, Revision D) — quick win on aggregation
4. **`bge-reranker-base` model choice** (§4, Revision A) — UPDATE_17B target swap
5. **4-tier rerank ladder** (§4, Revision C) — kills LLM-as-reranker variance
6. **Commitment extraction patterns** (§7c) — event extraction upgrade

The rest are architectural validations of paths we're already on.

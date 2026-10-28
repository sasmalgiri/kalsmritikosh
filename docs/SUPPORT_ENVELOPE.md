# Support envelope (F4 / T3) — measured

Measured on 2026-10-28 with `SupportEnvelopeTests.measuredEnvelope` (a booted production app, AI off,
the evidence-only answer path). Hardware: **Mac16,12 (MacBook Air, Apple M4), 16 GB RAM, 10 cores, macOS
27.0.1 (26A434)**. The input is generated text memos and emails with names, dates, amounts, quotes and
causal sentences. Real archives with large PDFs, scans or attachments are slower per document; their
parsers are covered by the bounded-memory scale tests (`ScaleRunTests`: a 50,000-message / ~100 MB
mbox and a 300,000-row SQLite database stream in bounded memory).

| Measure | 400 documents | 4,000 documents |
|---|---|---|
| Input | 300 memos + 100 emails, 0.1 MB | 3,000 memos + 1,000 emails, 1.1 MB |
| Ingest time | 15.9 s (25.1 docs/s) | 176.0 s (22.7 docs/s) |
| Derived | 400 objects, 400 chunks, 820 entities, 100 events, 400 vectors | 4,000 objects, 4,000 chunks, 5,352 entities, 1,000 events, 4,000 vectors |
| Ledger on disk | 19.9 MiB | 154.3 MiB |
| Memory | baseline 101 MiB, peak 395 MiB (+294) | baseline 115 MiB, peak 462 MiB (+347) |
| Answers (30 questions, case-scoped) | 27 answered, 3 refused | 30 answered, 0 refused |
| Answer latency | p50 985 ms, p95 1.9 s, max 1.9 s | p50 1.3 s, p95 2.5 s, max 2.5 s |

**What this supports stating:** on this hardware, cases of a few thousand text documents ingest at
about 20–25 documents per second. Memory growth stays bounded (it grew by about 50 MiB for ten times the
documents), and answers return in about 1–2.5 s at p95.

**What it does not support:** claims about very large archives (hundreds of thousands of documents or
terabytes), scan-heavy or attachment-heavy archives, or older or smaller Macs. Measure those before
stating them. Exact counts shown in the app come from scoped queries over the ledger, not estimates.

Not measured here:
- cancellation and restart during a large ingest (covered functionally by the re-ingest robustness
  and interrupted-erase tests);
- the on-device and Online AI answer paths (latency depends on the model and provider).

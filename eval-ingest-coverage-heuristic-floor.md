# Ingest coverage probe — per-file (heuristic-floor baseline)

**Generated:** 18 Jun 2026 at 1:45 AM

Total `chunks_fts` rows in the isolated DB: **8**

| filename | KOs | chunks | vectors | entities | FTS rows |
|---|---:|---:|---:|---:|---:|
| amendment-7.md | 1 | 1 | 1 | 4 | 1 |
| contract.md | 1 | 1 | 1 | 4 | 1 |
| invoice-401.eml | 1 | 1 | 1 | 3 | 1 |
| invoice-432.eml | 1 | 1 | 1 | 9 | 1 |
| supplier_abc_22.eml | 1 | 1 | 1 | 6 | 1 |
| supplier_abc_23.eml | 1 | 1 | 1 | 10 | 1 |
| supplier_abc_24.eml | 1 | 1 | 1 | 4 | 1 |
| supplier_abc_25.eml | 1 | 1 | 1 | 8 | 1 |

## Verdict

✓ `.md` files have chunks, vector embeddings, AND FTS rows. All 8 fixture files ingest cleanly into the isolated eval DB. Ingestion layer is closed.

# Retrieval probe — L1 (LLM-on baseline)

**Generated:** 18 Jun 2026 at 6:15 AM
**Mode:** LLM-on via Ollama (`llama3:latest`)

Question: "Who is the project owner of Project Delta?"

Expected source: contract.md

Layers used: memory, timeline, entity, metadata, summary, graph, vector

## Chunks (top-N per layer, hybrid retrieval result)

| # | layer | score | filename | objectID (short) | snippet |
|---:|---|---:|---|---|---|
| 1 | vector | 0.863 | contract.md | 46E65708 | # Master Supply Agreement — Project Delta  **Effective Date:** January 12, 2024  |
| 2 | vector | 0.860 | amendment-7.md | 87B20007 | # Amendment No. 7 — Project Delta Master Supply Agreement  **Effective Date:** M |
| 3 | vector | 0.853 | supplier_abc_24.eml | 2710465C | From: john.carter@northwind.example To: maria.lopez@supplier-abc.com Subject: Re |
| 4 | vector | 0.845 | invoice-432.eml | 4B531AB9 | From: ar@supplier-abc.com To: ap@northwind.example Subject: Invoice No. 432 — Pr |
| 5 | vector | 0.843 | supplier_abc_23.eml | 3EA0D2A1 | From: maria.lopez@supplier-abc.com To: john.carter@northwind.example Subject: Pr |
| 6 | vector | 0.840 | supplier_abc_25.eml | 843C38DD | From: program-office@northwind.example To: program-leads@northwind.example Subje |
| 7 | vector | 0.830 | supplier_abc_22.eml | 3D634F32 | From: maria.lopez@supplier-abc.com To: john.carter@northwind.example Cc: program |
| 8 | vector | 0.817 | invoice-401.eml | F2295D88 | From: ar@supplier-abc.com To: ap@northwind.example Subject: Invoice No. 401 — Pr |

## Verdict

✓ Retrieval is sound and identical to the floor probe — contract.md ranks #1 at 0.863. The LLM run cites contract.md for L1 (cited list: `contract.md, invoice-432.eml, supplier_abc_24.eml`, precision 0.33), which the floor also did. **The LLM doesn't change retrieval order; it changes answer text.** The remaining 2/3 citations being "wrong" is over-citation from other experts hitting the same top-3 by retrieval score — the reranker (Gate 2/3) is what selects by claim-relevance instead.

## Score-rank vs claim-rank — the Gate 1 / Gate 2 boundary

L1 floor cited list: `amendment-7.md, contract.md, supplier_abc_24.eml`
L1 LLM cited list:  `contract.md, invoice-432.eml, supplier_abc_24.eml`

Different specific docs cited, same precision. Both runs include contract.md. Both runs spend 2/3 citation slots on documents the question didn't strictly require. That's the **claim → citation linking** layer: in Gate 1 it uses retrieval similarity; in Gate 2 the reranker scores each candidate against the actual claim text.

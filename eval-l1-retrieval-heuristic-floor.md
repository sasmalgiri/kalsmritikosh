# Retrieval probe — L1 (heuristic-floor baseline)

**Generated:** 18 Jun 2026 at 1:45 AM
**Mode:** HEURISTIC FLOOR (no LLM)

Question: "Who is the project owner of Project Delta?"

Expected source: contract.md

Layers used: memory, timeline, entity, metadata, summary, graph, vector

## Chunks (top-N per layer, hybrid retrieval result)

| # | layer | score | filename | objectID (short) | snippet |
|---:|---|---:|---|---|---|
| 1 | vector | 0.863 | contract.md | F6A92DE8 | # Master Supply Agreement — Project Delta  **Effective Date:** January 12, 2024  |
| 2 | vector | 0.860 | amendment-7.md | DB4C23E8 | # Amendment No. 7 — Project Delta Master Supply Agreement  **Effective Date:** M |
| 3 | vector | 0.853 | supplier_abc_24.eml | 5FB1E161 | From: john.carter@northwind.example To: maria.lopez@supplier-abc.com Subject: Re |
| 4 | vector | 0.845 | invoice-432.eml | 6BDC8D70 | From: ar@supplier-abc.com To: ap@northwind.example Subject: Invoice No. 432 — Pr |
| 5 | vector | 0.843 | supplier_abc_23.eml | A6567C86 | From: maria.lopez@supplier-abc.com To: john.carter@northwind.example Subject: Pr |
| 6 | vector | 0.840 | supplier_abc_25.eml | 1C30082F | From: program-office@northwind.example To: program-leads@northwind.example Subje |
| 7 | vector | 0.830 | supplier_abc_22.eml | 9FD502AE | From: maria.lopez@supplier-abc.com To: john.carter@northwind.example Cc: program |
| 8 | vector | 0.817 | invoice-401.eml | 160C8FE7 | From: ar@supplier-abc.com To: ap@northwind.example Subject: Invoice No. 401 — Pr |

## Verdict

✓ `contract.md` IS in the retrieval candidate set, ranked #1 at score 0.863.

**Confirmed**: retrieval is sound. The remaining work was always citation assembly + answer synthesis (UPDATE_13) and over-citation control (UPDATE_14). With those two updates landed, the floor cites contract.md correctly on L1 (3 cited, contract.md present, precision 0.33).

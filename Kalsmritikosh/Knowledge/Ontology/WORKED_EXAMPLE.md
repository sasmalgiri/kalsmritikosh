# G3 worked example — ProjectDelta fixture walked end-to-end

The ProjectDelta fixture in `Resources/Fixtures/ProjectDelta/` has been
the eval testbed all along. This doc traces it through the v1 ontology
so future contributors can sanity-check both the schema (Phase 1) and
the bond engine (Phase 3) when they ship.

## The 8 fixture files in plain English

```
contract.md            Master Supply Agreement, signed 12 Jan 2024.
                       Parties: Northwind ↔ Supplier ABC. For Project Delta.
amendment-7.md         Amendment #7 to the same agreement.
                       Effective Mar 2024. Modifies delivery dates.
invoice-401.eml        Invoice from Supplier ABC to Northwind for
                       Project Delta milestone 1.
invoice-432.eml        Invoice from Supplier ABC to Northwind for
                       Project Delta milestone 2. Status: OVERDUE.
supplier_abc_22.eml    Week-22 status email from Maria Lopez.
supplier_abc_23.eml    Week-23 status email.
supplier_abc_24.eml    Week-24 status — Supplier ABC reports first
                       delivery delay.
supplier_abc_25.eml    Week-25 status — delay continues; weekly digest.
```

## Facts the classifier (G3.7) will produce

When G3 phase 2 ships and we classify the fixture, the typed-fact
table will contain (IDs abbreviated):

| FactType | Slot values |
|---|---|
| Person | `name=Maria Lopez`, `email=maria.lopez@supplier-abc.com` |
| Person | `name=John Carter`, `email=john.carter@northwind.example` |
| Person | (program office shared mailbox — possibly demoted to `email` only) |
| Organization | `name=Supplier ABC`, `kind=supplier`, `domain=supplier-abc.com` |
| Organization | `name=Northwind`, `kind=client`, `domain=northwind.example` |
| Project | `name=Project Delta`, `status=active` |
| Contract | `title=Master Supply Agreement`, `effective_date=2024-01-12` |
| Amendment | `summary="delivery date moved"`, `effective_date=2024-03-…` |
| Invoice | `number=401`, `for_project→Project Delta` |
| Invoice | `number=432`, `for_project→Project Delta`, `status=overdue` |
| Delivery | `scheduled_date=2024-04-08`, `status=delayed` |
| Delivery | `scheduled_date=2024-05-…`, `status=delayed` |
| Email (×4) | `subject=…`, `sender_person→Maria Lopez` |

## Bonds the BondConstructor (G3.10) will write

Reading right to left ("…is X for…"):

```
Maria Lopez   affiliated_with   Supplier ABC
John Carter   affiliated_with   Northwind
Contract      party_a           Northwind
Contract      party_b           Supplier ABC
Amendment     amends            Contract
Project Delta delivered_by      Supplier ABC
Invoice 401   issued_by         Supplier ABC
Invoice 401   issued_to         Northwind
Invoice 401   invoice_for       Project Delta
Invoice 432   issued_by         Supplier ABC
Invoice 432   issued_to         Northwind
Invoice 432   invoice_for       Project Delta
Delivery #1   delivers_for      Project Delta
Delivery #2   delivers_for      Project Delta
Email #22..25 sent_by           Maria Lopez
Email #22..25 received_by       John Carter
Email #22..25 discusses         Project Delta
```

## The questions, walked

These are the same questions as `Resources/Eval/questions.json`. Once
G3 phase 4 ships, the walk planner produces these paths.

### L1 — "Who is the project owner of Project Delta?"

Walk:
```
fact_type=Project, name="Project Delta"
   → owns⁻¹ (none in fixture)
```
**No bond fires**: the fixture has no Person→owns→Project edge.
Falls back to vector retrieval over `contract.md` (the answer is
implicit in the contract text). G3.17 will detect the empty walk and
flag this as a "graph gap" to the user — the system says
"this answer comes from text, not the graph."

### A3 — "List all delays mentioned across the Project Delta archive."

Walk:
```
fact_type=Project, name="Project Delta"
   → ← delivers_for                   (Delivery facts that point at this Project)
   filter status="delayed"
returns 2 Delivery facts plus their evidence email IDs
```
**Strong walk match.** The aggregation answer is the slot data, no
LLM synthesis required.

### T3 — "How did the contract status evolve over time for Project Delta?"

Walk:
```
fact_type=Project, name="Project Delta"
   → ← for_project                    (Contract that points at this Project)
   → ← amends                         (Amendments that point at this Contract)
sort by effective_date
returns 1 Contract + N Amendments, in date order
```
**Strong walk match.** This is the kind of question vector retrieval
has been failing on — Phase 4 should hit recall 1.00.

### M1 — "Why was Project Delta delayed?"

Walk:
```
fact_type=Project, name="Project Delta"
   → ← delivers_for                   (Delivery facts)
   filter status="delayed"
   → ← discusses                      (Emails that discuss this Project)
   filter sent_at ≈ Delivery date
returns 2 Delivery facts, ~4 Email facts, sender Person facts
```
**Strong walk match.** The chain is exactly the worked example in
GATE2_ROADMAP.md and `G3_PERIODIC_TABLE_ROADMAP.md`'s closing
paragraph:

```
Delivery for Project Delta slipped on 2024-04-08.

  Walk:
  Project Delta
    → delivers_for ← Delivery(2024-04-08, status=delayed)
      → caused_by ← Email(supplier_abc_22.eml, from=Maria Lopez,
                          mentions: "parts shortage upstream")
        → preceded_by ← Email(supplier_abc_22.eml,
                              forwarded: "supplier warned 5 days prior")
```

## What this example proves

1. **The v1 schema covers ProjectDelta's facts without extension.**
   No new FactType needed.
2. **The v1 bond rules wire up cleanly.** No new BondRule needed.
3. **3 of the 4 fixture questions are graph-walkable.** L1 has no
   `owns` edge — that's the gap surface, not a v1 schema bug.
4. **Vector + FTS retrieval remain the fallback** for questions whose
   answer isn't a typed slot. Phase 4 fuses both signal types.

## Phase 2's first task (when we get there)

Wire G3.5 + G3.6 schema migrations. Then write
`FactTypeClassifier.swift` (G3.7) using NLTagger + the v1 type list
above. Run the classifier on the ProjectDelta fixture. Confirm every
fact in this doc gets assigned the type predicted here.

If it doesn't — that's where the worked-example methodology pays off.
We catch the schema/extraction mismatch in eval, not in production.

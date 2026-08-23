# The Sūtra Engine — a constitution-driven system for rigorous work

> **Thesis.** The lowest form an app of this kind should start from is not a screen, a feature, or a model — it is the **doctrine**: the SOPs, standards, evidentiary rules, and report form of a discipline. Write that doctrine once, as a machine-readable **Sūtra** (a terse constitution). The app is then a faithful **interpreter** that *unfolds* the sūtra into a guided, evidence-gated practice — every job in between — ending in a defensible report. One engine, many subjects.

*Sūtra* (सूत्र): a thread; a compact rule that generates elaboration. The classical pattern is **sūtra → bhāṣya** — a seed rule and its unfolding into practice. That is precisely the architecture proposed here: a small constitution, mechanically elaborated into a whole workbench.

---

## 1. Why this is the right "lowest form"

Most apps start from features and accrete rules. That inverts the dependency: the rules (the SOP) are the *reason the features exist*. If the doctrine is the source of truth, then the surfaces, the gates, the evidence obligations, the forbidden conclusions, and the report are all **derivable** — not hand-built. Change the doctrine, the app changes. Add a new discipline, you write a sūtra, not code.

This is not speculative — it is the frontier of three converging fields:

- **Executable SOPs / policy-as-code.** Natural-language SOPs and clinical guidelines are compiled into executable BPMN/DMN and run on engines like SpiffWorkflow, Camunda/Zeebe, and Imixs — where even *security policy is declared in the model, not hard-coded* ([Imixs-Workflow](https://www.imixs.org/), [Policy-Based Management with BPMN + TOSCA](https://pmc.ncbi.nlm.nih.gov/articles/PMC9948795/), [LLM guideline→BPMN pipeline](https://arxiv.org/pdf/2604.07817)).
- **Ontology-driven information systems.** A single declarative domain model generates the UI *and* the validation rules *and* the business logic as a side effect — *"the ontology used by the UI generator is exactly the one used by the applications, so refining the ontology needs no refining of the UI"* ([deriving UI from ontologies](https://www.researchgate.net/publication/4205885_Deriving_user_interface_from_ontologies_A_model-based_approach), [ontology→rules](https://www.researchgate.net/publication/221581539_Ontology-Based_Information_Systems_Development_The_Problem_of_Automation_of_Information_Processing_Rules)).
- **Constitutional governance.** A short written *constitution* of principles governs behavior transparently and auditably, instead of exhaustively enumerated rules ([Constitutional AI](https://www.emergentmind.com/topics/constitutional-ai), [Specific vs General Principles](https://arxiv.org/html/2310.13798)).

**The gap they leave — and our innovation.** Executable-SOP engines produce a *process*. Ontology systems produce a *UI + rules*. Constitutional AI governs a *model*. **None grounds the process in an evidence ledger, resolves the ambiguity problem with human-decision gates, and terminates in a sealed, defensible report.** The literature names ambiguity as *the* unsolved problem: *"the same specification can yield multiple structurally valid but behaviorally different executable models"* ([ambiguity in executable process modeling](https://arxiv.org/pdf/2604.10884)). Our answer is structural: **evidence + human gates**. A step is not "done" because the process advanced; it is done because cited evidence supports it and a human made the decisions the doctrine reserves for a human. Ambiguity is not auto-resolved — it is *surfaced to the person the doctrine holds responsible.*

---

## 2. The proof already exists in this codebase

This isn't a rewrite; it's making an existing latent architecture **explicit and general**. The app already contains every organ of a Sūtra Engine:

| Sūtra Engine organ | Already present as |
|---|---|
| The doctrine (proto-constitution) | `JobDocumentation` — per job: workflow steps, required inputs, methods, **work products**, **human decisions**, **prohibited conclusions** |
| Unfolding doctrine → steps | `WCWorkflowDefinition` / Work Center (gated operations, plain-language locked reasons) |
| Evidence substrate | the ledger (KnowledgeObjects, entities, events, contradictions, gaps) + custody with hashes (SWGDE/NIST) |
| Tooling depth (which surface a step earns) | the four tiers in `PERSONA_JOB_DEPTH_MAP.md` — Capture / **Analyze** / Read-derive / **Decide-produce** |
| The doctrine's *methods* | the recognized rubrics now surfaced — Admiralty, ACH, GPS, PRISMA/GRADE, funds-tracing, SIU indicators, procedural fairness, journalistic verification |
| Human-decision gates (ambiguity answer) | evidence gate; standard-of-proof gate; open-items acknowledgment; reversible human-gated merges |
| The terminal artifact | the sealed findings receipt (report == receipt), scope-fingerprinted |
| Doctrine *lenses* over one engine | the 10 personas — the *same 16 job-kinds* re-labelled per profession |

The personas are the tell. Ten professions run on **one** set of shared engines because each persona is already a thin **lens (a partial sūtra)** over the same doctrine. Generalize that lens into a full, first-class **Sūtra**, and the app stops being "an investigation app with 10 personas" and becomes **an engine that becomes whatever discipline you hand it a constitution for.**

---

## 3. The Sūtra — what a domain's constitution declares

A Sūtra is a small, versioned, machine-readable document. It declares *what the discipline requires*, never *how the app renders it* (that's the engine's job — the ontology-driven lesson). Sketch:

```
Sūtra {
  id, version, title, provenance          // who authored it, from which standard, when — a citable constitution
  vocabulary { term → label }             // e.g. claim→finding, subject→guest (the persona lens, generalized)

  evidenceModel {
    admissible: [rule]                     // what counts as evidence in this domain (hearsay? privileged? custody?)
    reliabilityScale                       // Admiralty | GRADE | custom
  }

  phases: [ Phase {                        // the SOP, as ordered obligations
     id, title,
     tier: capture | analyze | readDerive | decideProduce,   // → the engine picks the surface
     method?: ACH | fishbone | fiveWhys | prisma | linkAnalysis | table(schema) | …
     requires: [precondition]              // gates (fail-closed, plain-language reason)
     obligations: [ "cite ≥2 independent sources", "record nil results" ]
     humanDecisions: [ "confirm/reject hypothesis" ]          // reserved for a person (ambiguity gate)
     prohibitedConclusions: [ "average conflicts", "assert beyond the standard of proof" ]
  } ]

  proof {
    standardOfProof: [balanceOfProbabilities | beyondReasonableDoubt | …]   // required before the report
    report: Section[]                       // the defensible report's structure + sign-off + seal
  }
}
```

**The engine is a pure interpreter of this.** Given a Sūtra it produces, deterministically:
- the **step rail** (phases, in order, with gates and locked reasons);
- the **right surface per step** from `tier` + `method` (a `capture` phase → a cited table; an `analyze` phase with `method: ACH` → the matrix studio; `fishbone` → the Reasoning Studio; `linkAnalysis` → the graph; a `decideProduce` phase → the gated Handoff with the standard-of-proof gate);
- the **evidence obligations** enforced against the ledger (uncited step → not done);
- the **prohibited conclusions** enforced as guards (the causal-language guard, the "both sides preserved" rule);
- the **report**, assembled from cited evidence, sealed, and sign-off-gated.

Nothing above is domain-specific to investigation. It is domain-specific to *rigor*.

---

## 4. The ambiguity answer (why this is more than BPMN)

The research's core caveat is that specifications under-determine execution. Three structural defenses, all already in the app, make that safe here:

1. **Evidence grounding.** Process state is necessary but not sufficient; a step advances only with cited evidence. The truth lives in the ledger, not the workflow token.
2. **Human-decision gates.** Where the doctrine is ambiguous or consequential, the sūtra marks a `humanDecision`; the engine *refuses to infer it* and hands it to the responsible person (mirroring the frontier's move from RLHF to explicit gates, but at *runtime*, for a *person*).
3. **Prohibited conclusions as guards.** The sūtra names what must never be asserted; the engine enforces it (no averaging conflicts, no claim beyond the declared standard of proof). This is Constitutional AI's "explain your refusals," applied to a *workflow*, not a chat.

Result: the same sūtra always yields the same rails and guards; only the *evidence and the human's judgment* vary — which is exactly correct.

---

## 5. One engine, many subjects — a worked generalization

To show it isn't investigation-bound, here is a **clinical differential diagnosis** sūtra sketch (same engine, zero new UI):

- `evidenceModel`: admissible = labs, imaging, history, exam; reliabilityScale = GRADE.
- Phases: *Intake* (capture: presenting complaint) → *Findings register* (capture table) → **Differential (analyze · method: ACH)** — diagnoses as hypotheses, findings as evidence, rank by fewest inconsistencies → *Red-flags* (capture, prohibited: "rule out on absence alone") → *Investigations plan* (decideProduce gate) → **Assessment** (decideProduce: standardOfProof = "clinical certainty tier", report = SOAP note, signed).

The ACH matrix built for investigators *is already* the differential-diagnosis surface. That is the whole thesis in one example: **the discipline changes; the engine doesn't.** The same holds for a safety incident (5 Whys/fishbone + CAPA), a systematic review (PRISMA/GRADE), an audit (controls testing + findings), a due-diligence memo, a scientific write-up.

---

## 6. Roadmap (incremental, non-breaking)

1. **Formalize the Sūtra schema** — promote `JobDocumentation` to a complete, versioned `Sūtra` (add `tier`, `method`, `evidenceModel`, `proof`). No behavior change; it already carries most fields.
2. **Make one surface sūtra-driven end-to-end** — have Work Center read `tier`/`method` from the sūtra and launch the matching surface (ACH / fishbone / table / graph / gated report) instead of a hard-coded mapping. The tiers + studios that now exist are the target set.
3. **A Sūtra authoring surface** — write/import a discipline's doctrine (and, per the LLM-guideline→BPMN frontier, *draft* a sūtra from an uploaded SOP PDF, then have a human ratify it — never auto-adopt).
4. **Conformance verification** — a checker that proves a run satisfied its sūtra (every obligation met, every human decision made, no prohibited conclusion asserted) — the sealed receipt becomes a *constitutional conformance certificate*.
5. **Ship a second discipline from a sūtra alone** — the proof that the engine generalizes: a non-investigation domain with no new UI code.

---

## 7. The one-line pitch

**Write the doctrine once; the app becomes the practice.** Every rigorous field already has its SOPs, its standards, its evidentiary bar, and its report. Kalsmritikosh is the engine that turns any such doctrine into a private, evidence-gated, on-device workbench that carries a professional from the first step to a report they can defend — with the constitution, not the code, in charge.

*Positioning note: executable-SOP engines automate the process; ontology systems automate the UI; constitutional AI governs the model. The Sūtra Engine governs the **practice** — process + evidence + human judgment + a defensible report — which is the layer professionals actually live in.*

---

### Sources
- Executable SOP / BPMN / policy-as-code: [Imixs-Workflow](https://www.imixs.org/) · [Policy-Based Management with BPMN + TOSCA](https://pmc.ncbi.nlm.nih.gov/articles/PMC9948795/) · [LLM guideline→BPMN pipeline](https://arxiv.org/pdf/2604.07817) · [ambiguity in executable process modeling](https://arxiv.org/pdf/2604.10884)
- Ontology-driven systems: [deriving UI from ontologies](https://www.researchgate.net/publication/4205885_Deriving_user_interface_from_ontologies_A_model-based_approach) · [ontology→executable rules](https://www.researchgate.net/publication/221581539_Ontology-Based_Information_Systems_Development_The_Problem_of_Automation_of_Information_Processing_Rules) · [semantic-model framework generation (US 8,522,195)](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/8522195)
- Constitutional governance: [Constitutional AI](https://www.emergentmind.com/topics/constitutional-ai) · [Specific vs General Principles for Constitutional AI](https://arxiv.org/html/2310.13798)

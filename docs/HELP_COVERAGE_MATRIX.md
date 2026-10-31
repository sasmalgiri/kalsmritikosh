<!-- GENERATED from Kalsmritikosh/UI/Help/HelpRegistry.swift by HelpDocsRenderer; do not edit by hand. Regenerate: HELP_DOCS_WRITE=1 HelpRegistryTests.generatedDocsMatch -->
# Help coverage matrix

One row per active screen (every sidebar destination), linking its Get started step, its detailed help topic, the critical explanations (ⓘ information buttons reading the registry) on it, its accessibility identifiers for help controls, and the UI journey that verified it on the current code. “gap” means not yet verified through the UI — stated, not hidden.

| Screen | Get started step | Detailed topic(s) | Critical explanations (ⓘ topics) | Accessibility ids | Verified journey |
|---|---|---|---|---|---|
| Home | — | screen-home | — | home.startInvestigation, home.resumeCase, purchase.screen, purchase.strip | ui-journeys-2026-10-31g (first screen; subscription screen leads when nothing is bought) |
| Ask | step 5 | screen-ask, task-search-and-refusals | task-search-and-refusals | — | gap |
| Search | — | screen-search | — | — | gap |
| Professional Jobs | step 2 | screen-work, get-started, persona-com-kalsmritikosh-persona-investigator, persona-com-kalsmritikosh-persona-lawyer, persona-com-kalsmritikosh-persona-compliance, persona-com-kalsmritikosh-persona-forensicaccountant, persona-com-kalsmritikosh-persona-siu, persona-com-kalsmritikosh-persona-journalist, persona-com-kalsmritikosh-persona-researcher, persona-com-kalsmritikosh-persona-genealogist, persona-com-kalsmritikosh-persona-individual | task-review-approve-export (Add documents to this case) | jobs.*, result.*, info.task-review-approve-export | ui-journeys-2026-10-30d, -e (start matter, Add documents to this case, run, result, handoff) |
| Work Center | — | screen-workcenter | — | — | gap |
| Logs & Trackers | — | screen-registers | — | — | gap |
| Cases | — | screen-cases, task-statements-and-interviews, task-review-approve-export | safety-decisions (Record finding), task-review-approve-export (Export), task-keys-backup-erase (Erase case) | case.output.notice, allegation.link.support, info.safety-decisions, info.task-keys-backup-erase | ui-journeys-2026-10-30d, -e (case file, evidence links, Open passage, exports, case log) |
| Workspaces | — | screen-workspaces | — | — | gap |
| DataLab | — | screen-datalab | — | — | ui-journeys-2026-10-30d (query above the table, unresolved-only, source pane) |
| Timeline | — | screen-timeline, task-chronology-and-hypotheses | — | — | gap |
| History | — | screen-history | — | — | gap |
| Findings | — | screen-findings, task-evidence-status | — | — | gap |
| Review | step 3 | screen-review | — | — | gap |
| Handoff & Review | — | screen-handoff | — | — | gap |
| Cross-Doc Matrix | — | screen-matrix | — | — | gap |
| Compare Documents | — | screen-comparedocs | — | — | gap |
| Connections | — | screen-connections | — | — | gap |
| Fund Flow | — | screen-fundflow, task-money | — | — | gap |
| Email Threads | — | screen-emailthreads | — | — | gap |
| Case Story | — | screen-story | — | — | gap |
| Reasoning Studio | — | screen-reasoning | — | — | gap |
| Competing Hypotheses | — | screen-hypotheses | — | ach.* | ui-journeys-2026-10-30d, -e (ACH filed under a case; copy/export recorded) |
| HR Investigation | — | screen-hrstudio | — | — | gap |
| Privilege Log | — | screen-privilegestudio | — | — | gap |
| SIU Report | — | screen-siustudio | — | — | gap |
| Expert Report | — | screen-fastudio | — | — | gap |
| Fact-Check | — | screen-jnstudio | — | — | gap |
| Evidence Review | — | screen-rsstudio | — | — | gap |
| Proof Argument | — | screen-gnstudio | — | — | gap |
| Emergency Binder | — | screen-instudio | — | — | gap |
| Dispute File | — | screen-dsstudio | — | — | gap |
| Transcripts | — | screen-transcripts | — | — | gap |
| Notebook | — | screen-notebook | — | — | gap |
| Dossier | — | screen-dossier | — | — | gap |
| Explore | — | screen-explore | — | — | gap |
| Insights | — | screen-insights | — | — | gap |
| What Changed | — | screen-changes | — | — | gap |
| Knowledge | — | screen-knowledge, task-people-and-namesakes | task-people-and-namesakes (Unmerge) | info.task-people-and-namesakes | gap |
| Assertions | — | screen-assertions | — | — | gap |
| Answers | step 3 | screen-answers | — | — | gap |
| Audit | — | screen-audit | — | — | gap |
| Verify Receipt | — | screen-verifyreceipt | — | — | gap |
| Library | — | screen-library | — | — | gap |
| Saved | — | screen-saved | — | — | gap |
| Authenticity | — | screen-authenticity | — | — | gap |
| Citations | — | screen-citations | — | — | gap |
| Freshness | — | screen-freshness | — | — | gap |
| Trends | — | screen-trends | — | — | gap |
| Query | — | screen-query | — | — | gap |
| Sources | step 1 | screen-sources, task-import-failures, trouble-nothing-found | task-import-failures | sources.* | ui-journeys-2026-10-30d, -e (folder picker reads at once; failed file stays failed; Ready) |
| Convert | — | screen-convert | — | — | gap |
| Completeness | — | screen-completeness | — | — | gap |
| Live | — | screen-live, trouble-slow | — | — | gap |
| Redaction | — | screen-redaction | — | — | gap |
| Caseload | — | screen-caseload | — | — | gap |
| Guide | — | screen-guide | — | help.guide, help.search, help.topic.<id>, help.replayTutorial, help.replayIntro, help.open.<screen> | gap |
| Constitution | — | screen-sutra | — | — | gap |
| Compliance Board | — | screen-sopboard | — | — | gap |
| Settings | step 1 | screen-settings, task-private-online, task-keys-backup-erase, task-support, subscription-plans, subscription-restore-offline, subscription-expiry | task-keys-backup-erase (Your data), subscription-plans (Subscription) | settings.subscription.status, info.subscription-plans | ui-journeys-2026-10-30f (Subscription section, Restore outcome) |

## Critical actions and their explanations (§6.8)

| Action | Hover (what it does) | ⓘ topic (prerequisites, consequences) | Where |
|---|---|---|---|
| Add documents to this case | scope preview: in scope / new / excluded; nothing added until confirmed | task-review-approve-export, trouble-nothing-found | Professional Jobs |
| Send (Online) | what is sent, to which host, with which key; bytes; masked details | task-private-online | Outbound consent sheet |
| Accept shown / Save review | one decision over the shown rows; each row records its own | task-review-approve-export | Job result |
| Unmerge | splits a merged identity; nothing deleted; recorded | task-people-and-namesakes | Knowledge ▸ Merged |
| Record finding | re-verifies every link before an adverse finding is written | safety-decisions | Case file ▸ Allegations |
| Case file report… / Export… | frozen, re-checked, scrubbed, written, read back, recorded | task-review-approve-export | Case file ▸ Export; Job result |
| Erase case… / Delete All My Data… | fail-closed; holds block; what is not reached | task-keys-backup-erase | Case file; Settings ▸ Your data |
| Complete backup / recovery key | ledger + originals with SHA-256; key shown once | task-keys-backup-erase | Settings ▸ Your data |
| Subscribe / Restore purchases / Manage subscription | storefront price and period, trial eligibility, renewal, cancel ≥ a day before | subscription-plans, subscription-restore-offline | Subscription screen; Settings ▸ Subscription |

## Beginner acceptance targets (§6, pilot — not measured yet)

- Open and check the first sample citation within 10 minutes of indexing.
- Finish a small guided draft/export exercise within 20 minutes.
- Complete without developer rescue; keyboard and VoiceOver findings recorded.

These are targets for the five-user evaluation on the distribution build; no result is claimed here.

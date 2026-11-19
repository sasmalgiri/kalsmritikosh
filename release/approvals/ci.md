# Evidence — hosted CI on the candidate (gate `ci`)

Candidate: 59874d589bcdacaffc873778cd29fe7a852c114f
Recorded by: agent (Claude), 2026-11-18, from `gh run view 44262553857` (read from GitHub, not from console text).

Run: https://github.com/sasmalgiri/kalsmritikosh/actions/runs/44262553857 — workflow "Build + Guards", head SHA
cae841345c4d85a6d9e2c4b7403c3809a4ebc469, completed **success** (2026-11-18T07:54:36Z → 2026-11-18T09:46:31Z UTC). The head is the candidate plus one commit that
changes only docs/RELEASE_CANDIDATE.md and release/approvals/simulation-journeys.md (no product code), so the run tested the
candidate's code.

| Job | Conclusion |
|---|---|
| build-and-test | success |
| release-build | success |
| architecture-guards | success |
| migration-matrix | success |
| parser-fixtures | success |
| report-receipt-integrity | success |
| sensitive-export | success |

All seven jobs green, including the CI type-check that failed run 44241676967 on 38bdd759 (fixed in 32f5bd75; run
44246334157 on 7b330af9 was then green).

## Earlier record (candidate 93a3870d, kept as history)

Earlier candidate line: 93a3870ddd0a6020559b038af4baf9560b51a294
Recorded by: agent (Claude), 2026-11-07, from `gh run view 42361432506` (read from GitHub, not from console text).

Run: https://github.com/sasmalgiri/kalsmritikosh/actions/runs/42361432506 — workflow "Build + Guards", head SHA
93a3870ddd0a6020559b038af4baf9560b51a294, completed **success** in 54 m 36 s.

| Job | Conclusion |
|---|---|
| build-and-test | success |
| release-build | success |
| architecture-guards | success |
| migration-matrix | success |
| parser-fixtures | success |
| report-receipt-integrity | success |
| sensitive-export | success |

All seven jobs green. build-and-test runs the whole KalsmritikoshTests target in 10 batches with
`-parallel-testing-enabled NO` (each test once; see 143a77b2), then verifies from the .xcresult that the executed count is
above the floor in ci/test-baseline.json, then runs the standalone verifier against a production-shaped bundle and its attack
matrix. The same seven jobs were also green on 54ed48b9 (run 42354356462, 43 m 27 s).

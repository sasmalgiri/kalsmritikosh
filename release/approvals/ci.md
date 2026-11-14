# Evidence — hosted CI on the candidate (gate `ci`)

Candidate: 93a3870ddd0a6020559b038af4baf9560b51a294
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

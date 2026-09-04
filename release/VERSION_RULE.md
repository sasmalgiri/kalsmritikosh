# Version & build rule (RC-6) — one label, one law

- **Marketing version**: `1.<minor>.<patch>`. 1.1 is the first public
  release. A patch (`1.1.x`) may contain fixes and ADDITIVE migrations only.
  A minor (`1.2`) is a feature release gated by its own sealed baseline.
- **Build number**: strictly increasing integer, bumped on every archive
  (Xcode "Current Project Version"); never reused, never reset.
- **Schema version** is independent of the marketing version and only ever
  increases; MigrationMatrixTests pins it and CI enforces the gap-free chain.
- A version number is a LABEL, not a plan: nothing ships on a date; a build
  ships when its gates are green (suite, guards, parity vs the sealed
  baseline, claims CI).

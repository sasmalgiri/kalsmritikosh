# ci/migrations/fixtures

Fixture **definitions** for the migration matrix (MIG-001A). This directory intentionally holds
**no opaque SQLite binaries** for the synthetic historical versions — those are reproduced at test
time by replaying the committed migration list
(`MigrationFixtureBuilder.database(atVersion:)` → `SchemaMigrations.migrate(_:through:)`), so the
fixtures can never drift from the real schema history.

`manifest.json` describes each fixture's starting version, how it is constructed, the era-limited
object types it seeds, the expected end version, and its preservation + integrity assertions. It
describes **definitions**, not the presence of committed binary files.

Committed database binaries are reserved for:
- one sanitized historical app database (only if not reproducible from history);
- one sanitized representative real archive (added in **MIG-001B**);

and must contain **no private user data**.

Authoritative narrative: `../../../MIGRATION_MATRIX.md`.

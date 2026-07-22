//
//  SchemaMigrations.swift
//  Kalsmritikosh
//
//  Versioned DDL for the 11 SQLite tables. Each migration bumps
//  PRAGMA user_version and is applied exactly once. Adding a new
//  migration is a pure append — never edit an existing one.
//

import Foundation

public enum SchemaMigrations {

    public static let latestVersion = 59

    /// True when the registered migration list is internally consistent: a
    /// gap-free `1...latestVersion` sequence whose head equals `latestVersion`.
    /// This is the real integrity invariant — it verifies the migrations match
    /// the declared latest WITHOUT a hardcoded "expected version" constant that
    /// has to be bumped by hand on every schema change (that constant is what
    /// caused the ReleaseReadiness "schema desynced" false alarm).
    public static var migrationListIsConsistent: Bool {
        all.map(\.0) == Array(1...latestVersion)
    }

    /// Apply every migration newer than the current `user_version`. Each
    /// migration runs inside a SAVEPOINT so a partial DDL failure leaves
    /// the schema at the previous version instead of half-applied.
    public static func migrate(_ database: Database) async throws {
        let current = try await database.currentUserVersion()
        // Self-heal a stale counter. Observed in the field: some databases carry
        // a fully-applied latest schema while `user_version` is stuck at an early
        // value (root cause not reproducible in isolation — migrate() persists
        // correctly on a fresh DB). Blindly re-running the pending migrations
        // would fail, because most use bare `CREATE TABLE` (no IF NOT EXISTS) and
        // would raise "table already exists", bricking boot. So: if the counter
        // looks stale BUT the newest migration's table already exists, the schema
        // is genuinely complete — just reconcile the counter and return.
        if current < latestVersion, try await isSchemaFullyApplied(database) {
            try await database.setUserVersion(latestVersion)
            return
        }
        for (version, sql) in all where version > current {
            let savepoint = "kalsmritikosh_mig_v\(version)"
            do {
                try await database.exec("SAVEPOINT \(savepoint);")
                try await database.exec(sql)
                try await database.setUserVersion(version)
                try await database.exec("RELEASE SAVEPOINT \(savepoint);")
            } catch {
                try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
                try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
                throw DatabaseError.migrationFailed(
                    version: version,
                    message: "\(error)"
                )
            }
        }
        // Belt-and-suspenders: after a fully-successful migration pass, stamp
        // the final version ONCE in plain autocommit context (outside any
        // SAVEPOINT). In some runtime/WAL configurations a `PRAGMA
        // user_version` issued inside a SAVEPOINT was observed NOT to persist
        // even though the migration DDL committed — leaving the counter stale
        // (e.g. stuck at an early version) while the schema was fully applied.
        // A stale counter would make a LATER boot re-run already-applied
        // migrations. This reconciles the on-disk counter with reality; it is a
        // no-op when the per-migration stamps already stuck, and only advances
        // (never downgrades a newer DB opened by an older build).
        if try await database.currentUserVersion() < Self.latestVersion {
            try await database.setUserVersion(Self.latestVersion)
        }
    }

    /// True when the LATEST migration's marker already exists — i.e. the schema
    /// is fully applied even if `user_version` disagrees. Because migrations are
    /// ordered and append-only, the newest marker's presence implies every
    /// earlier object exists too. UPDATE THIS SENTINEL whenever a new migration
    /// is added, to the newest object it creates (a table or, as here, a column).
    /// v59 adds the `enrichment_jobs` table — check it exists (newest object).
    private static func isSchemaFullyApplied(_ database: Database) async throws -> Bool {
        let rows = try await database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='enrichment_jobs';", []
        )
        return !rows.isEmpty
    }

    /// Migrations indexed by their `user_version` number. Append-only.
    private static let all: [(Int, String)] = [
        (1, v1),
        (2, v2),
        (3, v3),
        (4, v4),
        (5, v5),
        (6, v6),
        (7, v7),
        (8, v8),
        (9, v9),
        (10, v10),
        (11, v11),
        (12, v12),
        (13, v13),
        (14, v14),
        (15, v15),
        (16, v16),
        (17, v17),
        (18, v18),
        (19, v19),
        (20, v20),
        (21, v21),
        (22, v22),
        (23, v23),
        (24, v24),
        (25, v25),
        (26, v26),
        (27, v27),
        (28, v28),
        (29, v29),
        (30, v30),
        (31, v31),
        (32, v32),
        (33, v33),
        (34, v34),
        (35, v35),
        (36, v36),
        (37, v37),
        (38, v38),
        (39, v39),
        (40, v40),
        (41, v41),
        (42, v42),
        (43, v43),
        (44, v44),
        (45, v45),
        (46, v46),
        (47, v47),
        (48, v48),
        (49, v49),
        (50, v50),
        (51, v51),
        (52, v52),
        (53, v53),
        (54, v54),
        (55, v55),
        (56, v56),
        (57, v57),
        (58, v58),
        (59, v59)
    ]

    // MARK: - v1 — initial 11-table schema + FTS5

    private static let v1: String = """
    -- Files: raw file rows discovered on disk.
    CREATE TABLE IF NOT EXISTS files (
        id              TEXT PRIMARY KEY NOT NULL,
        url             TEXT NOT NULL,
        source_type     TEXT NOT NULL,
        size_bytes      INTEGER NOT NULL DEFAULT 0,
        modified_at     REAL NOT NULL DEFAULT 0,
        ingested_at     REAL,
        content_hash    TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_files_url ON files(url);
    CREATE INDEX IF NOT EXISTS idx_files_type ON files(source_type);

    -- Knowledge Objects: normalized unit every downstream system works with.
    CREATE TABLE IF NOT EXISTS knowledge_objects (
        id              TEXT PRIMARY KEY NOT NULL,
        file_id         TEXT NOT NULL,
        source_type     TEXT NOT NULL,
        content         TEXT NOT NULL,
        metadata_json   TEXT NOT NULL DEFAULT '{}',
        confidence      REAL NOT NULL DEFAULT 1.0,
        created_at      REAL NOT NULL,
        updated_at      REAL NOT NULL,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_ko_file ON knowledge_objects(file_id);

    -- Chunks: bounded slice of KO content, granularity for embeddings + citations.
    CREATE TABLE IF NOT EXISTS chunks (
        id              TEXT PRIMARY KEY NOT NULL,
        object_id       TEXT NOT NULL,
        ordinal         INTEGER NOT NULL,
        text            TEXT NOT NULL,
        char_start      INTEGER NOT NULL,
        char_end        INTEGER NOT NULL,
        page_number     INTEGER,
        created_at      REAL NOT NULL,
        FOREIGN KEY (object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_chunks_object ON chunks(object_id);

    -- Entities.
    CREATE TABLE IF NOT EXISTS entities (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,
        value           TEXT NOT NULL,
        normalized      TEXT,
        source_object_id TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        attributes_json TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_entities_kind ON entities(kind);
    CREATE INDEX IF NOT EXISTS idx_entities_norm ON entities(normalized);

    -- Events.
    CREATE TABLE IF NOT EXISTS events (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,
        date            REAL NOT NULL,
        end_date        REAL,
        title           TEXT NOT NULL,
        summary         TEXT,
        source_object_id TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        attributes_json TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind);
    CREATE INDEX IF NOT EXISTS idx_events_date ON events(date);

    -- Event<->Entity join (an event has many entity participants).
    CREATE TABLE IF NOT EXISTS event_entities (
        event_id        TEXT NOT NULL,
        entity_id       TEXT NOT NULL,
        PRIMARY KEY (event_id, entity_id),
        FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE,
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
    );

    -- Timelines (named views over events; the engine builds these on read).
    CREATE TABLE IF NOT EXISTS timelines (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,           -- global/project/person/company/financial
        scope_id        TEXT,                    -- nullable for global
        title           TEXT NOT NULL,
        created_at      REAL NOT NULL
    );

    -- Relationships (graph edges).
    CREATE TABLE IF NOT EXISTS relationships (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,
        from_entity_id  TEXT NOT NULL,
        to_entity_id    TEXT NOT NULL,
        via_event_id    TEXT,
        source_object_id TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        attributes_json TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (from_entity_id) REFERENCES entities(id) ON DELETE CASCADE,
        FOREIGN KEY (to_entity_id) REFERENCES entities(id) ON DELETE CASCADE,
        FOREIGN KEY (via_event_id) REFERENCES events(id) ON DELETE SET NULL,
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_rel_from ON relationships(from_entity_id);
    CREATE INDEX IF NOT EXISTS idx_rel_to ON relationships(to_entity_id);

    -- Summaries (hierarchical: 6 levels).
    CREATE TABLE IF NOT EXISTS summaries (
        id              TEXT PRIMARY KEY NOT NULL,
        level           TEXT NOT NULL,
        length          TEXT NOT NULL,
        scope_json      TEXT NOT NULL,
        body            TEXT NOT NULL,
        produced_at     REAL NOT NULL,
        model_id        TEXT,
        confidence      REAL NOT NULL DEFAULT 0.5
    );
    CREATE INDEX IF NOT EXISTS idx_summaries_level ON summaries(level);

    -- Conversations (Ask transcripts).
    CREATE TABLE IF NOT EXISTS conversations (
        id              TEXT PRIMARY KEY NOT NULL,
        started_at      REAL NOT NULL,
        title           TEXT
    );

    CREATE TABLE IF NOT EXISTS conversation_turns (
        id              TEXT PRIMARY KEY NOT NULL,
        conversation_id TEXT NOT NULL,
        ordinal         INTEGER NOT NULL,
        role            TEXT NOT NULL,           -- user / assistant
        body            TEXT NOT NULL,
        created_at      REAL NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
    );

    -- Projects / Companies / People are first-class for UI navigation;
    -- entities still drive truth.
    CREATE TABLE IF NOT EXISTS projects (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL,
        started_at      REAL,
        ended_at        REAL,
        notes           TEXT
    );

    CREATE TABLE IF NOT EXISTS companies (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL,
        kind            TEXT,                    -- vendor / client / other
        notes           TEXT
    );

    CREATE TABLE IF NOT EXISTS people (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL,
        email           TEXT,
        phone           TEXT,
        notes           TEXT
    );

    -- FTS5 virtual table over knowledge_objects.content + chunks.text.
    CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_objects_fts USING fts5(
        content,
        content='knowledge_objects',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );

    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        text,
        content='chunks',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );
    """

    // MARK: - v2 — Knowledge Memory layer (MemoryObject + change log)

    private static let v2: String = """
    -- Latest distilled state per subject (project / org / person / etc.).
    -- Decisions, risks, source IDs are JSON-encoded blobs since SQLite
    -- doesn't have arrays.
    CREATE TABLE IF NOT EXISTS memory_objects (
        id                          TEXT PRIMARY KEY NOT NULL,
        subject_kind                TEXT NOT NULL,
        subject_identifier          TEXT NOT NULL,
        key_decisions_json          TEXT NOT NULL DEFAULT '[]',
        key_event_ids_json          TEXT NOT NULL DEFAULT '[]',
        important_relationship_ids_json TEXT NOT NULL DEFAULT '[]',
        risks_json                  TEXT NOT NULL DEFAULT '[]',
        status                      TEXT NOT NULL DEFAULT 'active',
        narrative                   TEXT NOT NULL DEFAULT '',
        source_object_ids_json      TEXT NOT NULL DEFAULT '[]',
        confidence                  REAL NOT NULL DEFAULT 0.5,
        version                     INTEGER NOT NULL DEFAULT 1,
        created_at                  REAL NOT NULL,
        updated_at                  REAL NOT NULL,
        UNIQUE(subject_kind, subject_identifier)
    );
    CREATE INDEX IF NOT EXISTS idx_memory_subject
        ON memory_objects(subject_kind, subject_identifier);

    -- Append-only change log per memory object.
    CREATE TABLE IF NOT EXISTS memory_changes (
        id                     TEXT PRIMARY KEY NOT NULL,
        memory_object_id       TEXT NOT NULL,
        subject_kind           TEXT NOT NULL,
        subject_identifier     TEXT NOT NULL,
        prior_version          INTEGER NOT NULL,
        new_version            INTEGER NOT NULL,
        delta_json             TEXT NOT NULL,
        triggering_object_id   TEXT,
        occurred_at            REAL NOT NULL,
        FOREIGN KEY (memory_object_id) REFERENCES memory_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_memory_changes_subject
        ON memory_changes(subject_kind, subject_identifier, occurred_at DESC);
    """

    // MARK: - v3 — canonical entities + per-mention rows + alias table

    private static let v3: String = """
    -- T3 — Promote `entities` to a canonical table (UNIQUE on kind+normalized),
    -- preserve per-document occurrences as entity_mentions, and add an
    -- aliases table so domain stems and other synonyms can map onto orgs.
    -- Run with deferred FK checks so we can table-swap inside the savepoint.
    PRAGMA defer_foreign_keys = ON;

    -- Per-document mentions. One row per (entity, source_object) occurrence,
    -- with the surface span for future highlighting.
    CREATE TABLE entity_mentions (
        id              TEXT PRIMARY KEY NOT NULL,
        entity_id       TEXT NOT NULL,
        kind            TEXT NOT NULL,
        surface         TEXT NOT NULL,
        normalized      TEXT NOT NULL,
        source_object_id TEXT NOT NULL,
        span_start      INTEGER,
        span_end        INTEGER,
        confidence      REAL NOT NULL DEFAULT 0.5,
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE,
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_mentions_entity ON entity_mentions(entity_id);
    CREATE INDEX idx_mentions_source ON entity_mentions(source_object_id);
    CREATE INDEX idx_mentions_normalized ON entity_mentions(normalized);

    -- New canonical entities table (UNIQUE on kind+normalized).
    CREATE TABLE entities_new (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,
        value           TEXT NOT NULL,
        normalized      TEXT NOT NULL,
        source_object_id TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        attributes_json TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE,
        UNIQUE(kind, normalized)
    );

    -- Pick a representative row per (kind, normalized) and copy to entities_new.
    INSERT INTO entities_new (id, kind, value, normalized, source_object_id, confidence, attributes_json)
    SELECT id, kind, value, norm, source_object_id, confidence, attributes_json
    FROM (
        SELECT e.id, e.kind, e.value, e.source_object_id, e.confidence, e.attributes_json,
               COALESCE(NULLIF(e.normalized, ''), lower(e.value)) AS norm,
               ROW_NUMBER() OVER (
                   PARTITION BY e.kind, COALESCE(NULLIF(e.normalized, ''), lower(e.value))
                   ORDER BY e.confidence DESC, e.id ASC
               ) AS rn
        FROM entities e
    ) ranked
    WHERE rn = 1;

    -- Backfill mentions for every OLD entity row, pointing at the canonical.
    INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, span_start, span_end, confidence)
    SELECT
        lower(hex(randomblob(16))),
        canon.id,
        e.kind,
        e.value,
        COALESCE(NULLIF(e.normalized, ''), lower(e.value)),
        e.source_object_id,
        NULL,
        NULL,
        e.confidence
    FROM entities e
    JOIN entities_new canon
        ON e.kind = canon.kind
       AND COALESCE(NULLIF(e.normalized, ''), lower(e.value)) = canon.normalized;

    -- Retarget event_entities and relationships to the canonical ids.
    UPDATE event_entities
    SET entity_id = (
        SELECT canon.id
        FROM entities_new canon
        JOIN entities e ON e.kind = canon.kind
                       AND COALESCE(NULLIF(e.normalized, ''), lower(e.value)) = canon.normalized
        WHERE e.id = event_entities.entity_id
        LIMIT 1
    )
    WHERE entity_id NOT IN (SELECT id FROM entities_new);

    UPDATE relationships
    SET from_entity_id = (
        SELECT canon.id
        FROM entities_new canon
        JOIN entities e ON e.kind = canon.kind
                       AND COALESCE(NULLIF(e.normalized, ''), lower(e.value)) = canon.normalized
        WHERE e.id = relationships.from_entity_id
        LIMIT 1
    )
    WHERE from_entity_id NOT IN (SELECT id FROM entities_new);

    UPDATE relationships
    SET to_entity_id = (
        SELECT canon.id
        FROM entities_new canon
        JOIN entities e ON e.kind = canon.kind
                       AND COALESCE(NULLIF(e.normalized, ''), lower(e.value)) = canon.normalized
        WHERE e.id = relationships.to_entity_id
        LIMIT 1
    )
    WHERE to_entity_id NOT IN (SELECT id FROM entities_new);

    -- Swap old for new.
    DROP TABLE entities;
    ALTER TABLE entities_new RENAME TO entities;
    CREATE INDEX IF NOT EXISTS idx_entities_kind ON entities(kind);
    CREATE INDEX IF NOT EXISTS idx_entities_norm ON entities(normalized);

    -- Aliases — normalized synonyms (e.g. an email domain stem → an org).
    CREATE TABLE entity_aliases (
        entity_id        TEXT NOT NULL,
        alias_normalized TEXT NOT NULL,
        source           TEXT NOT NULL,
        UNIQUE(entity_id, alias_normalized),
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_aliases_norm ON entity_aliases(alias_normalized);
    """

    // MARK: - v4 — relationships gain weight + evidence list (T4)

    private static let v4: String = """
    -- T4 — Relationship edges accumulate weight and an evidence list of
    -- source KO ids (capped in code at 20). A UNIQUE index on
    -- (kind, from_entity_id, to_entity_id) lets ingest upsert idempotently
    -- via ON CONFLICT.
    ALTER TABLE relationships ADD COLUMN weight INTEGER NOT NULL DEFAULT 1;
    ALTER TABLE relationships ADD COLUMN evidence_object_ids_json TEXT NOT NULL DEFAULT '[]';
    CREATE UNIQUE INDEX idx_rel_canonical ON relationships(kind, from_entity_id, to_entity_id);
    """

    // MARK: - v5 — int8-quantized vectors table (T5)

    private static let v5: String = """
    -- T5 — Real vector store. One row per chunk: int8 symmetric blob +
    -- per-vector scale. Brute force at scan time until ANN (Gate 3).
    CREATE TABLE vectors (
        chunk_id    TEXT PRIMARY KEY NOT NULL,
        dim         INTEGER NOT NULL,
        q           BLOB NOT NULL,
        scale       REAL NOT NULL,
        FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
    );
    """

    // MARK: - v6 — files.alias_of for hash-based attachment dedup (T7)

    private static let v6: String = """
    -- T7 — A file whose contentHash matches an already-ingested file is
    -- stored as an alias row. Its alias_of points at the canonical file's
    -- id; no new knowledge_objects row is created. SET NULL on the FK so
    -- deleting the canonical doesn't cascade through alias bookkeeping.
    ALTER TABLE files ADD COLUMN alias_of TEXT NULL REFERENCES files(id) ON DELETE SET NULL;
    CREATE INDEX idx_files_content_hash ON files(content_hash);
    CREATE INDEX idx_files_alias_of ON files(alias_of);
    """

    // MARK: - v7 — files.availability for move/delete/revoke reconciliation (T8)

    private static let v7: String = """
    -- T8 — Files can be available, offline (their root is unreachable),
    -- or missing (gone from a still-reachable root). Reconciliation
    -- sweeps NEVER cascade-delete knowledge — they only flip this flag.
    ALTER TABLE files ADD COLUMN availability TEXT NOT NULL DEFAULT 'available';
    CREATE INDEX idx_files_availability ON files(availability);
    """

    // MARK: - v8 — event date confidence (T9)

    private static let v8: String = """
    -- T9 — Confidence in the event's date as a fact: 0.95 (parsed from
    -- an email header), 0.7 (extracted from content), 0.3 (file mtime
    -- fallback). 0.5 is the safe default for backfilled rows.
    ALTER TABLE events ADD COLUMN date_confidence REAL NOT NULL DEFAULT 0.5;
    """

    // MARK: - v9 — G2-SYNTHETIC-QUESTIONS + G2-QA-PAIRS storage

    private static let v9: String = """
    -- G2-SYNTHETIC-QUESTIONS — hypothetical questions per chunk.
    -- Each chunk can carry many generated questions; FTS5 indexes the
    -- text so question-shaped queries match by surface form, and the
    -- separate `vectors` table can host their embeddings under the
    -- `kind='synthetic_question'` discriminator (added below) so
    -- HybridRetriever's vector layer can fuse them at query time
    -- without changing the chunk text path.
    CREATE TABLE IF NOT EXISTS synthetic_questions (
        id              TEXT PRIMARY KEY NOT NULL,
        chunk_id        TEXT NOT NULL,
        object_id       TEXT NOT NULL,
        text            TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        produced_by     TEXT NOT NULL DEFAULT 'synthq.heuristic',
        created_at      REAL NOT NULL,
        FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE,
        FOREIGN KEY (object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_synthq_chunk ON synthetic_questions(chunk_id);
    CREATE INDEX IF NOT EXISTS idx_synthq_object ON synthetic_questions(object_id);

    CREATE VIRTUAL TABLE IF NOT EXISTS synthetic_questions_fts USING fts5(
        text,
        content='synthetic_questions',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );

    -- G2-QA-PAIRS — mined Q-A turns from threads / conversations.
    -- Sidecar table so the chunk path stays clean; retrieval can
    -- vector-search the answer summaries (held in `answer_text`) and
    -- RRF-fuse the hits with chunk + synthetic-question signals.
    CREATE TABLE IF NOT EXISTS qa_pairs (
        id                      TEXT PRIMARY KEY NOT NULL,
        question_text           TEXT NOT NULL,
        answer_text             TEXT NOT NULL,
        question_object_id      TEXT NOT NULL,
        answer_object_id        TEXT NOT NULL,
        confidence              REAL NOT NULL DEFAULT 0.5,
        produced_by             TEXT NOT NULL DEFAULT 'qa.email.thread',
        created_at              REAL NOT NULL,
        FOREIGN KEY (question_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE,
        FOREIGN KEY (answer_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_qa_q_object ON qa_pairs(question_object_id);
    CREATE INDEX IF NOT EXISTS idx_qa_a_object ON qa_pairs(answer_object_id);
    """

    // MARK: - v10 — G2-QA-PAIRS FTS view + thread_id on KO metadata index

    private static let v10: String = """
    -- G2-QA-PAIRS — FTS5 over the answer_text. The question shape comes
    -- from the user; the corpus side stores the answer's summary, so
    -- matching question-to-answer-summary on bm25 gives the retrieval
    -- layer a question-shaped second surface alongside chunk text and
    -- synthetic_questions_fts.
    CREATE VIRTUAL TABLE IF NOT EXISTS qa_pairs_fts USING fts5(
        question_text,
        answer_text,
        content='qa_pairs',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );
    """

    // MARK: - v11 — G3 Phase 2: fact_type column on canonical rows (G3.5)

    private static let v11: String = """
    -- G3.5 — Promote every entity / event / memory_object row to a
    -- typed fact. The column is nullable; NULL = "not yet classified"
    -- (the FactTypeClassifier backfill in G3.8 fills it in).
    -- Schema version stays small: just one TEXT column per table.
    ALTER TABLE entities         ADD COLUMN fact_type TEXT NULL;
    ALTER TABLE events           ADD COLUMN fact_type TEXT NULL;
    ALTER TABLE memory_objects   ADD COLUMN fact_type TEXT NULL;

    CREATE INDEX IF NOT EXISTS idx_entities_fact_type      ON entities(fact_type);
    CREATE INDEX IF NOT EXISTS idx_events_fact_type        ON events(fact_type);
    CREATE INDEX IF NOT EXISTS idx_memory_objects_fact_type ON memory_objects(fact_type);
    """

    // MARK: - v12 — G3 Phase 2: slot_values_json column (G3.6)

    private static let v12: String = """
    -- G3.6 — JSON-encoded typed slot values per row. The schema for
    -- each FactType lives in Ontology.swift; OntologyValidator (G3.9)
    -- checks the JSON against the type's expected slots before write.
    -- Defaults to "{}" so existing rows decode cleanly.
    ALTER TABLE entities       ADD COLUMN slot_values_json TEXT NOT NULL DEFAULT '{}';
    ALTER TABLE events         ADD COLUMN slot_values_json TEXT NOT NULL DEFAULT '{}';
    ALTER TABLE memory_objects ADD COLUMN slot_values_json TEXT NOT NULL DEFAULT '{}';
    """

    // MARK: - v13 — G3 Phase 3: fact_bonds (polymorphic typed graph edges)

    private static let v13: String = """
    -- G3.10 — Typed bonds between facts. Unlike `relationships`
    -- (entity↔entity only), bonds are polymorphic over fact kind:
    -- an Email-event can be bonded to a Person-entity via `sent_by`,
    -- a Decision-memory to a Project-entity via `concerns`, etc.
    -- Bond names come from Ontology.rules; this table has no FK to
    -- the fact rows themselves (different tables per kind) but the
    -- source_object_id FK gives us KO-cascade delete for free.
    CREATE TABLE fact_bonds (
        id                      TEXT PRIMARY KEY NOT NULL,
        bond_name               TEXT NOT NULL,
        from_fact_kind          TEXT NOT NULL,
        from_fact_id            TEXT NOT NULL,
        to_fact_kind            TEXT NOT NULL,
        to_fact_id              TEXT NOT NULL,
        source_object_id        TEXT NOT NULL,
        confidence              REAL NOT NULL DEFAULT 0.5,
        weight                  INTEGER NOT NULL DEFAULT 1,
        evidence_object_ids_json TEXT NOT NULL DEFAULT '[]',
        created_at              REAL NOT NULL,
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX idx_fact_bonds_unique
        ON fact_bonds(bond_name, from_fact_id, to_fact_id);
    CREATE INDEX idx_fact_bonds_from ON fact_bonds(from_fact_id, bond_name);
    CREATE INDEX idx_fact_bonds_to   ON fact_bonds(to_fact_id, bond_name);
    CREATE INDEX idx_fact_bonds_name ON fact_bonds(bond_name);
    """

    // MARK: - v14 — FTS5 population triggers + index rebuild
    //
    // CRITICAL FIX: chunks_fts / knowledge_objects_fts were created in
    // v1 as external-content FTS5 tables (content='chunks' / 'knowledge_objects')
    // but no triggers were ever added to populate the FTS index. Result:
    // 42K+ chunks in chunks but `chunks_fts MATCH 'patent'` returns 0
    // rows — the entire FTS retrieval tier in HybridRetriever has been
    // silently dead since launch. Every topic question silently fell
    // through to vector + entity-frequency, which is why "patents"
    // returned Google instead of IIPRD/Khurana.
    //
    // This migration:
    //   1. Adds INSERT/UPDATE/DELETE triggers so future writes stay in sync.
    //   2. Rebuilds the existing index for the rows already in chunks
    //      and knowledge_objects.

    private static let v14: String = """
    -- Triggers: keep chunks_fts in sync with chunks.
    CREATE TRIGGER IF NOT EXISTS chunks_fts_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_fts_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.rowid, old.text);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_fts_au AFTER UPDATE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.rowid, old.text);
        INSERT INTO chunks_fts(rowid, text) VALUES (new.rowid, new.text);
    END;

    -- Triggers: keep knowledge_objects_fts in sync with knowledge_objects.
    CREATE TRIGGER IF NOT EXISTS ko_fts_ai AFTER INSERT ON knowledge_objects BEGIN
        INSERT INTO knowledge_objects_fts(rowid, content) VALUES (new.rowid, new.content);
    END;
    CREATE TRIGGER IF NOT EXISTS ko_fts_ad AFTER DELETE ON knowledge_objects BEGIN
        INSERT INTO knowledge_objects_fts(knowledge_objects_fts, rowid, content) VALUES('delete', old.rowid, old.content);
    END;
    CREATE TRIGGER IF NOT EXISTS ko_fts_au AFTER UPDATE ON knowledge_objects BEGIN
        INSERT INTO knowledge_objects_fts(knowledge_objects_fts, rowid, content) VALUES('delete', old.rowid, old.content);
        INSERT INTO knowledge_objects_fts(rowid, content) VALUES (new.rowid, new.content);
    END;

    -- Rebuild the indexes from existing rows. Idempotent — running
    -- this twice produces the same final index.
    INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild');
    INSERT INTO knowledge_objects_fts(knowledge_objects_fts) VALUES('rebuild');
    """

    // MARK: - v15 — Boilerplate registry (Move B)
    //
    // Long repeated substrings (email signatures, legal disclaimers,
    // unsubscribe footers) are extracted ONCE into boilerplate_templates
    // and replaced in KO content with a `[[BOILERPLATE:<id>]]` token.
    // The boilerplate_uses join records every KO that referenced each
    // template so display / search can re-inject the text on demand.
    //
    // No data is destroyed: raw mbox/eml/pdf files on disk stay
    // untouched, and the templates table preserves the literal bytes
    // verbatim. Re-assembling the original KO body is one JOIN.

    private static let v15: String = """
    CREATE TABLE IF NOT EXISTS boilerplate_templates (
        id TEXT PRIMARY KEY,
        body TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'unknown',
        first_seen_at REAL NOT NULL,
        byte_size INTEGER NOT NULL,
        match_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_boilerplate_kind
        ON boilerplate_templates(kind);

    CREATE TABLE IF NOT EXISTS boilerplate_uses (
        template_id TEXT NOT NULL,
        ko_id TEXT NOT NULL,
        PRIMARY KEY (template_id, ko_id),
        FOREIGN KEY (template_id) REFERENCES boilerplate_templates(id) ON DELETE CASCADE,
        FOREIGN KEY (ko_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_boilerplate_uses_ko
        ON boilerplate_uses(ko_id);
    """

    // MARK: - v16 — G2-3 contextual retrieval (per-chunk context prefix)
    //
    // Anthropic-style contextual retrieval. Each chunk carries a one-
    // sentence summary of its role inside the parent document. The
    // prefix is prepended ONLY at embed time so display, FTS, and
    // citation snippets are unaffected — the stored `chunk.text` and
    // `chunks_fts.text` keep their original bytes. The column is
    // nullable so chunks ingested before this migration (and small-
    // doc chunks whose whole doc fits in one chunk) carry NULL.

    private static let v16: String = """
    ALTER TABLE chunks ADD COLUMN context_prefix TEXT;
    """

    // MARK: - v17 — G2-3 provenance: which generator produced the prefix
    //
    // Tracks whether each chunk's context_prefix came from the LLM
    // path or a fallback. Values written by IngestCoordinator:
    //   - "llm"                 — LLM provider produced the prefix
    //   - "heuristic"           — heuristic generator wired directly
    //   - "heuristic-fallback"  — LLM tried, timed out / failed / empty;
    //                             heuristic supplied the bytes instead
    //   - NULL                  — no prefix on this row (single-chunk
    //                             KOs, pre-v16 rows, generator disabled)
    //
    // Lets the user query "SELECT context_prefix_source, COUNT(*) FROM
    // chunks GROUP BY context_prefix_source" to see how often the
    // fallback path fired during ingest — useful for diagnosing a
    // misconfigured / unreachable LLM provider.

    private static let v17: String = """
    ALTER TABLE chunks ADD COLUMN context_prefix_source TEXT;
    """

    // MARK: - v18 — HISTORY Phase A: quality_tier on extracted facts
    //
    // Every extracted entity / event / memory_object / fact_bond
    // carries a `quality_tier` ('T1' / 'T2' / 'T3') so the brain can
    // demote noise at query time without ever deleting it. Direct
    // response to the "preserve all data, arrange don't filter"
    // directive.
    //
    // T1 — structured header-derived (EmailLoader's From / To / Cc /
    //      Date fields; calendar event ICS attendees; vCard rows).
    //      Highest trust.
    // T2 — body-text extraction via NER / NLTagger (the historical
    //      default). Mid trust.
    // T3 — shape-flagged noise (hostname-looking, vowel-less, mid-cap
    //      run, base64-ish). Preserved on disk; demoted at retrieval.
    //
    // Existing rows default to 'T2' since that's the historical
    // extraction path. A future backfill pass can re-classify
    // pre-v18 rows; not required for forward correctness.

    private static let v18: String = """
    ALTER TABLE entities       ADD COLUMN quality_tier TEXT NOT NULL DEFAULT 'T2';
    ALTER TABLE events         ADD COLUMN quality_tier TEXT NOT NULL DEFAULT 'T2';
    ALTER TABLE memory_objects ADD COLUMN quality_tier TEXT NOT NULL DEFAULT 'T2';
    ALTER TABLE fact_bonds     ADD COLUMN quality_tier TEXT NOT NULL DEFAULT 'T2';

    CREATE INDEX IF NOT EXISTS idx_entities_quality_tier       ON entities(quality_tier);
    CREATE INDEX IF NOT EXISTS idx_events_quality_tier         ON events(quality_tier);
    CREATE INDEX IF NOT EXISTS idx_memory_objects_quality_tier ON memory_objects(quality_tier);
    CREATE INDEX IF NOT EXISTS idx_fact_bonds_quality_tier     ON fact_bonds(quality_tier);
    """

    // MARK: - v19 — HISTORY Phase B.1: entity co-occurrence graph
    //
    // An edge in this graph means two entities appear in at least
    // one shared KnowledgeObject. weight = number of shared KOs. The
    // Phase B community detector (Leiden / agglomerative) walks this
    // graph; the Phase D narrative composer uses the resolved
    // communities as the "topic" of a chapter.
    //
    // Schema:
    //   entity_a / entity_b — ordered lexicographically so each pair
    //     appears once (avoids both (A,B) and (B,A) edges)
    //   weight              — shared-KO count
    //   computed_at         — when this row was last rebuilt
    //
    // Index on (entity_a, entity_b) is the PK; reverse-direction
    // queries hit idx_cooc_b_a.

    private static let v19: String = """
    CREATE TABLE entity_cooccurrences (
        entity_a    TEXT NOT NULL,
        entity_b    TEXT NOT NULL,
        weight      INTEGER NOT NULL DEFAULT 1,
        computed_at REAL NOT NULL,
        PRIMARY KEY (entity_a, entity_b),
        FOREIGN KEY (entity_a) REFERENCES entities(id) ON DELETE CASCADE,
        FOREIGN KEY (entity_b) REFERENCES entities(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_cooc_b_a   ON entity_cooccurrences(entity_b, entity_a);
    CREATE INDEX IF NOT EXISTS idx_cooc_weight ON entity_cooccurrences(weight DESC);
    """

    // MARK: - v20 — HISTORY Phase B.2: community detection results
    //
    // Two tables:
    //   entity_communities   — membership (which entity in which community)
    //   community_summaries  — LLM-generated per-community summary
    //
    // Why two: the detector (B.2) writes membership; the summarizer
    // (B.3) writes the LLM-derived narrative without needing to
    // rewrite memberships.
    //
    // A `level` column on entity_communities is reserved for the
    // hierarchical detector (Leiden produces a tree); the
    // agglomerative MVP shipped here uses level=0 only.

    private static let v20: String = """
    CREATE TABLE entity_communities (
        community_id TEXT NOT NULL,
        entity_id    TEXT NOT NULL,
        level        INTEGER NOT NULL DEFAULT 0,
        computed_at  REAL NOT NULL,
        PRIMARY KEY (community_id, entity_id, level),
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_communities_entity ON entity_communities(entity_id);
    CREATE INDEX IF NOT EXISTS idx_communities_level  ON entity_communities(level);

    CREATE TABLE community_summaries (
        community_id TEXT NOT NULL,
        level        INTEGER NOT NULL DEFAULT 0,
        title        TEXT NOT NULL,
        summary      TEXT NOT NULL,
        member_count INTEGER NOT NULL,
        top_entity_ids_json TEXT NOT NULL DEFAULT '[]',
        computed_at  REAL NOT NULL,
        PRIMARY KEY (community_id, level)
    );
    """

    // MARK: - v21 — HISTORY Phase C.1: per-event 5W+H narrative slots
    //
    // Adds `narrative_slots_json` to events. The column carries the
    // JSON encoding of an `EventNarrativeSlots` struct (six lists of
    // values keyed by who/what/when/where/why/how) with per-slot
    // provenance — source KO + chunk IDs and an extractor tag.
    //
    // This column is COMPLEMENTARY to v12's `slot_values_json` (the
    // FactSchema typed slot bag). FactSchema slots are typed and
    // bond-walkable; narrative_slots_json is the surface-form 5W+H
    // shape the Phase D composer reads to write chapter prose.
    //
    // Defaults to '{}' so existing rows decode as EventNarrativeSlots.empty.

    private static let v21: String = """
    ALTER TABLE events ADD COLUMN narrative_slots_json TEXT NOT NULL DEFAULT '{}';
    """

    // MARK: - v22 — HISTORY Phase G.1: temporal precision column
    //
    // Wikidata-style integer precision (0=unknown, 5=day, 7=instant,
    // see DatePrecision.swift). Default 5 = .day, which matches the
    // safest assumption for legacy rows: we know the date but not the
    // time. The G.2 composer reads this to render precision-aware
    // phrases ("in March 2025" vs "On Mar 14 at 09:00 UTC") instead
    // of falsely claiming midnight when the source was month-only.
    //
    // The G.2 backfill pass re-infers precision from each existing
    // event's dateConfidence (>=0.95 → instant, 0.85-0.94 → day,
    // 0.40-0.69 → month, <0.40 → unknown). New ingests will stamp
    // precision explicitly via the extractor.

    private static let v22: String = """
    ALTER TABLE events ADD COLUMN date_precision INTEGER NOT NULL DEFAULT 5;
    CREATE INDEX IF NOT EXISTS idx_events_precision ON events(date_precision);
    """

    // MARK: - v23 — HISTORY Phase G.3: typed causal links between events
    //
    // ONE table for all 5 relations (CAUSED / CONTRIBUTED_TO / ENABLED
    // / PREVENTED / FOLLOWED), append-only. Counterfactuals (hypothetical
    // "what-if" links) live in a SEPARATE table so they never UNION
    // into the verified history view — this honors the design research's
    // hard separation between verified-history and what-if reasoning.
    //
    // evidence_object_ids_json carries the source KOs that justify the
    // link (the composer cites these inline when rendering the
    // relation in prose). reason is an optional free-text snippet —
    // either the lexical trigger phrase that fired ("because of") or
    // a one-line heuristic description.
    //
    // superseded_by lets the Phase G.4 discoverer replace a link
    // without deleting its history; the link chain follows the same
    // append-only pattern as event_communities.

    private static let v23: String = """
    CREATE TABLE event_links (
        id                   TEXT PRIMARY KEY NOT NULL,
        source_event_id      TEXT NOT NULL,
        target_event_id      TEXT NOT NULL,
        relation             TEXT NOT NULL,
        confidence           REAL NOT NULL DEFAULT 0.5,
        evidence_object_ids_json TEXT NOT NULL DEFAULT '[]',
        allen                TEXT,
        source               TEXT NOT NULL DEFAULT 'heuristic',
        reason               TEXT,
        created_at           REAL NOT NULL,
        superseded_by        TEXT,
        FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE CASCADE,
        FOREIGN KEY (target_event_id) REFERENCES events(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_event_links_source ON event_links(source_event_id, relation);
    CREATE INDEX IF NOT EXISTS idx_event_links_target ON event_links(target_event_id, relation);
    CREATE INDEX IF NOT EXISTS idx_event_links_current ON event_links(superseded_by) WHERE superseded_by IS NULL;

    -- Parallel hypothetical-link table for Phase G future-work
    -- counterfactual reasoning. Never UNIONed into the verified-history
    -- timeline view. Same shape as event_links + a hypothesis note.
    CREATE TABLE event_links_hypothetical (
        id                   TEXT PRIMARY KEY NOT NULL,
        source_event_id      TEXT NOT NULL,
        target_event_id      TEXT NOT NULL,
        relation             TEXT NOT NULL,
        confidence           REAL NOT NULL DEFAULT 0.5,
        evidence_object_ids_json TEXT NOT NULL DEFAULT '[]',
        allen                TEXT,
        source               TEXT NOT NULL DEFAULT 'user',
        reason               TEXT,
        hypothesis_note      TEXT,
        created_at           REAL NOT NULL,
        FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE CASCADE,
        FOREIGN KEY (target_event_id) REFERENCES events(id) ON DELETE CASCADE
    );
    """

    // MARK: - v24 — HISTORY Phase I.A: event versioning (SCD2 + PROV-O)
    //
    // Slowly Changing Dimension Type 2: when an event's payload changes
    // (user correction, LLM re-enrichment refining a date, ontology
    // backfill flipping a kind), the existing row's `valid_to` is
    // closed and a new row is appended carrying the same `event_id`
    // and an incremented `version`. The current view is
    // `valid_to IS NULL`. Queries that want history walk the version
    // chain ordered by `version`.
    //
    // PROV-O light: every version carries (agent, activity) — who/what
    // proposed the change ("system.eventExtractor", "system.llmRefiner",
    // "user.correction", "ontology.backfill") and why. The compact form
    // here is deliberate — the full W3C PROV-O ontology is overkill for
    // a personal archive; the four fields cover the audit needs without
    // exploding the schema.
    //
    // No cascade on events(id) — the canonical row in `events` is the
    // current snapshot; version rows are an audit log that can outlive
    // a future events-table redesign.

    private static let v24: String = """
    CREATE TABLE event_versions (
        id              TEXT PRIMARY KEY NOT NULL,
        event_id        TEXT NOT NULL,
        version         INTEGER NOT NULL,
        valid_from      REAL NOT NULL,
        valid_to        REAL,
        payload_json    TEXT NOT NULL,
        agent           TEXT NOT NULL DEFAULT 'system',
        activity        TEXT,
        reason          TEXT,
        recorded_at     REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_event_versions_event ON event_versions(event_id, version);
    CREATE INDEX IF NOT EXISTS idx_event_versions_current ON event_versions(event_id) WHERE valid_to IS NULL;
    CREATE INDEX IF NOT EXISTS idx_event_versions_recorded ON event_versions(recorded_at);
    """

    // MARK: - v25 — HISTORY Phase I.B: investigation notebook
    //
    // Persisted Plan-and-Solve investigations. Each investigation row
    // is the user's original question + the runner's final synthesis;
    // the steps live in a separate child table to keep updates cheap
    // when the runner streams.
    //
    // FK cascade so deleting an investigation also drops its steps —
    // the user-facing "delete from notebook" action is a single row
    // delete from `investigations` and SQLite handles the rest.
    //
    // answer_body / answer_confidence / answer_citations_json store
    // the per-step VerifiedAnswer in a compact denormalized form so
    // the notebook detail view doesn't need to re-run anything. The
    // citations array is just the object-id list (the file resolution
    // happens at render time).

    private static let v25: String = """
    CREATE TABLE investigations (
        id              TEXT PRIMARY KEY NOT NULL,
        question        TEXT NOT NULL,
        synthesis       TEXT,
        created_at      REAL NOT NULL,
        finished_at     REAL
    );

    CREATE INDEX IF NOT EXISTS idx_investigations_created ON investigations(created_at DESC);

    CREATE TABLE investigation_steps (
        id                   TEXT PRIMARY KEY NOT NULL,
        investigation_id     TEXT NOT NULL,
        ordinal              INTEGER NOT NULL,
        question             TEXT NOT NULL,
        answer_body          TEXT,
        answer_confidence    REAL,
        answer_citations_json TEXT NOT NULL DEFAULT '[]',
        created_at           REAL NOT NULL,
        FOREIGN KEY (investigation_id) REFERENCES investigations(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_investigation_steps_inv
        ON investigation_steps(investigation_id, ordinal);
    """

    // MARK: - v26 — Saved queries (Vol 28 §Core Workspace)
    //
    // Lightweight bookmarking: the user marks a question (with
    // optional notes) so they can re-run it later without retyping.
    // No retrieval-result snapshot stored — re-running the question
    // re-walks the live ledger, which is the right semantic on a
    // continuously-ingesting personal archive (yesterday's "what
    // did supplier X send me" gains new evidence today).

    private static let v26: String = """
    CREATE TABLE saved_queries (
        id              TEXT PRIMARY KEY NOT NULL,
        question        TEXT NOT NULL,
        title           TEXT,
        notes           TEXT,
        category        TEXT,
        created_at      REAL NOT NULL,
        last_run_at     REAL
    );

    CREATE INDEX IF NOT EXISTS idx_saved_queries_created
        ON saved_queries(created_at DESC);
    """

    // MARK: - v27 — Assertion substrate (Vol 17 §A3)
    //
    // Subject-predicate-object triple that sits between extraction
    // and events. The full V17 §A3 refactor would derive events
    // from assertions, but the substrate ships first as an additive
    // table so user-asserted claims + future LLM extractions can
    // start landing without disturbing the existing event pipeline.
    //
    // Polymorphic object: an assertion can target another entity
    // (subject relates to entity X), an event (subject did event Y),
    // or a literal value (subject has property Z). Exactly one of
    // object_entity_id / object_event_id / object_value is set.
    //
    // Evidence + agent + recorded_at + retracted_at mirror the
    // PROV-O fields already on event_versions, so future tooling
    // can query both stores with one shape.

    private static let v27: String = """
    CREATE TABLE assertions (
        id                   TEXT PRIMARY KEY NOT NULL,
        subject_kind         TEXT NOT NULL,
        subject_id           TEXT NOT NULL,
        predicate            TEXT NOT NULL,
        object_kind          TEXT NOT NULL,
        object_value         TEXT,
        object_entity_id     TEXT,
        object_event_id      TEXT,
        confidence           REAL NOT NULL DEFAULT 0.5,
        evidence_object_ids_json TEXT NOT NULL DEFAULT '[]',
        agent                TEXT NOT NULL DEFAULT 'user',
        reason               TEXT,
        recorded_at          REAL NOT NULL,
        retracted_at         REAL
    );

    CREATE INDEX IF NOT EXISTS idx_assertions_subject
        ON assertions(subject_kind, subject_id);
    CREATE INDEX IF NOT EXISTS idx_assertions_predicate
        ON assertions(predicate);
    CREATE INDEX IF NOT EXISTS idx_assertions_recorded
        ON assertions(recorded_at DESC);
    CREATE INDEX IF NOT EXISTS idx_assertions_current
        ON assertions(retracted_at) WHERE retracted_at IS NULL;
    """

    // MARK: - v28 — Closed-corpus answer contract
    //
    // Kalsmritikosh is a ledger-based historical intelligence system,
    // not a chat-with-files RAG app. This migration adds the substrate
    // for "no citation, no factual claim":
    //
    //   corpus_snapshots  — a point-in-time census of the archive
    //       (files registered / parsed / searchable / ledgered /
    //       pending / failed) plus a content-manifest hash. Every
    //       answer is tied to the snapshot it was produced against, so
    //       the UI can say "answered from a corpus that was 87%
    //       ledgered, 1,204 files pending OCR".
    //
    //   answers           — the persisted answer object. The LLM prose
    //       is NOT the truth object; it's the human-facing rendering of
    //       a set of claims. Each answer carries an answer_state
    //       (SUPPORTED / PARTIALLY_SUPPORTED / CONTRADICTED /
    //       NOT_FOUND / INSUFFICIENTLY_INDEXED) and a confidence.
    //
    //   answer_claims     — one row per atomic claim inside an answer,
    //       each with its own support_status + confidence.
    //
    //   claim_evidence    — the claim→evidence contract, persisted.
    //       Polymorphic: a claim can be supported by a KO, a chunk, an
    //       event, or an entity. evidence_role distinguishes supports
    //       vs. contradicts vs. context.
    //
    // All four are additive; no existing table is touched. The brain
    // wires into these in a later change (answerability gate + persist
    // on answer) — the substrate ships first so the schema is stable.

    private static let v28: String = """
    CREATE TABLE corpus_snapshots (
        id                       TEXT PRIMARY KEY NOT NULL,
        created_at               REAL NOT NULL,
        schema_version           INTEGER NOT NULL,
        file_count               INTEGER NOT NULL DEFAULT 0,
        parsed_count             INTEGER NOT NULL DEFAULT 0,
        indexed_count            INTEGER NOT NULL DEFAULT 0,
        ledgered_count           INTEGER NOT NULL DEFAULT 0,
        failed_count             INTEGER NOT NULL DEFAULT 0,
        pending_ocr_count        INTEGER NOT NULL DEFAULT 0,
        pending_enrichment_count INTEGER NOT NULL DEFAULT 0,
        content_manifest_hash    TEXT NOT NULL DEFAULT ''
    );

    CREATE INDEX IF NOT EXISTS idx_corpus_snapshots_created
        ON corpus_snapshots(created_at DESC);

    CREATE TABLE answers (
        id                 TEXT PRIMARY KEY NOT NULL,
        question           TEXT NOT NULL,
        answer_state       TEXT NOT NULL,
        corpus_snapshot_id TEXT,
        body               TEXT NOT NULL,
        confidence         REAL NOT NULL DEFAULT 0.0,
        source             TEXT,
        created_at         REAL NOT NULL,
        FOREIGN KEY(corpus_snapshot_id) REFERENCES corpus_snapshots(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_answers_created
        ON answers(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_answers_state
        ON answers(answer_state);

    CREATE TABLE answer_claims (
        id             TEXT PRIMARY KEY NOT NULL,
        answer_id      TEXT NOT NULL,
        claim_text     TEXT NOT NULL,
        support_status TEXT NOT NULL,
        confidence     REAL NOT NULL DEFAULT 0.0,
        ordinal        INTEGER NOT NULL DEFAULT 0,
        created_at     REAL NOT NULL,
        FOREIGN KEY(answer_id) REFERENCES answers(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_answer_claims_answer
        ON answer_claims(answer_id);

    CREATE TABLE claim_evidence (
        claim_id      TEXT NOT NULL,
        object_id     TEXT,
        chunk_id      TEXT,
        event_id      TEXT,
        entity_id     TEXT,
        evidence_role TEXT NOT NULL DEFAULT 'supports',
        PRIMARY KEY(claim_id, object_id, chunk_id, event_id, entity_id),
        FOREIGN KEY(claim_id) REFERENCES answer_claims(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_claim_evidence_claim
        ON claim_evidence(claim_id);
    """

    // MARK: - v29 — Persistent embedding cache
    //
    // An L2 behind the in-memory LRU: identical text (email signatures,
    // legal disclaimers, quoted footers, and re-ingested files) doesn't
    // pay the embedding cost again across launches. Keyed by
    // (model_id, text_hash) so switching embedders (e.g. NL → BGE-M3)
    // never returns a stale vector — a different model_id is a cache
    // miss. Vector is stored as a raw Float32 BLOB (full fidelity; the
    // quantized copy still lives in `vectors` for the ANN index).
    //
    // This is a cache, not ledger data — safe to DELETE wholesale; it
    // rebuilds on demand. No foreign keys.

    private static let v29: String = """
    CREATE TABLE embedding_cache (
        model_id   TEXT NOT NULL,
        text_hash  TEXT NOT NULL,
        dimension  INTEGER NOT NULL,
        vector     BLOB NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY (model_id, text_hash)
    );

    CREATE INDEX IF NOT EXISTS idx_embedding_cache_created
        ON embedding_cache(created_at DESC);
    """

    // MARK: - v30 — Enrichment tiers (System 2: Hot / Warm / Cold)
    //
    // Per-document importance + tier. The TierPromoter recomputes
    // importance from cheap signals (citations, query hits, pins,
    // recency) and assigns a tier; in Hot/Warm/Cold mode only HOT
    // documents get deep LLM enrichment, cold stays rule-only. Additive
    // + cache-like: safe to clear (it rebuilds from signals).

    private static let v30: String = """
    CREATE TABLE enrichment_status (
        object_id      TEXT PRIMARY KEY NOT NULL,
        tier           TEXT NOT NULL DEFAULT 'cold',   -- cold | warm | hot
        importance     REAL NOT NULL DEFAULT 0,
        query_hits     INTEGER NOT NULL DEFAULT 0,
        citation_count INTEGER NOT NULL DEFAULT 0,
        pinned         INTEGER NOT NULL DEFAULT 0,
        enriched       INTEGER NOT NULL DEFAULT 0,      -- deep pass done?
        updated_at     REAL NOT NULL,
        FOREIGN KEY(object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_enrichment_tier
        ON enrichment_status(tier);
    CREATE INDEX IF NOT EXISTS idx_enrichment_importance
        ON enrichment_status(importance DESC);
    """

    // MARK: - v31 — Gap nodes + persisted contradictions (System 3)
    //
    // `gap_nodes` — INFERRED expected-but-missing evidence (a reply with
    // no ingested parent, a hole in a numbered/dated sequence, a
    // reference to an absent document). Never asserted as fact; low
    // confidence, always shown as "likely missing" with a reason. This
    // is the historiographical "silence" discipline: a gap is not a
    // negation.
    //
    // `contradictions` — persist conflicts the ContradictionFinder
    // detects so they accumulate in the ledger instead of being
    // recomputed per query.

    private static let v31: String = """
    CREATE TABLE gap_nodes (
        id            TEXT PRIMARY KEY NOT NULL,
        kind          TEXT NOT NULL,          -- threadParent | sequenceHole | danglingReference | cadenceBreak
        description   TEXT NOT NULL,
        reason        TEXT NOT NULL,
        confidence    REAL NOT NULL DEFAULT 0.3,
        near_entity   TEXT,
        before_event  TEXT,
        after_event   TEXT,
        evidence_object_id TEXT,
        detected_at   REAL NOT NULL,
        dismissed     INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_gap_nodes_kind ON gap_nodes(kind);
    CREATE INDEX IF NOT EXISTS idx_gap_nodes_entity ON gap_nodes(near_entity);

    CREATE TABLE contradictions (
        id           TEXT PRIMARY KEY NOT NULL,
        description  TEXT NOT NULL,
        claim_a      TEXT NOT NULL,
        claim_b      TEXT NOT NULL,
        evidence_a   TEXT,
        evidence_b   TEXT,
        severity     TEXT NOT NULL DEFAULT 'medium',
        status       TEXT NOT NULL DEFAULT 'open',
        detected_at  REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_contradictions_status
        ON contradictions(status);
    """

    // T16 — persist an evidentiary status per event (§13 vocabulary).
    // Backfill from each row's own signals so an existing corpus gets a
    // realistic spread instead of all-one-value. Idempotent: the guards are
    // mutually exclusive (observed/derived need confidence >= 0.60/0.75, so
    // an unsupported row can never match them), so re-running yields the same
    // result. CONTRADICTED/REVIEWED/REJECTED are never set here.
    private static let v32: String = """
    ALTER TABLE events ADD COLUMN status TEXT NOT NULL DEFAULT 'inferred';

    UPDATE events SET status = 'observed'
        WHERE quality_tier = 'T1' AND confidence >= 0.75 AND date_confidence >= 0.60;

    UPDATE events SET status = 'derived'
        WHERE quality_tier != 'T1' AND date_confidence < 0.60 AND confidence >= 0.60;

    UPDATE events SET status = 'unsupported'
        WHERE confidence < 0.33;

    CREATE INDEX IF NOT EXISTS idx_events_status ON events(status);
    """

    // T17 — append-only human-review ledger. Every accept/reject/correct is
    // a new row; prior_value preserves what it superseded. Nothing is ever
    // UPDATEd/DELETEd (§12.9 / §11 rule 11).
    private static let v33: String = """
    CREATE TABLE fact_reviews (
        id            TEXT PRIMARY KEY NOT NULL,
        subject_kind  TEXT NOT NULL,          -- event | assertion | contradiction | gap
        subject_id    TEXT NOT NULL,          -- the reviewed ledger item's id
        action        TEXT NOT NULL,          -- accept | reject | correct
        prior_value   TEXT,
        new_value     TEXT,
        reviewer      TEXT NOT NULL DEFAULT 'user',
        reason        TEXT,
        reviewed_at   REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_fact_reviews_subject ON fact_reviews(subject_id);
    CREATE INDEX IF NOT EXISTS idx_fact_reviews_at ON fact_reviews(reviewed_at);
    """

    // T18 — chain-of-custody ledger + privileged flags (§21). custody_events
    // is append-only. `privileged` marks material that must be filtered out of
    // answers by default (enforced like PrivacyGate filters cloud providers).
    private static let v34: String = """
    CREATE TABLE custody_events (
        id       TEXT PRIMARY KEY NOT NULL,
        file_id  TEXT NOT NULL,
        kind     TEXT NOT NULL,        -- acquired | hash_computed | hash_verified | hash_mismatch | exported | disclosed
        actor    TEXT NOT NULL DEFAULT 'system',
        at       REAL NOT NULL,
        detail   TEXT,
        hash     TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_custody_file ON custody_events(file_id);
    CREATE INDEX IF NOT EXISTS idx_custody_kind ON custody_events(kind);

    ALTER TABLE files ADD COLUMN privileged INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE knowledge_objects ADD COLUMN privileged INTEGER NOT NULL DEFAULT 0;
    """

    // §16 — derived-objects ledger. Append-only record of every USEFUL
    // query-time LLM extraction (claim / event / relationship / contradiction
    // / memory / timeline interpretation) with full provenance, so
    // minimum-LLM work compounds instead of repeating: a later request with an
    // unchanged source_hash + extractor_version can REUSE the stored result
    // rather than paying for the model again. Never overwritten — a correction
    // inserts a new row and points the old row's superseded_by at it.
    private static let v35: String = """
    CREATE TABLE derived_objects (
        id                TEXT PRIMARY KEY NOT NULL,
        kind              TEXT NOT NULL,
        content           TEXT NOT NULL,
        source_evidence   TEXT,
        source_hash       TEXT NOT NULL,
        model_id          TEXT,
        provider_id       TEXT,
        prompt_version    TEXT,
        extractor_version TEXT NOT NULL,
        confidence        REAL NOT NULL DEFAULT 0,
        review_status     TEXT NOT NULL DEFAULT 'unreviewed',
        superseded_by     TEXT,
        created_at        REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_derived_source_hash ON derived_objects(source_hash);
    CREATE INDEX IF NOT EXISTS idx_derived_kind ON derived_objects(kind);
    CREATE INDEX IF NOT EXISTS idx_derived_extractor ON derived_objects(extractor_version);
    """

    // P5.5 — contradiction taxonomy. Adds a `kind` column so a conflict is
    // classified (date/amount/identity/payment/…) rather than untyped. Additive
    // with a default so existing rows remain valid.
    private static let v36: String = """
    ALTER TABLE contradictions ADD COLUMN kind TEXT NOT NULL DEFAULT 'other';
    """

    // A1 (§6.3 / P3.0g) — canonical structural evidence layer. Additive: a file
    // becomes a source_version whose ParsedDocument is stored as ordered, typed
    // evidence_blocks with exact locators, plus a deterministic document_profile
    // and a parser_run record. Legacy knowledge_objects/chunks remain; these
    // tables become the authority as subsystems migrate. Nothing is dropped.
    private static let v37: String = """
    CREATE TABLE source_documents (
        id                 TEXT PRIMARY KEY NOT NULL,
        logical_source_id  TEXT NOT NULL,
        filename           TEXT NOT NULL,
        detected_type      TEXT NOT NULL,
        mime_type          TEXT,
        content_hash       TEXT NOT NULL,
        extraction_status  TEXT NOT NULL,
        metadata           TEXT,
        created_at         REAL NOT NULL
    );

    CREATE TABLE source_versions (
        id                 TEXT PRIMARY KEY NOT NULL,
        logical_source_id  TEXT NOT NULL,
        document_id        TEXT,
        content_hash       TEXT NOT NULL,
        supersedes         TEXT,
        valid_from         REAL NOT NULL,
        valid_to           REAL,
        is_current         INTEGER NOT NULL DEFAULT 1,
        original_url       TEXT,
        created_at         REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_source_versions_logical ON source_versions(logical_source_id);
    CREATE INDEX IF NOT EXISTS idx_source_versions_current ON source_versions(logical_source_id, is_current);

    CREATE TABLE evidence_blocks (
        id                    TEXT PRIMARY KEY NOT NULL,
        document_id           TEXT NOT NULL,
        source_version_id     TEXT,
        parent_block_id       TEXT,
        ordinal               INTEGER NOT NULL,
        kind                  TEXT NOT NULL,
        raw_text              TEXT NOT NULL,
        normalized_text       TEXT NOT NULL,
        locator               TEXT,
        extraction_method     TEXT NOT NULL,
        extraction_confidence REAL NOT NULL,
        language              TEXT,
        attributes            TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_blocks_version ON evidence_blocks(source_version_id);
    CREATE INDEX IF NOT EXISTS idx_blocks_document ON evidence_blocks(document_id, ordinal);
    CREATE INDEX IF NOT EXISTS idx_blocks_kind ON evidence_blocks(kind);
    CREATE INDEX IF NOT EXISTS idx_blocks_parent ON evidence_blocks(parent_block_id);

    CREATE TABLE evidence_block_edges (
        id            TEXT PRIMARY KEY NOT NULL,
        from_block_id TEXT NOT NULL,
        to_block_id   TEXT NOT NULL,
        relation      TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_block_edges_from ON evidence_block_edges(from_block_id);

    CREATE TABLE document_profiles (
        source_version_id      TEXT PRIMARY KEY NOT NULL,
        filename               TEXT NOT NULL,
        detected_type          TEXT NOT NULL,
        mime_type              TEXT,
        content_hash           TEXT NOT NULL,
        size_bytes             INTEGER NOT NULL DEFAULT 0,
        parser                 TEXT NOT NULL,
        parser_version         TEXT NOT NULL,
        language               TEXT,
        section_outline        TEXT,
        first_meaningful_block TEXT,
        block_count            INTEGER NOT NULL,
        page_count             INTEGER,
        sheet_count            INTEGER,
        slide_count            INTEGER,
        message_count          INTEGER,
        attachment_count       INTEGER,
        child_count            INTEGER,
        extraction_status      TEXT NOT NULL,
        warning_count          INTEGER NOT NULL DEFAULT 0,
        extraction_confidence  REAL NOT NULL DEFAULT 1.0,
        is_queryable           INTEGER NOT NULL DEFAULT 1,
        created_at             REAL NOT NULL
    );

    CREATE TABLE parser_runs (
        id                TEXT PRIMARY KEY NOT NULL,
        source_version_id TEXT,
        parser            TEXT NOT NULL,
        parser_version    TEXT NOT NULL,
        started_at        REAL NOT NULL,
        ended_at          REAL,
        status            TEXT NOT NULL,
        block_count       INTEGER,
        warning_count     INTEGER,
        error             TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_parser_runs_version ON parser_runs(source_version_id);
    """

    // A5.2 — Assertion provenance columns. The Assertion substrate becomes the
    // claim–evidence layer between structural EvidenceBlocks and typed
    // Event/Relationship rows: each assertion records the exact evidence blocks
    // that support it, the verbatim direct quote, the source that asserted it,
    // whether it was source-asserted vs deterministically-derived vs inferred,
    // and the extractor version that produced it. Additive with defaults so
    // existing rows remain valid; the legacy evidence_object_ids_json (KO-level)
    // stays for backward compatibility.
    private static let v38: String = """
    ALTER TABLE assertions ADD COLUMN evidence_block_ids_json TEXT NOT NULL DEFAULT '[]';
    ALTER TABLE assertions ADD COLUMN direct_quote TEXT;
    ALTER TABLE assertions ADD COLUMN asserting_source_id TEXT;
    ALTER TABLE assertions ADD COLUMN provenance TEXT NOT NULL DEFAULT 'source_asserted';
    ALTER TABLE assertions ADD COLUMN extractor_version TEXT NOT NULL DEFAULT 'v1';
    CREATE INDEX IF NOT EXISTS idx_assertions_source ON assertions(asserting_source_id);
    """

    // A5.8 — reversible human review. A `.reverse` review row records the id of
    // the review it undoes; the undone row is preserved (append-only). Additive,
    // nullable — older rows and non-reversal actions leave it NULL.
    private static let v39: String = """
    ALTER TABLE fact_reviews ADD COLUMN reversal_of TEXT;
    CREATE INDEX IF NOT EXISTS idx_fact_reviews_reversal ON fact_reviews(reversal_of);
    """

    // A5.9 / A5.10 — answer→block replay. A claim_evidence row for an event
    // citation records the event's supporting EvidenceBlock ids (JSON array, so
    // multiple blocks fit one row without changing the composite PK), extending
    // the audit chain answer → claim → event → block → locator → source version.
    // Additive, nullable — older rows leave it NULL.
    private static let v40: String = """
    ALTER TABLE claim_evidence ADD COLUMN block_ids TEXT;
    """

    // A6.1 — full-text index over the structural evidence layer, so retrieval
    // can find typed EvidenceBlocks (with exact locators) directly rather than
    // only flattened chunks. External-content FTS5 over evidence_blocks
    // .normalized_text, kept in sync by triggers, rebuilt from existing rows.
    // Additive: no existing table/behaviour changes.
    private static let v41: String = """
    CREATE VIRTUAL TABLE IF NOT EXISTS evidence_blocks_fts USING fts5(
        normalized_text,
        content='evidence_blocks',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );

    CREATE TRIGGER IF NOT EXISTS evidence_blocks_fts_ai AFTER INSERT ON evidence_blocks BEGIN
        INSERT INTO evidence_blocks_fts(rowid, normalized_text) VALUES (new.rowid, new.normalized_text);
    END;
    CREATE TRIGGER IF NOT EXISTS evidence_blocks_fts_ad AFTER DELETE ON evidence_blocks BEGIN
        INSERT INTO evidence_blocks_fts(evidence_blocks_fts, rowid, normalized_text) VALUES('delete', old.rowid, old.normalized_text);
    END;
    CREATE TRIGGER IF NOT EXISTS evidence_blocks_fts_au AFTER UPDATE ON evidence_blocks BEGIN
        INSERT INTO evidence_blocks_fts(evidence_blocks_fts, rowid, normalized_text) VALUES('delete', old.rowid, old.normalized_text);
        INSERT INTO evidence_blocks_fts(rowid, normalized_text) VALUES (new.rowid, new.normalized_text);
    END;

    INSERT INTO evidence_blocks_fts(evidence_blocks_fts) VALUES('rebuild');
    """

    // A2 §7.3/§7.7 — durable per-file ingest outcome, so a failed or skipped
    // ingest is visible (Sources UI) and re-tryable rather than silently lost.
    // Append-only log keyed by URL + content hash; the latest row per URL is the
    // current state. Additive; no existing table/behaviour changes.
    private static let v42: String = """
    CREATE TABLE ingest_file_attempts (
        id            TEXT PRIMARY KEY NOT NULL,
        url           TEXT NOT NULL,
        content_hash  TEXT,
        status        TEXT NOT NULL,
        stage         TEXT,
        detail        TEXT,
        attempted_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_ingest_attempts_url ON ingest_file_attempts(url, attempted_at);
    CREATE INDEX IF NOT EXISTS idx_ingest_attempts_status ON ingest_file_attempts(status);
    """

    // A2 §7.6 — parent→child source provenance (email→attachment, archive→
    // member, …) persisted as explicit relations, so an attachment folded into
    // one canonical copy by dedup still records WHICH parents referenced it.
    // Additive; deduped by (parent, child, relation).
    private static let v43: String = """
    CREATE TABLE source_relations (
        id             TEXT PRIMARY KEY NOT NULL,
        parent_file_id TEXT NOT NULL,
        child_file_id  TEXT NOT NULL,
        relation       TEXT NOT NULL,
        created_at     REAL NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_source_relations_unique
        ON source_relations(parent_file_id, child_file_id, relation);
    CREATE INDEX IF NOT EXISTS idx_source_relations_child ON source_relations(child_file_id);
    """

    // PI.1 — version-instead-of-delete. When a known file's bytes change, the
    // pipeline USED to cascade-delete the old file row (destroying its
    // extracted KO content). That violated "never delete extracted data". These
    // additive history tables let ingest ARCHIVE the prior version's file record
    // + KO content BEFORE the active rows are refreshed, so no extraction is
    // ever silently lost and the change is auditable. Active tables still hold
    // only the current version (retrieval unchanged — zero regression); surfacing
    // old versions in retrieval is deferred to the version-aware fusion (P5.1).
    private static let v44: String = """
    CREATE TABLE IF NOT EXISTS file_versions (
        version_id     TEXT PRIMARY KEY NOT NULL,
        file_id        TEXT NOT NULL,
        url            TEXT NOT NULL,
        source_type    TEXT NOT NULL,
        size_bytes     INTEGER NOT NULL DEFAULT 0,
        modified_at    REAL,
        ingested_at    REAL,
        content_hash   TEXT,
        superseded_at  REAL NOT NULL,
        superseded_by  TEXT,
        created_at     REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_file_versions_file ON file_versions(file_id);
    CREATE INDEX IF NOT EXISTS idx_file_versions_hash ON file_versions(content_hash);

    CREATE TABLE IF NOT EXISTS knowledge_objects_history (
        history_id     TEXT PRIMARY KEY NOT NULL,
        object_id      TEXT NOT NULL,
        file_id        TEXT NOT NULL,
        source_type    TEXT NOT NULL,
        content        TEXT NOT NULL,
        metadata_json  TEXT NOT NULL DEFAULT '{}',
        confidence     REAL NOT NULL DEFAULT 1.0,
        superseded_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_ko_history_object ON knowledge_objects_history(object_id);
    CREATE INDEX IF NOT EXISTS idx_ko_history_file ON knowledge_objects_history(file_id);
    """

    // MARK: - v45 — Persona features Epic 1: the shared evidence-work engine
    //
    // (Research-grounded persona program, F1 + F2.) ONE engine, many
    // work-product templates — NOT five persona apps. This migration adds:
    //
    //   workspaces          — a bounded matter / investigation / research
    //       question / personal issue. A workspace is a FILTERED VIEW over the
    //       single ledger; membership rows point at existing files/entities and
    //       NEVER duplicate evidence. Removing a membership row never deletes
    //       evidence; deleting a file cascades only the membership pointer.
    //   workspace_sources   — file membership (a source may belong to many
    //       workspaces).
    //   workspace_entities  — entity membership.
    //
    //   review_tags         — tag definitions (workspace-scoped or global).
    //   review_decisions    — APPEND-ONLY review ledger. Every tag application,
    //       review-state change, and note is a new row carrying prior→new values
    //       and the reviewer; nothing is ever UPDATEd/DELETEd, so history is
    //       complete and a decision is reversed by appending a reversing row
    //       (mirrors fact_reviews v33/v39). Polymorphic target_kind covers
    //       source / evidenceBlock / assertion / event / entity / relationship /
    //       contradiction / gap / answerClaim.
    //   saved_views         — named, reopenable filter sets over a workspace.
    //   saved_view_filters  — key/value filter pairs for a saved view.
    //
    // Persona templates (F6) change only default fields, tags, layout, and
    // terminology — never these tables' semantics. Additive; no existing table
    // is touched.
    private static let v45: String = """
    CREATE TABLE workspaces (
        id                 TEXT PRIMARY KEY NOT NULL,
        title              TEXT NOT NULL,
        template_type      TEXT NOT NULL DEFAULT 'general',
        description        TEXT,
        status             TEXT NOT NULL DEFAULT 'active',
        default_date_start REAL,
        default_date_end   REAL,
        default_scope_json TEXT NOT NULL DEFAULT '{}',
        created_at         REAL NOT NULL,
        updated_at         REAL NOT NULL,
        archived_at        REAL
    );
    CREATE INDEX idx_workspaces_status ON workspaces(status);

    CREATE TABLE workspace_sources (
        workspace_id  TEXT NOT NULL,
        file_id       TEXT NOT NULL,
        added_at      REAL NOT NULL,
        PRIMARY KEY (workspace_id, file_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_workspace_sources_file ON workspace_sources(file_id);

    CREATE TABLE workspace_entities (
        workspace_id  TEXT NOT NULL,
        entity_id     TEXT NOT NULL,
        added_at      REAL NOT NULL,
        PRIMARY KEY (workspace_id, entity_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_workspace_entities_entity ON workspace_entities(entity_id);

    CREATE TABLE review_tags (
        id            TEXT PRIMARY KEY NOT NULL,
        workspace_id  TEXT,
        name          TEXT NOT NULL,
        color         TEXT,
        kind          TEXT NOT NULL DEFAULT 'user',
        created_at    REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_review_tags_workspace ON review_tags(workspace_id);

    CREATE TABLE review_decisions (
        id            TEXT PRIMARY KEY NOT NULL,
        workspace_id  TEXT,
        target_kind   TEXT NOT NULL,
        target_id     TEXT NOT NULL,
        dimension     TEXT NOT NULL DEFAULT 'reviewState',
        decision      TEXT,
        tag_id        TEXT,
        note          TEXT,
        prior_value   TEXT,
        reviewer      TEXT NOT NULL DEFAULT 'user',
        reversal_of   TEXT,
        created_at    REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_review_decisions_target ON review_decisions(target_kind, target_id, created_at);
    CREATE INDEX idx_review_decisions_workspace ON review_decisions(workspace_id);
    CREATE INDEX idx_review_decisions_tag ON review_decisions(tag_id);

    CREATE TABLE saved_views (
        id            TEXT PRIMARY KEY NOT NULL,
        workspace_id  TEXT,
        title         TEXT NOT NULL,
        created_at    REAL NOT NULL,
        updated_at    REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_saved_views_workspace ON saved_views(workspace_id);

    CREATE TABLE saved_view_filters (
        id            TEXT PRIMARY KEY NOT NULL,
        view_id       TEXT NOT NULL,
        filter_key    TEXT NOT NULL,
        filter_value  TEXT NOT NULL,
        FOREIGN KEY (view_id) REFERENCES saved_views(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_saved_view_filters_view ON saved_view_filters(view_id);
    """

    // MARK: - v46 — Persona features F9: research screening workflow
    //
    // A transparent, single-user screening log with PRISMA-COMPATIBLE flow
    // counts (§14). It does NOT claim independent dual-review compliance,
    // meta-analysis, or a final risk-of-bias judgment. `screening_protocols`
    // holds one structured inclusion protocol per workspace (JSON — PICO is
    // optional; not every review uses it). `screening_records` is one row per
    // candidate document with its current stage + decision + exclusion reason;
    // every exclusion must carry a reason (enforced in the repo/UI). Decisions
    // are reversible; the append-only WHY lives in the shared review ledger. No
    // LLM ever makes the final inclusion decision — suggestions stay separate
    // from reviewer decisions. Additive; no existing table touched.
    private static let v46: String = """
    CREATE TABLE screening_protocols (
        workspace_id   TEXT PRIMARY KEY NOT NULL,
        protocol_json  TEXT NOT NULL DEFAULT '{}',
        updated_at     REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );

    CREATE TABLE screening_records (
        id               TEXT PRIMARY KEY NOT NULL,
        workspace_id     TEXT NOT NULL,
        source_id        TEXT,
        title            TEXT NOT NULL,
        authors          TEXT,
        year             INTEGER,
        stage            TEXT NOT NULL DEFAULT 'identified',
        decision         TEXT NOT NULL DEFAULT 'unresolved',
        exclusion_reason TEXT,
        reviewer         TEXT NOT NULL DEFAULT 'user',
        disagreement     INTEGER NOT NULL DEFAULT 0,
        notes            TEXT,
        created_at       REAL NOT NULL,
        updated_at       REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_screening_records_ws ON screening_records(workspace_id);
    CREATE INDEX idx_screening_records_stage ON screening_records(workspace_id, stage);
    CREATE INDEX idx_screening_records_decision ON screening_records(workspace_id, decision);
    """

    // MARK: - v47 — Persona features F8: timestamped transcript segments
    //
    // Timecoded transcript lines for audio/video sources (§13). Produced ON
    // DEMAND from the transcript UI (not during ingest), so the ingest path is
    // untouched. Each segment carries a real start/end (jump-to-time), the ASR
    // confidence, and a user-assignable speaker — speaker diarization is NOT
    // done on-device, so speakers default to unassigned and are renamed/merged
    // by the user (uncertain speakers stay visible, §13). `marked_quote` flags
    // a segment the user wants to export with its timecode. Additive.
    private static let v47: String = """
    CREATE TABLE transcript_segments (
        id                  TEXT PRIMARY KEY NOT NULL,
        source_file_id      TEXT NOT NULL,
        source_url          TEXT NOT NULL,
        ordinal             INTEGER NOT NULL,
        start_time          REAL NOT NULL,
        end_time            REAL NOT NULL,
        speaker             TEXT,
        speaker_confidence  REAL,
        text                TEXT NOT NULL,
        asr_confidence      REAL NOT NULL DEFAULT 0,
        review_state        TEXT NOT NULL DEFAULT 'unreviewed',
        marked_quote        INTEGER NOT NULL DEFAULT 0,
        engine              TEXT NOT NULL DEFAULT '',
        created_at          REAL NOT NULL
    );
    CREATE INDEX idx_transcript_segments_source ON transcript_segments(source_file_id, ordinal);
    CREATE INDEX idx_transcript_segments_quote ON transcript_segments(marked_quote);

    CREATE VIRTUAL TABLE IF NOT EXISTS transcript_segments_fts USING fts5(
        text,
        content='transcript_segments',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS transcript_segments_fts_ai AFTER INSERT ON transcript_segments BEGIN
        INSERT INTO transcript_segments_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS transcript_segments_fts_ad AFTER DELETE ON transcript_segments BEGIN
        INSERT INTO transcript_segments_fts(transcript_segments_fts, rowid, text) VALUES('delete', old.rowid, old.text);
    END;
    CREATE TRIGGER IF NOT EXISTS transcript_segments_fts_au AFTER UPDATE ON transcript_segments BEGIN
        INSERT INTO transcript_segments_fts(transcript_segments_fts, rowid, text) VALUES('delete', old.rowid, old.text);
        INSERT INTO transcript_segments_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    """

    // MARK: - v48 — Stage 1 ingest quality gate: chunk embedding-admission flag
    //
    // "Do not embed everything." Chunks that are blank, tiny fragments, bare
    // page numbers, or lone navigation tokens carry no semantic signal. This
    // flag lets ingest mark such chunks as NOT admitted to the vector index
    // (ChunkAdmissionGate decides). Non-admitted chunks are still STORED and
    // remain FTS-/citation-searchable — nothing is deleted; they are only
    // excluded from embedding. Existing rows default to 1 (admitted), so the
    // vector layer is unchanged for anything ingested before this gate.
    private static let v48: String = """
    ALTER TABLE chunks ADD COLUMN admit_embedding INTEGER NOT NULL DEFAULT 1;
    CREATE INDEX IF NOT EXISTS idx_chunks_admit_embedding ON chunks(admit_embedding);
    """

    // MARK: - v49 — human-in-loop entity review status (soft-exclude, reversible)
    //
    // Lets a user REJECT (exclude) or RESTORE a canonical entity from the
    // Knowledge browser. Honoring the preserve-everything directive, a rejected
    // entity is NOT deleted: `review_status = 'rejected'` marks it so the entity
    // read surface (list / search / mention-ranked candidates) hides it by
    // default, and setting it back to NULL restores it. The action itself is
    // recorded append-only in fact_reviews (subject_kind = 'entity'), so it
    // shows in the Audit trail and can be undone. NULL = normal (the default for
    // every existing row), so nothing changes for data ingested before this.
    private static let v49: String = """
    ALTER TABLE entities ADD COLUMN review_status TEXT NULL;
    CREATE INDEX IF NOT EXISTS idx_entities_review_status ON entities(review_status);
    """

    // MARK: - v50 — human-in-loop event review status (soft-exclude, reversible)
    //
    // Extends the v49 entity mechanism to events: a user can Reject (exclude) or
    // Restore a single event from its detail sheet. `review_status = 'rejected'`
    // hides the event from the timeline, retrieval, and answers; NULL restores
    // it. The row and its trust `status` column are untouched (preserve-
    // everything). The action is recorded append-only in fact_reviews
    // (subject_kind = 'event'), so it shows in the Audit trail and is reversible.
    private static let v50: String = """
    ALTER TABLE events ADD COLUMN review_status TEXT NULL;
    CREATE INDEX IF NOT EXISTS idx_events_review_status ON events(review_status);
    """

    // MARK: - v51 — human-in-loop chunk review status (soft-exclude, reversible)
    //
    // Finest-grain reject: a user can exclude a single passage (chunk) from the
    // search index and answers, reversibly, from a search result. `review_status
    // = 'rejected'` drops the chunk from FTS, vector-hit hydration, and
    // first-chunk lookups; NULL restores it. Distinct from `admit_embedding`
    // (which is the ingest-time "don't embed noise" gate): this is an explicit
    // human decision, recorded append-only in fact_reviews (subject_kind =
    // 'chunk'). The chunk text and row are never deleted.
    private static let v51: String = """
    ALTER TABLE chunks ADD COLUMN review_status TEXT NULL;
    CREATE INDEX IF NOT EXISTS idx_chunks_review_status ON chunks(review_status);
    """

    // MARK: - v52 — human-in-loop entity merge (soft, reversible)
    //
    // Lets a user (or a deterministic suggester) unify two canonical entities
    // that are the same real-world thing ("J. Smith" → "John Smith"). Honoring
    // the preserve-everything directive, the loser row is NOT deleted or
    // FK-repointed: `merged_into = <winner id>` marks it, so canonical listings
    // hide it and the winner's mention view folds in the loser's mentions. NULL
    // = not merged (the default for every existing row). Setting it back to NULL
    // is a full unmerge (split). The action is recorded append-only in
    // fact_reviews (subject_kind = 'entity', action 'merge'/'reverse'), so it
    // shows in the Audit trail and is reversible. Self-reference is rejected in
    // the repository; a small resolve chain (with a depth cap) yields the final
    // canonical so a merged-into-a-merged case still resolves.
    private static let v52: String = """
    ALTER TABLE entities ADD COLUMN merged_into TEXT NULL REFERENCES entities(id);
    CREATE INDEX IF NOT EXISTS idx_entities_merged_into ON entities(merged_into);
    """

    // MARK: - v53 — proactive change-monitoring snapshots
    //
    // A snapshot captures the set of content-derived SIGNATURES of the
    // contradictions + gaps present at a moment (kind + normalized claims/desc,
    // NOT the volatile per-scan UUIDs), so a later diff can surface what's NEW or
    // RESOLVED since the user last acknowledged. One row per acknowledged
    // snapshot; the newest is the baseline. Derived data — safe to clear/rebuild.
    private static let v53: String = """
    CREATE TABLE IF NOT EXISTS monitor_snapshots (
        id                  TEXT PRIMARY KEY NOT NULL,
        created_at          REAL NOT NULL,
        signatures_json     TEXT NOT NULL DEFAULT '[]',
        contradiction_count INTEGER NOT NULL DEFAULT 0,
        gap_count           INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_monitor_snapshots_created ON monitor_snapshots(created_at);
    """

    // MARK: - v54 — evidence-first chunking + model-aware embeddings (Phase 1)
    //
    // Two additive changes, both preserving every existing row (audit P0:
    // "Do not remove chunks or vectors").
    //
    // 1. chunks.evidence_block_id + block_kind — a chunk derived from a typed
    //    EvidenceBlock records exactly which block it came from and that block's
    //    kind. NULL for legacy chunks (derived from flattened KO.content) and
    //    for formats with no structural parser, so retrieval can prefer
    //    block-backed chunks without breaking the fallback path.
    //
    // 2. chunk_embeddings — model-aware vector storage keyed by
    //    (chunk_id, model_id) so an Apple index and a quality (Core ML) index
    //    can COEXIST instead of one overwriting the other (audit P0 #6). The
    //    legacy `vectors` table is left untouched; its rows are backfilled here
    //    tagged with the current Apple model id, so no embedding is lost and the
    //    read path can migrate incrementally.
    private static let v54: String = """
    ALTER TABLE chunks ADD COLUMN evidence_block_id TEXT NULL;
    CREATE INDEX IF NOT EXISTS idx_chunks_evidence_block ON chunks(evidence_block_id);
    ALTER TABLE chunks ADD COLUMN block_kind TEXT NULL;

    CREATE TABLE IF NOT EXISTS chunk_embeddings (
        chunk_id      TEXT NOT NULL,
        model_id      TEXT NOT NULL,
        model_version TEXT NOT NULL DEFAULT '1',
        dim           INTEGER NOT NULL,
        q             BLOB NOT NULL,
        scale         REAL NOT NULL,
        created_at    REAL NOT NULL,
        PRIMARY KEY (chunk_id, model_id),
        FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_chunk_embeddings_model ON chunk_embeddings(model_id);
    INSERT OR IGNORE INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
        SELECT chunk_id, 'apple.nl.v1', '1', dim, q, scale, strftime('%s','now') FROM vectors;
    """

    // LAB-002 — durable, paged store for the Workbench EvidenceDataset kernel. A dataset's
    // columns live in `evidence_datasets`; its rows are paged in `dataset_rows` (cells as
    // JSON, each carrying its source-block lineage). Append-only, additive — no existing
    // table touched. FK cascade so deleting a dataset drops its rows.
    private static let v55: String = """
    CREATE TABLE IF NOT EXISTS evidence_datasets (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        version      INTEGER NOT NULL DEFAULT 1,
        columns_json TEXT NOT NULL,
        created_at   REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS dataset_rows (
        dataset_id TEXT NOT NULL,
        ordinal    INTEGER NOT NULL,
        cells_json TEXT NOT NULL,
        PRIMARY KEY (dataset_id, ordinal),
        FOREIGN KEY (dataset_id) REFERENCES evidence_datasets(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_dataset_rows_dataset ON dataset_rows(dataset_id);
    """

    // ING-001 — durable ingest run-state so an interrupted ingest can be resumed instead of
    // silently half-done. `ingest_runs` is the run header; `ingest_run_files` records each
    // file's transition (pending→running→done/failed) keyed by a stable path hash. Append-only,
    // additive. A run left in 'running'/'paused' at boot is resumable.
    private static let v56: String = """
    CREATE TABLE IF NOT EXISTS ingest_runs (
        id              TEXT PRIMARY KEY,
        status          TEXT NOT NULL,        -- pending|running|paused|completed|failed
        total_files     INTEGER NOT NULL DEFAULT 0,
        completed_files INTEGER NOT NULL DEFAULT 0,
        failed_files    INTEGER NOT NULL DEFAULT 0,
        started_at      REAL NOT NULL,
        updated_at      REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ingest_run_files (
        run_id     TEXT NOT NULL,
        path_hash  TEXT NOT NULL,
        path       TEXT NOT NULL,
        state      TEXT NOT NULL,             -- pending|running|done|failed
        error      TEXT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (run_id, path_hash),
        FOREIGN KEY (run_id) REFERENCES ingest_runs(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_ingest_run_files_run ON ingest_run_files(run_id);
    CREATE INDEX IF NOT EXISTS idx_ingest_runs_status ON ingest_runs(status);
    """

    // SEM — durable store for domain-pack GenericFacts (subject/field/value + evidence + the
    // locked EvidenceStatus vocabulary). Source blocks kept as JSON so a fact always drills to
    // evidence. Append-only, additive. Indexed by (subject_label, field) for lookup.
    private static let v57: String = """
    CREATE TABLE IF NOT EXISTS generic_facts (
        id                TEXT PRIMARY KEY,
        subject_id        TEXT NULL,
        subject_label     TEXT NOT NULL,
        field             TEXT NOT NULL,
        value             TEXT NOT NULL,
        unit              TEXT NULL,
        status            TEXT NOT NULL,
        confidence        REAL NOT NULL,
        source_blocks_json TEXT NOT NULL,
        created_at        REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_generic_facts_subject_field ON generic_facts(subject_label, field);
    """

    // EV-004 — extend the EXISTING v28 `corpus_snapshots` census table with the
    // processing-version fields that make an output reproducible (embedding model,
    // retrieval-config / persona-policy / parser versions, scope, readiness), and add
    // `snapshot_sources` pinning the exact source-version IDs + content hashes the
    // snapshot covered. ALTER (not CREATE) because the table already exists — this is
    // the EV-006 "one version model" consolidation, not a parallel table. Append-only;
    // ADD COLUMN runs exactly once (guarded by user_version), so no duplicate-column
    // error. No cascade delete removes historical snapshots.
    private static let v58: String = """
    ALTER TABLE corpus_snapshots ADD COLUMN scope TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN embedding_model TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN retrieval_config_version TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN persona_policy_version TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN parser_versions_json TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN readiness REAL;
    CREATE TABLE IF NOT EXISTS snapshot_sources (
        snapshot_id       TEXT NOT NULL,
        source_version_id TEXT NOT NULL,
        content_hash      TEXT NULL,
        PRIMARY KEY (snapshot_id, source_version_id)
    );
    CREATE INDEX IF NOT EXISTS idx_snapshot_sources_snapshot ON snapshot_sources(snapshot_id);
    """

    // PERF.2 — durable enrichment-job ledger for the two-pass model (06_INGESTION §2/§4/§5).
    // The queryable core commits fast; deep enrichment (embeddings, typed facts, entity
    // reconciliation, contradiction/gap scans, OCR/ASR) is queued here as durable,
    // idempotent, resumable post-commit jobs. UNIQUE(subject_id, kind) makes enqueue
    // idempotent (a re-ingest doesn't duplicate work); state lets boot recovery find and
    // resume incomplete jobs and Sources show per-dimension readiness. Append-only rows;
    // never leaves invisible partial state.
    private static let v59: String = """
    CREATE TABLE IF NOT EXISTS enrichment_jobs (
        id           TEXT PRIMARY KEY NOT NULL,
        subject_id   TEXT NOT NULL,
        kind         TEXT NOT NULL,
        state        TEXT NOT NULL,
        attempts     INTEGER NOT NULL DEFAULT 0,
        last_error   TEXT,
        created_at   REAL NOT NULL,
        updated_at   REAL NOT NULL,
        UNIQUE(subject_id, kind)
    );
    CREATE INDEX IF NOT EXISTS idx_enrichment_jobs_state ON enrichment_jobs(state, kind);
    """
}

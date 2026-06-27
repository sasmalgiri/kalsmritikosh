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

    public static let latestVersion = 15

    /// Apply every migration newer than the current `user_version`. Each
    /// migration runs inside a SAVEPOINT so a partial DDL failure leaves
    /// the schema at the previous version instead of half-applied.
    public static func migrate(_ database: Database) async throws {
        let current = try await database.currentUserVersion()
        for (version, sql) in all where version > current {
            let savepoint = "atlas_mig_v\(version)"
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
        (18, v18)
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
}

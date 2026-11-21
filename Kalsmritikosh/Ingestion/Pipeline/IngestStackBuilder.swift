//
//  IngestStackBuilder.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), PERF-16 — builds the repository set and an IngestCoordinator
//  for ANY Database, wired the way AppState.boot wires the main ledger's ingest (same parser registry,
//  cleaner, chunker, entity / event / narrative-slot / relationship extractors, quality gate, typed
//  fields, evidence blocks, assertions, generic facts, custody, readiness, container inspection, canonical
//  source intake, managed evidence vault, progressive-upgrade bookkeeping). A shard worker uses it so the
//  full ingest pipeline runs against its own shard ledger.
//
//  Left out on purpose for a shard: vectors and the embedder (the main ledger's background embedding
//  drain embeds the merged chunks with the main ledger's active model), synthetic questions (already off
//  in release), the claim projection (run on the main ledger after the merge), the query-priority gate
//  (a shard never touches the main ledger while it is written) and the upgrade drain (scheduled upgrade
//  jobs are merged and drained by the main ledger).
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation
import os

@MainActor
public enum IngestStackBuilder {
    /// An IngestCoordinator writing to `db`. `vault` is the main ledger's evidence vault (the copies are
    /// content-addressed, so a shard and the main ledger share it); `chunker` should be the main
    /// coordinator's, so shard chunks are cut the same way.
    public static func makeCoordinator(database db: Database, vault: EvidenceVault?, chunker: Chunker) throws -> IngestCoordinator {
        let registry = try UniversalParserRegistryBuilder.standard(
            ocr: VisionOCR(),
            iMessageEnabled: FeatureFlags.shared.iMessageLoaderEnabled,
            browserHistoryEnabled: FeatureFlags.shared.browserHistoryLoaderEnabled,
            chatExportEnabled: FeatureFlags.shared.chatExportLoaderEnabled,
            mediaTranscriptionEnabled: KnowledgeModuleFlags.isEnabled(.mediaTranscription))
        let evidenceStore = EvidenceStore(database: db)
        let assertions = AssertionsRepository(database: db)
        let genericFacts = GenericFactRepository(database: db)
        let factBonds = FactBondsRepository(database: db)
        return IngestCoordinator(
            universalRegistry: registry,
            chunker: chunker,
            entityExtractor: NLEntityExtractor(),
            entityLinker: EntityLinker(),
            entityQualityGate: EntityQualityGate.bundled(),
            eventExtractor: RuleEventExtractor(),
            narrativeSlotExtractor: RuleNarrativeSlotExtractor(),
            relationshipExtractor: Tier1RelationshipExtractor(),
            embedder: nil,
            files: FilesRepository(database: db),
            objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db),
            entities: EntitiesRepository(database: db),
            events: EventsRepository(database: db),
            relationships: RelationshipsRepository(database: db),
            vectors: nil,
            syntheticQuestions: nil,
            syntheticQuestionGenerator: nil,
            synthQueue: nil,
            qaPairs: QAPairsRepository(database: db),
            qaPairExtractor: EmailThreadQAPairExtractor(),
            bondConstructor: BondConstructor(repository: factBonds, cache: InMemoryBondGraph()),
            emailParticipantRepository: EmailParticipantRepository(database: db),
            contextPrefixGenerator: nil,
            pipelineMetrics: nil,
            custody: CustodyRepository(database: db),
            evidenceStore: evidenceStore,
            assertions: assertions,
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            genericFacts: genericFacts,
            evidenceVault: vault,
            priorityGate: nil,
            claimProjection: nil,
            readiness: SourceReadinessRepository(database: db),
            typedFields: TypedFieldRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db),
            intakeCoordinator: UniversalSourceIntakeCoordinator(
                repository: CanonicalSourceIntakeRepository(database: db, vault: vault)))
    }

    /// The coordinator plus its progressive-upgrade bookkeeping (completion snapshot, resumable stream
    /// outcomes, boilerplate registry) against the same database — the upgrade drain is NOT started.
    public static func makeConfiguredCoordinator(database db: Database, vault: EvidenceVault?, chunker: Chunker) async throws -> IngestCoordinator {
        let ingest = try makeCoordinator(database: db, vault: vault, chunker: chunker)
        await ingest.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db), priorityGate: nil)
        return ingest
    }
}

//
//  AppState+Comparison.swift
//  Kalsmritikosh
//
//  G3 Workflow C (T-G3.3) — the live-data adapter for the comparison brief.
//  It reads the facts each selected document actually asserts, discovers the
//  fields those documents have in common, and runs the TESTED deterministic
//  core (ComparisonLedgerResolver → ComparisonService) over them. Precomputes
//  the resolver's two maps from real ledger reads so the brief runs on the
//  user's archive with no model call and no fabricated field.
//

import Foundation

public struct DocumentComparisonResult: Sendable {
    public let cells: [ComparisonCell]
    public let brief: ComparisonBrief
    /// The fields discovered across the chosen documents (canonical names).
    public let fields: [String]
    /// object id (uuidString) → display filename, in the order compared.
    public let sources: [(id: String, label: String)]
}

extension AppState {
    /// Compare what each of `objectIDs` says, field by field. Fields are
    /// DISCOVERED from the facts those documents carry (union, restricted to
    /// registered fields) — the caller does not have to name them. Returns nil
    /// when the ledger repositories aren't ready or fewer than two documents
    /// carry comparable facts.
    public func compareDocuments(objectIDs: [UUID]) async -> DocumentComparisonResult? {
        guard let genericFacts, let evidenceStore, let objects else { return nil }
        guard objectIDs.count >= 2 else { return nil }

        // 1) Gather each document's facts via its current version's blocks, and
        //    record which document every evidence block belongs to.
        var blockToDoc: [UUID: UUID] = [:]
        var factsByField: [String: [GenericFact]] = [:]
        var docsWithFacts: [UUID] = []

        for objID in objectIDs {
            guard let versionID = try? await evidenceStore.currentVersionID(forObject: objID) else { continue }
            let blocks = (try? await evidenceStore.blocks(forVersion: versionID)) ?? []
            guard !blocks.isEmpty else { continue }
            let blockIDs = blocks.map(\.id)
            for b in blockIDs { blockToDoc[b] = objID }

            let facts = (try? await genericFacts.facts(forBlockIDs: blockIDs)) ?? []
            var hasComparable = false
            for f in facts {
                let canon = FactSchemaRegistry.normalizeField(f.field)
                guard FieldRegistry.isKnown(canon) else { continue }
                factsByField[canon, default: []].append(f)
                hasComparable = true
            }
            if hasComparable { docsWithFacts.append(objID) }
        }
        guard docsWithFacts.count >= 2 else { return nil }

        // 2) Discovered fields — every registered field at least one chosen
        //    document asserts, sorted for a stable brief.
        let fields = Set(factsByField.keys).sorted()
        guard !fields.isEmpty else { return nil }

        // 3) Resolve display labels (filenames) for the source register.
        let names = (try? await objects.sourceFilenames(for: Set(docsWithFacts))) ?? [:]
        let sources: [(id: String, label: String)] = docsWithFacts.map {
            ($0.uuidString, names[$0] ?? String($0.uuidString.prefix(8)))
        }

        // 4) Run the TESTED core over the precomputed maps (no live DB in the
        //    resolver's hot loop; same stated/none/silent + unit logic as unit
        //    tests). `documentOfBlock` is a pure dictionary read.
        let resolver = ComparisonLedgerResolver(
            factsForField: { field in
                factsByField[FactSchemaRegistry.normalizeField(field)] ?? []
            },
            documentOfBlock: { block in blockToDoc[block] })
        let service = ComparisonService(resolver: resolver)
        let (cells, brief) = await service.compare(fields: fields, sources: sources)
        return DocumentComparisonResult(cells: cells, brief: brief, fields: fields, sources: sources)
    }
}

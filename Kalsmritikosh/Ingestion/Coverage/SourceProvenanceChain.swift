//
//  SourceProvenanceChain.swift
//  Kalsmritikosh
//
//  Smart-map IN-03 / SRC-06 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §04, §05): where an
//  extracted item came from, reconstructed from the ledger — the passage (evidence block) → the exact source
//  version it was read from → every parent that contained it (the email it was attached to, the archive and
//  member path it was unpacked from, the document it was embedded in), up to the root file → the intake
//  receipts that record when and how each was received. Derivation links are shown both ways: the original a
//  derived copy (a decrypted copy, a converted image) was made from, with the method, and the copies made
//  from this version.
//
//  Read-only over the one ledger (source_version_relations, container_members, source_intake_receipts,
//  source_conversions, evidence_blocks). A source reachable by several parents keeps every path. The walk is
//  cycle-safe and bounded; a chain cut short says so (`truncated`) instead of pretending to reach a root.
//

import Foundation

/// One version in a provenance path.
public nonisolated struct SourceProvenanceNode: Sendable, Equatable, Identifiable {
    public let sourceVersionID: UUID
    public let filename: String
    public let detectedType: String
    public let contentHash: String
    public let isCurrent: Bool
    /// How the PREVIOUS item of the path sits inside this one: "attachment", "archiveMember", "message",
    /// "embedded", "derivedConversion". Nil for the starting version.
    public let relationOfPrevious: String?
    /// The member path of the previous item inside this archive, when it was unpacked from one.
    public let memberPath: String?
    /// The previous item's position inside this one (attachment / member ordinal), when recorded.
    public let ordinal: Int?
    public var id: UUID { sourceVersionID }

    /// Plain words for the step from the previous item to this one ("attached to", "unpacked from", …).
    public var relationLabel: String? {
        switch relationOfPrevious {
        case "attachment": return "attached to"
        case "archiveMember": return memberPath.map { "unpacked as “\($0)” from" } ?? "unpacked from"
        case "message": return "a message in"
        case "embedded": return "embedded in"
        case "derivedConversion": return "made from"
        case let other?: return other
        case nil: return nil
        }
    }
}

/// How a version was received: one intake receipt.
public nonisolated struct SourceIntakeReceiptSummary: Sendable, Equatable {
    public let sourceVersionID: UUID
    public let outcome: String
    public let originalURL: String?
    public let custodyMode: String
    public let preservationStatus: String
    public let recordedAt: Date
}

/// A derived copy and the original it was made from (SRC-06).
public nonisolated struct SourceDerivationLink: Sendable, Equatable {
    public let originalSourceVersionID: UUID
    public let derivedSourceVersionID: UUID
    /// The recorded method ("decrypted with a password the investigator supplied", "converted to PNG", …);
    /// nil when the relation exists but no method was recorded (links written before v178).
    public let method: String?
    public let originalFilename: String
    public let derivedFilename: String
}

/// The passage an extracted item was read from.
public nonisolated struct SourceProvenanceBlock: Sendable, Equatable {
    public let blockID: UUID
    public let sourceVersionID: UUID
    public let kind: String
    public let page: Int?
    public let extractionMethod: String
    public let extractionConfidence: Double
    /// True when a later reading of the same version replaced this block (it is kept for citations).
    public let supersededByLaterReading: Bool
}

public nonisolated struct SourceProvenanceChain: Sendable, Equatable {
    /// The block it started from, when it started from one.
    public let block: SourceProvenanceBlock?
    /// The exact version the item was read from.
    public let version: SourceProvenanceNode
    /// Every path from the version up to a root, nearest parent first. Empty when the version was received
    /// directly (it is its own root).
    public let parentPaths: [[SourceProvenanceNode]]
    /// Intake receipts of the version and of every root it was reached from.
    public let receipts: [SourceIntakeReceiptSummary]
    /// The original(s) this version was derived from, when it is a derived copy.
    public let derivedFrom: [SourceDerivationLink]
    /// Copies derived from this version.
    public let derivatives: [SourceDerivationLink]
    /// True when the walk stopped at its bound or at a cycle before reaching every root.
    public let truncated: Bool

    /// The roots reached (the files the investigator actually supplied).
    public var roots: [SourceProvenanceNode] {
        let tops = parentPaths.compactMap(\.last)
        return tops.isEmpty ? [version] : tops
    }

    /// One readable line per path: "summary.pdf — attached to records.eml".
    public var pathDescriptions: [String] {
        guard !parentPaths.isEmpty else { return ["\(version.filename) — received directly"] }
        return parentPaths.map { path in
            path.reduce(version.filename) { line, parent in "\(line) — \(parent.relationLabel ?? "inside") \(parent.filename)" }
        }
    }
}

public nonisolated enum SourceProvenanceError: Error, Equatable, Sendable {
    case blockNotFound(UUID)
    case versionNotFound(UUID)
}

public nonisolated struct SourceProvenanceChainService: Sendable {
    private let database: Database
    /// Maximum parent hops walked per path (deeper than any container policy allows is not a real nesting).
    public static let maxDepth = 32
    /// Maximum distinct paths reported (a report attached to many emails lists each, up to this bound).
    public static let maxPaths = 64

    public init(database: Database) { self.database = database }

    /// The chain for the passage (evidence block) an item was extracted from.
    public func chain(forBlock blockID: UUID) async throws -> SourceProvenanceChain {
        guard let r = try await database.query("""
            SELECT source_version_id, kind, locator, extraction_method, extraction_confidence, superseded_by_run
              FROM evidence_blocks WHERE id = ? LIMIT 1;
            """, [.uuid(blockID)]).first, let version = r.uuid(0) else {
            throw SourceProvenanceError.blockNotFound(blockID)
        }
        let block = SourceProvenanceBlock(
            blockID: blockID, sourceVersionID: version, kind: r.string(1) ?? "", page: Self.page(fromLocator: r.string(2)),
            extractionMethod: r.string(3) ?? "", extractionConfidence: r.double(4) ?? 0,
            supersededByLaterReading: !r.isNull(5))
        return try await build(versionID: version, block: block)
    }

    /// The chain for an exact source version.
    public func chain(forVersion versionID: UUID) async throws -> SourceProvenanceChain {
        try await build(versionID: versionID, block: nil)
    }

    private func build(versionID: UUID, block: SourceProvenanceBlock?) async throws -> SourceProvenanceChain {
        guard let me = try await node(versionID, link: nil) else { throw SourceProvenanceError.versionNotFound(versionID) }

        // Depth-first over parents with an explicit stack; every path is kept. A version already on the
        // current path is a cycle (recorded as truncation, never followed).
        var paths: [[SourceProvenanceNode]] = []
        var truncated = false
        var stack: [(child: UUID, path: [SourceProvenanceNode], onPath: Set<UUID>)] = [(versionID, [], [versionID])]
        while let top = stack.popLast() {
            let (child, path, onPath) = (top.child, top.path, top.onPath)
            if paths.count >= Self.maxPaths { truncated = true; break }
            let parents = try await parentLinks(of: child)
            if parents.isEmpty {
                if !path.isEmpty { paths.append(path) }
                continue
            }
            if path.count >= Self.maxDepth { truncated = true; paths.append(path); continue }
            var followed = 0
            // Reverse so the first-recorded parent is explored first (stack order).
            for p in parents.reversed() {
                if onPath.contains(p.parent) { truncated = true; continue }
                guard let parent = try await node(p.parent, link: p) else { continue }
                stack.append((p.parent, path + [parent], onPath.union([p.parent])))
                followed += 1
            }
            if followed == 0, !path.isEmpty { paths.append(path) }
        }

        var receiptVersions = [versionID]
        for p in paths { if let root = p.last?.sourceVersionID, !receiptVersions.contains(root) { receiptVersions.append(root) } }
        var receipts: [SourceIntakeReceiptSummary] = []
        for v in receiptVersions { receipts += try await intakeReceipts(v) }

        return SourceProvenanceChain(block: block, version: me, parentPaths: paths, receipts: receipts,
                                     derivedFrom: try await derivationLinks(column: "r.child_source_version_id", versionID),
                                     derivatives: try await derivationLinks(column: "r.parent_source_version_id", versionID),
                                     truncated: truncated)
    }

    // MARK: - Reads

    private nonisolated struct ParentLink { let parent: UUID; let relation: String; let memberPath: String?; let ordinal: Int? }

    private func node(_ id: UUID, link: ParentLink?) async throws -> SourceProvenanceNode? {
        guard let r = try await database.query(
            "SELECT filename, detected_type, content_hash, is_current FROM source_versions WHERE id = ? LIMIT 1;", [.uuid(id)]).first else { return nil }
        return SourceProvenanceNode(sourceVersionID: id, filename: r.string(0) ?? "source", detectedType: r.string(1) ?? "unknown",
                                    contentHash: r.string(2) ?? "", isCurrent: (r.int(3) ?? 0) != 0,
                                    relationOfPrevious: link?.relation, memberPath: link?.memberPath, ordinal: link?.ordinal)
    }

    private func parentLinks(of child: UUID) async throws -> [ParentLink] {
        try await database.query("""
            SELECT r.parent_source_version_id, r.relation, r.ordinal,
                   (SELECT m.member_path FROM container_members m
                     WHERE m.parent_source_version_id = r.parent_source_version_id AND m.child_source_version_id = r.child_source_version_id
                     ORDER BY m.ordinal LIMIT 1)
              FROM source_version_relations r WHERE r.child_source_version_id = ?
             ORDER BY r.created_at, r.parent_source_version_id;
            """, [.uuid(child)]).compactMap { r in
            guard let p = r.uuid(0), let rel = r.string(1) else { return nil }
            return ParentLink(parent: p, relation: rel, memberPath: r.string(3), ordinal: r.int(2).map(Int.init))
        }
    }

    private func intakeReceipts(_ version: UUID) async throws -> [SourceIntakeReceiptSummary] {
        try await database.query("""
            SELECT outcome, original_url, custody_mode, preservation_status, recorded_at
              FROM source_intake_receipts WHERE source_version_id = ? ORDER BY recorded_at, id;
            """, [.uuid(version)]).map { r in
            SourceIntakeReceiptSummary(sourceVersionID: version, outcome: r.string(0) ?? "", originalURL: r.string(1),
                                       custodyMode: r.string(2) ?? "", preservationStatus: r.string(3) ?? "",
                                       recordedAt: r.date(4) ?? Date(timeIntervalSince1970: 0))
        }
    }

    /// Derivation links through the `derivedConversion` relation (the authority), with the recorded method when
    /// present. `column` selects whether `id` is the derived copy (its originals) or the original (its copies).
    private func derivationLinks(column: String, _ id: UUID) async throws -> [SourceDerivationLink] {
        try await database.query("""
            SELECT r.parent_source_version_id, r.child_source_version_id, c.method,
                   COALESCE(pv.filename, 'source'), COALESCE(cv.filename, 'source')
              FROM source_version_relations r
              LEFT JOIN source_conversions c ON c.source_version_id = r.child_source_version_id
                                             AND c.original_source_version_id = r.parent_source_version_id
              LEFT JOIN source_versions pv ON pv.id = r.parent_source_version_id
              LEFT JOIN source_versions cv ON cv.id = r.child_source_version_id
             WHERE r.relation = 'derivedConversion' AND \(column) = ?
             ORDER BY r.created_at;
            """, [.uuid(id)]).compactMap { r in
            guard let p = r.uuid(0), let c = r.uuid(1) else { return nil }
            return SourceDerivationLink(originalSourceVersionID: p, derivedSourceVersionID: c, method: r.string(2),
                                        originalFilename: r.string(3) ?? "source", derivedFilename: r.string(4) ?? "source")
        }
    }

    /// The page number in a stored locator JSON (`{"page": 3, …}`), when it has one.
    nonisolated static func page(fromLocator json: String?) -> Int? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(SourceLocator.self, from: data))?.page
    }
}

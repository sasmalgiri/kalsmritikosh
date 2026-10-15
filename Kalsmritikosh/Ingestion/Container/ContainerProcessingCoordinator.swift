//
//  ContainerProcessingCoordinator.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-006 §13/§14/§15) — orchestrates safe container expansion. It inspects a container,
//  streams each surviving candidate to a temp file within the SHARED root budget, hands admitted
//  members to the full ingest pipeline (via a closure — intake managed custody + UniversalParserRegistry,
//  never a bypass path), records the container manifest + every member disposition, and recurses into
//  nested ZIP children within the shared depth / cycle / nested-container limits. Blocked / encrypted /
//  unsupported / failed members remain VISIBLE; none is silently dropped.
//

import Foundation
import OSLog
import CryptoKit

public struct ContainerProcessingCoordinator: Sendable {

    private let repository: ContainerInspectionRepository?
    private let policy: ContainerSafetyPolicy

    public init(repository: ContainerInspectionRepository?, policy: ContainerSafetyPolicy = .standard) {
        self.repository = repository
        self.policy = policy
    }

    /// The identity of a fully-ingested member, returned by the ingest closure.
    public struct MemberIngestOutcome: Sendable {
        public let childSourceVersionID: UUID?
        public let contentHash: String?
        public let detectedType: SourceType?
        public var succeeded: Bool { childSourceVersionID != nil && contentHash != nil }
        public init(childSourceVersionID: UUID?, contentHash: String?, detectedType: SourceType?) {
            self.childSourceVersionID = childSourceVersionID; self.contentHash = contentHash; self.detectedType = detectedType
        }
    }

    public typealias IngestMember = @Sendable (_ byteURL: URL, _ origin: URL, _ parent: SourceParentReference) async -> MemberIngestOutcome

    /// Expand ONE container SourceVersion whose bytes are at `byteURL`. Records the manifest + members.
    public func expand(containerVersionID: UUID, containerType: SourceType, byteURL: URL,
                       context: ContainerTraversalContext, now: Date, ingestMember: IngestMember) async {
        // Recognized-but-undecodable containers (RAR/7z): custody preserved, contents not enumerated.
        // "Unsupported with unknown contents" ≠ "empty container" — the manifest EXISTS to say so.
        // W4-2 — 7z is read natively while "More file types" is on (Copy/LZMA/LZMA2).
        if containerType == .sevenZip, ProductModuleFlags.isEnabled(.extraParsers) {
            await expandSevenZip(containerVersionID: containerVersionID, byteURL: byteURL, context: context,
                                 now: now, ingestMember: ingestMember)
            return
        }
        // RAR's format is proprietary and its licence forbids reimplementing the decoder, so RAR
        // stays recognised-not-expanded; 7z without the switch stays the same.
        if containerType == .rar || containerType == .sevenZip {
            do {
                _ = try await repository?.record(sourceVersionID: containerVersionID, containerType: containerType,
                                          status: .unsupported, members: [], at: now)
            } catch {
                KalsmritikoshLog.ingestion.error("ContainerProcessingCoordinator: manifest record failed — \(String(describing: error), privacy: .public)")
            }
            return
        }
        let enumeration = ZIPContainerInspector.inspect(url: byteURL, containerType: containerType, policy: policy)
        guard !enumeration.unreadable, let reader = enumeration.reader else {
            do {
                _ = try await repository?.record(sourceVersionID: containerVersionID, containerType: containerType,
                                          status: .failed, members: [], at: now)
            } catch {
                KalsmritikoshLog.ingestion.error("ContainerProcessingCoordinator: manifest record failed — \(String(describing: error), privacy: .public)")
            }
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usfm2-expand-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var members: [ContainerMember] = []
        var sawProblem = false

        for insp in enumeration.members {
            // Cheap dispositions decided by the inspector pass straight through, VISIBLE.
            if insp.disposition != .admitted {
                if insp.disposition != .directory { sawProblem = true }
                members.append(finalize(insp, parent: containerVersionID, disposition: insp.disposition)); continue
            }
            guard let entry = insp.entry else { sawProblem = true; members.append(finalize(insp, parent: containerVersionID, disposition: .failedExtraction)); continue }

            let dest = root.appendingPathComponent(insp.normalizedMemberPath)
            guard ZIPContainerExtractor.isContained(dest, inRoot: root) else {
                sawProblem = true; members.append(finalize(insp, parent: containerVersionID, disposition: .blockedUnsafePath, detail: "escapes extraction root")); continue
            }
            // Reserve the SHARED root budget BEFORE extracting.
            let verdict = context.budget.reserveMember(uncompressedBytes: insp.uncompressedSize)
            if verdict != .ok {
                sawProblem = true; members.append(finalize(insp, parent: containerVersionID, disposition: .blockedRootBudget, detail: "\(verdict)")); continue
            }
            // Stream-extract to the temp file (bounded).
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try ZIPContainerExtractor.streamExtract(reader: reader, entry: entry, to: dest, maxMemberBytes: policy.maxSingleMemberBytes)
            } catch let f as ZIPContainerExtractor.ExtractionFailure {
                sawProblem = true
                let d: ContainerMemberDisposition = f == .exceededCap ? .blockedSizeLimit : (f == .unsupportedCompression ? .unsupported : .failedExtraction)
                members.append(finalize(insp, parent: containerVersionID, disposition: d, detail: "\(f)")); continue
            } catch {
                sawProblem = true; members.append(finalize(insp, parent: containerVersionID, disposition: .failedExtraction)); continue
            }

            // Decide recursion BEFORE ingesting so a cycle/too-deep nested container is BLOCKED (fail
            // closed), never admitted or expanded. Its bytes still live inside the parent's custody.
            let childHash = Self.hashFile(dest)
            let expandable = Self.isExpandableZip(fileURL: dest, originName: insp.normalizedMemberPath)
            if expandable {
                if context.isCycle(childHash: childHash) {
                    sawProblem = true; members.append(finalize(insp, parent: containerVersionID, disposition: .blockedCycle, detail: "cycle with ancestor container")); continue
                }
                if context.wouldExceedDepth {
                    sawProblem = true; members.append(finalize(insp, parent: containerVersionID, disposition: .blockedDepth, detail: "nesting depth exceeded")); continue
                }
                if context.budget.registerNestedContainer() != .ok {
                    sawProblem = true; members.append(finalize(insp, parent: containerVersionID, disposition: .blockedRootBudget, detail: "nested container limit")); continue
                }
            }

            // Full ingest through the real pipeline (managed custody + universal parser).
            let origin = Self.origin(parent: containerVersionID, ordinal: insp.ordinal, name: insp.normalizedMemberPath)
            let parentRef = SourceParentReference(parentSourceVersionID: containerVersionID, relation: .archiveMember, ordinal: insp.ordinal)
            let outcome = await ingestMember(dest, origin, parentRef)
            guard outcome.succeeded, let childID = outcome.childSourceVersionID, let ch = outcome.contentHash else {
                sawProblem = true; members.append(finalize(insp, parent: containerVersionID, disposition: .failedExtraction, detail: "member ingest failed")); continue
            }
            members.append(ContainerMember(
                parentSourceVersionID: containerVersionID, ordinal: insp.ordinal, memberPath: insp.memberPath,
                normalizedMemberPath: insp.normalizedMemberPath, entryKind: .file, compressedSize: insp.compressedSize,
                uncompressedSize: insp.uncompressedSize, detectedType: outcome.detectedType ?? insp.detectedType,
                disposition: .admitted, childSourceVersionID: childID, contentHash: ch))

            // Recurse into a nested ZIP child, sharing the SAME root budget + ancestor chain.
            if (outcome.detectedType ?? .unknown) == .zip || expandable {
                await expand(containerVersionID: childID, containerType: .zip, byteURL: dest,
                             context: context.descending(intoContainerHash: ch), now: now, ingestMember: ingestMember)
            }
        }

        let status: ContainerManifestStatus = sawProblem ? .partial : .complete
        do {
            _ = try await repository?.record(sourceVersionID: containerVersionID, containerType: containerType,
                                      status: status, members: members, at: now)
        } catch {
            KalsmritikoshLog.ingestion.error("ContainerProcessingCoordinator: manifest record failed — \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Helpers

    private func finalize(_ insp: ContainerMemberInspection, parent: UUID, disposition: ContainerMemberDisposition, detail: String? = nil) -> ContainerMember {
        ContainerMember(parentSourceVersionID: parent, ordinal: insp.ordinal, memberPath: insp.memberPath,
                        normalizedMemberPath: insp.normalizedMemberPath, entryKind: insp.entryKind,
                        compressedSize: insp.compressedSize, uncompressedSize: insp.uncompressedSize,
                        detectedType: insp.entryKind == .file ? insp.detectedType : nil, disposition: disposition,
                        childSourceVersionID: nil, contentHash: nil, detail: detail ?? insp.detail)
    }

    static func origin(parent: UUID, ordinal: Int, name: String) -> URL {
        URL(string: "kalsmritikosh-container://\(parent.uuidString)/\(ordinal)/\(name)")
            ?? URL(fileURLWithPath: "/container/\(parent.uuidString)/\(ordinal)/\(name)")
    }

    static func hashFile(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether an extracted file is an EXPANDABLE ZIP (a plain zip, not a docx/xlsx/… compound subtype).
    static func isExpandableZip(fileURL: URL, originName: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        guard SourceType.sniffMagicBytes(head) == .zip else { return false }
        let ext = (originName as NSString).pathExtension
        return SourceType.zipSubtype(forDeclaredExtension: ext) == .zip
    }

    // MARK: - 7z (W4-2)

    /// Expand a .7z the same way as a ZIP: safe paths, per-member and ratio caps, the SHARED root
    /// budget, recursion limits, full ingest per member, and a manifest where nothing is dropped silently.
    private func expandSevenZip(containerVersionID: UUID, byteURL: URL, context: ContainerTraversalContext,
                                now: Date, ingestMember: IngestMember) async {
        func record(_ status: ContainerManifestStatus, _ members: [ContainerMember]) async {
            do {
                _ = try await repository?.record(sourceVersionID: containerVersionID, containerType: .sevenZip,
                                                 status: status, members: members, at: now)
            } catch {
                KalsmritikoshLog.ingestion.error("ContainerProcessingCoordinator: 7z manifest record failed — \(String(describing: error), privacy: .public)")
            }
        }
        let maxFolder = Int(min(policy.maxSingleMemberBytes * 4, Int64(Int32.max)))
        guard let bytes = try? Data(contentsOf: byteURL, options: .mappedIfSafe),
              let reader = try? SevenZipReader(data: bytes, maxFolderBytes: maxFolder) else {
            await record(.failed, []); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-7z-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var members: [ContainerMember] = []
        var sawProblem = false
        for (ordinal, e) in reader.entries.enumerated() {
            func member(_ normalized: String, _ disp: ContainerMemberDisposition, _ kind: ContainerEntryKind = .file,
                        detail: String? = nil, child: UUID? = nil, hash: String? = nil, type: SourceType? = nil) -> ContainerMember {
                ContainerMember(parentSourceVersionID: containerVersionID, ordinal: ordinal, memberPath: e.name,
                                normalizedMemberPath: normalized, entryKind: kind,
                                compressedSize: e.folder.map { reader.packedSize(folder: $0) } ?? 0, uncompressedSize: e.size,
                                detectedType: kind == .file ? (type ?? SourceType.detect(from: URL(fileURLWithPath: normalized))) : nil,
                                disposition: disp, childSourceVersionID: child, contentHash: hash, detail: detail)
            }
            if e.isDirectory { members.append(member(e.name, .directory, .directory)); continue }
            let normalized: String
            switch ZIPContainerExtractor.classifyPath(e.name) {
            case .directory: members.append(member(e.name, .directory, .directory)); continue
            case .unsafe(let reason): sawProblem = true; members.append(member(e.name, .blockedUnsafePath, detail: reason)); continue
            case .file(let n): normalized = n
            }
            if ordinal >= policy.maxEntriesPerContainer {
                sawProblem = true; members.append(member(normalized, .blockedEntryLimit, detail: "beyond per-container entry limit")); continue
            }
            if let f = e.folder, let why = reader.unsupportedReason(folder: f) {
                sawProblem = true
                members.append(member(normalized, why.hasPrefix("encrypted") ? .encrypted : .unsupported, detail: why)); continue
            }
            if e.size > policy.maxSingleMemberBytes {
                sawProblem = true; members.append(member(normalized, .blockedSizeLimit, detail: "size exceeds per-member cap")); continue
            }
            if let f = e.folder, reader.packedSize(folder: f) > 0, e.size / max(1, reader.packedSize(folder: f)) > Int64(policy.maxCompressionRatio) {
                sawProblem = true; members.append(member(normalized, .blockedCompressionRatio, detail: "compression ratio exceeds cap")); continue
            }
            let dest = root.appendingPathComponent(normalized)
            guard ZIPContainerExtractor.isContained(dest, inRoot: root) else {
                sawProblem = true; members.append(member(normalized, .blockedUnsafePath, detail: "escapes extraction root")); continue
            }
            let verdict = context.budget.reserveMember(uncompressedBytes: e.size)
            if verdict != .ok {
                sawProblem = true; members.append(member(normalized, .blockedRootBudget, detail: "\(verdict)")); continue
            }
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try reader.extract(e).write(to: dest)
            } catch {
                sawProblem = true; members.append(member(normalized, .failedExtraction, detail: "\(error)")); continue
            }
            let childHash = Self.hashFile(dest)
            let expandable = Self.isExpandableZip(fileURL: dest, originName: normalized)
            if expandable {
                if context.isCycle(childHash: childHash) {
                    sawProblem = true; members.append(member(normalized, .blockedCycle, detail: "cycle with ancestor container")); continue
                }
                if context.wouldExceedDepth {
                    sawProblem = true; members.append(member(normalized, .blockedDepth, detail: "nesting depth exceeded")); continue
                }
                if context.budget.registerNestedContainer() != .ok {
                    sawProblem = true; members.append(member(normalized, .blockedRootBudget, detail: "nested container limit")); continue
                }
            }
            let origin = Self.origin(parent: containerVersionID, ordinal: ordinal, name: normalized)
            let parentRef = SourceParentReference(parentSourceVersionID: containerVersionID, relation: .archiveMember, ordinal: ordinal)
            let outcome = await ingestMember(dest, origin, parentRef)
            guard outcome.succeeded, let childID = outcome.childSourceVersionID, let ch = outcome.contentHash else {
                sawProblem = true; members.append(member(normalized, .failedExtraction, detail: "member ingest failed")); continue
            }
            members.append(member(normalized, .admitted, child: childID, hash: ch, type: outcome.detectedType))
            if (outcome.detectedType ?? .unknown) == .zip || expandable {
                await expand(containerVersionID: childID, containerType: .zip, byteURL: dest,
                             context: context.descending(intoContainerHash: ch), now: now, ingestMember: ingestMember)
            }
        }
        await record(sawProblem ? .partial : .complete, members)
    }
}

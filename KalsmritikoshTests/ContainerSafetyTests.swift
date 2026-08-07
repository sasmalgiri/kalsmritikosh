//
//  ContainerSafetyTests.swift
//  KalsmritikoshTests
//
//  USF-M2 (USF-006 §7/§13/§14) — the immutable safety policy, the SHARED root budget (not reset per
//  nested container), and the traversal context (depth ceiling + ancestor-hash cycle detection).
//  Path-normalization + streaming-extraction safety are covered in the extraction section below.
//  Synthetic bytes only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M2 — container safety policy + traversal")
struct ContainerSafetyTests {

    private func tinyPolicy(members: Int = 3, bytes: Int64 = 100, nested: Int = 2, depth: Int = 2, ratio: Int = 10) -> ContainerSafetyPolicy {
        ContainerSafetyPolicy(version: "test", maxEntriesPerContainer: 10, maxExpandedBytesPerContainer: 1000,
                              maxSingleMemberBytes: 500, maxNestingDepth: depth, maxRootTotalMembers: members,
                              maxRootExpandedBytes: bytes, maxNestedContainerCount: nested, maxCompressionRatio: ratio)
    }

    // MARK: - Policy

    @Test("The standard policy preserves the per-container limits and adds root-recursion ceilings")
    func standardPolicyConstants() {
        let p = ContainerSafetyPolicy.standard
        #expect(p.maxEntriesPerContainer == 20_000)
        #expect(p.maxExpandedBytesPerContainer == 4 * 1024 * 1024 * 1024)
        #expect(p.maxSingleMemberBytes == 1 * 1024 * 1024 * 1024)
        #expect(p.maxNestingDepth == 8)
        #expect(p.maxRootTotalMembers > 0)
        #expect(p.maxRootExpandedBytes > p.maxExpandedBytesPerContainer)
        #expect(p.maxNestedContainerCount > 0)
        #expect(p.maxCompressionRatio == 200)
        #expect(!p.version.isEmpty)
    }

    // MARK: - Shared root budget

    @Test("The root budget admits members up to the root member ceiling, then blocks")
    func budgetMemberCeiling() {
        let b = ContainerRootBudget(policy: tinyPolicy(members: 2))
        #expect(b.reserveMember(uncompressedBytes: 1) == .ok)
        #expect(b.reserveMember(uncompressedBytes: 1) == .ok)
        #expect(b.reserveMember(uncompressedBytes: 1) == .rootMemberLimit)
        #expect(b.consumed.members == 2)
    }

    @Test("An over-budget byte reservation consumes nothing and reports the root byte limit")
    func budgetByteCeiling() {
        let b = ContainerRootBudget(policy: tinyPolicy(members: 100, bytes: 100))
        #expect(b.reserveMember(uncompressedBytes: 80) == .ok)
        #expect(b.reserveMember(uncompressedBytes: 80) == .rootByteLimit)   // 160 > 100
        #expect(b.consumed.bytes == 80)                                     // nothing consumed on failure
    }

    @Test("The root budget bounds the number of nested containers")
    func budgetNestedContainerCeiling() {
        let b = ContainerRootBudget(policy: tinyPolicy(nested: 1))
        #expect(b.registerNestedContainer() == .ok)
        #expect(b.registerNestedContainer() == .nestedContainerLimit)
    }

    // MARK: - Traversal context

    @Test("A root context starts at depth 0 with the root hash on the ancestor chain")
    func rootContext() {
        let ctx = ContainerTraversalContext.root(sourceVersionID: UUID(), containerHash: "AABB", policy: tinyPolicy())
        #expect(ctx.currentDepth == 0)
        #expect(ctx.ancestorContainerHashes.contains("aabb"))   // normalized lowercase
    }

    @Test("Descending increments depth, extends the ancestor chain, and shares the root budget")
    func descending() {
        let ctx = ContainerTraversalContext.root(sourceVersionID: UUID(), containerHash: "root", policy: tinyPolicy())
        let child = ctx.descending(intoContainerHash: "child")
        #expect(child.currentDepth == 1)
        #expect(child.ancestorContainerHashes.isSuperset(of: ["root", "child"]))
        #expect(child.budget === ctx.budget)   // ONE shared budget across the traversal
    }

    @Test("A child hash already on the ancestor chain is detected as a cycle")
    func cycleDetection() {
        let ctx = ContainerTraversalContext.root(sourceVersionID: UUID(), containerHash: "H1", policy: tinyPolicy())
        #expect(ctx.isCycle(childHash: "h1"))       // same hash (case-insensitive) = cycle
        #expect(!ctx.isCycle(childHash: "h2"))
        let deeper = ctx.descending(intoContainerHash: "H2")
        #expect(deeper.isCycle(childHash: "h1"))    // ancestor still remembered deeper down
    }

    @Test("The depth ceiling is enforced independently of the byte/member budget")
    func depthCeiling() {
        var ctx = ContainerTraversalContext.root(sourceVersionID: UUID(), containerHash: "d0", policy: tinyPolicy(depth: 2))
        #expect(!ctx.wouldExceedDepth)               // depth 0 → next is 1, allowed
        ctx = ctx.descending(intoContainerHash: "d1")
        #expect(!ctx.wouldExceedDepth)               // depth 1 → next is 2, allowed
        ctx = ctx.descending(intoContainerHash: "d2")
        #expect(ctx.wouldExceedDepth)                // depth 2 → next is 3 > 2, blocked
    }

    // MARK: - Manifest tally

    @Test("Tally derives count-consistent manifest numbers from the member list")
    func tallyConsistency() {
        let parent = UUID()
        func m(_ ord: Int, _ d: ContainerMemberDisposition, kind: ContainerEntryKind = .file, bytes: Int64 = 10) -> ContainerMember {
            ContainerMember(parentSourceVersionID: parent, ordinal: ord, memberPath: "p\(ord)", normalizedMemberPath: "p\(ord)",
                            entryKind: kind, compressedSize: 1, uncompressedSize: bytes, detectedType: .pdf, disposition: d,
                            childSourceVersionID: d == .admitted ? UUID() : nil, contentHash: d == .admitted ? "h" : nil)
        }
        let members = [m(0, .admitted), m(1, .encrypted), m(2, .unsupported), m(3, .failedExtraction),
                       m(4, .directory, kind: .directory, bytes: 0)]
        let t = ContainerInspectionResult.tally(members: members)
        #expect(t.total == 5)
        #expect(t.regular == 4)                       // directory excluded
        #expect(t.admitted == 1)
        #expect(t.blocked == 1)                       // encrypted counts as blocked
        #expect(t.unsupported == 1)
        #expect(t.failed == 1)
        #expect(t.admitted + t.blocked + t.unsupported + t.failed <= t.regular)   // the v87 CHECK invariant
        #expect(t.declaredBytes == 40)               // 4 files × 10 bytes
    }

    @Test("Disposition classification: only admitted admits; blocked family is stable")
    func dispositionClassification() {
        #expect(ContainerMemberDisposition.admitted.isAdmitted)
        #expect(!ContainerMemberDisposition.encrypted.isAdmitted)
        #expect(ContainerMemberDisposition.blockedCycle.isBlocked)
        #expect(ContainerMemberDisposition.encrypted.isBlocked)
        #expect(!ContainerMemberDisposition.unsupported.isBlocked)
        #expect(!ContainerMemberDisposition.failedExtraction.isBlocked)
        #expect(!ContainerMemberDisposition.directory.isBlocked)
    }

    // MARK: - Path safety (§9)

    @Test("Path classification rejects only genuine escapes; a filename containing '..' is safe")
    func pathClassification() {
        typealias C = ZIPContainerExtractor.PathClassification
        #expect(ZIPContainerExtractor.classifyPath("dir/report.pdf") == .file(normalized: "dir/report.pdf"))
        #expect(ZIPContainerExtractor.classifyPath("a..b.txt") == .file(normalized: "a..b.txt"))   // harmless dots
        #expect(ZIPContainerExtractor.classifyPath("./x/./y.txt") == .file(normalized: "x/y.txt"))
        #expect(ZIPContainerExtractor.classifyPath("sub/") == .directory)
        if case .unsafe = ZIPContainerExtractor.classifyPath("/etc/passwd") {} else { Issue.record("absolute not rejected") }
        if case .unsafe = ZIPContainerExtractor.classifyPath("../../escape") {} else { Issue.record("traversal not rejected") }
        if case .unsafe = ZIPContainerExtractor.classifyPath("a/../../b") {} else { Issue.record("mid traversal not rejected") }
        if case .unsafe = ZIPContainerExtractor.classifyPath("C:\\win") {} else { Issue.record("drive letter not rejected") }
        if case .unsafe = ZIPContainerExtractor.classifyPath("bad\u{0}name") {} else { Issue.record("NUL not rejected") }
    }

    @Test("Containment check catches a destination that escapes the extraction root")
    func containment() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("root-\(UUID().uuidString)", isDirectory: true)
        #expect(ZIPContainerExtractor.isContained(root.appendingPathComponent("a/b.txt"), inRoot: root))
        #expect(!ZIPContainerExtractor.isContained(root.appendingPathComponent("../sibling.txt"), inRoot: root))
    }

    // MARK: - Streaming extraction (§8)

    private func extract(_ entry: ZIPTestFixture.Entry, max: Int64 = 1 << 30) throws -> (Int64, Data) {
        let url = try ZIPTestFixture.writeZIP([entry])
        let reader = try ZIPReader(url: url)
        let e = try #require(try reader.entries().first)
        let dest = url.deletingLastPathComponent().appendingPathComponent("out.bin")
        let n = try ZIPContainerExtractor.streamExtract(reader: reader, entry: e, to: dest, maxMemberBytes: max)
        return (n, try Data(contentsOf: dest))
    }

    @Test("A STORED member streams out byte-exact")
    func storedRoundTrip() throws {
        let (n, data) = try extract(ZIPTestFixture.stored("a.txt", "stored synthetic body"))
        #expect(n == Int64("stored synthetic body".utf8.count))
        #expect(String(decoding: data, as: UTF8.self) == "stored synthetic body")
    }

    @Test("A DEFLATE member inflates byte-exact via the streaming path")
    func deflateRoundTrip() throws {
        let body = String(repeating: "deflate me — synthetic. ", count: 40)
        let (n, data) = try extract(ZIPTestFixture.deflated("a.txt", body))
        #expect(n == Int64(body.utf8.count))
        #expect(String(decoding: data, as: UTF8.self) == body)
    }

    @Test("A member exceeding the per-member byte cap aborts as exceededCap")
    func extractExceedsCap() throws {
        #expect(throws: ZIPContainerExtractor.ExtractionFailure.exceededCap) {
            _ = try self.extract(ZIPTestFixture.stored("big.txt", String(repeating: "x", count: 500)), max: 100)
        }
    }

    @Test("A corrupt DEFLATE member fails as decompressionFailed")
    func extractCorruptDeflate() throws {
        #expect(throws: ZIPContainerExtractor.ExtractionFailure.self) {
            _ = try self.extract(ZIPTestFixture.Entry(name: "c.bin", data: Data(repeating: 1, count: 200), method: 8, corrupt: true, declaredUncompressed: 200))
        }
    }

    @Test("An unsupported compression method fails as unsupportedCompression")
    func extractUnsupportedMethod() throws {
        #expect(throws: ZIPContainerExtractor.ExtractionFailure.unsupportedCompression) {
            _ = try self.extract(ZIPTestFixture.Entry(name: "z.bin", data: Data("x".utf8), method: 12))
        }
    }

    @Test("S6 — a zero-byte member is legal: admitted by the inspector and extracted byte-exact to empty")
    func zeroByteMemberIsValid() throws {
        let (n, data) = try extract(ZIPTestFixture.stored("empty.txt", ""))
        #expect(n == 0)
        #expect(data.isEmpty)
        let url = try ZIPTestFixture.writeZIP([ZIPTestFixture.stored("empty.txt", "")])
        let e = ZIPContainerInspector.inspect(url: url, containerType: .zip, policy: .standard)
        #expect(e.members.first?.disposition == .admitted)
    }

    // MARK: - Inspector classification (§15)

    @Test("The inspector assigns exactly one disposition to every member, none dropped")
    func inspectorClassifiesEveryMember() throws {
        let url = try ZIPTestFixture.writeZIP([
            ZIPTestFixture.stored("doc/report.pdf", "pdf"),                          // candidate
            ZIPTestFixture.directory("extras/"),                                     // directory
            ZIPTestFixture.Entry(name: "../escape.txt", data: Data("x".utf8)),       // unsafe path
            ZIPTestFixture.Entry(name: "locked.txt", data: Data("x".utf8), encrypted: true),  // encrypted
            ZIPTestFixture.Entry(name: "weird.bin", data: Data("x".utf8), method: 14),         // unsupported method
            ZIPTestFixture.Entry(name: "huge.db", data: Data("x".utf8), declaredUncompressed: 10_000_000),  // size
        ])
        let policy = ContainerSafetyPolicy(version: "t", maxEntriesPerContainer: 100, maxExpandedBytesPerContainer: 1 << 30,
                                           maxSingleMemberBytes: 1000, maxNestingDepth: 8, maxRootTotalMembers: 1000,
                                           maxRootExpandedBytes: 1 << 30, maxNestedContainerCount: 10, maxCompressionRatio: 200)
        let e = ZIPContainerInspector.inspect(url: url, containerType: .zip, policy: policy)
        #expect(!e.unreadable)
        #expect(e.members.count == 6)
        func disp(_ path: String) -> ContainerMemberDisposition? { e.members.first { $0.memberPath.contains(path) }?.disposition }
        #expect(disp("report.pdf") == .admitted)
        #expect(disp("extras/") == .directory)
        #expect(disp("escape") == .blockedUnsafePath)
        #expect(disp("locked") == .encrypted)
        #expect(disp("weird") == .unsupported)
        #expect(disp("huge") == .blockedSizeLimit)
        // A candidate carries its entry (for streaming); a non-candidate does not.
        #expect(e.members.first { $0.disposition == .admitted }?.entry != nil)
        #expect(e.members.first { $0.disposition == .encrypted }?.entry == nil)
    }

    @Test("Members beyond the per-container entry ceiling are blocked, not dropped")
    func inspectorEntryCeiling() throws {
        let entries = (0..<5).map { ZIPTestFixture.stored("f\($0).txt", "body\($0)") }
        let url = try ZIPTestFixture.writeZIP(entries)
        let policy = ContainerSafetyPolicy(version: "t", maxEntriesPerContainer: 3, maxExpandedBytesPerContainer: 1 << 30,
                                           maxSingleMemberBytes: 1 << 20, maxNestingDepth: 8, maxRootTotalMembers: 1000,
                                           maxRootExpandedBytes: 1 << 30, maxNestedContainerCount: 10, maxCompressionRatio: 200)
        let e = ZIPContainerInspector.inspect(url: url, containerType: .zip, policy: policy)
        #expect(e.members.count == 5)
        #expect(e.members.filter { $0.disposition == .admitted }.count == 3)
        #expect(e.members.filter { $0.disposition == .blockedEntryLimit }.count == 2)
    }

    @Test("An unreadable container yields unreadable == true with no members")
    func inspectorUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notzip.zip")
        try Data("this is not a zip file".utf8).write(to: url)
        let e = ZIPContainerInspector.inspect(url: url, containerType: .zip, policy: .standard)
        #expect(e.unreadable)
        #expect(e.members.isEmpty)
    }

    @Test("A high compression ratio member is blocked as a suspected bomb")
    func inspectorCompressionRatio() throws {
        // Declared uncompressed 100000 with a tiny stored payload → ratio far exceeds the cap.
        let url = try ZIPTestFixture.writeZIP([
            ZIPTestFixture.Entry(name: "bomb.txt", data: Data("x".utf8), method: 8, declaredUncompressed: 100_000)])
        let policy = ContainerSafetyPolicy(version: "t", maxEntriesPerContainer: 100, maxExpandedBytesPerContainer: 1 << 30,
                                           maxSingleMemberBytes: 1 << 30, maxNestingDepth: 8, maxRootTotalMembers: 1000,
                                           maxRootExpandedBytes: 1 << 30, maxNestedContainerCount: 10, maxCompressionRatio: 50)
        let e = ZIPContainerInspector.inspect(url: url, containerType: .zip, policy: policy)
        #expect(e.members.first?.disposition == .blockedCompressionRatio)
    }
}

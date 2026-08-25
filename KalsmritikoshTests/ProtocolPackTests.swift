//
//  ProtocolPackTests.swift
//  KalsmritikoshTests
//
//  Conformance roadmap 1.1 — signed offline protocol packs + registry.
//  Acceptance tests: 8 (an unsigned/edited pack cannot activate), 9 (a
//  protocol never mutates during a run — frozen snapshots survive activation
//  of a newer version), 11 (protocol updates work through offline signed
//  packs end-to-end: export → verify → import → activate → govern new runs).
//

import Foundation
import Testing
import CryptoKit
@testable import Kalsmritikosh

@Suite("Protocol packs — sign, verify, refuse")
struct ProtocolPackTests {

    private let sutra = SutraCompiler.shared()
    private let now = Date(timeIntervalSince1970: 1_756_000_000)
    private let key = P256.Signing.PrivateKey()

    @Test("Export → verify round trip")
    func roundTrip() throws {
        let data = try ProtocolPacks.export(sutra: sutra, publisher: "Test Org",
                                            assurance: "organization-approved", key: key, at: now)
        let (pack, decoded) = try ProtocolPacks.verify(data)
        #expect(decoded.citation == sutra.citation)
        #expect(pack.envelope.publisher == "Test Org")
        #expect(pack.envelope.sutraID == sutra.id)
        #expect(ProtocolPacks.signerKeyID(of: pack) == ConformanceSigningKey.keyID(for: key))
    }

    /// Acceptance test 8 — an edited pack fails verification and can never
    /// reach the registry (import requires a verified pack).
    @Test("An edited pack refuses: hash, then signature")
    func editedPackRefuses() throws {
        let data = try ProtocolPacks.export(sutra: sutra, publisher: "Test Org",
                                            assurance: "developer", key: key, at: now)
        // Tamper with the snapshot: hash mismatch.
        var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
        var pack = try decoder.decode(SignedProtocolPack.self, from: data)
        let tamperedSnapshot = SignedProtocolPack(envelope: pack.envelope,
                                                  sutraSnapshotJSON: pack.sutraSnapshotJSON + " ",
                                                  signatureHex: pack.signatureHex,
                                                  publicKeyHex: pack.publicKeyHex)
        #expect(throws: ProtocolPackError.hashMismatch) {
            _ = try ProtocolPacks.verify(try ConformanceCanonical.data(of: tamperedSnapshot))
        }
        // Tamper with the envelope AND recompute the snapshot hash consistently:
        // the signature check must still refuse.
        pack = try decoder.decode(SignedProtocolPack.self, from: data)
        let forgedEnvelope = ProtocolPackEnvelope(
            formatVersion: pack.envelope.formatVersion, sutraID: pack.envelope.sutraID,
            sutraVersion: pack.envelope.sutraVersion, sutraSHA256: pack.envelope.sutraSHA256,
            publisher: "Forged Publisher", assurance: "independently-reviewed",   // the lie
            publishedAt: pack.envelope.publishedAt)
        let forged = SignedProtocolPack(envelope: forgedEnvelope,
                                        sutraSnapshotJSON: pack.sutraSnapshotJSON,
                                        signatureHex: pack.signatureHex,
                                        publicKeyHex: pack.publicKeyHex)
        #expect(throws: ProtocolPackError.signatureInvalid) {
            _ = try ProtocolPacks.verify(try ConformanceCanonical.data(of: forged))
        }
    }

    @Test("A pack whose schema does not compile refuses")
    func brokenSchemaRefuses() throws {
        var broken = sutra
        broken.globalRequirements = ["fine requirement"]
        // Encode, then inject an unparseable applicability by round-tripping the
        // rules is not possible through Sutra alone — the compiler assigns
        // applicability. Instead verify the compile gate catches a Sutra whose
        // snapshot decodes but whose identity mismatches the envelope.
        let data = try ProtocolPacks.export(sutra: broken, publisher: "T", assurance: "developer",
                                            key: key, at: now)
        var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
        let pack = try decoder.decode(SignedProtocolPack.self, from: data)
        // Re-sign an envelope claiming a different version than the snapshot holds.
        let mismatched = ProtocolPackEnvelope(
            formatVersion: pack.envelope.formatVersion, sutraID: pack.envelope.sutraID,
            sutraVersion: pack.envelope.sutraVersion + 7, sutraSHA256: pack.envelope.sutraSHA256,
            publisher: "T", assurance: "developer", publishedAt: pack.envelope.publishedAt)
        let canonical = try ConformanceCanonical.data(of: mismatched)
        let sig = try key.signature(for: canonical)
        let repacked = SignedProtocolPack(
            envelope: mismatched, sutraSnapshotJSON: pack.sutraSnapshotJSON,
            signatureHex: sig.derRepresentation.map { String(format: "%02x", $0) }.joined(),
            publicKeyHex: key.publicKey.x963Representation.map { String(format: "%02x", $0) }.joined())
        #expect(throws: ProtocolPackError.schemaDoesNotCompile("envelope identity does not match the snapshot")) {
            _ = try ProtocolPacks.verify(try ConformanceCanonical.data(of: repacked))
        }
    }
}

@Suite("Protocol registry — activate, supersede, revoke, govern")
struct ProtocolRegistryTests {

    private let sutra = SutraCompiler.shared()
    private let now = Date(timeIntervalSince1970: 1_756_000_000)
    private let key = P256.Signing.PrivateKey()

    private func makeRig() async throws -> ProtocolRegistryRepository {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("protoreg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        return ProtocolRegistryRepository(database: db)
    }

    private func verifiedPack(of s: Sutra) throws -> SignedProtocolPack {
        let data = try ProtocolPacks.export(sutra: s, publisher: "Test Org",
                                            assurance: "organization-approved", key: key, at: now)
        return try ProtocolPacks.verify(data).pack
    }

    /// Acceptance test 11 — the full offline update loop, including supersession.
    @Test("Import → activate governs new runs; a newer version supersedes")
    func offlineUpdateLoop() async throws {
        let repo = try await makeRig()
        // Nothing active → nil (callers fall back to the built-in doctrine).
        #expect(try await repo.activeSutra(id: sutra.id) == nil)

        let v1 = try await repo.importPack(try verifiedPack(of: sutra), at: now)
        #expect(v1.status == .imported)
        try await repo.activate(id: v1.id, at: now)
        let activeV1 = try await repo.activeSutra(id: sutra.id)
        #expect(activeV1?.version == sutra.version)

        // An amendment ships as a NEW pack; activating it supersedes v1.
        let amended = sutra.amended(on: "2026-08-26", summary: "pack-delivered amendment")
        let v2 = try await repo.importPack(try verifiedPack(of: amended), at: now.addingTimeInterval(60))
        try await repo.activate(id: v2.id, at: now.addingTimeInterval(60))
        let active = try await repo.activeSutra(id: sutra.id)
        #expect(active?.version == amended.version)
        let rows = try await repo.list()
        #expect(rows.first { $0.id == v1.id }?.status == .superseded)
        #expect(rows.first { $0.id == v2.id }?.status == .active)
    }

    /// Acceptance test 9 — activation never mutates a frozen run: an assessment
    /// recorded against v1 still reopens as v1 after v2 activates.
    @Test("Activation never touches frozen runs")
    func frozenRunsSurviveActivation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("protofreeze-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let protocols = ProtocolRegistryRepository(database: db)
        let assessments = ConformanceAssessmentRepository(database: db)

        // Freeze + record a run against v1.
        let attested = Set(SutraRuleCompiler.rules(for: sutra)
            .filter { $0.phaseKind == .findings || $0.phaseKind == nil }.map(\.id))
        let facts = ConformanceFacts(completedPhaseKinds: [.findings],
                                     standardOfProofDeclared: true, openItemsAcknowledged: true,
                                     humanDecisionsMade: [.findings], attestedRuleIDs: attested)
        let assessment = SutraConformance.assess(facts: facts, against: sutra, at: now)
        let caseID = UUID()
        _ = try await assessments.record(caseID: caseID, assessment: assessment, seal: nil, at: now)

        // v2 activates afterwards.
        let amended = sutra.amended(on: "2026-08-26", summary: "post-run amendment")
        let v2 = try await protocols.importPack(try verifiedPack(of: amended), at: now)
        try await protocols.activate(id: v2.id, at: now)

        // The frozen run still reopens as v1 — byte-identical snapshot hash.
        let reopened = try await assessments.latest(caseID: caseID)
        #expect(reopened?.assessment.sutraSHA256 == assessment.sutraSHA256)
        #expect(reopened?.assessment.sutraCitation == sutra.citation)
    }

    @Test("A revoked pack can never activate; revocation is recorded")
    func revocation() async throws {
        let repo = try await makeRig()
        let row = try await repo.importPack(try verifiedPack(of: sutra), at: now)
        try await repo.revoke(id: row.id, reason: "publisher key compromised", at: now)
        await #expect(throws: ProtocolRegistryError.revoked(row.id)) {
            try await repo.activate(id: row.id, at: now)
        }
        let listed = try await repo.list().first { $0.id == row.id }
        #expect(listed?.status == .revoked)
        #expect(listed?.revocationReason == "publisher key compromised")
        #expect(try await repo.activeSutra(id: sutra.id) == nil)
    }

    @Test("Governed review records round-trip with a verifiable signature")
    func governedReviews() async throws {
        let repo = try await makeRig()
        let record = try ProtocolReviewRecord(
            subjectID: "sop.frcp26", reviewer: "Owner", role: "counsel",
            sourceNote: "uscourts.gov FRCP 2026 edition", sourceSHA256: nil,
            diffSummary: "no relevant change", decision: .current,
            notes: "still matches", reviewedAt: now).signed(key: key)
        _ = try await repo.recordReview(record)
        let latest = try await repo.latestReview(subjectID: "sop.frcp26")
        #expect(latest?.reviewer == "Owner")
        #expect(latest?.decision == .current)
        // The stored signature still verifies over the reloaded payload.
        if let latest, let sig = latest.signature {
            #expect(RecordSigner.verify(latest.payload, signature: sig))
        } else {
            Issue.record("signature missing after round-trip")
        }
        // And a tampered payload fails.
        if let latest, let sig = latest.signature {
            var forged = latest.payload
            forged = ProtocolReviewRecord(
                id: latest.id, subjectID: latest.subjectID, reviewer: "Someone Else",
                role: latest.role, sourceNote: latest.sourceNote, sourceSHA256: latest.sourceSHA256,
                diffSummary: latest.diffSummary, affectedRuleIDs: latest.affectedRuleIDs,
                decision: latest.decision, notes: latest.notes, reviewedAt: latest.reviewedAt).payload
            #expect(!RecordSigner.verify(forged, signature: sig))
        }
    }
}

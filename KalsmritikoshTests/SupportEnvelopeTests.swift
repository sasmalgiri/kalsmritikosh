//
//  SupportEnvelopeTests.swift
//  KalsmritikoshTests
//
//  F4 / T3 — a measured support envelope on the hardware the test runs on: ingest a generated case
//  of memos and emails through the production pipeline (AI off), then ask questions through the
//  case-scoped answer service. Records wall time, throughput, memory footprint, ledger size,
//  derived counts, and answer latency p50/p95, with the hardware and OS. The numbers are recorded
//  as an attachment and printed (docs/SUPPORT_ENVELOPE.md is written from a run; a 10× run is made by raising `memos`/`emails`); the assertions only check that
//  every document was taken in and every question answered or honestly refused.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Support envelope (T3)", .serialized)
struct SupportEnvelopeTests {

    static let people = ["Asha Rao", "Vikram Mehta", "Clara Jones", "David Okafor", "Mei Lin", "Rahul Sen", "Sofia Rossi", "Tom Becker"]

    static func memo(_ i: Int) -> String {
        let a = people[i % people.count], b = people[(i * 3 + 1) % people.count]
        let day = (i % 28) + 1, month = ["January", "February", "March", "April", "May", "June"][i % 6]
        return """
        Memo \(i): payment review
        On \(month) \(day), 2025 \(a) approved invoice INV-\(1000 + i) for ₹\(1000 + i * 7) after \(b) checked the delivery note.
        The delay happened because the vendor sent the wrong quantity. \(b) said "the count was short by \(i % 9 + 1) units."
        Follow-up is due on \(month) \(min(day + 7, 28)), 2025.
        """
    }

    static func email(_ i: Int) -> String {
        let a = people[(i + 2) % people.count], b = people[(i + 5) % people.count]
        let mail = { (n: String) in n.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com" }
        return """
        From: \(a) <\(mail(a))>
        To: \(b) <\(mail(b))>
        Subject: Shipment \(i)
        Date: Mon, \((i % 27) + 1) Jan 2025 10:\(String(format: "%02d", i % 60)):00 +0000

        Hi \(b.split(separator: " ")[0]), the shipment for order PO-\(5000 + i) left the warehouse. Total \(i % 5 == 0 ? "$" : "€")\(250 + i).
        Regards, \(a)
        """
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    @Test("Ingest 400 documents (×SUPPORT_ENVELOPE_SCALE) and answer 30 questions; record the measured envelope", .timeLimit(.minutes(60)))
    func measuredEnvelope() async throws {
        await SharedSettingsLock.shared.acquire()
        defer { Task { await SharedSettingsLock.shared.release() } }
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var settings = previous
        settings["kalsmritikosh.privacy.offlineNoLLM"] = true
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("envelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let docs = temp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        // The 400-document run is the default; SUPPORT_ENVELOPE_SCALE=10 measures 4,000 (3,000 memos and
        // 1,000 emails) without a source edit. Record the scale with the result.
        let scale = max(1, Int(ProcessInfo.processInfo.environment["SUPPORT_ENVELOPE_SCALE"] ?? "") ?? 1)
        let memos = 300 * scale, emails = 100 * scale
        var inputBytes = 0
        for i in 0..<memos {
            let d = Data(Self.memo(i).utf8); inputBytes += d.count
            try d.write(to: docs.appendingPathComponent("memo-\(i).txt"))
        }
        for i in 0..<emails {
            let d = Data(Self.email(i).utf8); inputBytes += d.count
            try d.write(to: docs.appendingPathComponent("mail-\(i).eml"))
        }

        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("case.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database else {
            Issue.record("ledger did not boot"); return
        }
        let baseline = ProcessFootprint.bytes()
        var peak = baseline
        let started = Date()
        var fileIDs: [UUID] = []
        let files = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (n, url) in files.enumerated() {
            fileIDs.append(try await ingest.ingest(fileAt: url).fileRecord.id)
            if n % 25 == 0 { peak = max(peak, ProcessFootprint.bytes()) }
        }
        let ingestSeconds = Date().timeIntervalSince(started)
        peak = max(peak, ProcessFootprint.bytes())

        // A case over every document, then questions through the case-scoped answer service.
        let now = Date(), ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Envelope"), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        try await (try #require(await state.workspaceSourceCoordinator)).addSources(Set(fileIDs), to: ws, at: now)
        let c = try await (try #require(await state.investigationCases)).createCase(workspaceID: ws, title: "Envelope", actor: "T", at: now)
        _ = try await (try #require(await state.investigationWorkspaceIntake)).includeWorkspaceSources(caseID: c.id, actor: "T", at: now)
        let answers = try #require(await state.investigationAnswers)
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted,
                                                                  permitsPrivilegedMaterial: false, purpose: .export))
        var latencies: [Double] = []
        var answered = 0, refused = 0
        for q in 0..<30 {
            let p = Self.people[q % Self.people.count]
            let question = [
                "Who approved invoice INV-\(1000 + q * 9)?",
                "When was the follow-up due for memo \(q * 7)?",
                "What did \(p) say about the count?",
                "What was the total for order PO-\(5000 + q * 3)?",
                "Why was the payment delayed?",
            ][q % 5]
            let t0 = Date()
            let a = try await answers.answer(caseID: c.id, question: question, access: access)
            latencies.append(Date().timeIntervalSince(t0) * 1000)
            if a.verified.refused { refused += 1 } else { answered += 1 }
        }
        peak = max(peak, ProcessFootprint.bytes())

        func count(_ t: String) async -> Int { Int((try? await db.query("SELECT COUNT(*) FROM \(t);", []).first?.int(0)) ?? 0) ?? 0 }
        let ledgerBytes = (try? FileManager.default.attributesOfItem(atPath: temp.appendingPathComponent("case.sqlite").path)[.size] as? Int) ?? 0
        let hardware = await MainActor.run { ScaleRunRecorder.hardware() }
        let mib = { (b: Int) in String(format: "%.1f MiB", Double(b) / 1_048_576) }
        let report = """
        hardware: \(hardware)
        os: \(ProcessInfo.processInfo.operatingSystemVersionString)
        documents: \(files.count) (\(memos) memos, \(emails) emails), \(inputBytes) bytes of input
        ingest: \(String(format: "%.1f", ingestSeconds)) s, \(String(format: "%.1f", Double(files.count) / max(ingestSeconds, 0.001))) documents/s
        derived: \(await count("knowledge_objects")) knowledge objects, \(await count("chunks")) chunks, \(await count("entities")) entities, \(await count("events")) events, \(await count("chunk_embeddings")) chunk vectors
        ledger: \(mib(ledgerBytes)) on disk
        memory: baseline \(mib(Int(baseline))), peak \(mib(Int(peak))), growth \(mib(Int(peak) - Int(baseline)))
        answers (AI off, case-scoped): \(answered) answered, \(refused) refused; latency p50 \(String(format: "%.0f", Self.percentile(latencies, 0.5))) ms, p95 \(String(format: "%.0f", Self.percentile(latencies, 0.95))) ms, max \(String(format: "%.0f", latencies.max() ?? 0)) ms
        """
        Attachment.record(report, named: "support-envelope.txt")
        print("SUPPORT-ENVELOPE\n" + report)
        #expect(fileIDs.count == files.count, "every document was taken in")
        #expect(answered + refused == 30)
    }
}

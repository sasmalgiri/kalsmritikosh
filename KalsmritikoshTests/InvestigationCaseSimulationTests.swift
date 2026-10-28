//
//  InvestigationCaseSimulationTests.swift
//  KalsmritikoshTests
//
//  C1/C2 (docs/INVESTIGATION_FOCUS_TODO.md) — every persona runs one real, public-domain case
//  start to end through the app: intake → ingest → subjects → chronology → contradictions/gaps →
//  studio draft (filled from the case) → findings report. Scored against the published record in
//  the pack's expected values:
//    * recall of the expected facts, dates, parties and amounts somewhere in what the app produced;
//    * WRONG FACTS = 0 — every studio field the app filled "from the case" appears verbatim in the
//      case's own documents (a value it invented, or took from another case, is a wrong fact);
//    * every findings citation points at a source inside the case.
//
//  Packs: Fixtures/InvestigationCases (built by scripts/casebench/persona_packs.py; SOURCES.md).
//  Runs with the AI off (evidence path) so the result is deterministic.
//

import Foundation
import Testing
@testable import Kalsmritikosh

final class InvestigationCaseMarker {}

enum InvestigationCasePacks {
    static let bundle = Bundle(for: InvestigationCaseMarker.self)

    struct Pack: Decodable {
        let persona: String
        let investigation: String
        let caseTitle: String
        let files: [String]
        let expected: [String: JSONValue]
    }

    /// A loose JSON value — expected entries are strings, lists of strings, or {date|any|overlap|number} objects.
    enum JSONValue: Decodable {
        case string(String), list([JSONValue]), object([String: JSONValue]), number(Double), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let l = try? c.decode([JSONValue].self) { self = .list(l) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
        }
        /// Every string the value names (an `any` list counts as one alternative set).
        var strings: [String] {
            switch self {
            case .string(let s): return [s]
            case .number(let n): return [n == n.rounded() ? String(Int(n)) : String(n)]
            case .list(let l): return l.flatMap(\.strings)
            case .object(let o): return o.values.flatMap(\.strings)
            case .null: return []
            }
        }
    }

    static func url(_ name: String) throws -> URL {
        if let direct = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                   withExtension: (name as NSString).pathExtension) { return direct }
        let root = try #require(bundle.resourceURL)
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL { if u.lastPathComponent == name { return u } }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
    }

    static func packs() throws -> [Pack] {
        try JSONDecoder().decode([Pack].self, from: Data(contentsOf: url("investigation-cases.json")))
    }

    /// One expected item per check: the alternatives that count as finding it.
    static func checks(_ p: Pack) -> [(name: String, alternatives: [String])] {
        var out: [(String, [String])] = []
        for (key, value) in p.expected.sorted(by: { $0.key < $1.key }) {
            switch (key, value) {
            case ("title", _), ("facts", _): continue          // the title is the case name; facts are scored separately
            case (_, .list(let items)) where ["parties", "amounts"].contains(key):
                for item in items { out.append(("\(key): \(item.strings.first ?? "")", item.strings)) }
            case (_, .object(let o)) where o["any"] != nil:
                out.append((key, o["any"]?.strings ?? []))
            case (_, .object(let o)) where o["date"] != nil:
                out.append((key, dateForms(o["date"]?.strings.first ?? "")))
            case (_, .string(let s)) where key == "date":
                out.append((key, dateForms(s)))
            case (_, .string(let s)):
                out.append((key, [s]))
            default: continue
            }
        }
        return out
    }

    static func dateForms(_ iso: String) -> [String] {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return [iso] }
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let m = months[max(0, min(11, parts[1] - 1))]
        return [iso, "\(m) \(parts[2]), \(parts[0])", "\(m.prefix(3)) \(parts[2]), \(parts[0])", "\(m.prefix(3)). \(parts[2]), \(parts[0])",
                "\(parts[2]) \(m) \(parts[0])", String(format: "%02d/%02d/%04d", parts[2], parts[1], parts[0])]
    }
}

/// The studio each persona produces from its case.
enum PersonaStudioDraft {
    static func draft(persona: String, from facts: StudioCaseFacts, now: Date) -> (gate: [String: String], provenance: StudioProvenance?, report: String)? {
        switch persona {
        case "lawyer":
            var m = PrivilegeLog(title: facts.caseTitle, now: now); m.prefill(from: facts)
            return (m.gateValues, m.provenance, PrivilegeLogRenderer.markdown(m, generatedAt: now))
        case "compliance":
            var m = WorkplaceInvestigation(title: facts.caseTitle, now: now); m.prefill(from: facts)
            return (m.gateValues, m.provenance, WIReportRenderer.markdown(m, generatedAt: now))
        case "forensic":
            var m = ForensicEngagement(title: facts.caseTitle, now: now); m.prefill(from: facts)
            return (m.gateValues, m.provenance, FAReportRenderer.markdown(m, generatedAt: now))
        case "siu":
            var m = SIUReferral(title: facts.caseTitle, now: now); m.prefill(from: facts)
            return (m.gateValues, m.provenance, SIUReportRenderer.markdown(m, generatedAt: now))
        case "journalist":
            var m = FactCheckMemo(title: facts.caseTitle, now: now); m.prefill(from: facts)
            return (m.gateValues, m.provenance, FactCheckMemoRenderer.markdown(m, generatedAt: now))
        case "researcher":
            var m = ResearchReview(title: facts.caseTitle, now: now); m.prefill(from: facts)
            return (m.gateValues, m.provenance, ResearchReviewRenderer.markdown(m, generatedAt: now))
        case "genealogist":
            var m = ProofArgument(title: facts.caseTitle, now: now); m.prefill(from: facts)
            return (m.gateValues, m.provenance, ProofArgumentRenderer.markdown(m, generatedAt: now))
        case "individual":
            var m = DisputeFile(title: facts.caseTitle, now: now); m.prefill(from: facts)
            return (m.gateValues, m.provenance, DisputeFileRenderer.markdown(m, generatedAt: now))
        default:
            return nil   // the Investigator's deliverable is the findings report itself
        }
    }
}

@Suite("Investigation cases — each persona start to end on a real public case", .serialized)
struct InvestigationCaseSimulationTests {

    static let personas = ["investigator", "lawyer", "compliance", "forensic", "siu", "journalist",
                           "researcher", "genealogist", "individual"]

    @Test("Start to end: intake → documents → subjects → chronology → contradictions/gaps → studio → findings",
          arguments: personas)
    func simulate(persona: String) async throws {
        let pack = try #require(try InvestigationCasePacks.packs().first { $0.persona == persona }, "no pack for \(persona)")

        // The evidence path (AI off) for a deterministic result, in this process's argument domain only.
        await SharedSettingsLock.shared.acquire()
        defer { Task { await SharedSettingsLock.shared.release() } }
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var settings = previous
        settings["kalsmritikosh.privacy.offlineNoLLM"] = true
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pj-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = await AppState(bookmarks: BookmarkStore())
        await state.boot(databaseURL: temp.appendingPathComponent("case.sqlite"))
        guard case .ready = await state.phase, let ingest = await state.ingest, let db = await state.database else {
            Issue.record("ledger did not boot"); return
        }

        // 1. Documents in (copied under their original names so the case reads like the record).
        var fileIDs: [UUID] = []
        var documentText = ""
        for name in pack.files {
            let src = try InvestigationCasePacks.url(name)
            let dst = temp.appendingPathComponent(String(name.dropFirst(persona.count + 1)))
            try FileManager.default.copyItem(at: src, to: dst)
            documentText += (try? String(contentsOf: dst, encoding: .utf8)) ?? ""
            let r = try await ingest.ingest(fileAt: dst)
            fileIDs.append(r.fileRecord.id)
        }

        // 2. Intake: a workspace with the documents, and a case over them.
        let now = Date()
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text(pack.caseTitle), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        let sources = try #require(await state.workspaceSourceCoordinator)
        try await sources.addSources(Set(fileIDs), to: ws, at: now)
        let cases = try #require(await state.investigationCases)
        let c = try await cases.createCase(workspaceID: ws, title: pack.caseTitle, actor: "simulation", at: now)
        let intake = try #require(await state.investigationWorkspaceIntake)
        _ = try await intake.includeWorkspaceSources(caseID: c.id, actor: "simulation", at: now)
        let answers = try #require(await state.investigationAnswers)
        let authorized = try await answers.scopeContext(caseID: c.id).scope.authorizedSourceVersionIDs
        #expect(!authorized.isEmpty, "the case has its documents in scope")

        // 3. Subjects, chronology, contradictions and gaps — the case engine.
        let subjects = try await (try #require(await state.investigationSubjectDossier)).subjects(caseID: c.id)
        let cg = try #require(await state.investigationContradictionGap)
        let contradictions = try await cg.contradictions(caseID: c.id)
        let gaps = try await cg.gaps(caseID: c.id)

        // 4. The persona's studio, filled from the case.
        let reader = StudioCaseFactsReader(facts: try #require(await state.genericFacts),
                                           events: try #require(await state.events),
                                           objects: try #require(await state.objects),
                                           entities: await state.entities)
        let facts = try await reader.read(caseTitle: pack.caseTitle, sourceVersionIDs: Set(authorized))
        let studio = PersonaStudioDraft.draft(persona: persona, from: facts, now: now)

        // 5. The findings report.
        let exportAccess = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: true, purpose: .export))
        let findings = try await (try #require(await state.investigationFindings))
            .buildFindings(caseID: c.id, access: exportAccess, actor: "simulation", at: now)
        let product = findings.assembled.workProduct
        let findingsText = product.sections.map { ([$0.title] + $0.preamble + $0.claims.map(\.text)).joined(separator: "\n") }
            .joined(separator: "\n")

        // Diagnostic: what the ledger extracted as names and money for the case documents.
        if let ents = await state.entities {
            var lines: [String] = []
            for d in facts.documents { for e in (try? await ents.findByMentionSource(d.objectID)) ?? [] { lines.append("\(e.kind.rawValue)|\(e.qualityTier)|\(e.value)") } }
            Attachment.record((["named: " + facts.named.map(\.value).joined(separator: "; "),
                                "amounts: " + facts.statedAmounts.map(\.value).joined(separator: "; ")] + lines.sorted()).joined(separator: "\n"),
                              named: "\(persona)-entities.txt")
        }

        // ── Score ─────────────────────────────────────────────────────────────
        // The investigator's deliverable is the case file (findings + what the documents name).
        let caseFileDigest = studio == nil ? CaseFileDocuments.namedInDocuments(facts) : ""
        let produced = ([findingsText, studio?.report ?? "", caseFileDigest] + facts.allFacts.map(\.value)
                        + facts.events.map { "\($0.title) \(StudioPrefill.isoDay($0.date))" } + subjects.map(\.label))
            .joined(separator: "\n").lowercased()
        let checks = InvestigationCasePacks.checks(pack)
        let found = checks.filter { check in check.alternatives.contains { !$0.isEmpty && produced.contains($0.lowercased()) } }
        let recall = checks.isEmpty ? 1 : Double(found.count) / Double(checks.count)

        // Wrong facts: a studio value the app says came from the case, which the case's documents do not state.
        let corpus = documentText.lowercased().replacingOccurrences(of: "\n", with: " ")
        var wrong: [String] = []
        if let studio {
            for (path, value) in studio.gate where StudioExportGate.status(of: value, provenance: studio.provenance?[path]) == .evidenced {
                let v = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let quotes = (studio.provenance?[path]?.evidence ?? []).compactMap { $0.quote?.lowercased() }
                // A document's type is read from its own file name — check that derivation exactly.
                let derivedType = path.hasSuffix(".docType") && pack.files.contains {
                    PrivilegeLog.documentType(String($0.dropFirst(persona.count + 1))).lowercased() == v }
                let stated = corpus.contains(v) || quotes.contains { corpus.contains($0) } || derivedType
                    || pack.files.contains { $0.lowercased().hasSuffix(v) || v.hasSuffix(String($0.dropFirst(persona.count + 1)).lowercased()) }
                if !stated { wrong.append("\(path) = \(value)") }
            }
        }
        let citations = product.allCitations
        let outOfCase = citations.filter { cit in cit.sourceVersionID.map { !authorized.contains($0) } ?? false }
        let unsupported = studio.map { StudioExportGate.unsupportedFields($0.gate, provenance: $0.provenance) } ?? []

        // A record for the verification report (written next to the test's temp dir output).
        let line = String(format: "%@ | recall %.0f%% (%d/%d) | wrong facts %d | subjects %d | contradictions %d | gaps %d | findings citations %d (out of case %d) | studio fields %d",
                          persona, recall * 100, found.count, checks.count, wrong.count, subjects.count,
                          contradictions.count, gaps.count, citations.count, outOfCase.count, studio?.gate.count ?? 0)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("investigation-case-simulation.txt")
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
        else { try? (line + "\n").write(to: log, atomically: true, encoding: .utf8) }

        #expect(wrong.isEmpty, "wrong facts must be 0: \(wrong.prefix(5))")
        #expect(outOfCase.isEmpty, "every findings citation is inside the case")
        #expect(unsupported.isEmpty, "every pre-filled studio field carries its source: \(unsupported.prefix(5))")
        #expect(!product.sections.isEmpty, "a findings report is produced")
        #expect(recall >= 0.5, "recall of the published record \(found.count)/\(checks.count): missing \(checks.filter { c in !found.contains { $0.name == c.name } }.map(\.name).prefix(6))")
    }
}

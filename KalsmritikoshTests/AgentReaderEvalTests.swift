//
//  AgentReaderEvalTests.swift
//  KalsmritikoshTests
//
//  Agent eval (2026-11-23) — "is it really Investigations Made Easy?" Real solved cases (the public persona packs in
//  Fixtures/InvestigationCases and the hand-keyed supplier case INV-104) worked through the REAL app: a throwaway ledger,
//  the real import, a case over the imported documents, the case permission answered "Allow" for the run, and every
//  question asked through InvestigationAnswerService on the one case path (Brain steps → briefing → parts → reader →
//  merge → second look → verifier). The AI reader is a file exchange: every request the app would send (prefix blocks +
//  suffix) is DUMPED to <root>/<case>/<q>/<kind>-p<part>-r<round>.txt and the reply is read from the same name with
//  `.reply.json` (missing → an honest not_stated placeholder). An agent writes the replies between runs; the next run
//  sends them through the app's merge, second look and verifier. The final shown answer, the rules (AI-off) reading, the
//  briefing, the consent summary, the rules contradictions and the drafted timeline are dumped beside them.
//
//  Debug-only and owner/agent-run only: it runs ONLY when AGENT_EVAL=1 is set or the git-ignored trigger file
//  build/agent-eval.trigger exists (its content, if any, is a comma-separated list of case ids to run). CI never has it.
//  No model, no network, no API spend. Evaluation only — it asserts nothing about answer quality.
//

#if DEBUG
import Foundation
import Testing
@testable import Kalsmritikosh

enum AgentEval {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static var trigger: URL { repoRoot.appendingPathComponent("build/agent-eval.trigger") }

    static var isOn: Bool {
        ProcessInfo.processInfo.environment["AGENT_EVAL"] == "1" || FileManager.default.fileExists(atPath: trigger.path)
    }

    /// The case ids to run (trigger content or AGENT_EVAL_CASES); empty = all.
    static var selected: Set<String> {
        let raw = ProcessInfo.processInfo.environment["AGENT_EVAL_CASES"]
            ?? ((try? String(contentsOf: trigger, encoding: .utf8)) ?? "")
        return Set(raw.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " }).map(String.init).filter { !$0.isEmpty })
    }

    /// The exchange folder: the first of these the test host can write and read back.
    static let root: URL = {
        var candidates: [URL] = []
        if let d = ProcessInfo.processInfo.environment["AGENT_EVAL_DIR"] { candidates.append(URL(fileURLWithPath: d, isDirectory: true)) }
        candidates.append(URL(fileURLWithPath: "/tmp/agent-eval", isDirectory: true))
        candidates.append(repoRoot.appendingPathComponent("build/agent-eval", isDirectory: true))
        candidates.append(FileManager.default.temporaryDirectory.appendingPathComponent("agent-eval", isDirectory: true))
        for c in candidates {
            do {
                try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
                let probe = c.appendingPathComponent(".probe")
                try Data("ok".utf8).write(to: probe)
                if (try? String(contentsOf: probe, encoding: .utf8)) == "ok" {
                    print("AGENTEVAL|root|\(c.path)")
                    return c
                }
            } catch {
                print("AGENTEVAL|root-rejected|\(c.path)|\(error.localizedDescription)")
            }
        }
        return candidates.last!
    }()

    /// Where the agent's replies are read from: the git-ignored build/agent-eval in the repo (the sandboxed test host may
    /// read the repo but write only its container, which the shell cannot read), else the exchange folder.
    static let replies = repoRoot.appendingPathComponent("build/agent-eval", isDirectory: true)

    /// Every dump is written to the exchange folder AND printed to the console between markers
    /// (scripts outside the host extract it from the test console log).
    static func write(_ text: String, _ path: String) {
        let url = root.appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        } catch {
            print("AGENTEVAL|write-failed|\(path)|\(error.localizedDescription)")
        }
        print("AGENTEVAL-DUMP-BEGIN \(path)\n\(text)\nAGENTEVAL-DUMP-END \(path)")
    }

    static func read(_ path: String) -> String? {
        if let s = try? String(contentsOf: replies.appendingPathComponent(path), encoding: .utf8) { return s }
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static let placeholder = #"{"status": "not_stated", "claims": [], "answer": ""}"#

    struct Question { let id: String; let text: String }
    struct Case {
        let id: String
        let title: String
        /// (file name, bytes) in import order.
        let files: () throws -> [(String, Data)]
        let questions: [Question]
    }

    static func pack(_ names: [String]) -> () throws -> [(String, Data)] {
        { try names.map { ($0, try Data(contentsOf: try InvestigationCasePacks.url($0))) } }
    }

    static let inv104Source = repoRoot.appendingPathComponent("Kalsmritikosh/Resources/Fixtures/\(SupplierINV104Fixture.folderName)", isDirectory: true)

    /// The cases and the questions (investigator wording; the answer keys stay out of the test).
    static let cases: [Case] = [
        Case(id: "forensic", title: "West Point embezzlement — funds tracing", files: pack(["forensic-press-release.txt"]), questions: [
            .init(id: "q1", text: "How much did Bobbie Cyana Ryan authorize in payments to CWG Enterprises?"),
            .init(id: "q2", text: "How did the government's money reach Ryan's own account?"),
            .init(id: "q3", text: "What bond was Ryan released on, and when is her next court appearance?"),
        ]),
        Case(id: "investigator", title: "Goodyear trade secrets", files: pack(["investigator-press-release.txt"]), questions: [
            .init(id: "q1", text: "Who was charged with stealing trade secrets from Goodyear, and what company did they work for?"),
            .init(id: "q2", text: "How were the trade secrets obtained, and where were they sent?"),
            .init(id: "q3", text: "What maximum penalty does each defendant face?"),
        ]),
        Case(id: "journalist", title: "State Department passport files — false statements", files: pack(["journalist-press-release.txt"]), questions: [
            .init(id: "q1", text: "What did Brooke E. Reyna plead guilty to?"),
            .init(id: "q2", text: "What exactly was the false statement she made to the investigators?"),
            .init(id: "q3", text: "How many passport applications did Reyna view without reason, and over what period?"),
        ]),
        Case(id: "researcher", title: "Grant fraud scheme", files: pack(["researcher-press-release.txt"]), questions: [
            .init(id: "q1", text: "Who was charged in the grant fraud scheme?"),
            .init(id: "q2", text: "How much did the business owners pay up front, and what total cost were they told?"),
            .init(id: "q3", text: "Which company did the defendants claim to represent, and whom did they actually represent?"),
        ]),
        Case(id: "siu", title: "Staged automobile accident scheme", files: pack(["siu-press-release.txt"]), questions: [
            .init(id: "q1", text: "When did Yanet Hernandez plead guilty, and when is she scheduled to be sentenced?"),
            .init(id: "q2", text: "How much restitution has been ordered so far?"),
            .init(id: "q3", text: "How many defendants have been charged in Operation Sledgehammer, and how many of them federally?"),
        ]),
        Case(id: "compliance", title: "Keepseagle false claim — Patrick Charles Thomas", files: pack(["compliance-press-release.txt"]), questions: [
            .init(id: "q1", text: "How much does the United States seek to recover from Patrick Charles Thomas?"),
            .init(id: "q2", text: "What did Thomas receive on his Keepseagle claim, and what was it worth in total?"),
            .init(id: "q3", text: "What contradicts Thomas's claim that he complained about discrimination at the time?"),
            .init(id: "q4", text: "What sentence did Thomas receive in the criminal case, and for what offence?"),
        ]),
        Case(id: "lawyer", title: "Corporation of America v. McLaughlin", files: pack(["lawyer-decision.txt"]), questions: [
            .init(id: "q1", text: "When was Corporation of America v. McLaughlin decided, by which court, and under which docket number?"),
            .init(id: "q2", text: "Which judge wrote the opinion, and did any judge dissent?"),
            .init(id: "q3", text: "What was the outcome of the appeal?"),
        ]),
        Case(id: "genealogist", title: "Estate of Cervin v. Commissioner", files: pack(["genealogist-decision.txt"]), questions: [
            .init(id: "q1", text: "When was Estate of Cervin v. Commissioner decided, by which court, and under which docket number?"),
            .init(id: "q2", text: "Which judge wrote the opinion?"),
            .init(id: "q3", text: "What share of the life insurance proceeds must be included in the gross estate, and does the court of appeals agree with the Tax Court on it?"),
        ]),
        Case(id: "individual", title: "NTSB SEA08LA057 — mid-air collision at Sonoma", files: pack(["individual-analysis.txt", "individual-factual.txt", "individual-probable-cause.txt", "individual-report-page-1.txt"]), questions: [
            .init(id: "q1", text: "When and where did the collision happen?"),
            .init(id: "q2", text: "What was the probable cause of the accident?"),
            .init(id: "q3", text: "Which aircraft were involved, and what damage did each sustain?"),
            .init(id: "q4", text: "Do the two pilots' accounts differ about the runway or about who was warned?"),
        ]),
        Case(id: "inv104", title: "Was Kestrel Supplies paid twice for INV-104?", files: {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aee-inv104-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let written = try SupplierINV104Fixture.materialise(from: inv104Source, into: temp)
            return try written.keys.sorted().map { ($0, try Data(contentsOf: written[$0]!)) }
        }, questions: [
            .init(id: "q1", text: "Was Kestrel Supplies paid twice for invoice INV-104?"),
            .init(id: "q2", text: "How much was paid to Kestrel in March 2026, how much came back, and what is the net outflow?"),
            .init(id: "q3", text: "Is finding 2 of forensic report FR-12 still standing?"),
            .init(id: "q4", text: "Who approved the second payment, KS-77985?"),
            .init(id: "q5", text: "Is the Arjun Mehta in the newsletter the same person who signed the invoice?"),
        ]),
    ]

    /// The request log of one run (thread-safe: parts are read concurrently).
    nonisolated final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var current = "none"
        private var counters: [String: Int] = [:]
        private var sends: [String] = []
        func set(_ q: String) { lock.withLock { current = q; sends = [] } }
        var question: String { lock.withLock { current } }
        var log: [String] { lock.withLock { sends } }
        func next(_ key: String) -> Int { lock.withLock { let n = counters[key, default: 0]; counters[key] = n + 1; return n } }
        func record(_ s: String) { lock.withLock { sends.append(s) } }
    }

    static func partNumber(_ prefix: [String]) -> Int {
        guard let first = prefix.first, let r = first.range(of: #"This is part (\d+) of"#, options: .regularExpression) else { return 1 }
        return Int(first[r].filter(\.isNumber).prefix(4)) ?? 1
    }

    static func reader(caseID: String, exchange: Exchange) -> CaseReader {
        CaseReader { send in
            let kind: String
            let folder: String
            if send.purpose == "case.question" {
                kind = send.suffix.hasPrefix("Task: a check of an answer already given") ? "look" : "q"
                folder = "\(caseID)/\(exchange.question)"
            } else {
                kind = send.purpose.replacingOccurrences(of: "case.", with: "")
                folder = "\(caseID)/_\(kind)"
            }
            let part = partNumber(send.prefix)
            let round = exchange.next("\(folder)|\(kind)|\(part)")
            let base = "\(folder)/\(kind)-p\(part)-r\(round)"
            var dump = "=== REQUEST \(base) purpose=\(send.purpose) batch=\(send.batch) replyTokens=\(send.replyTokens)\n"
            for (i, b) in send.prefix.enumerated() { dump += "\n--- PREFIX BLOCK \(i + 1) of \(send.prefix.count) ---\n" + b + "\n" }
            dump += "\n--- SUFFIX ---\n" + send.suffix + "\n"
            write(dump, base + ".txt")
            let reply = read(base + ".reply.json")
            exchange.record("\(base) reply=\(reply == nil ? "placeholder" : "file") tokens≈\(CaseReader.estimatedTokens(send.prefix + [send.suffix]))")
            return CaseReader.Reply(text: reply ?? placeholder)
        }
    }

    static func describe(_ a: VerifiedAnswer, path: InvestigationAnswerService.CaseReadPath?, seconds: Double) -> String {
        var s = "path=\(path.map(\.rawValue) ?? "nil") intentKind=\(a.intentKind ?? "nil") state=\(String(describing: a.answerState)) refused=\(a.refused) writer=\(VerifiedAnswerComposer.writer(of: a)) seconds=\(String(format: "%.2f", seconds))\n"
        s += "--- BODY ---\n\(a.body)\n"
        if !a.citations.isEmpty {
            s += "--- CITATIONS ---\n" + a.citations.map { "- \($0.objectID.uuidString.prefix(8)): \($0.snippet.prefix(300))" }.joined(separator: "\n") + "\n"
        }
        return s
    }
}

@Suite("Agent eval — real solved cases with the agent as the AI reader", .serialized, .enabled(if: AgentEval.isOn))
struct AgentReaderEvalTests {

    @Test("Work every selected case through the one case path, dumping each AI request and reading the agent's replies")
    func run() async throws {
        let selected = AgentEval.selected
        let root = AgentEval.root
        print("AGENTEVAL|start|root=\(root.path)|cases=\(selected.isEmpty ? "all" : selected.sorted().joined(separator: ","))")
        var summary: [String] = []
        for c in AgentEval.cases where selected.isEmpty || selected.contains(c.id) {
            let lines = try await Self.work(c)
            summary.append(contentsOf: lines)
        }
        AgentEval.write(summary.joined(separator: "\n") + "\n", "summary-\(selected.isEmpty ? "all" : selected.sorted().joined(separator: "_")).txt")
        print("AGENTEVAL|done|\(summary.count) line(s)")
    }

    /// Why the verifier kept or dropped each claim of the agent's last question reply and second-look reply (diagnostic:
    /// the same `VerifiedAnswerComposer.verify` the case path runs, over the same case documents and question).
    static func verifierReasons(caseID: String, q: AgentEval.Question, documents: [CaseReader.Document]) -> String {
        var out = "--- VERIFIER (per claim of the agent's replies) ---\n"
        let passages = CaseReader.passages(documents)
        let person = ProceedingAnswerer.person(in: q.text)
        out += "question person: \(person ?? "none")\n"
        for kind in ["q", "look"] {
            var last: String?
            for round in 0..<4 { if let r = AgentEval.read("\(caseID)/\(q.id)/\(kind)-p1-r\(round).reply.json") { last = r } }
            guard let reply = last, let parsed = VerifiedAnswerComposer.parse(reply) else { continue }
            for claim in parsed.claims ?? [] {
                let why = VerifiedAnswerComposer.whyNot(claim, passages: passages, person: person)
                out += "\(kind): \(why.map { "DROPPED (\($0))" } ?? "kept") — \(claim.text ?? "")\n"
            }
        }
        return out
    }

    static func work(_ c: AgentEval.Case) async throws -> [String] {
        var out: [String] = []
        func note(_ s: String) { out.append("\(c.id)|\(s)"); print("AGENTEVAL|\(c.id)|\(s.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(600))") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aee-\(UUID().uuidString)", isDirectory: true)
        let folder = temp.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // 1. Boot the app on a throwaway ledger; import the case's documents through the real pipeline.
        let t0 = Date()
        let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        note("boot|\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        let ingest = try #require(await state.ingest)
        let db = try #require(await state.database)
        let coordinator = try #require(await state.workspaceSourceCoordinator)
        let cases = try #require(await state.investigationCases)
        let intake = try #require(await state.investigationWorkspaceIntake)
        let answers = try #require(await state.investigationAnswers)
        var fileIDs: [UUID] = []
        let t1 = Date()
        for (name, bytes) in try c.files() {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            let s = Date()
            do {
                let r = try await ingest.ingest(fileAt: url)
                fileIDs.append(r.fileRecord.id)
                note("ingest|\(name)|chunks=\(r.chunkCount) entities=\(r.entityCount) events=\(r.eventCount) status=\(r.processingStatus.map { "\($0)" } ?? "nil") outcome=\(r.intakeOutcome.map { $0.rawValue } ?? "nil") \(String(format: "%.2f", Date().timeIntervalSince(s)))s")
            } catch {
                note("ingest|\(name)|ERROR \(error)")
            }
        }
        await ingest.drainEmbeddingsNow()
        note("ingest-total|\(String(format: "%.2f", Date().timeIntervalSince(t1)))s")

        // 2. A case over the imported documents.
        let t2 = Date()
        let ws = UUID(), now = Date()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text(c.title), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        try await coordinator.addSources(Set(fileIDs), to: ws, at: now)
        let record = try await cases.createCase(workspaceID: ws, title: c.title, actor: "Agent Investigator", at: now)
        let (_, included) = try await intake.includeWorkspaceSources(caseID: record.id, actor: "Agent Investigator", at: now)
        note("case|\(included) document(s) included|\(String(format: "%.2f", Date().timeIntervalSince(t2)))s")
        let access = SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))

        // 3. What the permission sheet would show and the briefing the reader gets (the app's own plan).
        var caseDocuments: [CaseReader.Document] = []
        if let objects = await state.objects, let scopes = await state.sensitiveScopes {
            let plan = await state.caseWholeReading(objects: objects, sensitiveScopes: scopes)
            let ctx = try await answers.scopeContext(caseID: record.id)
            let (prepared, excluded) = await plan.prepare(caseID: record.id, versions: ctx.scope.authorizedSourceVersionIDs, binding: answers.cloudScope(caseID: record.id))
            let notReadable = await plan.notReadable(record.id)
            var consent = "case=\(c.title)\nauthorised source versions=\(ctx.scope.authorizedSourceVersionIDs.count)\n"
            if let p = prepared {
                caseDocuments = p.documents
                consent += "documents sent=\(p.documents.count) of \(p.caseDocuments) case documents; parts=\(p.parts.count); tokens≈\(p.tokens); limit=\(p.limit); readsWhole=\(p.fits)\n"
                consent += p.documents.enumerated().map { "  [Document \($0 + 1)] \($1.fileName ?? "?") \($1.text.utf8.count) bytes" }.joined(separator: "\n") + "\n"
                AgentEval.write(p.briefing.isEmpty ? "(no briefing)" : p.briefing, "\(c.id)/briefing.txt")
                note("briefing|\(p.briefing.count) chars, \(p.briefing.split(separator: "\n").filter { $0.hasPrefix("- ") }.count) lines")
            } else {
                consent += "NOTHING SENDABLE\n"
            }
            consent += "excluded=\(excluded.map { "\($0.name): \($0.reason ?? "?")" })\nnot readable=\(notReadable.map { "\($0.name): \($0.reason ?? "?")" })\n"
            AgentEval.write(consent, "\(c.id)/consent.txt")
        }

        // 4. The case tools without AI: the rules contradiction check and the drafted timeline.
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let gap = try #require(await state.investigationContradictionGap)
            let t = Date()
            let run = try await gap.findContradictions(caseID: record.id)
            var text = "documents=\(run.documents) rule findings=\(run.ruleFindings.count) (\(String(format: "%.2f", Date().timeIntervalSince(t)))s)\n"
            text += run.ruleFindings.map { "- \($0.kind) · \($0.subject) · \($0.attribute): “\($0.valueA)” vs “\($0.valueB)”" }.joined(separator: "\n")
            let t3 = Date()
            let drafts = try await gap.buildDrafts(caseID: record.id, useAI: false)
            text += "\n\n=== drafted timeline (rules) \(drafts.timeline.count) item(s), \(String(format: "%.2f", Date().timeIntervalSince(t3)))s ===\n"
            text += drafts.timeline.map { "- \($0.year)-\(String(format: "%02d", $0.month))-\(String(format: "%02d", $0.day)) — \($0.what)" }.joined(separator: "\n")
            AgentEval.write(text, "\(c.id)/case-tools.txt")
            note("case-tools|contradictions=\(run.ruleFindings.count) timeline=\(drafts.timeline.count)")
        }

        // 5. Each question: the rules (AI-off) reading, then the AI path with the agent as the reader.
        let exchange = AgentEval.Exchange()
        for q in c.questions {
            await state.cloudReaderHolder.set(CloudReaders())
            let tr = Date()
            let rules = try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
                try await answers.answer(caseID: record.id, question: q.text, access: access).verified
            }
            let rulesSeconds = Date().timeIntervalSince(tr)
            AgentEval.write("Q: \(q.text)\n" + AgentEval.describe(rules, path: await answers.lastCasePath, seconds: rulesSeconds), "\(c.id)/\(q.id)/rules.txt")

            var readers = CloudReaders(modelsAllowedOverride: true)
            readers.caseReader = AgentEval.reader(caseID: c.id, exchange: exchange)
            await state.cloudReaderHolder.set(readers)
            await MainActor.run { CaseReadConsent.shared.scriptedAnswer = true }   // the case permission: Allow, given programmatically
            exchange.set(q.id)
            let ta = Date()
            let final = try await answers.answer(caseID: record.id, question: q.text, access: access).verified
            let seconds = Date().timeIntervalSince(ta)
            let path = await answers.lastCasePath
            var text = "Q: \(q.text)\n" + AgentEval.describe(final, path: path, seconds: seconds)
            text += "--- SENDS ---\n" + exchange.log.joined(separator: "\n") + "\n"
            text += Self.verifierReasons(caseID: c.id, q: q, documents: caseDocuments)
            AgentEval.write(text, "\(c.id)/\(q.id)/final.txt")
            note("\(q.id)|path=\(path.map(\.rawValue) ?? "nil")|kind=\(final.intentKind ?? "nil")|sends=\(exchange.log.count)|rules \(String(format: "%.2f", rulesSeconds))s ai \(String(format: "%.2f", seconds))s|\(final.body.prefix(240))")
        }
        await state.cloudReaderHolder.set(CloudReaders())
        await MainActor.run { CaseReadConsent.shared.scriptedAnswer = nil }
        // The background AI-suggestions read (AI-37) may still be running; give it a moment, then close.
        try? await Task.sleep(for: .seconds(1))
        await state.shutdown()
        return out
    }
}
#endif

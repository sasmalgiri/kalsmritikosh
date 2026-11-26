//
//  CaseTypesSolveTests.swift
//  KalsmritikoshTests
//
//  One case of each type the app serves (the nine professions), worked end to end through the PRODUCTION services on a
//  throwaway ledger with AI OFF (owner 2026-11-18: "take all types of case, each one, then try to solve it"). Each case
//  has a few short documents with a planted answer; the run ingests them through the real pipeline, scopes them into a
//  case and works it the way a person would without AI: the contradiction check, the drafted timeline, the profession's
//  own jobs and the offline Ask. What each step found is printed ("SOLVE|case|step|…") for docs/evidence/case-types-solve;
//  the expectations are the planted answers. A scenario run, not an accuracy measurement.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("One case of each type, solved with AI off", .serialized)
struct CaseTypesSolveTests {

    /// A booted app on a temporary ledger with one case holding the given documents.
    struct Rig {
        let state: AppState
        let temp: URL
        let caseID: UUID
        let ws: UUID
        let versions: [String: UUID]
        let name: String

        var access: SensitiveAccessContext {
            SensitiveAccessContext(scope: SensitiveScope(workspaceID: ws, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
        }

        static func make(_ name: String, title: String, docs: [(String, String)]) async throws -> Rig {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("solve-\(UUID().uuidString)", isDirectory: true)
            let folder = temp.appendingPathComponent("documents", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let state = await AppState(bookmarks: BookmarkStore(ephemeral: true))
            await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
            let ingest = try #require(await state.ingest)
            let db = try #require(await state.database)
            let coordinator = try #require(await state.workspaceSourceCoordinator)
            let cases = try #require(await state.investigationCases)
            let intake = try #require(await state.investigationWorkspaceIntake)
            var fileIDs: [UUID] = [], versions: [String: UUID] = [:]
            for (file, text) in docs {
                let url = folder.appendingPathComponent(file)
                try Data(text.utf8).write(to: url)
                let r = try await ingest.ingest(fileAt: url)
                fileIDs.append(r.fileRecord.id)
                if let v = r.sourceVersionID { versions[file] = v }
                print("SOLVE|\(name)|ingest|\(file)|chunks=\(r.chunkCount) entities=\(r.entityCount) events=\(r.eventCount) status=\(r.processingStatus.map { "\($0)" } ?? "nil")")
            }
            let ws = UUID(), now = Date()
            try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                              [.uuid(ws), .text(title), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            try await coordinator.addSources(Set(fileIDs), to: ws, at: now)
            let c = try await cases.createCase(workspaceID: ws, title: title, actor: "Asha Investigator", at: now)
            let (_, included) = try await intake.includeWorkspaceSources(caseID: c.id, actor: "Asha Investigator", at: now)
            print("SOLVE|\(name)|scope|\(included) document(s) in the case")
            return Rig(state: state, temp: temp, caseID: c.id, ws: ws, versions: versions, name: name)
        }

        func log(_ step: String, _ text: String) { print("SOLVE|\(name)|\(step)|\(text.replacingOccurrences(of: "\n", with: " ⏎ "))") }

        /// The rules contradiction check (AI off).
        func contradictions() async throws -> [CaseContradictionFinder.Finding] {
            let svc = try #require(await state.investigationContradictionGap)
            let run = try await svc.findContradictions(caseID: caseID)
            for f in run.ruleFindings {
                log("contradiction", "\(f.kind) · \(f.subject) · \(f.attribute): “\(f.valueA)” vs “\(f.valueB)”")
            }
            if run.ruleFindings.isEmpty { log("contradiction", "none found over \(run.documents) document(s)") }
            return run.ruleFindings
        }

        /// The timeline drafted from the documents (AI off).
        func timeline() async throws -> [CaseDraftTimelineItem] {
            let svc = try #require(await state.investigationContradictionGap)
            let drafts = try await svc.buildDrafts(caseID: caseID, useAI: false)
            for t in drafts.timeline {
                let when = "\(t.year)-\(String(format: "%02d", t.month))-\(String(format: "%02d", t.day))"
                log("timeline", "\(when) — \(t.what)")
            }
            if drafts.timeline.isEmpty { log("timeline", "nothing dated") }
            return drafts.timeline
        }

        /// One of the profession's jobs, launched in the case; its result rows.
        func job(_ persona: ApplicationDefinitionID, _ jobID: String) async throws -> JobResultRecord? {
            let service = try #require(await state.personaJobs)
            guard let job = await service.jobs(forPersona: persona).first(where: { $0.id == jobID }) else { log("job", "\(jobID): not offered"); return nil }
            _ = try await service.launch(job, context: PersonaJobLaunchContext(caseID: caseID, access: access, actor: "Asha Investigator", at: Date()))
            let db = try #require(await state.database)
            let r = try await JobResultRepository(database: db).latest(caseID: caseID, jobID: jobID)
            guard let r else { log("job", "\(jobID): no result saved"); return nil }
            log("job", "\(jobID): \(r.content.rows.count) row(s); limitations: \(r.content.limitations.joined(separator: "; "))")
            for row in r.content.rows.prefix(12) {
                log("job", "  \(jobID) · \(row.title)\(row.date.map { " [\($0)]" } ?? "") — \(row.detail ?? "")\(row.flags.isEmpty ? "" : " {\(row.flags.joined(separator: "; "))}")")
            }
            return r
        }

        /// The offline Ask (AI off): search results with citations.
        func ask(_ q: String) async throws -> VerifiedAnswer? {
            let svc = try #require(await state.investigationAnswers)
            let a = try await svc.answer(caseID: caseID, question: q, access: access)
            log("ask", "Q: \(q) → \(String(a.verified.body.prefix(400)))")
            return a.verified
        }

        func finish() async {
            await state.shutdown()
            try? FileManager.default.removeItem(at: temp)
        }
    }

    static func text(_ rows: [JobResultRow]?) -> String {
        (rows ?? []).map { "\($0.title) \($0.detail ?? "") \($0.flags.joined(separator: " ")) \($0.fields?.values.joined(separator: " ") ?? "")" }.joined(separator: "\n")
    }

    @Test("Regression 2026-11-18: a name inside a longer known name (“Leela Menon” in “Mayor Leela Menon”) no longer crashes speaker attribution")
    func nestedNamesDoNotCrash() {
        let r = SpeakerAttribution.resolve("Mayor Leela Menon said the city built 1,200 homes in 2025.", named: ["Leela Menon", "Mayor Leela Menon"])
        #expect(r.speaker == "Mayor Leela Menon", "\(r.basis)")
        let s = SpeakerAttribution.resolve("Dr Asha Rao, who met Asha Rao's deputy, said the payment was late.", named: ["Asha Rao", "Dr Asha Rao"])
        #expect(s.speaker != nil || !s.basis.isEmpty)
    }

    // MARK: 1. Investigator — missing cash box

    @Test("Investigator: who entered the store room after it was locked, and how much was in the cash box?")
    func investigator() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("investigator", title: "Missing cash box from Store Room 2", docs: [
                ("statement-mohan-lal.txt", "Statement of Mohan Lal, security guard, recorded on 13 March 2026.\nMohan Lal said he locked Store Room 2 at 21:00 on 12 March 2026. He said the cash box then held INR 45,000."),
                ("statement-suresh-kumar.txt", "Statement of Suresh Kumar, store assistant, recorded on 13 March 2026.\nSuresh Kumar said he did not enter Store Room 2 on 12 March 2026 after 18:00."),
                ("badge-log-12-march.csv", "Date,Time,Badge,Name,Door\n2026-03-12,20:55,B-101,Mohan Lal,Store Room 2\n2026-03-12,22:10,B-114,Suresh Kumar,Store Room 2\n"),
                ("cashier-count.txt", "Cashier's count sheet, 12 March 2026.\nThe cashier counted INR 40,000 in the cash box of Store Room 2 at 17:30 on 12 March 2026."),
            ])
            let found = try await r.contradictions()
            let amountPairs: [String] = found.filter { $0.kind == .amount }.map { "\($0.valueA)|\($0.valueB)" }
            withKnownIssue("GAP 2026-11-18: the rules contradiction check compares only keyed facts; two prose amounts for one cash box are not compared") {
                #expect(amountPairs.contains { $0.contains("45") && $0.contains("40") }, "the two cash-box amounts disagree (45,000 vs 40,000): \(amountPairs)")
            }
            _ = try await r.timeline()
            _ = try await r.job(InvestigatorPersonaPackage.applicationID, "inv.linkage")
            _ = try await r.job(InvestigatorPersonaPackage.applicationID, "inv.source-reliability")
            let a = try await r.ask("Who entered Store Room 2 at 22:10?")
            let body: String = a?.body ?? ""
            #expect(body.contains("Suresh Kumar") || body.contains("22:10"), "the badge log line is found")
            await r.finish()
        }
    }

    // MARK: 2. Lawyer — termination notice

    @Test("Lawyer: what notice did the contract require, and when was notice given and received?")
    func lawyer() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("lawyer", title: "Was the termination notice given in time?", docs: [
                ("services-agreement.txt", "Services Agreement between Orion Logistics Pvt Ltd and Bluewater Foods Ltd dated 2 January 2025.\nClause 14.2: Either party may terminate this Agreement by giving not less than 30 days' written notice to the other party."),
                ("termination-letter.txt", "Letter from Bluewater Foods Ltd to Orion Logistics Pvt Ltd dated 15 May 2026.\nBluewater Foods Ltd hereby terminates the Services Agreement with effect from 31 May 2026."),
                ("email-receipt.txt", "Email from Kiran Shah of Orion Logistics dated 20 May 2026.\nOrion Logistics received the termination letter on 20 May 2026."),
            ])
            let obligations = try await r.job(LawyerPersonaPackage.applicationID, "law.obligations")
            let obligationText: String = Self.text(obligations?.content.rows)
            withKnownIssue("GAP 2026-11-18: law.obligations reads typed facts (dates, parties as 'employer'), not a notice clause") {
                #expect(obligationText.contains("30 days"), "the 30-day notice clause is found")
            }
            let chronology = try await r.job(LawyerPersonaPackage.applicationID, "law.fact-chronology")
            let chronoRows: [JobResultRow] = chronology?.content.rows ?? []
            let days: Set<String> = Set(chronoRows.compactMap { $0.date })
            #expect(days.isSuperset(of: ["2026-05-15", "2026-05-20", "2026-05-31"]), "the letter, its receipt and the effective date are in the chronology: \(days.sorted())")
            _ = try await r.job(LawyerPersonaPackage.applicationID, "law.deadlines")
            _ = try await r.job(LawyerPersonaPackage.applicationID, "law.parties-issues")
            _ = try await r.timeline()
            _ = try await r.ask("How much notice does clause 14.2 require?")
            await r.finish()
        }
    }

    // MARK: 3. Compliance / HR — complaint with a denial

    @Test("Compliance/HR: who says what about the 3 April meeting, and does the respondent deny it?")
    func compliance() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("compliance", title: "Complaint by Neha Singh about the 3 April team meeting", docs: [
                ("complaint-neha-singh.txt", "Complaint from Neha Singh dated 5 April 2026.\nNeha Singh said that Rahul Verma shouted at her during the team meeting on 3 April 2026 and called her work useless."),
                ("witness-anil-joshi.txt", "Interview note, 8 April 2026.\nAnil Joshi said that Rahul Verma shouted at Neha Singh during the team meeting on 3 April 2026."),
                ("response-rahul-verma.txt", "Response of Rahul Verma, 10 April 2026.\nRahul Verma denied that he shouted at Neha Singh. He said he only raised his voice because the projector was loud."),
            ])
            let statements = try await r.job(CompliancePersonaPackage.applicationID, "hr.statements")
            let rows: [JobResultRow] = statements?.content.rows ?? []
            let witnesses: Set<String> = Set(rows.compactMap { $0.fields?["witness"] })
            #expect(witnesses.isSuperset(of: ["Neha Singh", "Anil Joshi", "Rahul Verma"]), "all three accounts: \(witnesses.sorted())")
            #expect(rows.contains { $0.fields?["witness"] == "Rahul Verma" && $0.flags.contains("denial") }, "the respondent's denial is marked")
            _ = try await r.job(CompliancePersonaPackage.applicationID, "hr.allegations")
            _ = try await r.job(CompliancePersonaPackage.applicationID, "hr.incident-timeline")
            _ = try await r.timeline()
            await r.finish()
        }
    }

    // MARK: 4. Forensic accountant — the same invoice paid twice

    @Test("Forensic accountant: was invoice INV-778 paid twice, and what is the gross and net?")
    func forensicAccountant() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("forensic", title: "Was Apex Supplies paid twice for INV-778?", docs: [
                ("invoice-INV-778.txt", "Apex Supplies — Invoice INV-778 dated 1 June 2026 to Meridian Hospitals for INR 72,500."),
                ("bank-statement-june.csv", "Date,Description,Reference,Debit,Credit\n2026-06-04,Apex Supplies,INV-778,\"72,500.00\",\n2026-06-18,Apex Supplies,INV-778,\"72,500.00\",\n2026-06-20,Office rent,RENT-06,\"40,000.00\",\n"),
                ("ap-clerk-note.txt", "Note from the accounts payable clerk, 25 June 2026.\nThe clerk said invoice INV-778 was paid once, on 4 June 2026."),
            ])
            _ = try await r.job(ForensicAccountantPersonaPackage.applicationID, "fa.funds-tracing")
            let disc = try await r.job(ForensicAccountantPersonaPackage.applicationID, "fa.discrepancies")
            _ = disc
            // The money records: the statement imported as a person would (Case tools ▸ Money).
            let file = try #require(await r.state.caseFiles).file
            let acct = try await file.addMoneyAccount(caseID: r.caseID, identifier: "Meridian current account", institution: "City Bank", actor: "Asha Investigator")
            let st = try await file.addMoneyStatement(caseID: r.caseID, accountID: acct, periodStart: "2026-06-01", periodEnd: "2026-06-30", opening: nil, closing: nil,
                                                      currency: "INR", actor: "Asha Investigator")
            _ = try await file.importStatementRows(caseID: r.caseID, statementID: st,
                                                   text: "Date,Description,Reference,Debit,Credit\n2026-06-04,Apex Supplies,INV-778,\"72,500.00\",\n2026-06-18,Apex Supplies,INV-778,\"72,500.00\",\n",
                                                   actor: "Asha Investigator")
            let ledger = try await file.moneyLedger(caseID: r.caseID)
            let pairs = ledger.undecidedPairs()
            r.log("money", "\(ledger.transactions().transactions.count) movement(s); possible duplicates to decide: \(pairs.count)")
            for line in ledger.figures() { r.log("money", "\(line)") }
            #expect(ledger.transactions().transactions.count == 2, "two debits are two movements until a person decides")
            _ = try await r.ask("When was invoice INV-778 paid?")
            _ = try await r.contradictions()
            await r.finish()
        }
    }

    // MARK: 5. Insurance SIU — loss before the policy started, prior claim

    @Test("Insurance SIU: did the loss happen before cover began, and was the vehicle claimed for before?")
    func siu() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("siu", title: "Claim CL-2209: theft of vehicle MH12AB1234", docs: [
                ("policy-schedule.txt", "Policy P-55120 for vehicle MH12AB1234 issued to Deepak Rao. Period of insurance: 1 August 2026 to 31 July 2027."),
                ("claim-form.txt", "Claim form CL-2209 signed by Deepak Rao on 4 August 2026.\nDate of loss: 2 August 2026. The vehicle MH12AB1234 was stolen from outside his house."),
                ("police-report.txt", "FIR 311/2026 registered at Kothrud police station on 29 July 2026.\nDeepak Rao reported that his vehicle MH12AB1234 was stolen on 28 July 2026."),
                ("prior-claims-extract.txt", "Industry claims database extract: claim CL-1730 for theft of vehicle MH12AB1234 by Deepak Rao, notified on 3 March 2025, paid INR 2,10,000."),
            ])
            let found = try await r.contradictions()
            withKnownIssue("GAP 2026-11-18: the police report's 'stolen on 28 July' is not read as a date of loss, so it is never compared with the claim's") {
                #expect(found.contains { $0.kind == .date }, "the date of loss disagrees (2 August vs 28 July 2026)")
            }
            _ = try await r.job(SIUPersonaPackage.applicationID, "siu.red-flags")
            let prior = try await r.job(SIUPersonaPackage.applicationID, "siu.prior-claims")
            let priorText: String = Self.text(prior?.content.rows)
            #expect(priorText.contains("CL-1730") || priorText.contains("2025"), "the earlier claim on the same vehicle is listed")
            _ = try await r.job(SIUPersonaPackage.applicationID, "siu.loss-chronology")
            _ = try await r.timeline()
            await r.finish()
        }
    }

    // MARK: 6. Journalist — official claim vs the department's own report

    @Test("Journalist: does the mayor's figure for homes built in 2025 match the housing department's report?")
    func journalist() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("journalist", title: "Did the city build 1,200 homes in 2025?", docs: [
                ("mayor-speech.txt", "Speech by Mayor Leela Menon on 12 January 2026.\nMayor Leela Menon said the city built 1,200 homes in 2025."),
                ("housing-department-report.txt", "Housing Department annual report 2025, published 2 February 2026.\nThe Housing Department said the city completed 800 homes in 2025, and 400 more were under construction."),
                ("press-release.txt", "City press release, 13 January 2026.\nThe city built 1,200 homes in 2025, the press office said."),
            ])
            let found = try await r.contradictions()
            withKnownIssue("GAP 2026-11-18: counts in prose ('built 1,200 homes', 'completed 800 homes') are not compared") {
                #expect(found.contains { $0.kind == .count || $0.kind == .amount }, "1,200 vs 800 homes in 2025")
            }
            let sources = try await r.job(JournalistPersonaPackage.applicationID, "jrn.source-map")
            _ = sources
            _ = try await r.job(JournalistPersonaPackage.applicationID, "jrn.quote-book")
            _ = try await r.job(JournalistPersonaPackage.applicationID, "jrn.chronology")
            _ = try await r.ask("How many homes were completed in 2025?")
            await r.finish()
        }
    }

    // MARK: 7. Researcher / historian — two dates for one event

    @Test("Researcher: when did the Howrah jute mill open — 1857 or 1859?")
    func researcher() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("researcher", title: "When did the Howrah jute mill open?", docs: [
                ("letter-ashton-1860.txt", "Letter from William Ashton to his brother, written in Calcutta on 3 May 1860.\nAshton wrote that the Howrah jute mill opened in 1857 and employed 400 hands."),
                ("bengal-gazette-1859.txt", "Bengal Gazette, 14 November 1859.\nThe Howrah jute mill opened this week; it employs 300 workers."),
                ("company-history-1910.txt", "A history of the Howrah Jute Company, published 1910.\nThe company history says the Howrah jute mill opened in 1859."),
            ])
            let found = try await r.contradictions()
            withKnownIssue("GAP 2026-11-18: year-only dates and prose head-counts are not compared (and year-only dates are left out of res.chronology)") {
                #expect(!found.isEmpty, "the opening year (1857 vs 1859) or the workforce (400 vs 300) disagrees")
            }
            _ = try await r.job(ResearcherPersonaPackage.applicationID, "res.chronology")
            _ = try await r.job(ResearcherPersonaPackage.applicationID, "res.source-criticism")
            _ = try await r.timeline()
            _ = try await r.ask("When did the Howrah jute mill open?")
            await r.finish()
        }
    }

    // MARK: 8. Genealogist — father and son with one name

    @Test("Genealogist: are the two Ramesh Ghosh records one man or two?")
    func genealogist() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("genealogist", title: "Which Ramesh Ghosh is my great-grandfather?", docs: [
                ("census-1931.txt", "Census of 1931, Bankura district, household 44.\nRamesh Ghosh, head, age 30, born about 1901, clerk. Ramesh Ghosh, son, age 3, born about 1928."),
                ("baptism-1928.txt", "Baptism register, St Thomas Church, Bankura.\nOn 9 March 1928 Ramesh Ghosh, son of Ramesh Ghosh and Kamala Ghosh, was baptised."),
                ("marriage-1952.txt", "Marriage register, Bankura, 1952.\nRamesh Ghosh, aged 24, son of Ramesh Ghosh, married Sushila Dey on 20 February 1952."),
            ])
            let same = try await r.job(GenealogistPersonaPackage.applicationID, "gen.same-person")
            let sameText: String = Self.text(same?.content.rows).lowercased()
            #expect(!sameText.contains("same person: yes"), "one name alone never makes one person")
            _ = try await r.job(GenealogistPersonaPackage.applicationID, "gen.conflicts")
            _ = try await r.job(GenealogistPersonaPackage.applicationID, "gen.family-lines")
            // The person decides, one pair at a time: the matcher on the two records.
            let file = try #require(await r.state.caseFiles).file
            let father = try await file.addPerson(caseID: r.caseID, name: "Ramesh Ghosh", role: .other, entityID: nil, contact: nil, notes: "born about 1901 (1931 census)", actor: "Asha Investigator")
            let son = try await file.addPerson(caseID: r.caseID, name: "Ramesh Ghosh", role: .other, entityID: nil, contact: nil, notes: "born 1928 (baptism)", actor: "Asha Investigator")
            let a = try await file.assessSamePerson(caseID: r.caseID, personA: father, personB: son, actor: "Asha Investigator")
            r.log("same-person", "\(a.verdict) — \(a.reasons.map { "\($0.kind.rawValue): \($0.detail)" }.joined(separator: "; "))")
            #expect(a.verdict != .strongCandidate, "the same name is at most a weak candidate")
            await r.finish()
        }
    }

    // MARK: 9. Individual — renewals and expiry dates

    @Test("Individual: which of my documents expire, and when?")
    func individual() async throws {
        try await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            let r = try await Rig.make("individual", title: "My renewals", docs: [
                ("passport.txt", "Passport of Meera Iyer, number Z4471229, issued 15 January 2017, valid until 14 January 2027."),
                ("car-insurance.txt", "Motor policy MP-8820 for Meera Iyer's car KA05MN7788. The policy expires on 30 November 2026."),
                ("tv-warranty.txt", "Warranty card for a Sony television bought on 2 October 2024. The warranty is valid until 1 October 2026."),
            ])
            let db = try #require(await r.state.database)
            var expiries: [String] = []
            for (file, v) in r.versions {
                for f in try await TypedFieldRepository(database: db).fields(forVersion: v, type: .expiryDate) {
                    expiries.append("\(file): \(f.normalizedValue ?? f.rawValue)")
                }
            }
            r.log("expiry", expiries.sorted().joined(separator: "; "))
            #expect(expiries.count >= 3, "passport, insurance and warranty expiry dates are read: \(expiries)")
            let reminders = try await r.job(IndividualPersonaPackage.applicationID, "ind.reminders")
            _ = reminders
            _ = try await r.job(IndividualPersonaPackage.applicationID, "ind.personal-chronology")
            _ = try await r.ask("When does my car insurance expire?")
            await r.finish()
        }
    }
}

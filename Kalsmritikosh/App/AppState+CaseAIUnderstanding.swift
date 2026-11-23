//
//  AppState+CaseAIUnderstanding.swift
//  Kalsmritikosh
//
//  AI split AI-48 (owner 2026-11-23) — the case's understanding consumers read the AI's quote-checked records. The AI
//  classifies money (the app sums), names the people's roles, and decides merges the app proposes; each write carries the
//  actor "AI (found by AI, quote checked)" so the case history says who decided. Nothing here sends anything: it reads the
//  records the case picture and the questions already stored (under the case's permission).
//

import Foundation
import os

extension AppState {
    static let aiActor = "AI (\(CaseAIRecord.checkedLabel))"

    /// The case's AI records (none when the ledger is not open or the case may not be read).
    func caseAIRecords(caseID: UUID) async -> [CaseAIRecord] {
        guard let db = database else { return [] }
        do { return try await CaseAIRecordRepository(database: db).records(caseID: caseID) } catch {
            KalsmritikoshLog.app.error("AI records unreadable: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The AI's money classification applied to the case's unclassified money records (the same amount in the same document
    /// as an AI money record). Returns how many were classified. The rule word-classification only hints (AI-48).
    @discardableResult
    func applyAIMoneyClassifications(caseID: UUID) async -> Int {
        guard !CaseAIUnderstanding.rulesDecide, let files = caseFiles else { return 0 }
        let records = await caseAIRecords(caseID: caseID)
        guard records.contains(where: { $0.entityType == CaseAIRecord.moneyType }) else { return 0 }
        let ledger: CaseMoneyLedger
        do { ledger = try await files.file.moneyLedger(caseID: caseID) } catch {
            KalsmritikoshLog.app.error("AI money: ledger unreadable: \(String(describing: error), privacy: .public)")
            return 0
        }
        let open = ledger.records.filter { $0.kind == .unclassified }
        guard !open.isEmpty else { return 0 }
        var objectOf: [UUID: UUID] = [:]
        if let objects {
            let versions = Set(open.compactMap(\.sourceVersionID))
            do {
                for (object, vs) in try await objects.sourceVersionsByObject(inSourceVersionIDs: versions) { for v in vs { objectOf[v] = object } }
            } catch {
                KalsmritikoshLog.app.error("AI money: documents unreadable: \(String(describing: error), privacy: .public)")
            }
        }
        var done = 0
        for r in open {
            guard let raw = CaseAIUnderstanding.classification(amount: r.amountText, document: r.sourceVersionID.flatMap { objectOf[$0] }, in: records),
                  let kind = CaseMoneyKind(rawValue: raw), kind != .unclassified else { continue }
            do {
                try await files.file.classifyMoney(caseID: caseID, id: r.id, kind: kind, actor: Self.aiActor)
                done += 1
            } catch {
                KalsmritikoshLog.app.error("AI money: not classified: \(String(describing: error), privacy: .public)")
            }
        }
        return done
    }

    /// The AI's role kinds recorded for the case's people, added as roles to the case's person rows of the same name (or one
    /// of the AI's other spellings). A role already held is not added twice. Returns how many roles were added.
    @discardableResult
    func applyAIPeopleRoles(caseID: UUID) async -> Int {
        guard !CaseAIUnderstanding.rulesDecide, let files = caseFiles else { return 0 }
        let people = CaseAIUnderstanding.people(await caseAIRecords(caseID: caseID)).filter { !$0.roleKinds.isEmpty }
        guard !people.isEmpty else { return 0 }
        let rows: [CasePersonIdentityView]
        do { rows = try await files.file.identityViews(caseID: caseID) } catch {
            KalsmritikoshLog.app.error("AI roles: people unreadable: \(String(describing: error), privacy: .public)")
            return 0
        }
        var added = 0
        for p in people {
            let names = Set([p.key] + p.alsoWrittenAs.map { VerifiedRecordExtractor.normalized($0) })
            for row in rows where names.contains(VerifiedRecordExtractor.normalized(row.person.name)) {
                for raw in p.roleKinds {
                    guard let kind = CasePersonRoleKind(rawValue: raw) else { continue }
                    let context = (p.roles.first.map { $0 + " — " } ?? "") + CaseAIRecord.checkedLabel
                    do {
                        _ = try await files.file.addPersonRole(caseID: caseID, personID: row.person.id, role: kind, context: context, actor: Self.aiActor)
                        added += 1
                    } catch {
                        KalsmritikoshLog.app.info("AI roles: role not added (\(String(describing: error), privacy: .public))")
                    }
                }
            }
        }
        return added
    }

    /// Every case's AI records the person may read (the archive-level view: the union of the case pictures).
    func archiveAIRecords() async -> [CaseAIRecord] {
        guard let db = database else { return [] }
        let repo = CaseAIRecordRepository(database: db)
        let ids: [UUID]
        do { ids = try await repo.caseIDs() } catch {
            KalsmritikoshLog.app.error("AI records: cases unreadable: \(String(describing: error), privacy: .public)")
            return []
        }
        var out: [CaseAIRecord] = []
        for id in ids {
            do { out += try await repo.records(caseID: id) } catch {
                KalsmritikoshLog.app.info("AI records: a case is not readable now (\(String(describing: error), privacy: .public))")
            }
        }
        return out
    }
}

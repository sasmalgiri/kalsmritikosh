//
//  CaseTeamService.swift
//  Kalsmritikosh
//
//  The steps of team work that touch both the shared folder and the case (v198; owner decision 2026-11-18: no server,
//  no accounts): link a folder, publish a contribution request, read the folder (submissions, shared work, retries), and
//  decide a submission through the case's intake contract with a receipt back to the contributor.
//
//  Order of writes, so nothing is shown as delivered before it is (TEAM-05/07): the case records a request as pending,
//  then writes it to the folder, then marks it published — or keeps the error and tries again on the next read. A
//  submission is decided in the case first, then its receipt is written; a receipt that could not be written is retried.
//  A folder that cannot be reached is said so (last error) and changes nothing in the case (PERF-09).
//

import Foundation
import CryptoKit
import os

/// What one read of a team folder found and did.
public nonisolated struct CaseTeamReading: Sendable, Equatable {
    public var reachable = true
    public var problems: [String] = []
    public var newSubmissions = 0
    public var admittedByPolicy = 0
    public var retried = 0
    public var newRecords = 0
    public var conflicts = 0

    public var summary: String {
        guard reachable else { return "The team folder can't be reached now; nothing changed. It is read again when it is back." }
        var parts: [String] = []
        if newSubmissions > 0 { parts.append("\(newSubmissions) new submission(s)") }
        if admittedByPolicy > 0 { parts.append("\(admittedByPolicy) included under the team-submission policy") }
        if newRecords > 0 { parts.append("\(newRecords) shared work update(s)") }
        if conflicts > 0 { parts.append("\(conflicts) conflicting edit(s) to resolve") }
        if retried > 0 { parts.append("\(retried) waiting item(s) written to the folder") }
        if !problems.isEmpty { parts.append("\(problems.count) log problem(s): \(problems.joined(separator: " "))") }
        return parts.isEmpty ? "Read the team folder: nothing new." : "Read the team folder: " + parts.joined(separator: "; ") + "."
    }
}

actor CaseTeamService {
    let file: CaseFileRepository
    let intake: InvestigationWorkspaceIntake
    /// Read one file into the archive and return its source version (the app's ingest; a test's seeded passage).
    let admitFile: @Sendable (URL) async throws -> UUID

    init(file: CaseFileRepository, intake: InvestigationWorkspaceIntake, admitFile: @escaping @Sendable (URL) async throws -> UUID) {
        self.file = file; self.intake = intake; self.admitFile = admitFile
    }

    // MARK: Folder access

    /// A bookmark that reopens the folder on a later launch (security-scoped in the sandbox; plain where that is refused).
    nonisolated static func bookmark(for url: URL) -> Data? {
        if let d = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) { return d }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    nonisolated static func resolve(_ bookmark: Data?) -> (url: URL, scoped: Bool)? {
        guard let bookmark else { return nil }
        var stale = false
        if let u = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (u, u.startAccessingSecurityScopedResource())
        }
        if let u = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) { return (u, false) }
        return nil
    }

    private func link(_ caseID: UUID, _ linkID: UUID) async throws -> CaseTeamLink {
        guard let l = try await file.teamLinks(caseID: caseID).first(where: { $0.id == linkID }) else { throw CaseTeamError.notLinked }
        return l
    }

    /// The folder of a link, checked against this Mac's key (RECOVERY-08: a restored ledger cannot write as the old member).
    private func open(_ l: CaseTeamLink, key: Curve25519.Signing.PrivateKey) throws -> (folder: TeamCase, release: @Sendable () -> Void) {
        guard TeamIdentity.memberID(key.publicKey) == l.memberID else { throw CaseTeamError.otherInstallation }
        guard let (url, scoped) = Self.resolve(l.bookmark) else { throw TeamFolderError.unreachable("its location could not be found") }
        let release: @Sendable () -> Void = { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let folder = TeamCase.open(url), folder.reachable() else { release(); throw TeamFolderError.unreachable("it is not available now") }
        return (folder, release)
    }

    // MARK: Link

    /// Link the case to a team folder: create one (with its purpose) or join an existing one, as this Mac's member.
    @discardableResult
    func linkFolder(caseID: UUID, folder url: URL, create: Bool, name: String, purpose: TeamFolderPurpose,
                           displayName: String, key: Curve25519.Signing.PrivateKey, actor: String, at date: Date = Date()) async throws -> UUID {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let folder: TeamCase
        if create {
            folder = try TeamCase.create(at: url, name: name, purpose: purpose)
        } else {
            guard let f = TeamCase.open(url) else { throw TeamFolderError.notATeamFolder }
            folder = f
        }
        let teamID = try folder.ensureTeamCaseID()
        let member = try folder.join(displayName: displayName, key: key)
        return try await file.linkTeamFolder(caseID: caseID, teamCaseID: teamID, purpose: folder.purpose.rawValue,
                                             folderLabel: url.lastPathComponent, bookmark: Self.bookmark(for: url),
                                             memberID: member, displayName: displayName, actor: actor, at: date)
    }

    // MARK: Requests (TEAM-02)

    /// Publish a contribution request: recorded in the case as pending, then written to the folder (inputs first).
    @discardableResult
    func publishRequest(caseID: UUID, linkID: UUID, title: String, deliverable: String, recipient: String, due: String?,
                               inputs: [URL], workRef: String?, key: Curve25519.Signing.PrivateKey, actor: String,
                               at date: Date = Date()) async throws -> CaseTeamRequest {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let l = try await link(caseID, linkID)
        guard TeamIdentity.memberID(key.publicKey) == l.memberID else { throw CaseTeamError.otherInstallation }
        // The inputs as they are now: names, digests and sizes (the folder copy is checked against them).
        var refs: [TeamFileRef] = []
        for u in inputs {
            guard let data = try? Data(contentsOf: u) else { throw TeamFolderError.missingInput(name: u.lastPathComponent) }
            refs.append(TeamFileRef(name: u.lastPathComponent, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: data.count))
        }
        let inputsJSON = String(decoding: try JSONEncoder().encode(refs), as: UTF8.self)
        let id = try await file.createTeamRequest(caseID: caseID, linkID: linkID, title: title, deliverable: deliverable, recipient: recipient,
                                                  due: due, inputsJSON: inputsJSON, workRef: workRef, actor: actor, at: date)
        try await writeRequest(caseID: caseID, l: l, requestID: id, inputs: inputs, key: key, at: date)
        guard let r = try await file.teamRequests(caseID: caseID).first(where: { $0.id == id }) else { throw CaseTeamError.notLinked }
        return r
    }

    private func writeRequest(caseID: UUID, l: CaseTeamLink, requestID: UUID, inputs: [URL]?, key: Curve25519.Signing.PrivateKey, at date: Date) async throws {
        guard let r = try await file.teamRequests(caseID: caseID).first(where: { $0.id == requestID }) else { return }
        do {
            let (folder, release) = try open(l, key: key)
            defer { release() }
            let refs = (try? JSONDecoder().decode([TeamFileRef].self, from: Data(r.inputsJSON.utf8))) ?? []
            let recipientName = r.recipient == "anyone" ? "Any member" : (folder.members().first { $0.id == r.recipient }?.name ?? r.recipient)
            let spec = TeamRequestSpec(id: r.id.uuidString, title: r.title, deliverable: r.deliverable, recipient: r.recipient,
                                       recipientName: recipientName, due: r.due, inputs: refs, from: l.displayName)
            // A retry has no input URLs: the inputs were copied before the announcement failed, and are checked by digest.
            if inputs == nil {
                for ref in refs where TeamCase.sha256(of: folder.inputURL(requestID: spec.id, name: ref.name)) != ref.sha256 {
                    throw TeamFolderError.missingInput(name: ref.name)
                }
            }
            _ = try folder.publishRequest(spec, inputs: inputs ?? [], member: l.memberID, key: key)
            try await file.setTeamRequestState(caseID: caseID, requestID: requestID, published: true, detail: nil, at: date)
        } catch {
            KalsmritikoshLog.app.error("Team request not written to the folder: \(error.localizedDescription, privacy: .private)")
            try await file.setTeamRequestState(caseID: caseID, requestID: requestID, published: false, detail: error.localizedDescription, at: date)
        }
    }

    func withdrawRequest(caseID: UUID, requestID: UUID, reason: String, key: Curve25519.Signing.PrivateKey, actor: String,
                                at date: Date = Date()) async throws {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        try await file.withdrawTeamRequest(caseID: caseID, requestID: requestID, reason: reason, actor: actor, at: date)
        guard let r = try await file.teamRequests(caseID: caseID).first(where: { $0.id == requestID }) else { return }
        let l = try await link(caseID, r.linkID)
        do {
            let (folder, release) = try open(l, key: key)
            defer { release() }
            try folder.withdrawRequest(id: requestID.uuidString, reason: reason, member: l.memberID, key: key)
        } catch {
            KalsmritikoshLog.app.error("Team request withdrawal not written: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: Read (TEAM-03 / TEAM-05 / TEAM-07 / PERF-09)

    /// Read the folder: write what is waiting (requests, receipts, shared work), note new submissions to this case's
    /// requests, include them under the case's team-submission policy when there is one, and take in shared work.
    func read(caseID: UUID, linkID: UUID, key: Curve25519.Signing.PrivateKey, actor: String, at date: Date = Date()) async throws -> CaseTeamReading {
        // Reading the folder records what arrived in the case (submissions, shared work): a contribution, not a plain read.
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .contribute)
        let l = try await link(caseID, linkID)
        var out = CaseTeamReading()
        let folder: TeamCase, release: @Sendable () -> Void
        do { (folder, release) = try open(l, key: key) } catch let e as CaseTeamError {
            throw e
        } catch {
            KalsmritikoshLog.app.error("Team folder unreachable: \(error.localizedDescription, privacy: .private)")
            try await file.noteTeamRead(caseID: caseID, linkID: linkID, error: error.localizedDescription, at: date)
            out.reachable = false
            return out
        }
        defer { release() }
        // Waiting requests and receipts first (queued while the folder was away).
        for r in try await file.teamRequests(caseID: caseID) where r.linkID == linkID && r.state != "published" && !r.isWithdrawn {
            try await writeRequest(caseID: caseID, l: l, requestID: r.id, inputs: nil, key: key, at: date)
            if try await file.teamRequests(caseID: caseID).first(where: { $0.id == r.id })?.state == "published" { out.retried += 1 }
        }
        for s in try await file.teamSubmissions(caseID: caseID) where s.linkID == linkID && (s.receiptState == "pending" || s.receiptState == "error") {
            if try await writeReceipt(caseID: caseID, submission: s, folder: folder, l: l, key: key) { out.retried += 1 }
        }
        out.retried += try await retryRecords(caseID: caseID, l: l, folder: folder, key: key, at: date)
        let (entries, problems) = folder.verifiedEntries()
        out.problems = problems.map(\.text)
        let mine = Set(try await file.teamRequests(caseID: caseID).filter { $0.linkID == linkID }.map { $0.id.uuidString })
        var fresh: [UUID] = []
        for s in folder.submissions(in: entries) where mine.contains(s.value.requestID) {
            guard let sid = UUID(uuidString: s.value.id), let rid = UUID(uuidString: s.value.requestID) else { continue }
            if try await file.noteTeamSubmission(caseID: caseID, linkID: linkID, submissionID: sid, requestID: rid, submitterMember: s.member,
                                                 submitterName: s.memberName, note: s.value.note, submittedAt: s.at, files: s.value.files, at: date) {
                out.newSubmissions += 1
                fresh.append(sid)
            }
        }
        // IN-05: with an active trusted-source policy for team submissions, new submissions are included under it.
        if !fresh.isEmpty, let policy = try await intake.ledger.activeArrivalPolicies().first(where: { $0.caseID == caseID && $0.channel == .teamSubmission }) {
            for sid in fresh {
                do {
                    _ = try await decide(caseID: caseID, submissionID: sid, include: true, note: nil, byPolicy: true, key: key, actor: policy.createdBy, at: date)
                    out.admittedByPolicy += 1
                } catch {
                    KalsmritikoshLog.app.error("Team submission not included under the policy: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let applied = try await takeInRecords(caseID: caseID, l: l, folder: folder, entries: entries, at: date)
        out.newRecords = applied.records; out.conflicts = applied.conflicts
        try await file.noteTeamRead(caseID: caseID, linkID: linkID, error: nil, at: date)
        return out
    }

    // MARK: Decide a submission (TEAM-03 / IN-01 / TEAM-07)

    /// Include (or decline, with a reason) a submission. Each file is checked against what was announced, a file the case
    /// already received is a duplicate (not read twice), the rest are read into the archive and taken in through the
    /// intake contract. The decision is recorded once; then the receipt goes back to the folder.
    @discardableResult
    func decide(caseID: UUID, submissionID: UUID, include: Bool, note: String?, byPolicy: Bool = false,
                       key: Curve25519.Signing.PrivateKey, actor: String, at date: Date = Date()) async throws -> CaseTeamSubmission {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        guard let s = try await file.teamSubmissions(caseID: caseID).first(where: { $0.id == submissionID }) else { throw CaseTeamError.unknownSubmission }
        guard s.decidedAt == nil else { throw CaseTeamError.alreadyDecided }
        if try await file.isClosed(caseID: caseID) { throw CaseFileError.caseClosed }
        let l = try await link(caseID, s.linkID)
        let (folder, release) = try open(l, key: key)
        defer { release() }
        let request = try await file.teamRequests(caseID: caseID).first { $0.id == s.requestID }
        let reason = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !include && reason.isEmpty { throw CaseTeamError.blank("The reason for declining") }
        var received = 0, duplicates = 0, failed = 0
        for f in s.files where f.status == "waiting" || f.status == "failed" {
            if !include {
                try await file.setTeamFileOutcome(caseID: caseID, submissionID: s.id, sha256: f.sha256, status: "declined", sourceVersionID: nil, duplicateOf: nil, detail: reason)
                continue
            }
            let url = folder.submissionURL(submissionID: s.id.uuidString, name: f.name)
            guard TeamCase.sha256(of: url) == f.sha256 else {
                failed += 1
                try await file.setTeamFileOutcome(caseID: caseID, submissionID: s.id, sha256: f.sha256, status: "failed", sourceVersionID: nil, duplicateOf: nil,
                                                  detail: "The file in the folder is missing or not what was submitted")
                continue
            }
            if let earlier = try await file.teamFileAlreadyReceived(caseID: caseID, sha256: f.sha256, except: s.id) {
                duplicates += 1
                try await file.setTeamFileOutcome(caseID: caseID, submissionID: s.id, sha256: f.sha256, status: "duplicate", sourceVersionID: earlier.version,
                                                  duplicateOf: earlier.submission.uuidString, detail: nil)
                continue
            }
            do {
                let version = try await admitFile(url)
                let provenance = "Submitted by \(s.submitterName) through the team folder “\(l.folderLabel)”" + (request.map { " for “\($0.title)”" } ?? "")
                let admission = try await intake.admitTeamSubmission(caseID: caseID, version: version, label: f.name, provenance: provenance,
                                                                     suppliedBy: s.submitterName, receivedAt: s.seenAt, include: true, byPolicy: byPolicy,
                                                                     note: nil, actor: actor, at: date)
                if admission == .waiting { throw CaseTeamError.blank("A team-submission policy") }
                received += 1
                try await file.setTeamFileOutcome(caseID: caseID, submissionID: s.id, sha256: f.sha256, status: "received", sourceVersionID: version, duplicateOf: nil, detail: nil)
            } catch {
                failed += 1
                KalsmritikoshLog.app.error("Team submission file not taken in: \(error.localizedDescription, privacy: .public)")
                try await file.setTeamFileOutcome(caseID: caseID, submissionID: s.id, sha256: f.sha256, status: "failed", sourceVersionID: nil, duplicateOf: nil,
                                                  detail: error.localizedDescription)
            }
        }
        let outcome: String
        if !include { outcome = "declined" }
        else if received == 0 && failed == 0 && duplicates > 0 { outcome = "duplicate" }
        else if failed > 0 { outcome = "partial" }
        else { outcome = "received" }
        try await file.decideTeamSubmission(caseID: caseID, submissionID: s.id, outcome: outcome, actor: actor, at: date)
        guard let decided = try await file.teamSubmissions(caseID: caseID).first(where: { $0.id == s.id }) else { throw CaseTeamError.unknownSubmission }
        _ = try await writeReceipt(caseID: caseID, submission: decided, folder: folder, l: l, key: key)
        return try await file.teamSubmissions(caseID: caseID).first { $0.id == s.id } ?? decided
    }

    /// Write a decided submission's receipt to the folder; record whether it got there.
    private func writeReceipt(caseID: UUID, submission s: CaseTeamSubmission, folder: TeamCase, l: CaseTeamLink, key: Curve25519.Signing.PrivateKey) async throws -> Bool {
        let lines = s.files.map { TeamReceiptLine(sha256: $0.sha256, status: $0.status, detail: $0.detail) }
        let receipt = TeamReceipt(submissionID: s.id.uuidString, requestID: s.requestID.uuidString, outcome: s.outcome, lines: lines, note: nil)
        do {
            try folder.writeReceipt(receipt, member: l.memberID, key: key)
            try await file.setTeamReceiptState(caseID: caseID, submissionID: s.id, written: true, detail: nil)
            return true
        } catch {
            KalsmritikoshLog.app.error("Team receipt not written: \(error.localizedDescription, privacy: .private)")
            try await file.setTeamReceiptState(caseID: caseID, submissionID: s.id, written: false, detail: error.localizedDescription)
            return false
        }
    }

    // MARK: Contributor side (no case needed)

    /// What a contributor sees in a contribution folder: requests addressed to them (or to anyone), not withdrawn, with
    /// their own submissions and the receipts that came back — and nothing else.
    nonisolated struct ContributorView: Sendable {
        let requests: [TeamSigned<TeamRequestSpec>]
        let withdrawn: [String: String]
        let mySubmissions: [TeamSigned<TeamSubmissionManifest>]
        let receipts: [String: TeamReceipt]
        let incomplete: [TeamCase.IncompleteSubmission]
    }

    nonisolated static func contributorView(folder: TeamCase, member: String) -> ContributorView {
        let (entries, _) = folder.verifiedEntries()
        let withdrawn = folder.withdrawals(in: entries)
        let requests = folder.requests(in: entries).filter { ($0.value.recipient == member || $0.value.recipient == "anyone") && withdrawn[$0.value.id] == nil }
        let requestAuthors = Dictionary(folder.requests(in: entries).map { ($0.value.id, $0.member) }, uniquingKeysWith: { a, _ in a })
        let mine = folder.submissions(in: entries).filter { $0.member == member }
        let myIDs = Set(mine.map { $0.value.id })
        // A receipt counts only from the author of the request it answers.
        var receipts: [String: TeamReceipt] = [:]
        for r in folder.receipts(in: entries) where myIDs.contains(r.value.submissionID) && requestAuthors[r.value.requestID] == r.member {
            receipts[r.value.submissionID] = r.value
        }
        return ContributorView(requests: requests, withdrawn: withdrawn, mySubmissions: mine, receipts: receipts,
                               incomplete: folder.incompleteSubmissions(member: member))
    }
}

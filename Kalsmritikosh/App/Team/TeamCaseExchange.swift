//
//  TeamCaseExchange.swift
//  Kalsmritikosh
//
//  Team work over a shared folder (owner decision 2026-11-18: no server, no accounts). This file is the folder side only:
//  what is written where, signed by whom. The case side (what the ledger keeps) is CaseTeamWork.swift.
//
//  The folder is a TeamCase (signed, hash-chained log per member). On top of it:
//
//    <folder>/case.json                              name, created, teamCaseID, purpose (team | contribution)
//    <folder>/requests/<requestID>/inputs/<file>     the inputs a request shares (copied by its author)
//    <folder>/submissions/<submissionID>/<file>      what a contributor submitted
//    <folder>/submissions/<submissionID>/.incomplete written first, removed last: a copy that was cut off is visible
//
//  Log entries (TeamLogEntry.action): "request", "request.withdraw", "submission", "receipt", "record". The value is JSON.
//  A submission is announced only after every file is in place and checked, so a reader never takes a half-copied file;
//  a cut-off copy is finished by `resumeSubmission` on the contributor's Mac. Readers take entries only from logs whose
//  signatures and chain verify (up to the first bad entry) and report the rest.
//
//  Honest scope: the folder's own access (who can reach it) is the only access control; a signature proves which
//  installation wrote an entry, not which person. A contribution folder holds requests and submissions only — never the
//  case's work — so giving a contributor that folder gives them no general case access.
//

import Foundation
import CryptoKit

nonisolated enum TeamFolderPurpose: String, Codable, Sendable {
    /// Case members exchanging work (assignments, action reviews), and requests among them.
    case team
    /// Requests to outside contributors and what they submit — nothing else of the case.
    case contribution
}

/// A file named in a request or a submission: its name, SHA-256 and size.
nonisolated struct TeamFileRef: Codable, Sendable, Hashable {
    let name: String
    let sha256: String
    let bytes: Int
}

/// A scoped contribution request (TEAM-02): what is wanted, what is shared for it, from whom, by when.
nonisolated struct TeamRequestSpec: Codable, Sendable, Hashable {
    let id: String
    let title: String
    let deliverable: String
    /// A member id, or "anyone" (any member of the folder may answer).
    let recipient: String
    let recipientName: String
    let due: String?
    let inputs: [TeamFileRef]
    let from: String
}

nonisolated struct TeamSubmissionManifest: Codable, Sendable, Hashable {
    let id: String
    let requestID: String
    let files: [TeamFileRef]
    let note: String?
}

nonisolated struct TeamReceiptLine: Codable, Sendable, Hashable {
    let sha256: String
    /// received | duplicate | failed | declined
    let status: String
    let detail: String?
}

/// What the requester's case made of a submission, written back to the folder for the contributor (TEAM-03).
nonisolated struct TeamReceipt: Codable, Sendable, Hashable {
    let submissionID: String
    let requestID: String
    /// received | partial | duplicate | declined
    let outcome: String
    let lines: [TeamReceiptLine]
    let note: String?
}

/// A piece of shared work state (TEAM-05): its kind, stable id, revision and the revision it was made from.
nonisolated struct TeamWorkRecord: Codable, Sendable, Hashable {
    let kind: String
    let id: String
    let label: String
    let revision: Int
    let base: Int
    let payload: [String: String]
}

/// One verified log entry with its author's registered name.
nonisolated struct TeamSigned<Value: Sendable>: Sendable {
    let value: Value
    let member: String
    let memberName: String
    let at: String
}

nonisolated enum TeamFolderError: Error, LocalizedError, Equatable {
    case unreachable(String)
    case notATeamFolder
    case fileChanged(name: String)
    case missingInput(name: String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let why): return "The team folder can't be reached: \(why)"
        case .notATeamFolder: return "This folder is not a team folder."
        case .fileChanged(let name): return "“\(name)” changed while it was being copied; nothing was announced."
        case .missingInput(let name): return "“\(name)” is not available to copy."
        }
    }
}

nonisolated extension TeamCase {

    var requestsDir: URL { root.appendingPathComponent("requests", isDirectory: true) }
    var submissionsDir: URL { root.appendingPathComponent("submissions", isDirectory: true) }

    private var meta: [String: String] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("case.json")))) as? [String: String]) ?? [:]
    }
    /// The folder's stable id (folders made before v198 have none; they are given one when a case links them).
    var teamCaseID: String? { meta["teamCaseID"] }
    var purpose: TeamFolderPurpose { meta["purpose"].flatMap(TeamFolderPurpose.init(rawValue:)) ?? .team }

    /// Create a team folder with a stable id and a purpose.
    static func create(at root: URL, name: String, purpose: TeamFolderPurpose) throws -> TeamCase {
        let c = TeamCase(root: root)
        for d in [c.membersDir, c.logDir, c.leaseDir, c.requestsDir, c.submissionsDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let meta = ["name": name, "created": ISO8601DateFormatter().string(from: Date()),
                    "teamCaseID": UUID().uuidString, "purpose": purpose.rawValue]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]).write(to: root.appendingPathComponent("case.json"), options: .withoutOverwriting)
        return c
    }

    /// Give an older folder (no id) its id, once. Returns the id.
    func ensureTeamCaseID() throws -> String {
        if let id = teamCaseID { return id }
        var m = meta
        let id = UUID().uuidString
        m["teamCaseID"] = id
        if m["purpose"] == nil { m["purpose"] = TeamFolderPurpose.team.rawValue }
        try JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]).write(to: root.appendingPathComponent("case.json"), options: .atomic)
        for d in [requestsDir, submissionsDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return id
    }

    /// Whether the folder can be read now (a share that went away, a disk that was ejected).
    func reachable() -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: logDir.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Verified reading

    /// Every entry of every log that verifies, up to the first bad entry of a log, with the problems found.
    func verifiedEntries() -> (entries: [(entry: TeamLogEntry, name: String)], problems: [TeamVerifyFinding]) {
        let members = Dictionary(members().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [(TeamLogEntry, String)] = []
        var problems: [TeamVerifyFinding] = []
        let logs = ((try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for log in logs {
            let id = log.deletingPathExtension().lastPathComponent
            guard let m = members[id], let raw = Data(base64Encoded: m.publicKey),
                  let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
                problems.append(.unknownMember(file: log.lastPathComponent)); continue
            }
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: true)
            var prev = "", expectedSeq = 1
            for (i, line) in lines.enumerated() {
                guard let e = try? JSONDecoder().decode(TeamLogEntry.self, from: Data(line.utf8)) else {
                    // A last line cut off while it was being written is not tampering; it is read again next time.
                    if i < lines.count - 1 { problems.append(.unreadable(member: m.name, line: i + 1)) }
                    break
                }
                guard let sig = Data(base64Encoded: e.sig), e.member == id, pub.isValidSignature(sig, for: e.canonical) else {
                    problems.append(.badSignature(member: m.name, seq: e.seq)); break
                }
                guard e.prev == prev, e.seq == expectedSeq else { problems.append(.brokenChain(member: m.name, seq: e.seq)); break }
                prev = e.hash; expectedSeq += 1
                out.append((e, m.name))
            }
        }
        return (out, problems)
    }

    private func decoded<T: Decodable>(_ type: T.Type, action: String, from entries: [(entry: TeamLogEntry, name: String)]) -> [TeamSigned<T>] where T: Sendable {
        entries.filter { $0.entry.action == action }.compactMap { e in
            guard let v = try? JSONDecoder().decode(T.self, from: Data(e.entry.value.utf8)) else { return nil }
            return TeamSigned(value: v, member: e.entry.member, memberName: e.name, at: e.entry.at)
        }
    }

    func requests(in entries: [(entry: TeamLogEntry, name: String)]) -> [TeamSigned<TeamRequestSpec>] { decoded(TeamRequestSpec.self, action: "request", from: entries) }
    func submissions(in entries: [(entry: TeamLogEntry, name: String)]) -> [TeamSigned<TeamSubmissionManifest>] { decoded(TeamSubmissionManifest.self, action: "submission", from: entries) }
    func receipts(in entries: [(entry: TeamLogEntry, name: String)]) -> [TeamSigned<TeamReceipt>] { decoded(TeamReceipt.self, action: "receipt", from: entries) }
    func records(in entries: [(entry: TeamLogEntry, name: String)]) -> [TeamSigned<TeamWorkRecord>] { decoded(TeamWorkRecord.self, action: "record", from: entries) }
    /// Withdrawn request ids with the reason, from their own author only.
    func withdrawals(in entries: [(entry: TeamLogEntry, name: String)]) -> [String: String] {
        let authors = Dictionary(requests(in: entries).map { ($0.value.id, $0.member) }, uniquingKeysWith: { a, _ in a })
        var out: [String: String] = [:]
        for e in entries where e.entry.action == "request.withdraw" && authors[e.entry.objectRef] == e.entry.member {
            out[e.entry.objectRef] = e.entry.value
        }
        return out
    }

    /// Whether `member` has already announced an entry for `objectRef` with `action` (makes publishing idempotent).
    func hasEntry(member: String, action: String, objectRef: String) -> Bool {
        entries(of: member).contains { $0.action == action && $0.objectRef == objectRef }
    }

    // MARK: Writing

    private func signedAppend(action: String, objectRef: String, objectName: String, value: some Encodable,
                              member: String, key: Curve25519.Signing.PrivateKey) throws {
        guard reachable() else { throw TeamFolderError.unreachable("its log folder is missing") }
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        _ = try append([(action, objectRef, objectName, json)], member: member, key: key)
    }

    /// Copy `source` to `dir/name` through a temporary name, then check it arrived intact. Returns its reference.
    static func copyChecked(_ source: URL, into dir: URL, name: String) throws -> TeamFileRef {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: source) else { throw TeamFolderError.missingInput(name: name) }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = dir.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: target), existing == data { return TeamFileRef(name: name, sha256: sha, bytes: data.count) }
        let part = dir.appendingPathComponent(".\(name).part")
        try? fm.removeItem(at: part)
        try data.write(to: part)
        guard let back = try? Data(contentsOf: part), SHA256.hash(data: back).map({ String(format: "%02x", $0) }).joined() == sha else {
            try? fm.removeItem(at: part)
            throw TeamFolderError.fileChanged(name: name)
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: part, to: target)
        return TeamFileRef(name: name, sha256: sha, bytes: data.count)
    }

    /// The SHA-256 of a file in the folder now (nil if it cannot be read).
    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Publish a request: inputs copied and checked first, then the signed announcement. Idempotent per request id.
    func publishRequest(_ spec: TeamRequestSpec, inputs: [URL], member: String, key: Curve25519.Signing.PrivateKey) throws -> TeamRequestSpec {
        if hasEntry(member: member, action: "request", objectRef: spec.id) { return spec }
        let dir = requestsDir.appendingPathComponent(spec.id, isDirectory: true).appendingPathComponent("inputs", isDirectory: true)
        var refs: [TeamFileRef] = []
        for url in inputs { refs.append(try Self.copyChecked(url, into: dir, name: url.lastPathComponent)) }
        let published = TeamRequestSpec(id: spec.id, title: spec.title, deliverable: spec.deliverable, recipient: spec.recipient,
                                        recipientName: spec.recipientName, due: spec.due, inputs: refs.isEmpty ? spec.inputs : refs, from: spec.from)
        try signedAppend(action: "request", objectRef: spec.id, objectName: spec.title, value: published, member: member, key: key)
        return published
    }

    func withdrawRequest(id: String, reason: String, member: String, key: Curve25519.Signing.PrivateKey) throws {
        if hasEntry(member: member, action: "request.withdraw", objectRef: id) { return }
        guard reachable() else { throw TeamFolderError.unreachable("its log folder is missing") }
        _ = try append([("request.withdraw", id, "withdrawn", reason)], member: member, key: key)
    }

    func inputURL(requestID: String, name: String) -> URL {
        requestsDir.appendingPathComponent(requestID, isDirectory: true).appendingPathComponent("inputs", isDirectory: true).appendingPathComponent(name)
    }

    func submissionURL(submissionID: String, name: String) -> URL {
        submissionsDir.appendingPathComponent(submissionID, isDirectory: true).appendingPathComponent(name)
    }

    /// The marker of a submission whose copy has not finished: who, for which request, which files from where.
    nonisolated struct IncompleteSubmission: Codable, Sendable, Hashable {
        let id: String
        let requestID: String
        let member: String
        let note: String?
        let sources: [String]
    }

    /// Submit files for a request: marker first, each file copied and checked, marker removed, then the signed
    /// announcement. A copy cut off part-way leaves the marker; `resumeSubmission` finishes it. Idempotent per id.
    func submit(id: String = UUID().uuidString, requestID: String, files: [URL], note: String?,
                member: String, key: Curve25519.Signing.PrivateKey) throws -> TeamSubmissionManifest {
        let dir = submissionsDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = IncompleteSubmission(id: id, requestID: requestID, member: member, note: note, sources: files.map(\.path))
        try JSONEncoder().encode(marker).write(to: dir.appendingPathComponent(".incomplete"), options: .atomic)
        return try finish(marker, member: member, key: key)
    }

    /// Submissions this member started whose copy did not finish (TEAM-07).
    func incompleteSubmissions(member: String) -> [IncompleteSubmission] {
        ((try? FileManager.default.contentsOfDirectory(at: submissionsDir, includingPropertiesForKeys: nil)) ?? []).compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(".incomplete")),
                  let m = try? JSONDecoder().decode(IncompleteSubmission.self, from: data), m.member == member else { return nil }
            return m
        }
    }

    /// Finish a cut-off submission: files already in place and intact are kept, the rest copied again.
    func resumeSubmission(_ marker: IncompleteSubmission, key: Curve25519.Signing.PrivateKey) throws -> TeamSubmissionManifest {
        try finish(marker, member: marker.member, key: key)
    }

    private func finish(_ marker: IncompleteSubmission, member: String, key: Curve25519.Signing.PrivateKey) throws -> TeamSubmissionManifest {
        let dir = submissionsDir.appendingPathComponent(marker.id, isDirectory: true)
        var refs: [TeamFileRef] = []
        for path in marker.sources {
            let url = URL(fileURLWithPath: path)
            refs.append(try Self.copyChecked(url, into: dir, name: url.lastPathComponent))
        }
        let manifest = TeamSubmissionManifest(id: marker.id, requestID: marker.requestID, files: refs, note: marker.note)
        if !hasEntry(member: member, action: "submission", objectRef: marker.id) {
            try signedAppend(action: "submission", objectRef: marker.id, objectName: "\(refs.count) file(s)", value: manifest, member: member, key: key)
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(".incomplete"))
        return manifest
    }

    func writeReceipt(_ receipt: TeamReceipt, member: String, key: Curve25519.Signing.PrivateKey) throws {
        if hasEntry(member: member, action: "receipt", objectRef: receipt.submissionID) { return }
        try signedAppend(action: "receipt", objectRef: receipt.submissionID, objectName: receipt.outcome, value: receipt, member: member, key: key)
    }

    func publishRecord(_ record: TeamWorkRecord, member: String, key: Curve25519.Signing.PrivateKey) throws {
        let ref = "\(record.kind):\(record.id):\(record.revision)"
        if hasEntry(member: member, action: "record", objectRef: ref) { return }
        try signedAppend(action: "record", objectRef: ref, objectName: record.label, value: record, member: member, key: key)
    }
}

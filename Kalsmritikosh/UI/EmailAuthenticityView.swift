//
//  EmailAuthenticityView.swift
//  Kalsmritikosh
//
//  W2-2 — what an email says about its own history, decoded offline from the
//  original message bytes (DKIM needs the exact bytes): hidden timestamps, the
//  Received trace, DKIM and ARC checked against keys the examiner pastes in (no
//  DNS lookup is ever made), the missing-signature check, removed-attachment
//  signals, and W4-3 deleted-but-still-present status. Results are shown as
//  derived signals with their source; they never change evidence status.
//

import SwiftUI
import os

struct EmailAuthenticityReport: Sendable {
    let timestamps: [ForensicTimestamp]
    let hops: [ReceivedHop]
    let dkim: DKIMResult
    let arc: DKIMVerifier.ARCResult
    let missingSignature: String?
    let tampering: [String]
    let recovery: RecoveryInfo?
}

nonisolated enum EmailAuthenticityAnalyzer {
    /// Unfolded header fields of a raw RFC 5322 message.
    static func headers(_ raw: String) -> [String: String] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let head = text.components(separatedBy: "\n\n").first ?? ""
        var out: [String: String] = [:]
        var current: String?
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = line.first, f == " " || f == "\t", let c = current {
                out[c, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                current = name
                if out[name] == nil { out[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
            }
        }
        return out
    }

    static func analyze(raw: String, keys: DKIMKeyCache, folderPath: String?) -> EmailAuthenticityReport {
        let h = headers(raw)
        let date = h["Date"].flatMap(RFC5322Date.parse)
        return EmailAuthenticityReport(
            timestamps: HiddenTimestamps.all(headers: h, rawSource: raw),
            hops: ReceivedTrace.hops(rawSource: raw),
            dkim: DKIMVerifier.verify(rawSource: raw, keys: keys),
            arc: DKIMVerifier.verifyARCChain(rawSource: raw, keys: keys),
            missingSignature: DKIMExpectations.missingSignature(headers: h, rawSource: raw, date: date),
            tampering: TamperingSignals.find(headers: h, rawSource: raw, attachmentCount: 0),
            recovery: RecoveryDetector.detect(headers: h, folderPath: folderPath))
    }
}

struct EmailAuthenticityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var emails: [(id: UUID, name: String, url: URL?)] = []
    @State private var selected: UUID?
    @State private var report: EmailAuthenticityReport?
    @State private var message: String?
    @AppStorage("kalsmritikosh.dkim.keys") private var keysText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Email authenticity").font(.title3.bold())
            Text("Decoded offline from the original message. DKIM and ARC are checked only against keys you paste below — no internet lookup is made.")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(emails, id: \.id, selection: $selected) { e in Text(e.name).font(.caption) }
                    .frame(minWidth: 220)
                    .onChange(of: selected) { _, id in Task { await analyze(id) } }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let message { Text(message).foregroundStyle(.orange).font(.callout) }
                        if let r = report { reportView(r) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .frame(minWidth: 420)
            }
            .frame(minHeight: 340)
            DisclosureGroup("DKIM keys (one per line: selector._domainkey.domain  \"v=DKIM1; k=rsa; p=…\")") {
                TextEditor(text: $keysText).font(.caption.monospaced()).frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 780, minHeight: 560)
        .task { await loadEmails() }
    }

    @ViewBuilder
    private func reportView(_ r: EmailAuthenticityReport) -> some View {
        if let rec = r.recovery {
            Label("\(rec.label) — \(rec.evidence)", systemImage: "trash").foregroundStyle(.orange)
        }
        Group {
            Text("DKIM").font(.headline)
            Text(describe(r.dkim)).font(.callout)
            Text("ARC chain").font(.headline)
            Text(describe(r.arc)).font(.callout)
            if let m = r.missingSignature { Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        if !r.tampering.isEmpty {
            Text("Signs of change").font(.headline)
            ForEach(r.tampering, id: \.self) { Text("• \($0)").font(.caption) }
        }
        Text("Timeline hidden in the message").font(.headline)
        ForEach(Array(r.timestamps.enumerated()), id: \.offset) { _, t in
            Text("\(t.date.formatted(date: .abbreviated, time: .standard)) — \(t.source)").font(.caption)
        }
        Text("Received hops").font(.headline)
        ForEach(Array(r.hops.enumerated()), id: \.offset) { _, h in
            Text("\(h.index). \(h.from) → \(h.by)\(h.date.map { " · " + $0.formatted(date: .abbreviated, time: .standard) } ?? "")\(h.delay.map { $0 < 0 ? " · clock went backwards" : "" } ?? "")")
                .font(.caption2)
        }
    }

    private func describe(_ d: DKIMResult) -> String {
        switch d {
        case .pass(let domain, let sel): return "Verified for \(domain) (selector \(sel)) with the key you supplied."
        case .fail(let why): return "Failed: \(why)"
        case .noKey(let domain, let sel): return "Signed by \(domain) (selector \(sel)); paste its key to verify."
        case .noSignature: return "No DKIM signature in this message."
        case .unsupported(let why): return "Cannot check: \(why)"
        }
    }

    private func describe(_ a: DKIMVerifier.ARCResult) -> String {
        switch a {
        case .none: return "No ARC headers."
        case .pass(let n): return "Chain of \(n) hop\(n == 1 ? "" : "s") verified."
        case .fail(let i, let why): return "Breaks at hop \(i): \(why)"
        case .noKey(let i, let domain, let sel): return "Hop \(i) signed by \(domain) (selector \(sel)); paste its key to verify."
        }
    }

    private func loadEmails() async {
        guard let db = appState.database else { return }
        let rows = (try? await db.query("""
            SELECT ko.id, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            WHERE LOWER(f.url) LIKE '%.eml' OR LOWER(f.url) LIKE '%.emlx'
            ORDER BY ko.created_at DESC LIMIT 500;
            """, [])) ?? []
        emails = rows.compactMap { r in
            guard let id = r.uuid(0) else { return nil }
            let url = r.string(1).flatMap(URL.init(string:))
            return (id, url?.lastPathComponent ?? "Email", url)
        }
        if emails.isEmpty { message = "No single-message email files (.eml, .emlx) found. Messages inside mailbox files cannot be checked here yet, because their exact original bytes are needed." }
    }

    private func analyze(_ id: UUID?) async {
        report = nil; message = nil
        guard let id, let e = emails.first(where: { $0.id == id }), let url = e.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            message = "The original file is not readable from here (moved, or its folder is no longer shared with the app)."
            return
        }
        // .emlx starts with a byte count line before the message.
        var raw = String(decoding: data, as: UTF8.self)
        if url.pathExtension.lowercased() == "emlx", let nl = raw.firstIndex(of: "\n") { raw = String(raw[raw.index(after: nl)...]) }
        report = EmailAuthenticityAnalyzer.analyze(raw: raw, keys: DKIMKeyCache.parse(keysText), folderPath: url.path)
    }
}

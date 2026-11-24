//
//  DataIntegrityChecks.swift
//  Kalsmritikosh
//
//  ALCOA ALC-12 / ALC-16 (owner 2026-11-24) — the data-integrity lines of the data health check: the clock (jumps
//  against the monotonic clock this session), the audit chain (a full verify), the evidence vault (a re-hash of a sample
//  of kept copies), custody completeness (every current document has a chain of custody) and the last practice restore.
//  Each check says what it found; a check that could not run says so and counts as an issue (never a silent pass).
//

import Foundation
import os

public nonisolated enum DataIntegrityChecks {

    public struct Line: Sendable, Equatable {
        public let title: String
        public let text: String
        /// True when the line is a problem (or a check that could not run).
        public let issue: Bool
    }

    /// Every integrity line for the open ledger.
    @MainActor
    public static func run(_ state: AppState) async -> [Line] {
        var out: [Line] = []
        if let clock = state.clockMonitor {
            let line = await clock.healthLine()
            out.append(Line(title: "Clock", text: line, issue: await !clock.jumps.isEmpty))
        } else {
            out.append(Line(title: "Clock", text: "Clock: not checked — the clock check did not start with this ledger.", issue: true))
        }
        out.append(await chainLine(state))
        if let db = state.database {
            out.append(await vaultLine(db, vault: state.evidenceVault))
            out.append(await custodyLine(db))
            out.append(practiceLine(PracticeRestore.last(besideLedgerAt: db.url)))
        } else {
            out.append(Line(title: "Ledger", text: "not open — the vault, custody and backup checks did not run.", issue: true))
        }
        return out
    }

    @MainActor
    static func chainLine(_ state: AppState) async -> Line {
        guard let chain = state.auditChain else {
            return Line(title: "Audit chain", text: "not checked — no audit chain is wired for this ledger.", issue: true)
        }
        do {
            let v = try await chain.verify()
            return Line(title: "Audit chain", text: v.statusLine, issue: !v.isIntact)
        } catch {
            KalsmritikoshLog.app.error("Health check: chain verify failed: \(error.localizedDescription, privacy: .private)")
            return Line(title: "Audit chain", text: "the check could not run (\(error.localizedDescription)).", issue: true)
        }
    }

    /// How many kept copies a health check re-hashes.
    public static let vaultSampleSize = 12

    /// Re-hash a random sample of the vault's kept copies (in memory; nothing is opened on disk).
    static func vaultLine(_ db: Database, vault: EvidenceVault?) async -> Line {
        guard let vault else { return Line(title: "Evidence vault", text: "not checked — the vault is not open.", issue: true) }
        let addresses: [String]
        do {
            addresses = try await db.query("""
                SELECT DISTINCT lower(coalesce(nullif(vault_address, ''), content_hash)) FROM source_versions
                WHERE custody_mode = 'managed' ORDER BY random() LIMIT ?;
                """, [.integer(Int64(vaultSampleSize))]).compactMap { $0.string(0) }
        } catch {
            KalsmritikoshLog.app.error("Health check: vault sample not read: \(error.localizedDescription, privacy: .private)")
            return Line(title: "Evidence vault", text: "the check could not run (\(error.localizedDescription)).", issue: true)
        }
        guard !addresses.isEmpty else { return Line(title: "Evidence vault", text: "no kept copies to re-hash.", issue: false) }
        var verified = 0, altered = 0, unreadable = 0
        for a in addresses {
            switch await vault.checkedData(for: a).check {
            case .verified: verified += 1
            case .mismatch: altered += 1
            case .notVaulted, .notOpenable: unreadable += 1
            }
        }
        let text = "re-hashed \(addresses.count) kept cop\(addresses.count == 1 ? "y" : "ies") at random: \(verified) match their SHA-256"
            + (altered > 0 ? ", \(altered) DO NOT MATCH (altered or damaged)" : "") + (unreadable > 0 ? ", \(unreadable) missing or could not be opened" : "") + "."
        return Line(title: "Evidence vault", text: text, issue: altered > 0 || unreadable > 0)
    }

    /// Every current document version has a chain of custody (at least one custody event for its document).
    static func custodyLine(_ db: Database) async -> Line {
        do {
            let rows = try await db.query("""
                SELECT COUNT(*),
                       SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM custody_events c WHERE c.file_id IN (v.logical_source_id, upper(v.logical_source_id))) THEN 1 ELSE 0 END),
                       SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM custody_events c WHERE c.file_id IN (v.logical_source_id, upper(v.logical_source_id))
                                                  AND c.kind = 'acquired') THEN 1 ELSE 0 END)
                FROM source_versions v WHERE v.is_current = 1;
                """, [])
            let total = Int(rows.first?.int(0) ?? 0), none = Int(rows.first?.int(1) ?? 0), noAcquired = Int(rows.first?.int(2) ?? 0)
            guard total > 0 else { return Line(title: "Custody", text: "no documents yet.", issue: false) }
            if none > 0 {
                return Line(title: "Custody", text: "\(none) of \(total) current document version(s) have NO custody record.", issue: true)
            }
            let extra = noAcquired > 0 ? " (\(noAcquired) recorded before acquisition events were written)" : ""
            return Line(title: "Custody", text: "every one of \(total) current document version(s) has a chain of custody\(extra).", issue: false)
        } catch {
            KalsmritikoshLog.app.error("Health check: custody completeness not read: \(error.localizedDescription, privacy: .private)")
            return Line(title: "Custody", text: "the check could not run (\(error.localizedDescription)).", issue: true)
        }
    }

    /// The last practice restore: none, failed, or older than the schedule (plus a week) is an issue.
    static func practiceLine(_ last: PracticeRestore.Result?, now: Date = Date()) -> Line {
        guard let last else { return Line(title: "Backups", text: "no practice restore has run yet (Settings ▸ Backups ▸ Practise a restore).", issue: true) }
        let stale = now.timeIntervalSince1970 - last.ranAt > PracticeRestore.interval + 7 * 86_400
        return Line(title: "Backups", text: last.line + (stale ? " This is older than the monthly schedule." : ""), issue: !last.ok || stale)
    }

    /// The report section.
    public static func section(_ lines: [Line]) -> String {
        var md = "## Data integrity (ALCOA++ checks)\n\n"
        for l in lines { md += "- **\(l.title)** — \(l.text)\(l.issue ? " ⚠︎" : "")\n" }
        return md + "\n"
    }
}

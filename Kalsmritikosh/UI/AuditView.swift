//
//  AuditView.swift
//  Kalsmritikosh
//
//  The unified audit trail — a single read-only, newest-first feed of
//  everything that has happened to the data, merged from the two append-only
//  ledgers the app already keeps:
//    • chain-of-custody (custody_events): file acquired, hash computed /
//      verified / MISMATCH, exported, disclosed — tamper is surfaced, never
//      hidden;
//    • human decisions (fact_reviews): accept / reject / correct / merge /
//      split / … — every human edit is a row here (nothing is deleted, a
//      rejection is recorded as rejected).
//
//  Both substrates are append-only, so this view can never mislead: it shows
//  exactly what was recorded, in order. Human-in-loop actions taken elsewhere
//  in the app land in fact_reviews and appear here automatically.
//

import SwiftUI

public struct AuditView: View {
    @Environment(AppState.self) private var appState

    @State private var entries: [AuditEntry] = []
    @State private var custodyCount = 0
    @State private var decisionCount = 0
    @State private var mismatchCount = 0
    @State private var loaded = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summary
                if mismatchCount > 0 { tamperBanner }
                if entries.isEmpty && loaded {
                    empty
                } else {
                    ForEach(entries) { row(for: $0) }
                }
            }
            .padding(20)
        }
        .navigationTitle("Audit")
        .task { await load() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audit trail")
                .font(Theme.display(24, .bold))
                .foregroundStyle(Theme.brandGradient())
            Text("A complete, append-only record of what happened to your data — every file acquisition and integrity check, and every human decision. Nothing here is editable or deletable; it is the receipt for the ledger.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .cardSurface(cornerRadius: 16, tint: Theme.brand)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            stat("Custody events", custodyCount, "shield.lefthalf.filled", .blue)
            stat("Human decisions", decisionCount, "person.crop.circle.badge.checkmark", Theme.brand)
            stat("Integrity alerts", mismatchCount, "exclamationmark.shield",
                 mismatchCount > 0 ? .red : .green)
        }
    }

    private func stat(_ label: String, _ value: Int, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text("\(value)").font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    private var tamperBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
            Text("\(mismatchCount) file\(mismatchCount == 1 ? "" : "s") changed on disk since first ingest. The original hash is preserved above — review before relying on the affected sources.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.red.opacity(0.3), lineWidth: 1))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No audit events yet").font(.headline)
            Text("Once you ingest files and review facts, every action is recorded here.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func row(for e: AuditEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: e.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(e.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.title).font(.callout.weight(.semibold))
                    Text("· \(e.actor)").font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text(e.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let detail = e.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    // MARK: Load

    private func load() async {
        var merged: [AuditEntry] = []
        if let custody = appState.custody {
            custodyCount = (try? await custody.count()) ?? 0
            mismatchCount = (try? await custody.mismatchCount()) ?? 0
            let events = (try? await custody.recent(limit: 400)) ?? []
            merged.append(contentsOf: events.map(AuditEntry.init(custody:)))
        }
        if let reviews = appState.factReviews {
            decisionCount = (try? await reviews.count()) ?? 0
            let rows = (try? await reviews.recent(limit: 400)) ?? []
            merged.append(contentsOf: rows.map(AuditEntry.init(review:)))
        }
        merged.sort { $0.date > $1.date }
        entries = Array(merged.prefix(500))
        loaded = true
    }
}

// MARK: - Unified entry

private struct AuditEntry: Identifiable {
    let id: UUID
    let date: Date
    let icon: String
    let tint: Color
    let title: String
    let actor: String
    let detail: String?

    init(custody e: CustodyEvent) {
        id = e.id
        date = e.at
        actor = e.actor
        title = e.kind.displayName
        detail = e.detail
        switch e.kind {
        case .acquired:     icon = "tray.and.arrow.down"; tint = .blue
        case .hashComputed: icon = "number";              tint = .secondary
        case .hashVerified: icon = "checkmark.shield";    tint = .green
        case .hashMismatch: icon = "exclamationmark.shield"; tint = .red
        case .exported:     icon = "square.and.arrow.up"; tint = .orange
        case .disclosed:    icon = "person.badge.key";    tint = .purple
        }
    }

    init(review r: FactReview) {
        id = r.id
        date = r.reviewedAt
        actor = r.reviewer
        title = "Human: \(AuditEntry.label(for: r.action))"
        // Prefer the reason; otherwise show the before → after change.
        if let reason = r.reason, !reason.isEmpty {
            detail = reason
        } else if let prior = r.priorValue {
            detail = r.newValue.map { "\(prior) → \($0)" } ?? prior
        } else {
            detail = r.newValue
        }
        switch r.action {
        case .accept:               icon = "hand.thumbsup";       tint = .green
        case .reject:               icon = "hand.thumbsdown";     tint = .red
        case .correct:              icon = "pencil";              tint = .orange
        case .merge:                icon = "arrow.triangle.merge"; tint = .blue
        case .split:                icon = "arrow.triangle.branch"; tint = .blue
        case .precisionChange:      icon = "calendar.badge.clock"; tint = .orange
        case .resolveContradiction: icon = "checkmark.bubble";    tint = .green
        case .dismissGap:           icon = "xmark.bin";           tint = .secondary
        case .reopenGap:            icon = "arrow.uturn.backward"; tint = Theme.brand
        case .markAuthority:        icon = "star";                tint = .yellow
        case .reverse:              icon = "arrow.uturn.left";    tint = .secondary
        }
    }

    static func label(for action: FactReview.Action) -> String {
        switch action {
        case .accept:               return "Accepted"
        case .reject:               return "Rejected"
        case .correct:              return "Corrected"
        case .merge:                return "Merged"
        case .split:                return "Split"
        case .precisionChange:      return "Changed date precision"
        case .resolveContradiction: return "Resolved contradiction"
        case .dismissGap:           return "Dismissed gap"
        case .reopenGap:            return "Reopened gap"
        case .markAuthority:        return "Marked authoritative"
        case .reverse:              return "Undid a decision"
        }
    }
}

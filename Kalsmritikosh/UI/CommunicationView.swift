//
//  CommunicationView.swift
//  Kalsmritikosh
//
//  N-2 — who talks to whom, email volume by month, and replies whose original
//  message is not in the archive. G3 — the same question for phone extractions:
//  calls and messages per contact pair, per-party totals, monthly volume.
//

import SwiftUI
import Charts

struct CommunicationView: View {
    enum Lane: String, CaseIterable, Identifiable {
        case email = "Email", phone = "Calls & messages"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var report: CommunicationReport?
    @State private var loading = true
    @State private var lane: Lane = .email

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Who talks to whom").font(.title3.bold())
                Spacer()
                Picker("Show", selection: $lane) {
                    ForEach(Lane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .accessibilityIdentifier("communication.lane")
            }
            switch lane {
            case .email: emailBody
            case .phone: PhoneCommunicationSection()
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
        .task { report = await appState.communicationReport(); loading = false }
    }

    @ViewBuilder
    private var emailBody: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else if let r = report {
            if !r.monthly.isEmpty {
                Chart(r.monthly, id: \.month) { m in
                    BarMark(x: .value("Month", m.month), y: .value("Emails", m.count))
                }
                .frame(height: 140)
                .accessibilityLabel("Emails per month")
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Most frequent sender → recipient").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    List(r.pairs) { p in
                        HStack { Text("\(p.from) → \(p.to)").lineLimit(1); Spacer(); Text("\(p.count)").monospacedDigit() }
                            .font(.caption)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Replies whose original is missing (\(r.missingOriginals.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    List(r.missingOriginals) { m in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.document).font(.caption)
                            Text("Replies to \(m.missingID), which is not in your archive").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(minHeight: 280)
        } else {
            Text("No email participants found yet.").foregroundStyle(.secondary)
        }
    }
}

/// G3 — calls and messages from phone extractions (Cellebrite UFDR reports and
/// any chat export whose records name their parties).
struct PhoneCommunicationSection: View {
    @Environment(AppState.self) private var appState
    @State private var report: PhoneCommunicationReport?
    @State private var loading = true
    @State private var sort = [KeyPathComparator(\PhoneContactPair.contacts, order: .reverse)]
    @State private var selection: PhoneContactPair.ID?
    @State private var opened: OpenedSource?
    @State private var status: String?
    @State private var rereading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let r = report, r.totalRecords > 0 {
                Text(r.coverageLine)
                    .font(.caption)
                    .foregroundStyle(r.withoutPartyData + r.oneSided > 0 ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("communication.phone.coverage")
                if r.withoutPartyData > 0 { rereadButton }
                if !r.monthly.isEmpty { monthlyChart(r.monthly) }
                HStack(alignment: .top, spacing: 12) {
                    pairsTable(r)
                    partyTotals(r)
                }
                .frame(minHeight: 240)
            } else {
                Text("No phone calls or messages found yet. Import a Cellebrite report (.ufdr or report.xml) to see them here.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("communication.phone.empty")
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .task { await load() }
        .sheet(item: $opened) { o in
            VStack(spacing: 0) {
                EvidenceViewer(citation: o.citation)
                HStack { Spacer(); Button("Close") { opened = nil }.keyboardShortcut(.cancelAction) }.padding(10)
            }
        }
    }

    private func load() async {
        loading = true
        report = await appState.phoneCommunicationReport()
        loading = false
    }

    private var rereadButton: some View {
        Button(rereading ? "Re-reading…" : "Re-read phone reports") {
            rereading = true
            Task {
                let r = await appState.rereadPhoneReports()
                status = "Re-read \(r.reprocessed) report(s); \(r.upToDate) already up to date; \(r.failed) kept their earlier reading."
                rereading = false
                await load()
            }
        }
        .disabled(rereading)
        .help("Read imported phone and chat exports again with the current reader, so their calls and messages name both parties.")
        .accessibilityIdentifier("communication.phone.reread")
    }

    private func monthlyChart(_ months: [PhoneMonthVolume]) -> some View {
        Chart {
            ForEach(months) { m in
                BarMark(x: .value("Month", m.month), y: .value("Records", m.calls))
                    .foregroundStyle(by: .value("Kind", "Calls"))
                BarMark(x: .value("Month", m.month), y: .value("Records", m.messages))
                    .foregroundStyle(by: .value("Kind", "Messages"))
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Calls and messages per month")
        .accessibilityIdentifier("communication.phone.monthly")
    }

    private func label(_ party: String, _ r: PhoneCommunicationReport) -> String {
        r.names[party].map { "\($0) (\(party))" } ?? party
    }

    private func pairsTable(_ r: PhoneCommunicationReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contact pairs (\(r.pairs.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Table(r.pairs.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                TableColumn("Party") { p in Text(label(p.partyA, r)).lineLimit(1) }
                TableColumn("With") { p in Text(label(p.partyB, r)).lineLimit(1) }
                TableColumn("Contacts", value: \.contacts) { Text("\($0.contacts)").monospacedDigit() }.width(64)
                TableColumn("Calls", value: \.calls) { Text("\($0.calls)").monospacedDigit() }.width(48)
                TableColumn("Messages", value: \.messages) { Text("\($0.messages)").monospacedDigit() }.width(64)
                TableColumn("Call time", value: \.callSeconds) {
                    Text(PhoneCommunicationAnalysis.formatSeconds($0.callSeconds)).monospacedDigit()
                }.width(70)
                TableColumn("First – last") { p in
                    Text(span(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityIdentifier("communication.phone.pairs")
            HStack {
                Spacer()
                Button("Open source") {
                    guard let id = selection, let pair = r.pairs.first(where: { $0.id == id }) else { return }
                    Task {
                        if let citation = await appState.phoneRecordCitation(blockID: pair.sampleBlockID) {
                            opened = OpenedSource(citation: citation)
                        } else {
                            status = "The source of this record is not in the ledger's current reading."
                        }
                    }
                }
                .disabled(selection == nil)
                .help("Open a record of the selected pair in its source.")
                .accessibilityIdentifier("communication.phone.openSource")
            }
        }
    }

    private func span(_ p: PhoneContactPair) -> String {
        guard let first = p.firstContact, let last = p.lastContact else { return "undated" }
        let f = first.formatted(date: .abbreviated, time: .omitted)
        let l = last.formatted(date: .abbreviated, time: .omitted)
        return f == l ? f : "\(f) – \(l)"
    }

    private func partyTotals(_ r: PhoneCommunicationReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Per party").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            List(r.parties) { p in
                VStack(alignment: .leading, spacing: 1) {
                    Text(label(p.party, r)).font(.caption).lineLimit(1)
                    Text("\(p.calls) call(s), \(p.missedCalls) missed, \(PhoneCommunicationAnalysis.formatSeconds(p.callSeconds)) talk · \(p.messages) message(s)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("communication.phone.parties")
        }
        .frame(width: 260)
    }
}

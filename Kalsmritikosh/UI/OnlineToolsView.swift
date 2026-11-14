//
//  OnlineToolsView.swift
//  Kalsmritikosh
//
//  A8–A11 — Sources ▸ Online tools: exchange rate at a date, sanctions lists, company registry, court
//  records, web capture and recording transcription. Every result says where it came from and when;
//  a lookup is a lead to check, never a finding.
//

import SwiftUI
import UniformTypeIdentifiers

struct OnlineToolsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Tool: String, CaseIterable, Identifiable {
        case rate = "Exchange rate", sanctions = "Sanctions lists", registry = "Company registry",
             courts = "Court records", capture = "Capture a web page", transcribe = "Transcribe a recording"
        var id: String { rawValue }
    }

    @State private var tool: Tool = .rate
    @State private var busy = false
    @State private var message: String?
    // Exchange rate
    @State private var amount = ""
    @State private var from = "USD"
    @State private var to = "EUR"
    @State private var date = Date()
    @State private var conversion: OnlineLookupClient.Conversion?
    // Names
    @State private var name = ""
    @State private var sanctions: OnlineLookupClient.SanctionsResult?
    @State private var records: [RegistryLookups.Record] = []
    // Capture / transcribe
    @State private var address = ""
    @State private var pickRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Online tools", systemImage: "globe").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if ConnectivityMode.current != .online {
                Label("These tools need Online mode (Settings ▸ Modules). Nothing is sent while the app is Private.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            Picker("Tool", selection: $tool) { ForEach(Tool.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.menu).labelsHidden()
                .onChange(of: tool) { _, _ in message = nil }
            Group {
                switch tool {
                case .rate: rateTool
                case .sanctions: sanctionsTool
                case .registry, .courts: recordsTool
                case .capture: captureTool
                case .transcribe: transcribeTool
                }
            }
            .disabled(busy || ConnectivityMode.current != .online)
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            Text("Every request is shown to you before it is sent (except the public sanctions-list downloads, which carry nothing of yours) and recorded in Settings ▸ Online ▸ What was sent. Results are leads to check against the source, not findings.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 640, height: 560)
        .fileImporter(isPresented: $pickRecording, allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            run { await appState.transcribeRecording(url) }
        }
    }

    private func run(_ op: @escaping @MainActor () async -> String) {
        Task { @MainActor in busy = true; message = await op(); busy = false }
    }

    private var isoDate: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private var rateTool: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Amount", text: $amount).frame(width: 140)
                TextField("From", text: $from).frame(width: 60)
                Text("→")
                TextField("To", text: $to).frame(width: 60)
                DatePicker("on", selection: $date, in: ...Date(), displayedComponents: .date)
            }
            .textFieldStyle(.roundedBorder)
            Button("Convert at the ECB reference rate") {
                guard let value = Decimal(string: amount.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) else { message = "Enter an amount such as 1250.00."; return }
                let (f, t, d) = (from.uppercased(), to.uppercased(), isoDate)
                Task { @MainActor in
                    busy = true; defer { busy = false }
                    do { conversion = try await appState.lookupClient.convert(value, from: f, to: t, on: d); message = nil }
                    catch { conversion = nil; message = error.localizedDescription }
                }
            }
            if let c = conversion {
                Text("\(c.amount.formatted()) \(c.from) = \(c.result.formatted()) \(c.to)").font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(c.citation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("ECB reference rates are published for about 30 currencies on euro-area business days; for a weekend or holiday the last earlier rate is used and named.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var sanctionsTool: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Person or organisation name", text: $name).textFieldStyle(.roundedBorder)
                Button("Check") {
                    let n = name
                    Task { @MainActor in
                        busy = true; defer { busy = false }
                        do { sanctions = try await appState.lookupClient.checkSanctions(n); message = nil }
                        catch { sanctions = nil; message = error.localizedDescription }
                    }
                }.disabled(name.trimmingCharacters(in: .whitespaces).count < 2)
            }
            Text("The complete OFAC SDN list (with aliases) and the UN consolidated list are downloaded and searched on this Mac — the name you check is not sent anywhere.")
                .font(.caption2).foregroundStyle(.secondary)
            if let s = sanctions {
                Text(s.matches.isEmpty ? "No list entry holds every word of “\(name)”." : "\(s.matches.count) possible match(es) — a name match is not an identification; compare dates of birth, nationality and identifiers.")
                    .font(.callout.weight(.semibold))
                List(Array(s.matches.enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.entry.name + (m.exact ? "  (same words)" : "")).font(.callout)
                        Text("\(m.entry.list.displayName) · ref \(m.entry.reference) · \(m.entry.detail)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 160)
                Text(s.listDates.map { "\($0.key.displayName): \($0.value.formatted())" }.sorted().joined(separator: "\n"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var recordsTool: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(tool == .registry ? "Company name" : "Name or exact phrase", text: $name).textFieldStyle(.roundedBorder)
                Button("Search") {
                    let (n, registry) = (name, tool == .registry)
                    Task { @MainActor in
                        busy = true; defer { busy = false }
                        do {
                            records = registry ? try await appState.lookupClient.searchRegistry(n) : try await appState.lookupClient.searchCourts(n)
                            message = records.isEmpty ? "No records found for “\(n)”." : nil
                        } catch { records = []; message = error.localizedDescription }
                    }
                }.disabled(name.trimmingCharacters(in: .whitespaces).count < 2)
            }
            Text(tool == .registry
                 ? "GLEIF holds the Legal Entity Identifier records of companies worldwide. The name you search is sent to GLEIF (shown to you first)."
                 : "CourtListener searches published US court opinions. The phrase you search is sent to CourtListener (shown to you first). Not every court or docket is covered.")
                .font(.caption2).foregroundStyle(.secondary)
            List(Array(records.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.callout)
                    Text(r.detail).font(.caption).foregroundStyle(.secondary)
                    if let url = URL(string: r.link), !r.link.isEmpty { Link("Open the record", destination: url).font(.caption) }
                }
            }
            .frame(minHeight: 200)
        }
    }

    private var captureTool: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("https://…", text: $address).textFieldStyle(.roundedBorder)
                Button("Capture") { let a = address; run { await appState.captureWebPage(a) } }
                    .disabled(!address.lowercased().hasPrefix("https://"))
            }
            Text("Saves the page exactly as the site returns it, with a capture record (address, time, HTTP status, SHA-256), and adds both to the archive. Scripts and images are not run or loaded.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var transcribeTool: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Choose a recording…") { pickRecording = true }
            Text("Up to 18 MB (m4a, mp3, wav, aac, aiff, flac, ogg, mp4, mov). Sent — shown to you first — through your AI plan (AI Included or AI Pro) to Google Gemini; the transcript, with speaker labels and timecodes, is added as a marked document. Speaker labels are guesses, not identifications.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

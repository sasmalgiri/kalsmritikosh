//
//  CitationBuilderView.swift
//  Kalsmritikosh
//
//  UI for the Evidence Explained citation builder. Pick a source type, fill
//  the fields EE requires, and get all three layered citation forms, each
//  copyable. Addresses the genealogist's wish for standards-conformant,
//  layered citations without hand-formatting.
//

import SwiftUI

public struct CitationBuilderView: View {
    @Environment(AppState.self) private var appState

    @State private var template: EETemplate = .book
    @State private var values: [String: String] = [:]

    public init() {}

    private var citation: EECitation {
        EvidenceExplainedFormatter.format(template, values: values)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Picker("Source type", selection: $template) {
                    ForEach(EETemplate.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: template) { _, _ in values = [:] }

                fieldsSection

                Divider()

                layer("First (full) reference note", citation.first,
                      "The complete footnote the first time you cite this source.")
                layer("Subsequent (short) note", citation.subsequent,
                      "The abbreviated footnote for every later citation of the same source.")
                layer("Source-list entry", citation.sourceList,
                      "The bibliography form — author inverted, period-separated.")

                explainer
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .navigationTitle("Citations")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Evidence Explained citations", systemImage: "quote.bubble")
                .font(.title2.bold())
            Text("Build a standards-conformant, layered citation — full note, short note, and source-list entry — without hand-formatting. Fill only what you have; empty parts are dropped cleanly.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(template.fields) { field in
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    TextField(field.placeholder, text: binding(for: field.key))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func layer(_ title: String, _ text: String, _ note: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button {
                        #if canImport(AppKit)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        #endif
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines) == ".")
                }
                Text(text).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why layered citations").font(.subheadline.bold())
            Text("Evidence Explained's discipline is that a source is cited fully once, briefly thereafter, and listed once in the bibliography — and that the citation records not just where you found it but what it actually is (the \"citing\" line). That's what lets another researcher — or a court — evaluate and re-find your evidence.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}

#if canImport(AppKit)
import AppKit
#endif

//
//  KillerFeaturesView.swift
//  Kalsmritikosh
//
//  The six "Phase 17" features that justify the product:
//      1. Reconstruct Project
//      2. Reconstruct Relationship
//      3. Explain History
//      4. Executive Briefing
//      5. Risk Detection
//      6. Missing Information
//
//  Each is a guided prompt the MasterBrain handles like any other
//  question; the UI just shapes the question for the user.
//

import SwiftUI

public struct KillerFeaturesView: View {
    @Environment(AppState.self) private var appState
    @State private var argument: String = ""
    @State private var year: String = "\(Calendar.current.component(.year, from: .now))"
    @State private var answer: VerifiedAnswer?
    @State private var running = false

    public init() {}

    public var body: some View {
        VStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    card("Reconstruct Project", systemImage: "shippingbox") {
                        VStack(spacing: 6) {
                            TextField("Project name", text: $argument)
                                .textFieldStyle(.roundedBorder)
                            Button("Reconstruct") {
                                ask("Reconstruct Project \(argument).")
                            }.disabled(running)
                        }
                    }
                    card("Reconstruct Relationship", systemImage: "person.line.dotted.person") {
                        VStack(spacing: 6) {
                            TextField("Supplier / Person", text: $argument)
                                .textFieldStyle(.roundedBorder)
                            Button("Show Relationship") {
                                ask("Show relationship with \(argument).")
                            }.disabled(running)
                        }
                    }
                    card("Explain History", systemImage: "clock.arrow.circlepath") {
                        VStack(spacing: 6) {
                            TextField("Year", text: $year)
                                .textFieldStyle(.roundedBorder)
                            Button("Explain") {
                                ask("What happened during \(year)?")
                            }.disabled(running)
                        }
                    }
                    card("Executive Briefing", systemImage: "doc.richtext") {
                        VStack(spacing: 6) {
                            TextField("Company", text: $argument)
                                .textFieldStyle(.roundedBorder)
                            Button("Brief") {
                                ask("Summarize everything I know about \(argument).")
                            }.disabled(running)
                        }
                    }
                    card("Risk Detection", systemImage: "exclamationmark.shield") {
                        Button("Scan for Risks") {
                            ask("What risks exist?")
                        }.disabled(running)
                    }
                    card("Missing Information", systemImage: "questionmark.app") {
                        Button("Find Gaps") {
                            ask("What information is missing?")
                        }.disabled(running)
                    }
                }
                .padding()

                if running {
                    ProgressView().padding()
                }
                if let answer {
                    AnswerCard(answer: answer)
                        .padding(.horizontal)
                        .padding(.bottom)
                }
            }
        }
        .navigationTitle("Killer Features")
    }

    @ViewBuilder
    private func card<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    private func ask(_ q: String) {
        running = true
        answer = nil
        Task {
            let result = await appState.brain.answer(question: q)
            await MainActor.run {
                self.answer = result
                self.running = false
            }
        }
    }
}

private struct AnswerCard: View {
    let answer: VerifiedAnswer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: answer.refused ? "questionmark.circle" : "checkmark.seal")
                    .foregroundStyle(answer.refused ? .orange : .green)
                Text(answer.refused ? "Kalsmritikosh can't answer yet" : "Answer")
                    .font(.headline)
                Spacer()
                ConfidenceBadge(answer.confidence)
            }
            Text(answer.body).font(.body).textSelection(.enabled)
            if let reason = answer.refusalReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if !answer.citations.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(answer.citations.prefix(20), id: \.snippet) { c in
                            SourcePill("KO \(c.objectID.uuidString.prefix(6))")
                        }
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }
}

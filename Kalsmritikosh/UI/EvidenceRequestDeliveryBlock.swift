//
//  EvidenceRequestDeliveryBlock.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (ADAPT-10) — on an evidence request: whether it was actually sent. Prepare for sending (the
//  recipient and channel, once), record that you handed it over (posted, emailed it yourself, uploaded), then confirm it
//  was sent or not. A copied draft is never shown as sent; a second hand-over waits until the first is confirmed.
//

import SwiftUI
import os

struct EvidenceRequestDeliveryBlock: View {
    @Environment(AppState.self) private var appState
    let caseID: UUID
    let file: EvidenceRequestFile
    let actor: String
    let closed: Bool
    /// The request's text as the draft writes it (what is handed over).
    let text: () -> String
    @State private var effect: CaseExternalEffect?
    @State private var channel = "letter"
    @State private var reference = ""
    @State private var note = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CaseRequestDelivery.line(effect)).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("case.requests.delivery")
            HStack {
                switch effect?.state {
                case nil, .confirmedNotSent?:
                    Picker("By", selection: $channel) {
                        ForEach(["letter", "email", "portal"], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 140)
                    if effect == nil {
                        Button("Prepare for sending") { Task { await prepare() } }
                            .caseMapControlHelp("Prepare for sending")
                    } else {
                        handOver
                    }
                case .prepared?:
                    handOver
                case .handedOver?:
                    TextField("How you know (e.g. the bank acknowledged on 5 Nov)", text: $note).textFieldStyle(.roundedBorder)
                    Button("Confirm sent") { Task { await reconcile(true) } }.disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                        .caseMapControlHelp("Confirm sent")
                    Button("Confirm not sent") { Task { await reconcile(false) } }.disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                        .caseMapControlHelp("Confirm not sent")
                case .confirmedSent?:
                    EmptyView()
                }
            }
            .controlSize(.small)
            .disabled(closed)
            if let message { Text(message).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .task(id: file.request.revision) { await load() }
    }

    @ViewBuilder private var handOver: some View {
        TextField("Reference (tracking number, sent mail id)", text: $reference).textFieldStyle(.roundedBorder)
        Button("Record handed over") { Task { await markHandedOver() } }
            .caseMapControlHelp("Record handed over")
    }

    private func load() async {
        guard let auto = appState.caseAutomation else { return }
        do { effect = try await auto.requestDelivery(caseID: caseID, request: file.request) } catch {
            KalsmritikoshLog.ui.error("Request delivery read failed: \(error.localizedDescription, privacy: .public)")
            message = "Whether it was sent could not be read: \(error.localizedDescription)"
        }
    }

    private func prepare() async {
        guard let auto = appState.caseAutomation else { message = "The ledger isn't open."; return }
        do {
            effect = try await auto.prepareRequestDelivery(caseID: caseID, request: file, channel: channel, text: text(), actor: actor)
            message = nil
        } catch {
            KalsmritikoshLog.ui.error("Request delivery not prepared: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    private func markHandedOver() async {
        guard let auto = appState.caseAutomation else { return }
        do {
            // Not prepared yet: prepare it first (a confirmed-not-sent delivery is handed over again as it is).
            if effect == nil {
                effect = try await auto.prepareRequestDelivery(caseID: caseID, request: file, channel: channel, text: text(), actor: actor)
            }
            guard let e = effect else { return }
            try await auto.markHandedOver(caseID: caseID, effectID: e.id, providerRef: reference.isEmpty ? nil : reference, actor: actor)
            reference = ""
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Request hand-over not recorded: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }

    private func reconcile(_ sent: Bool) async {
        guard let auto = appState.caseAutomation, let e = effect else { return }
        do {
            try await auto.reconcileExternalEffect(caseID: caseID, effectID: e.id, sent: sent, note: note, actor: actor)
            note = ""
            await load()
        } catch {
            KalsmritikoshLog.ui.error("Request delivery not reconciled: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
    }
}

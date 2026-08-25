//
//  ComplianceBoardView.swift
//  Kalsmritikosh
//
//  The futuristic board (SOP lifecycle step 6): every tracked external SOP with
//  the edition the app implements, when it was last verified, and whether its
//  periodic re-check is due. "Mark reviewed today" records a manual
//  re-verification on-device; the whole board is copyable as a hardcopy.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct ComplianceBoardView: View {
    @Environment(AppState.self) private var appState
    /// Owner review overrides: SOP id → yyyy-mm-dd of last manual verification.
    @AppStorage("kalsmritikosh.sopboard.reviews") private var reviewBlob = ""
    @State private var showHandbook = false
    // Governed review capture (v108): the SOP being reviewed + the record fields.
    @State private var reviewTarget: SOPRecord?
    @State private var reviewerName = ""
    @State private var reviewerRole = ""
    @State private var reviewSource = ""
    @State private var reviewNotes = ""
    @State private var reviewDecision: ProtocolReviewRecord.ReviewDecision = .current
    @State private var latestReviews: [String: ProtocolReviewRecord] = [:]
    // Protocol packs (v108).
    @State private var registry: [RegisteredProtocol] = []
    @State private var showPackImporter = false
    @State private var packStatus: String?

    public init() {}

    private var overrides: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(reviewBlob.utf8))) ?? [:]
    }
    private func markReviewed(_ id: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        var o = overrides
        o[id] = f.string(from: Date())
        if let d = try? JSONEncoder().encode(o), let s = String(data: d, encoding: .utf8) { reviewBlob = s }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("SOP Compliance Board", systemImage: "checklist.checked")
                        .font(.largeTitle.weight(.bold))
                    Text("Every external SOP the app implements, at the exact edition verified — with a periodic re-check so compliance is maintained, not just achieved once. Checks are on-device reminders; re-verification is a human act against the governing body's current text.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let due = ComplianceBoard.due(now: Date(), overrides: overrides)
                if !due.isEmpty {
                    Label("\(due.count) SOP(s) due for periodic re-verification.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button { showHandbook = true } label: { Label("Read the SOP Handbook", systemImage: "book") }
                        .buttonStyle(.borderedProminent)
                        .guidance(GuidanceTip("SOP Handbook",
                                              what: "The presentable form of everything the app binds itself to: the system flow, the core SOPs, every constitution's obligations and prohibitions, and this board — generated live from the enforced rules, so it can never drift from the app."))
                    Button { copyBoard() } label: { Label("Copy board as hardcopy", systemImage: "doc.on.doc") }
                        .guidance(GuidanceTip("Copy board",
                                              what: "Copies the whole board as a markdown table — the compliance evidence you can hand to anyone."))
                }
                .sheet(isPresented: $showHandbook) { handbookSheet }
                VStack(spacing: 10) {
                    ForEach(ComplianceBoard.records) { r in row(r) }
                }
                protocolPacksSection
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Compliance Board")
        .task { await reload() }
        .sheet(item: $reviewTarget) { target in governedReviewSheet(target) }
    }

    private func reload() async {
        guard let repo = appState.protocolRegistry else { return }
        registry = (try? await repo.list()) ?? []
        var latest: [String: ProtocolReviewRecord] = [:]
        for r in ComplianceBoard.records {
            latest[r.id] = try? await repo.latestReview(subjectID: r.id)
        }
        latestReviews = latest
    }

    // MARK: - Protocol packs (v108 — signed, offline)

    private var protocolPacksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protocol packs").font(.title3.weight(.bold))
            Text("Constitutions update as SIGNED files imported locally (Files, AirDrop, USB, MDM) — the app never fetches anything. A pack activates only when its signature verifies, its hash matches, and its schema compiles. Activating supersedes the previous active version; sealed runs keep their frozen snapshot forever.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { showPackImporter = true } label: { Label("Import protocol pack…", systemImage: "square.and.arrow.down") }
                    .fileImporter(isPresented: $showPackImporter,
                                  allowedContentTypes: [.json, .data],
                                  allowsMultipleSelection: false) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            Task { await importPack(url) }
                        }
                    }
                Button { exportCurrentConstitution() } label: { Label("Export current constitution as signed pack…", systemImage: "square.and.arrow.up") }
                    .guidance(GuidanceTip("Export signed pack",
                                          what: "Signs the active investigation constitution with this installation's key and saves it as a .kalprotocol file another Mac can import offline. The signer key ID and assurance label travel with it."))
            }
            if let packStatus {
                Text(packStatus).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(registry) { p in registryRow(p) }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func registryRow(_ p: RegisteredProtocol) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(p.sutraID) v\(p.version)").font(.callout.weight(.semibold))
                Text(p.assurance).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text(p.status.rawValue).font(.caption.weight(.semibold))
                    .foregroundStyle(p.status == .active ? Color.green :
                                     p.status == .revoked ? Color.red : Color.secondary)
            }
            Text("Publisher \(p.publisher) · signer \(p.signerKeyID) · sha256 \(p.sutraSHA256.prefix(12))…")
                .font(.caption2).foregroundStyle(.tertiary)
            if let reason = p.revocationReason {
                Text("Revoked: \(reason)").font(.caption2).foregroundStyle(.red)
            }
            HStack {
                if p.status == .imported || p.status == .superseded {
                    Button("Activate") { Task { await activate(p) } }.controlSize(.small)
                }
                if p.status != .revoked {
                    Button("Revoke…") { Task { await revoke(p) } }.controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func importPack(_ url: URL) async {
        guard let repo = appState.protocolRegistry else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let (pack, sutra) = try ProtocolPacks.verify(data)
            _ = try await repo.importPack(pack, at: Date())
            packStatus = "Imported \(sutra.citation) — signature verified, schema compiles. Activate it below to govern new runs."
        } catch {
            packStatus = "Import refused: \(error)"
        }
        await reload()
    }

    private func exportCurrentConstitution() {
        let panel = NSSavePanel()
        let sutra = SutraCompiler.shared()
        panel.nameFieldStringValue = "\(sutra.id)-v\(sutra.version).\(ProtocolPacks.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ProtocolPacks.export(sutra: sutra, publisher: "Eco Sanskriti Innovation",
                                                assurance: "developer", at: Date())
            try data.write(to: url)
            packStatus = "Exported signed pack: \(url.lastPathComponent)"
        } catch {
            packStatus = "Export failed: \(error)"
        }
    }

    private func activate(_ p: RegisteredProtocol) async {
        guard let repo = appState.protocolRegistry else { return }
        do { try await repo.activate(id: p.id, at: Date()); packStatus = "\(p.id) is now the active constitution for new runs." }
        catch { packStatus = "Activation refused: \(error)" }
        await reload()
    }

    private func revoke(_ p: RegisteredProtocol) async {
        guard let repo = appState.protocolRegistry else { return }
        do { try await repo.revoke(id: p.id, reason: "Revoked by owner from the board", at: Date()) }
        catch { packStatus = "Revocation failed: \(error)" }
        await reload()
    }

    // MARK: - Governed review capture (v108)

    private func governedReviewSheet(_ target: SOPRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Governed review — \(target.title)").font(.headline)
            Text("Records WHO reviewed \(target.governingBody)'s current text against the app's \(target.editionImplemented), and what was decided. The record is signed with this installation's key; the truthful status is “reviewed as of date”, never automatically “current”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Reviewer (required)", text: $reviewerName).textFieldStyle(.roundedBorder)
            TextField("Role (e.g. owner, counsel)", text: $reviewerRole).textFieldStyle(.roundedBorder)
            TextField("Source consulted (URL or edition of the official text)", text: $reviewSource).textFieldStyle(.roundedBorder)
            Picker("Decision", selection: $reviewDecision) {
                Text("Still current — app matches").tag(ProtocolReviewRecord.ReviewDecision.current)
                Text("Update required").tag(ProtocolReviewRecord.ReviewDecision.updateRequired)
                Text("No longer applicable").tag(ProtocolReviewRecord.ReviewDecision.notApplicable)
            }
            TextField("Notes (what changed, impact)", text: $reviewNotes, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            HStack {
                Spacer()
                Button("Cancel") { reviewTarget = nil }
                Button("Record signed review") { Task { await saveReview(target) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(reviewerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18).frame(minWidth: 520)
    }

    private func saveReview(_ target: SOPRecord) async {
        guard let repo = appState.protocolRegistry else { reviewTarget = nil; return }
        let record = ProtocolReviewRecord(
            subjectID: target.id,
            reviewer: reviewerName.trimmingCharacters(in: .whitespaces),
            role: reviewerRole.isEmpty ? nil : reviewerRole,
            sourceNote: reviewSource.isEmpty ? nil : reviewSource,
            decision: reviewDecision,
            notes: reviewNotes.isEmpty ? nil : reviewNotes,
            reviewedAt: Date())
        let signed = (try? record.signed()) ?? record
        _ = try? await repo.recordReview(signed)
        // Keep the legacy date override so the due computation stays in sync.
        if reviewDecision == .current { markReviewed(target.id) }
        reviewerName = ""; reviewerRole = ""; reviewSource = ""; reviewNotes = ""
        reviewDecision = .current
        reviewTarget = nil
        await reload()
    }

    private func row(_ r: SOPRecord) -> some View {
        let verified = overrides[r.id] ?? r.verifiedOn
        let effective = SOPRecord(id: r.id, title: r.title, governingBody: r.governingBody,
                                  editionImplemented: r.editionImplemented, implementedIn: r.implementedIn,
                                  verifiedOn: verified, reviewIntervalDays: r.reviewIntervalDays)
        let isDue = effective.isDue(now: Date())
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.title).font(.headline)
                Spacer()
                Label(isDue ? "Review due" : "Current",
                      systemImage: isDue ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDue ? Color.orange : Color.green)
            }
            Text("\(r.governingBody) — \(r.editionImplemented)")
                .font(.callout).foregroundStyle(.secondary)
            Text("Enforced in: \(r.implementedIn)").font(.caption).foregroundStyle(.secondary)
            if let review = latestReviews[r.id] {
                Text("Reviewed as of \(review.reviewedAt.formatted(date: .abbreviated, time: .omitted)) by \(review.reviewer)\(review.role.map { " (\($0))" } ?? "") — \(review.decision.rawValue)\(review.signature != nil ? " · signed" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("Verified \(verified) · re-check every \(r.reviewIntervalDays) days")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Record governed review…") { reviewTarget = r }
                    .controlSize(.small)
                    .guidance(GuidanceTip("Governed review",
                                          what: "Records WHO checked the governing body's current text, against which source, and what was decided — signed with this installation's key. A bare date can't establish that anything was reviewed; this record can."))
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var handbookSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SOP Handbook").font(.headline)
                Spacer()
                Button { copyHandbook() } label: { Label("Copy", systemImage: "doc.on.doc") }.controlSize(.small)
                Button("Done") { showHandbook = false }.keyboardShortcut(.defaultAction).controlSize(.small)
            }
            .padding(14)
            Divider()
            ScrollView {
                Text(SOPHandbook.markdown(now: Date()))
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
    private func copyHandbook() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SOPHandbook.markdown(now: Date()), forType: .string)
        #endif
    }

    private func copyBoard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ComplianceBoard.markdown(now: Date(), overrides: overrides), forType: .string)
        #endif
    }
}

#if DEBUG
#Preview("Compliance Board") { ComplianceBoardView().frame(width: 1000, height: 720) }
#endif

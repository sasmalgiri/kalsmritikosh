//
//  PersonaStudiosViews.swift
//  Kalsmritikosh
//
//  Persona studios #6–#9 on the shared PersonaStudioShell:
//    Researcher  → Evidence Review Studio  (PRISMA / extraction / GRADE)
//    Genealogist → Proof Argument Studio   (GPS five elements)
//    Creator     → Publish Package Studio  (claims / rights / disclosures)
//    Individual  → Emergency Binder Studio (findability in an emergency)
//

import SwiftUI

// MARK: - Conformances

extension ResearchReview.Stage: StudioStageProtocol {}
extension ResearchReview: StudioDeliverable {}
extension ProofArgument.Stage: StudioStageProtocol {}
extension ProofArgument: StudioDeliverable {}
extension PublishPackage.Stage: StudioStageProtocol {}
extension PublishPackage: StudioDeliverable {}
extension EmergencyBinder.Stage: StudioStageProtocol {}
extension EmergencyBinder: StudioDeliverable {}
extension DisputeFile.Stage: StudioStageProtocol {}
extension DisputeFile: StudioDeliverable {}

// MARK: - #6 Researcher

public struct ResearcherStudioView: View {
    public init() {}
    public var body: some View {
        PersonaStudioShell(config: StudioConfig<ResearchReview>(
            name: "Evidence Review Studio",
            icon: "doc.text.magnifyingglass",
            blurb: "Run a review the way researchers publish them: fix the question first, screen with PRISMA counts and exclusion reasons, extract one row per included study, then state the synthesis with a GRADE certainty — conflicts shown, never averaged.",
            storeKey: "kalsmritikosh.rs.store",
            filenamePrefix: "evidence-review",
            newItem: { ResearchReview(title: "New review", now: $0) },
            sampleItem: { ResearchReview.sample(now: $0) },
            subtitle: { r in r.question.trimmed.isEmpty ? "No question yet." : r.question },
            render: { ResearchReviewRenderer.markdown($0, generatedAt: $1) }
        )) { m, s, goTo in
            switch s {
            case .protocolStage:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Protocol", "The question and criteria are fixed BEFORE screening — changing them mid-review is how bias creeps in.")
                    TextEditor(text: m.question).font(.body).frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        .disabled(m.wrappedValue.protocolFrozenAt != nil)
                    StudioField("Eligibility criteria (population, intervention, comparison, outcomes, designs)",
                                Binding(get: { m.wrappedValue.eligibilityCriteria ?? "" }, set: { m.wrappedValue.eligibilityCriteria = $0 }))
                    StudioField("Reviewer", m.reviewer)
                    if let frozen = m.wrappedValue.protocolFrozenAt {
                        Label("Protocol fixed on \(frozen.formatted(date: .abbreviated, time: .shortened)).", systemImage: "lock.fill").font(.caption)
                    } else {
                        Button("Fix the protocol before screening") { m.wrappedValue.protocolFrozenAt = Date() }
                            .disabled(m.wrappedValue.question.trimmed.isEmpty)
                    }
                    studioNext("Screening (PRISMA)") { goTo(.screening) }
                }
            case .screening:
                ResearchScreeningStage(m: m) { goTo(.extraction) }
            case .extraction:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Extraction", "One row per included STUDY (two reports of one trial are one study), each with the source its values come from. A review that includes no study needs no rows.")
                    let n = m.wrappedValue.includedStudyCount
                    if m.wrappedValue.studies.count != n {
                        Label("\(m.wrappedValue.studies.count) row(s) extracted; \(n) stud\(n == 1 ? "y" : "ies") included.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(m.studies) { $s in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("Study (author, year)", text: $s.study).textFieldStyle(.roundedBorder)
                                TextField("Design", text: $s.design).textFieldStyle(.roundedBorder).frame(width: 120)
                                TextField("Sample", text: $s.sample).textFieldStyle(.roundedBorder).frame(width: 100)
                                Button { m.wrappedValue.studies.removeAll { $0.id == s.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                TextField("Outcome measured", text: $s.outcome).textFieldStyle(.roundedBorder)
                                TextField("Result", text: $s.result).textFieldStyle(.roundedBorder)
                                TextField("Source document (required)", text: $s.source).textFieldStyle(.roundedBorder)
                            }
                            if !s.isComplete { Text("Needs the study, its result and the source document.").font(.caption2).foregroundStyle(.orange) }
                        }
                        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { m.wrappedValue.studies.append(RSStudy()) } label: { Label("Add study", systemImage: "plus") }
                    studioNext("Synthesis (GRADE)") { goTo(.synthesis) }
                }
            case .synthesis:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Synthesis & certainty", "State what the evidence shows; rate certainty for EACH outcome on the GRADE scale with the reason. Conflicting findings are presented as conflicts, and a review that found nothing says so.")
                    TextEditor(text: m.synthesis).font(.body).frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    ForEach(Binding(get: { m.wrappedValue.outcomeCertainty ?? [] }, set: { m.wrappedValue.outcomeCertainty = $0 })) { $o in
                        HStack(spacing: 8) {
                            TextField("Outcome", text: $o.outcome).textFieldStyle(.roundedBorder).frame(width: 180)
                            Picker("Certainty", selection: $o.certainty) {
                                Text("—").tag(Optional<GRADECertainty>.none)
                                ForEach(GRADECertainty.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                            }.frame(width: 170)
                            TextField("Why (risk of bias, inconsistency, imprecision…)", text: $o.reason).textFieldStyle(.roundedBorder)
                        }
                    }
                    Button { m.wrappedValue.outcomeCertainty = (m.wrappedValue.outcomeCertainty ?? []) + [RSOutcomeCertainty()] } label: { Label("Rate an outcome", systemImage: "plus") }
                    Text("PRISMA describes how a review is reported; it is not a quality score.").font(.caption2).foregroundStyle(.secondary)
                    StudioField("Limitations", m.limitations)
                    Text("Report preview").font(.callout.weight(.semibold))
                    StudioReportPreview(text: ResearchReviewRenderer.markdown(m.wrappedValue, generatedAt: Date()))
                }
            }
        }
    }

    private func countField(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 110)
        }
    }
}

/// Searches run, every record found with its screening decision, and the PRISMA flow DERIVED from
/// those decisions (final brief §3.6). A review saved before this keeps its typed counts, labelled.
struct ResearchScreeningStage: View {
    @Binding var m: ResearchReview
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioStageHeader("Screening (PRISMA)", "Record each search exactly as run, then every record found and your decision on it. The flow counts are worked out from the decisions.")
            Text("Searches").font(.headline)
            ForEach(Binding(get: { m.searches ?? [] }, set: { m.searches = $0 })) { $q in
                HStack(spacing: 6) {
                    TextField("Database", text: $q.database).textFieldStyle(.roundedBorder).frame(width: 120)
                    TextField("Full search string", text: $q.searchString).textFieldStyle(.roundedBorder)
                    TextField("yyyy-mm-dd", text: $q.date).textFieldStyle(.roundedBorder).frame(width: 110)
                    TextField("Hits", text: $q.hits).textFieldStyle(.roundedBorder).frame(width: 70)
                }
            }
            Button { m.searches = (m.searches ?? []) + [RSSearch()] } label: { Label("Add search", systemImage: "plus") }
            Text("Records and decisions").font(.headline)
            ForEach(Binding(get: { m.records ?? [] }, set: { m.records = $0 })) { $r in
                HStack(spacing: 6) {
                    TextField("Citation", text: $r.citation).textFieldStyle(.roundedBorder)
                    TextField("Study (same for two reports of one study)", text: $r.studyKey).textFieldStyle(.roundedBorder).frame(width: 200)
                    Picker("", selection: $r.decision) { ForEach(RSDecision.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(width: 210)
                    if r.decision == .excludedOnFullText || r.decision == .excludedOnTitle {
                        TextField("Reason", text: $r.reason).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                }
            }
            Button { m.records = (m.records ?? []) + [RSRecord()] } label: { Label("Add record", systemImage: "plus") }
            if m.totalsDerived {
                let f = m.flow
                Text("Identified \(f.identified) · duplicates \(f.duplicates) · screened \(f.screened) · full text assessed \(f.fullTextAssessed) · included \(f.includedReports) report(s) of \(f.includedStudies) study(ies)\(f.pending > 0 ? " · \(f.pending) not yet screened" : "")")
                    .font(.callout.weight(.semibold))
            } else {
                Text("No records recorded yet. An older review's typed counts:").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    countField("Identified", $m.identified); countField("Screened", $m.screened)
                    countField("Eligible", $m.eligible); countField("Included", $m.included)
                }
                StudioField("Exclusion reasons (with counts)", $m.exclusionReasons)
            }
            studioNext("Extraction", next)
        }
    }

    private func countField(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 110)
        }
    }
}

// MARK: - #7 Genealogist

public struct GenealogistStudioView: View {
    public init() {}
    public var body: some View {
        PersonaStudioShell(config: StudioConfig<ProofArgument>(
            name: "Proof Argument Studio",
            icon: "person.text.rectangle",
            blurb: "Answer a genealogical question to the Genealogical Proof Standard: a reasonably exhaustive search with nil results logged, complete citations, analysis and correlation, conflicts resolved with reasoning, and a written conclusion.",
            jurisdiction: JurisdictionNotice.studio(instrument: "the Genealogical Proof Standard (BCG, US)"),
            storeKey: "kalsmritikosh.gn.store",
            filenamePrefix: "proof-argument",
            newItem: { ProofArgument(title: "New proof argument", now: $0) },
            sampleItem: { ProofArgument.sample(now: $0) },
            subtitle: { p in p.question.trimmed.isEmpty ? "No question yet." : p.question },
            render: { ProofArgumentRenderer.markdown($0, generatedAt: $1) }
        )) { m, s, goTo in
            switch s {
            case .question:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("The question", "One specific, answerable question about one person, relationship, or event.")
                    TextEditor(text: m.question).font(.body).frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    StudioField("Researcher", m.researcher)
                    studioNext("Research log") { goTo(.research) }
                }
            case .research:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Research log", "Every source searched goes on the log — INCLUDING searches that found nothing. Nil results are what make the search 'reasonably exhaustive'.")
                    ForEach(m.searches) { $r in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("yyyy-mm-dd", text: $r.date).textFieldStyle(.roundedBorder).frame(width: 120)
                                TextField("Repository", text: $r.repository).textFieldStyle(.roundedBorder)
                                Button { m.wrappedValue.searches.removeAll { $0.id == r.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            TextField("Source searched", text: $r.source).textFieldStyle(.roundedBorder)
                            TextField("Result — or 'NIL result' (log it anyway)", text: $r.result).textFieldStyle(.roundedBorder)
                        }
                        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { m.wrappedValue.searches.append(GNSearch()) } label: { Label("Add search", systemImage: "plus") }
                    studioNext("Analysis & conflicts") { goTo(.analysis) }
                }
            case .analysis:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Analysis & conflict resolution", "Weigh each source (original vs derivative, primary vs secondary information), correlate them — and resolve every conflict with stated reasoning, never by ignoring it.")
                    Text("Analysis & correlation").font(.callout.weight(.semibold))
                    TextEditor(text: m.analysis).font(.body).frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    Text("Resolution of conflicting evidence").font(.callout.weight(.semibold))
                    TextEditor(text: m.conflictResolution).font(.body).frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    studioNext("Proof argument") { goTo(.proof) }
                }
            case .proof:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("The proof argument", "The written, soundly-reasoned conclusion — the fifth GPS element — plus the citation check.")
                    TextEditor(text: m.conclusion).font(.body).frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    Toggle("Citations complete — every stated fact reopens its source", isOn: m.citationsComplete)
                    if !m.wrappedValue.isComplete(.proof) {
                        Label("The argument completes with a written conclusion and the citation check.", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Report preview").font(.callout.weight(.semibold))
                    StudioReportPreview(text: ProofArgumentRenderer.markdown(m.wrappedValue, generatedAt: Date()))
                }
            }
        }
    }
}

// MARK: - #8 Content Creator

public struct CreatorStudioView: View {
    public init() {}
    public var body: some View {
        PersonaStudioShell(config: StudioConfig<PublishPackage>(
            name: "Publish Package Studio",
            icon: "shippingbox",
            blurb: "Ship a piece the professional way: every factual claim checked to a source, every third-party asset cleared, material connections disclosed, and a corrections path in place — packaged as the pre-publish checklist.",
            jurisdiction: JurisdictionNotice.studio(instrument: "the US FTC Endorsement Guides (2023)"),
            storeKey: "kalsmritikosh.cc.store",
            filenamePrefix: "publish-package",
            newItem: { PublishPackage(title: "New piece", now: $0) },
            sampleItem: { PublishPackage.sample(now: $0) },
            subtitle: { p in p.piece.trimmed.isEmpty ? "No piece described yet." : p.piece },
            render: { PublishPackageRenderer.markdown($0, generatedAt: $1) }
        )) { m, s, goTo in
            switch s {
            case .piece:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("The piece", "What is being published, where, and when.")
                    TextEditor(text: m.piece).font(.body).frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    StudioField("Creator", m.creator)
                    studioNext("Claims checked") { goTo(.claims) }
                }
            case .claims:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Claims checked", "Every factual claim in the piece, checked to a named source before publishing — not after the comments find it.")
                    ForEach(m.claims) { $c in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("The claim", text: $c.text, axis: .vertical)
                                    .textFieldStyle(.roundedBorder).lineLimit(1...2)
                                Toggle("Checked", isOn: $c.checked).toggleStyle(.checkbox)
                                Button { m.wrappedValue.claims.removeAll { $0.id == c.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            TextField("Source it was checked against", text: $c.source).textFieldStyle(.roundedBorder).font(.caption)
                        }
                        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { m.wrappedValue.claims.append(CCClaim()) } label: { Label("Add claim", systemImage: "plus") }
                    studioNext("Rights & disclosures") { goTo(.rights) }
                }
            case .rights:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Rights & disclosures", "Every third-party asset needs a stated right to use it; every material connection (sponsorship, affiliate, AI-generated material) gets disclosed.")
                    ForEach(m.assets) { $a in
                        HStack(spacing: 8) {
                            TextField("Asset (clip / image / quote / track)", text: $a.asset).textFieldStyle(.roundedBorder)
                            TextField("Rights / licence / permission", text: $a.rights).textFieldStyle(.roundedBorder)
                            Button { m.wrappedValue.assets.removeAll { $0.id == a.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { m.wrappedValue.assets.append(CCAsset()) } label: { Label("Add asset", systemImage: "plus") }
                    Text("Disclosures").font(.callout.weight(.semibold))
                    TextEditor(text: m.disclosures).font(.body).frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    Toggle("All material connections are disclosed in or alongside the piece", isOn: m.disclosureConfirmed)
                    studioNext("Publish package") { goTo(.package) }
                }
            case .package:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("The publish package", "The final gate, then the exact checklist that travels with the piece.")
                    Toggle("A corrections path exists after publishing (pinned comment / description edit / erratum)", isOn: m.correctionsPathConfirmed)
                    if !m.wrappedValue.isComplete(.package) {
                        Label("The package completes when the corrections path is confirmed.", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Package preview").font(.callout.weight(.semibold))
                    StudioReportPreview(text: PublishPackageRenderer.markdown(m.wrappedValue, generatedAt: Date()))
                }
            }
        }
    }
}

// MARK: - #9 Individual

public struct BinderStudioView: View {
    public init() {}
    public var body: some View {
        PersonaStudioShell(config: StudioConfig<EmergencyBinder>(
            name: "Emergency Binder Studio",
            icon: "book.closed",
            blurb: "Build the document professional organizers actually leave behind: who to call, where every important document and account lives, who can access it, and your instructions — printable, and reviewed so it never goes stale.",
            storeKey: "kalsmritikosh.in.store",
            filenamePrefix: "emergency-binder",
            newItem: { EmergencyBinder(title: "New binder", now: $0) },
            sampleItem: { EmergencyBinder.sample(now: $0) },
            subtitle: { b in "\(b.contacts.count) contact(s) · \(b.items.count) item(s)" },
            render: { EmergencyBinderRenderer.markdown($0, generatedAt: $1) }
        )) { m, s, goTo in
            switch s {
            case .people:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Key people", "Who a family member should call, in what role — doctor, lawyer, executor, next of kin.")
                    StudioField("Binder owner", m.owner)
                    ForEach(m.contacts) { $c in
                        HStack(spacing: 8) {
                            TextField("Name", text: $c.name).textFieldStyle(.roundedBorder)
                            TextField("Role", text: $c.role).textFieldStyle(.roundedBorder)
                            TextField("Phone / email", text: $c.reach).textFieldStyle(.roundedBorder)
                            Button { m.wrappedValue.contacts.removeAll { $0.id == c.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { m.wrappedValue.contacts.append(BinderContact()) } label: { Label("Add person", systemImage: "plus") }
                    studioNext("Documents & accounts") { goTo(.documents) }
                }
            case .documents:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Documents & accounts", "The point is findability: where each thing physically or digitally lives, and who can get to it.")
                    ForEach(m.items) { $i in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("Item (will / policy / account / deed)", text: $i.item).textFieldStyle(.roundedBorder)
                                Button { m.wrappedValue.items.removeAll { $0.id == i.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                TextField("Where it lives", text: $i.location).textFieldStyle(.roundedBorder)
                                TextField("Who can access, and how", text: $i.access).textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { m.wrappedValue.items.append(BinderItem()) } label: { Label("Add item", systemImage: "plus") }
                    studioNext("Instructions") { goTo(.wishes) }
                }
            case .wishes:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Instructions", "What you want the reader to do first — in your words.")
                    TextEditor(text: m.wishes).font(.body).frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    studioNext("The binder") { goTo(.binder) }
                }
            case .binder:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("The binder", "Confirm it's current, then print it — a binder nobody can find or that's five years stale protects nobody.")
                    Toggle("Reviewed within the last year", isOn: m.reviewedRecently)
                    if !m.wrappedValue.isComplete(.binder) {
                        Label("The binder completes when the review is confirmed.", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Binder preview").font(.callout.weight(.semibold))
                    StudioReportPreview(text: EmergencyBinderRenderer.markdown(m.wrappedValue, generatedAt: Date()))
                }
            }
        }
    }
}

// MARK: - Shared next button

// MARK: - #10 Individual — Dispute file

public struct DisputeFileStudioView: View {
    public init() {}
    public var body: some View {
        PersonaStudioShell(config: StudioConfig<DisputeFile>(
            name: "Dispute File",
            icon: "doc.plaintext",
            blurb: "Put a personal dispute on paper the way an insurer, landlord, employer or ombudsman expects it: who it is with and their reference, what is disputed, a timeline with the document behind every line, and what you ask for. Fill it from your case and every line keeps its source.",
            storeKey: "kalsmritikosh.ds.store",
            filenamePrefix: "dispute-file",
            newItem: { DisputeFile(title: "New dispute", now: $0) },
            sampleItem: { DisputeFile.sample(now: $0) },
            subtitle: { d in d.counterparty.trimmed.isEmpty ? d.kind.label : "\(d.kind.label) — \(d.counterparty)" },
            render: { DisputeFileRenderer.markdown($0, generatedAt: $1) }
        )) { m, s, goTo in
            switch s {
            case .dispute:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("The dispute", "Who it is with, and the reference number they use — the first thing anyone handling it will ask for.")
                    Picker("Type", selection: m.kind) {
                        ForEach(DisputeKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.frame(maxWidth: 360)
                    StudioField("With (insurer, landlord, employer, seller)", m.counterparty)
                    StudioField("Their reference (claim, policy, account, case number)", m.reference)
                    StudioField("Your name", m.myName)
                    studioNext("What is disputed") { goTo(.disputed) }
                }
            case .disputed:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("What is disputed", "In plain words: what happened, and what you disagree with.")
                    StudioField("Amount in dispute", m.disputedAmount)
                    TextEditor(text: m.summary).font(.body).frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    studioNext("Timeline & documents") { goTo(.evidence) }
                }
            case .evidence:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("Timeline & documents", "Every line of the timeline names the document that shows it.")
                    ForEach(m.timeline) { $t in
                        HStack(spacing: 8) {
                            TextField("yyyy-MM-dd", text: $t.date).textFieldStyle(.roundedBorder).frame(width: 110)
                            TextField("What happened", text: $t.event).textFieldStyle(.roundedBorder)
                            TextField("Shown by (document)", text: $t.source).textFieldStyle(.roundedBorder).frame(width: 220)
                            Button { m.wrappedValue.timeline.removeAll { $0.id == t.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    Button { m.wrappedValue.timeline.append(DisputeTimelineEntry()) } label: { Label("Add timeline entry", systemImage: "plus") }
                    Text("Documents enclosed").font(.callout.weight(.semibold))
                    ForEach(m.documents) { $d in
                        HStack(spacing: 8) {
                            TextField("Document", text: $d.name).textFieldStyle(.roundedBorder)
                            TextField("What it proves", text: $d.why).textFieldStyle(.roundedBorder)
                            Button { m.wrappedValue.documents.removeAll { $0.id == d.id } } label: { Label("Remove", systemImage: "xmark.circle").labelStyle(.iconOnly) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    Button { m.wrappedValue.documents.append(DisputeDocument()) } label: { Label("Add document", systemImage: "plus") }
                    studioNext("What I ask for") { goTo(.request) }
                }
            case .request:
                VStack(alignment: .leading, spacing: 12) {
                    StudioStageHeader("What I ask for", "The outcome you want, the date you want a reply by, and where it goes if refused.")
                    StudioField("What you ask for", m.remedy)
                    StudioField("Reply by (yyyy-MM-dd)", m.deadline)
                    StudioField("If refused, refer to", m.escalation)
                    Text("Report preview").font(.callout.weight(.semibold))
                    StudioReportPreview(text: DisputeFileRenderer.markdown(m.wrappedValue, generatedAt: Date()))
                }
            }
        }
    }
}

private func studioNext(_ title: String, _ go: @escaping () -> Void) -> some View {
    HStack { Spacer(); Button(action: go) { Label("Next: \(title)", systemImage: "arrow.right") }.buttonStyle(.borderedProminent) }
}

#if DEBUG
#Preview("Researcher Studio") { ResearcherStudioView().frame(width: 1040, height: 760) }
#endif

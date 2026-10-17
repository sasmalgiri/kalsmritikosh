//
//  ToolSheet.swift
//  Kalsmritikosh
//
//  The sidebar "Tools" menu: every stand-alone tool from the beat-DEVONthink
//  plan, listed only while its module is switched on.
//

import SwiftUI

enum ToolSheet: String, Identifiable, CaseIterable {
    case factCheck, statementDrift, caseSlices, watchlists, alerts, chronology, reviewCoding, communication, graph, customTypes, studio, emailAuthenticity, mailRecovery, nearDuplicates, highlights, legalProduction, smartCollections, exportCenter, places, images, notesImport, devonthink, capture, textRecognition, teamReview, myNotes

    var id: String { rawValue }

    var module: ProductModule {
        switch self {
        case .factCheck: return .liveFactCheck
        case .statementDrift: return .statementDrift
        case .caseSlices: return .caseSlices
        case .watchlists: return .watchlists
        case .alerts: return .proactiveAlerts
        case .chronology: return .issueChronology
        case .reviewCoding: return .reviewCoding
        case .communication: return .communicationAnalysis
        case .graph: return .timelineGraph
        case .customTypes: return .customEntityTypes
        case .studio: return .studioOutputs
        case .emailAuthenticity: return .emailAuthenticity
        case .mailRecovery: return .mailRecovery
        case .nearDuplicates: return .nearDuplicates
        case .highlights: return .annotations
        case .legalProduction: return .legalProduction
        case .smartCollections: return .smartCollections
        case .exportCenter: return .exportFormats
        case .places: return .locationMap
        case .images: return .imageIntelligence
        case .notesImport: return .notesImport
        case .devonthink: return .devonthinkImport
        case .capture: return .captureExtensions
        case .textRecognition: return .ocrUpgrade
        case .teamReview: return .teamReview
        case .myNotes: return .writtenNotes
        }
    }

    var title: String { module.title }

    var symbol: String {
        switch self {
        case .factCheck: return "text.badge.checkmark"
        case .statementDrift: return "person.text.rectangle"
        case .caseSlices: return "square.on.square.badge.person.crop"
        case .watchlists: return "list.bullet.clipboard"
        case .alerts: return "bell.badge"
        case .chronology: return "calendar.badge.clock"
        case .reviewCoding: return "checklist"
        case .communication: return "bubble.left.and.bubble.right"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .customTypes: return "tablecells"
        case .studio: return "doc.richtext"
        case .emailAuthenticity: return "checkmark.shield"
        case .mailRecovery: return "trash.slash"
        case .nearDuplicates: return "doc.on.doc"
        case .highlights: return "highlighter"
        case .legalProduction: return "number.square"
        case .smartCollections: return "folder.badge.gearshape"
        case .exportCenter: return "square.and.arrow.up.on.square"
        case .places: return "mappin.and.ellipse"
        case .images: return "photo.stack"
        case .notesImport: return "note.text"
        case .devonthink: return "archivebox"
        case .capture: return "tray.and.arrow.down"
        case .textRecognition: return "text.viewfinder"
        case .teamReview: return "person.2.badge.key"
        case .myNotes: return "square.and.pencil"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .factCheck: FactCheckWritingView()
        case .statementDrift: StatementDriftView()
        case .caseSlices: CaseSliceView()
        case .watchlists: WatchlistView()
        case .alerts: AlertsView()
        case .chronology: IssueChronologyView()
        case .reviewCoding: ReviewCodingView()
        case .communication: CommunicationView()
        case .graph: RelationshipGraphView()
        case .customTypes: CustomTypesView()
        case .studio: StudioOutputsView()
        case .emailAuthenticity: EmailAuthenticityView()
        case .mailRecovery: MailRecoveryView()
        case .nearDuplicates: NearDuplicatesView()
        case .highlights: HighlightsView()
        case .legalProduction: LegalProductionView()
        case .smartCollections: SmartCollectionsView()
        case .exportCenter: ExportCenterView()
        case .places: PlacesView()
        case .images: ImageIntelligenceView()
        case .notesImport: NotesImportView()
        case .devonthink: DevonthinkImportView()
        case .capture: CaptureView()
        case .textRecognition: TextRecognitionView()
        case .teamReview: TeamReviewView()
        case .myNotes: MyNotesView()
        }
    }

    @MainActor
    static var available: [ToolSheet] {
        allCases.filter { t in
            ProductModuleFlags.isEnabled(t.module) || (t == .alerts && ProductModuleFlags.isEnabled(.questionMonitors))
        }
    }
}

/// The Tools menu groups related tools into one window with tabs, so the menu
/// stays short (about ten entries) however many modules are switched on. A hub
/// appears only when at least one of its tools is on; a hub with one tool opens
/// that tool directly.
enum ToolHub: String, Identifiable, CaseIterable {
    case legal, watch, people, emailForensics, writing, documents, bringIn, export, team

    var id: String { rawValue }

    var title: String {
        switch self {
        case .legal: return "Legal review"
        case .watch: return "Watch & alerts"
        case .people: return "People & connections"
        case .emailForensics: return "Email forensics"
        case .writing: return "Writing & checking"
        case .documents: return "Documents"
        case .bringIn: return "Bring documents in"
        case .export: return "Export"
        case .team: return "Team review"
        }
    }

    var symbol: String {
        switch self {
        case .legal: return "scalemass"
        case .watch: return "bell.badge"
        case .people: return "person.2.wave.2"
        case .emailForensics: return "envelope.badge.shield.half.filled"
        case .writing: return "text.badge.checkmark"
        case .documents: return "doc.on.doc"
        case .bringIn: return "tray.and.arrow.down"
        case .export: return "square.and.arrow.up.on.square"
        case .team: return "person.2.badge.key"
        }
    }

    var tools: [ToolSheet] {
        switch self {
        case .legal: return [.reviewCoding, .chronology, .legalProduction, .caseSlices]
        case .watch: return [.alerts, .watchlists, .smartCollections]
        case .people: return [.graph, .communication, .places]
        case .emailForensics: return [.emailAuthenticity, .mailRecovery]
        case .writing: return [.myNotes, .factCheck, .statementDrift, .highlights, .studio]
        case .documents: return [.nearDuplicates, .textRecognition, .images, .customTypes]
        case .bringIn: return [.devonthink, .notesImport, .capture]
        case .export: return [.exportCenter]
        case .team: return [.teamReview]
        }
    }

    @MainActor var availableTools: [ToolSheet] {
        let on = Set(ToolSheet.available)
        return tools.filter(on.contains)
    }

    @MainActor static var available: [ToolHub] { allCases.filter { !$0.availableTools.isEmpty } }
}

struct ToolHubView: View {
    let hub: ToolHub
    @State private var selection: ToolSheet?

    var body: some View {
        let tools = hub.availableTools
        if tools.count == 1, let only = tools.first {
            only.view
        } else {
            TabView(selection: $selection) {
                ForEach(tools) { tool in
                    tool.view
                        .tabItem { Label(tool.title, systemImage: tool.symbol) }
                        .tag(Optional(tool))
                }
            }
            .frame(minWidth: 820, minHeight: 600)
            .onAppear { if selection == nil { selection = tools.first } }
        }
    }
}

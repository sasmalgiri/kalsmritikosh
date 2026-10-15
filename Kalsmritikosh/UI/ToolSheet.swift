//
//  ToolSheet.swift
//  Kalsmritikosh
//
//  The sidebar "Tools" menu: every stand-alone tool from the beat-DEVONthink
//  plan, listed only while its module is switched on.
//

import SwiftUI

enum ToolSheet: String, Identifiable, CaseIterable {
    case factCheck, statementDrift, caseSlices, watchlists, alerts, chronology, reviewCoding, communication, graph, customTypes, studio, emailAuthenticity, mailRecovery, nearDuplicates, highlights, legalProduction, smartCollections, exportCenter, places, images, notesImport, devonthink, capture, textRecognition, teamReview

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
        }
    }

    @MainActor
    static var available: [ToolSheet] {
        allCases.filter { t in
            ProductModuleFlags.isEnabled(t.module) || (t == .alerts && ProductModuleFlags.isEnabled(.questionMonitors))
        }
    }
}

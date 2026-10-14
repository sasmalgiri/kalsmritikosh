//
//  ToolSheet.swift
//  Kalsmritikosh
//
//  The sidebar "Tools" menu: every stand-alone tool from the beat-DEVONthink
//  plan, listed only while its module is switched on.
//

import SwiftUI

enum ToolSheet: String, Identifiable, CaseIterable {
    case factCheck, statementDrift, caseSlices, watchlists, alerts, chronology, reviewCoding, communication, graph, customTypes, studio, emailAuthenticity, mailRecovery

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
        }
    }

    @MainActor
    static var available: [ToolSheet] {
        allCases.filter { t in
            ProductModuleFlags.isEnabled(t.module) || (t == .alerts && ProductModuleFlags.isEnabled(.questionMonitors))
        }
    }
}

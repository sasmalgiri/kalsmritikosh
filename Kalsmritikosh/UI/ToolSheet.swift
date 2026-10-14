//
//  ToolSheet.swift
//  Kalsmritikosh
//
//  The sidebar "Tools" menu: every stand-alone tool from the beat-DEVONthink
//  plan, listed only while its module is switched on.
//

import SwiftUI

enum ToolSheet: String, Identifiable, CaseIterable {
    case factCheck, statementDrift, caseSlices

    var id: String { rawValue }

    var module: ProductModule {
        switch self {
        case .factCheck: return .liveFactCheck
        case .statementDrift: return .statementDrift
        case .caseSlices: return .caseSlices
        }
    }

    var title: String { module.title }

    var symbol: String {
        switch self {
        case .factCheck: return "text.badge.checkmark"
        case .statementDrift: return "person.text.rectangle"
        case .caseSlices: return "square.on.square.badge.person.crop"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .factCheck: FactCheckWritingView()
        case .statementDrift: StatementDriftView()
        case .caseSlices: CaseSliceView()
        }
    }

    @MainActor
    static var available: [ToolSheet] { allCases.filter { ProductModuleFlags.isEnabled($0.module) } }
}

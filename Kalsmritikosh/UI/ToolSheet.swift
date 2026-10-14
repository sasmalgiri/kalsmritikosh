//
//  ToolSheet.swift
//  Kalsmritikosh
//
//  The sidebar "Tools" menu: every stand-alone tool from the beat-DEVONthink
//  plan, listed only while its module is switched on.
//

import SwiftUI

enum ToolSheet: String, Identifiable, CaseIterable {
    case factCheck, statementDrift

    var id: String { rawValue }

    var module: ProductModule {
        switch self {
        case .factCheck: return .liveFactCheck
        case .statementDrift: return .statementDrift
        }
    }

    var title: String { module.title }

    var symbol: String {
        switch self {
        case .factCheck: return "text.badge.checkmark"
        case .statementDrift: return "person.text.rectangle"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .factCheck: FactCheckWritingView()
        case .statementDrift: StatementDriftView()
        }
    }

    @MainActor
    static var available: [ToolSheet] { allCases.filter { ProductModuleFlags.isEnabled($0.module) } }
}

//
//  ShellRouter.swift
//  Kalsmritikosh
//
//  SHELL-002 (product shell) — the ONE routing authority. It resolves a (persona, mode, surface) request
//  into a shared destination decorated with persona context. The load-bearing rule it enforces is:
//
//      persona route → shared destination → persona context/configuration
//
//  NOT persona → duplicate implementation. Every persona reaches the SAME AppNavigationDestination for a
//  given surface; a persona only changes labels, recommended surfaces and the default answer mode. The
//  persona identity is the EXISTING WorkspaceTemplate — this file forks neither the persona vocabulary
//  nor the destination vocabulary. Simple and Advanced route to the same destinations over the same
//  state, so switching presentation never forks or loses the current location.
//

import Foundation

/// Persona routing decoration: what a persona changes about a shared surface set (labels, emphasis,
/// default answer mode) — never the destinations or the engines behind them.
public nonisolated struct PersonaRoutingContext: Sendable, Equatable {
    public let template: WorkspaceTemplate
    public let homeLabel: String
    public let myWorkLabel: String
    public let recommendedSurfaces: [ShellSurface]
    public let defaultAnswerMode: ShellAnswerMode

    public nonisolated init(template: WorkspaceTemplate, homeLabel: String, myWorkLabel: String,
                            recommendedSurfaces: [ShellSurface], defaultAnswerMode: ShellAnswerMode) {
        self.template = template; self.homeLabel = homeLabel; self.myWorkLabel = myWorkLabel
        self.recommendedSurfaces = recommendedSurfaces; self.defaultAnswerMode = defaultAnswerMode
    }
}

/// The per-persona routing contexts. Pure presentation configuration over the shared shell — it changes
/// only labels / emphasis / default mode, keyed by the existing WorkspaceTemplate persona identity.
public nonisolated enum PersonaRoutingCatalog {
    public nonisolated static func context(for template: WorkspaceTemplate) -> PersonaRoutingContext {
        switch template {
        case .general:
            return .init(template: .general, homeLabel: "Home", myWorkLabel: "My Work",
                         recommendedSurfaces: [.home, .ask, .sources], defaultAnswerMode: .fast)
        case .investigation:
            return .init(template: .investigation, homeLabel: "Investigation", myWorkLabel: "Investigation Work",
                         recommendedSurfaces: [.myWork, .evidence, .dataLab], defaultAnswerMode: .fullEvidence)
        case .researchReview:
            return .init(template: .researchReview, homeLabel: "Research", myWorkLabel: "Review Work",
                         recommendedSurfaces: [.sources, .dataLab, .reports], defaultAnswerMode: .fullEvidence)
        case .journalism:
            return .init(template: .journalism, homeLabel: "Newsroom", myWorkLabel: "Story Work",
                         recommendedSurfaces: [.ask, .sources, .reports], defaultAnswerMode: .fullEvidence)
        case .personalMatter:
            return .init(template: .personalMatter, homeLabel: "Home", myWorkLabel: "My Work",
                         recommendedSurfaces: [.home, .ask, .dataLab], defaultAnswerMode: .fast)
        case .legalMatter:
            return .init(template: .legalMatter, homeLabel: "Matters", myWorkLabel: "Matter Work",
                         recommendedSurfaces: [.myWork, .evidence, .reports], defaultAnswerMode: .fullEvidence)
        }
    }
}

/// A resolved route: the shared destination + the persona-decorated display label. The `destination` is
/// identical for every persona and every mode for a given surface — that is the shared-truth guarantee.
public nonisolated struct ShellRoute: Sendable, Equatable {
    public let surface: ShellSurface
    public let destination: AppNavigationDestination
    public let displayLabel: String
    public let template: WorkspaceTemplate

    public nonisolated init(surface: ShellSurface, destination: AppNavigationDestination, displayLabel: String, template: WorkspaceTemplate) {
        self.surface = surface; self.destination = destination; self.displayLabel = displayLabel; self.template = template
    }
}

public nonisolated enum ShellRouter {

    /// Resolve a (persona, mode, surface) into a shared destination decorated with persona labels.
    /// `mode` never changes the destination — it only governs which surfaces are OFFERED (availableSurfaces).
    public nonisolated static func route(template: WorkspaceTemplate, mode: WorkbenchDatasetMode, surface: ShellSurface) -> ShellRoute {
        let ctx = PersonaRoutingCatalog.context(for: template)
        let label: String
        switch surface {
        case .home:   label = ctx.homeLabel
        case .myWork: label = ctx.myWorkLabel
        default:      label = surface.defaultLabel
        }
        return ShellRoute(surface: surface, destination: surface.destination, displayLabel: label, template: template)
    }

    /// The surfaces a mode offers: Simple's focused subset, or every surface in Advanced (a superset).
    public nonisolated static func availableSurfaces(mode: WorkbenchDatasetMode) -> [ShellSurface] {
        switch mode {
        case .simple:   return ShellSurface.simpleSurfaces
        case .advanced: return ShellSurface.allCases
        }
    }

    /// The persona's recommended surfaces for its dashboard emphasis, intersected with what the mode offers.
    public nonisolated static func recommendedSurfaces(template: WorkspaceTemplate, mode: WorkbenchDatasetMode) -> [ShellSurface] {
        let available = Set(availableSurfaces(mode: mode))
        return PersonaRoutingCatalog.context(for: template).recommendedSurfaces.filter { available.contains($0) }
    }

    /// Bridge a resolved route into a SHELL-001 navigation entry so it flows through the shared
    /// Back/Forward history + autosave/resume (the persona is carried as the entry's context).
    public nonisolated static func navigationEntry(for route: ShellRoute) -> AppNavigationEntry {
        AppNavigationEntry(destination: route.destination, contextKind: "persona", contextID: route.template.rawValue)
    }
}

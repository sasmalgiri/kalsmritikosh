//
//  ShellSurface.swift
//  Kalsmritikosh
//
//  SHELL-002 (product shell) — the ONE persona-neutral catalogue of the shell's shared surfaces. Every
//  persona reaches the SAME surfaces (Home, Ask, My Work, DataLab, Sources, Evidence, Reports, Settings);
//  a persona only changes labels, recommended actions and emphasis, never the surface or its underlying
//  engine. Each surface maps to a SHARED SHELL-001 AppNavigationDestination — the routing layer forks no
//  destination vocabulary. Simple presents a focused subset of these surfaces; Advanced presents them
//  all (a strict superset), over the same routes and the same state.
//

import Foundation

/// The persona-neutral shared surfaces of the product shell. Each maps to a shared navigation destination.
public nonisolated enum ShellSurface: String, Codable, Sendable, Equatable, CaseIterable {
    case home
    case ask
    case myWork
    case dataLab
    case sources
    case evidence
    case reports
    case settings

    /// The SHARED SHELL-001 destination this surface routes to. Reused, never forked per persona.
    public nonisolated var destination: AppNavigationDestination {
        switch self {
        case .home:     return .home
        case .ask:      return .answers
        case .myWork:   return .jobs
        case .dataLab:  return .dataLab
        case .sources:  return .sources
        case .evidence: return .evidenceInspector
        case .reports:  return .reports
        case .settings: return .settings
        }
    }

    /// The persona-neutral default label (a persona context may override the display label, never the route).
    public nonisolated var defaultLabel: String {
        switch self {
        case .home:     return "Home"
        case .ask:      return "Ask"
        case .myWork:   return "My Work"
        case .dataLab:  return "DataLab"
        case .sources:  return "Sources"
        case .evidence: return "Evidence"
        case .reports:  return "Reports"
        case .settings: return "Settings"
        }
    }

    /// The focused set Simple presents. Advanced presents every surface. The Simple set is a strict
    /// subset, so Simple never reaches a surface Advanced cannot — one shell, two presentations.
    public nonisolated static let simpleSurfaces: [ShellSurface] = [.home, .ask, .myWork, .dataLab, .sources]
}

/// The ONLY two normal Ask modes the shell exposes. Both route to the existing AEE authority — there is
/// no second answer engine, and no older depth names (Auto/Normal/Research/Deep/Expert/Intermediate).
public nonisolated enum ShellAnswerMode: String, Codable, Sendable, Equatable, CaseIterable {
    case fast
    case fullEvidence

    public nonisolated var displayName: String {
        switch self {
        case .fast:         return "Fast"
        case .fullEvidence: return "Full Evidence"
        }
    }
}

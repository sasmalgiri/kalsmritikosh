//
//  ContainerError.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-006 §23) — typed errors for the container subsystem. A container that cannot be safely
//  opened fails CLOSED (custody is already recorded by intake; nothing is fabricated). Per-member
//  problems are recorded as member DISPOSITIONS (see ContainerMemberDisposition), NOT thrown — a bad
//  member never aborts the whole inspection.
//

import Foundation

public nonisolated enum ContainerError: Error, Sendable, Equatable {
    /// The SourceType is not a container this subsystem handles.
    case notAContainer(SourceType)
    /// The container bytes could not be read/opened at all.
    case unreadableContainer(detail: String)
    /// The exact container SourceVersion does not exist (persistence precondition).
    case sourceVersionMissing(UUID)
    /// The SourceVersion is not container-compatible for a manifest write.
    case notContainerCompatible(UUID, SourceType)
    /// Manifest disposition counts are internally inconsistent (would violate the v87 CHECK).
    case inconsistentCounts(detail: String)
    /// An admitted member row lacked its required child version / content hash pair.
    case admittedMemberMissingChild(ordinal: Int)
    /// A non-admitted member carried a fabricated child version.
    case nonAdmittedMemberHasChild(ordinal: Int)
    /// The persisted member rows did not match the manifest's declared counts.
    case memberCountMismatch(expected: Int, actual: Int)
    /// Optimistic revision conflict when replacing an existing manifest.
    case revisionConflict(UUID)
}

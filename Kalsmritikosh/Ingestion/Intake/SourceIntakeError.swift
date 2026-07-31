//
//  SourceIntakeError.swift
//  Kalsmritikosh
//
//  USF-001 — typed intake failures. Custody guarantees apply to every ACCESSIBLE input;
//  an inaccessible input surfaces a precise reason and never fabricates a hash or a fake
//  source version. Errors stay typed (never reduced to generic strings).
//

import Foundation

public nonisolated enum SourceIntakeError: Error, Equatable, Sendable {
    /// No bytes could be read from the input.
    case inputNotAccessible(URL)
    /// The path exists but is not a regular file (directory, symlink target missing, etc.).
    case notARegularFile(URL)
    /// A security-scoped resource could not be reached.
    case securityScopeUnavailable(URL)
    /// The file's size / modification time / resource identity changed during hashing.
    case sourceChangedDuringCapture(URL)
    /// The streaming hash could not be computed.
    case hashComputationFailed(URL)
    /// Managed-copy storage into the evidence vault failed (source stays visible as managedCopyFailed).
    case managedCopyFailed(reason: String)
    /// A referenced logical source id does not exist.
    case logicalSourceNotFound(UUID)
    /// A referenced source version id does not exist.
    case sourceVersionNotFound(UUID)
    /// The identity transaction found an inconsistent/duplicate source identity.
    case sourceIdentityConflict(String)
    /// A parent reference names a nonexistent version, or would form an invalid relation.
    case invalidParentReference(String)
    /// A relation value or self-relation is not allowed.
    case invalidRelation(String)
    /// The atomic intake write failed.
    case databaseWriteFailed(String)
    /// A parsed document does not match the source version it is being attached to.
    case parsedDocumentIdentityMismatch(String)
}

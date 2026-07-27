//
//  EmailParticipantRole.swift
//  Kalsmritikosh
//
//  OPS-005 — six distinct email participant roles, matching RFC 2822
//  header semantics exactly. Each occurrence row records one role;
//  a single address appearing in both To and Cc produces two rows.
//

public enum EmailParticipantRole: String, Codable, Sendable, CaseIterable {
    /// RFC 2822 From — the author's mailbox.
    case from    = "from"
    /// RFC 2822 Sender — the submitting agent (distinct from From
    /// when someone sends on behalf of someone else).
    case sender  = "sender"
    /// RFC 2822 Reply-To — where replies should be directed.
    case replyTo = "reply-to"
    /// RFC 2822 To — primary recipients.
    case to      = "to"
    /// RFC 2822 Cc — carbon-copy recipients.
    case cc      = "cc"
    /// RFC 2822 Bcc — blind-carbon-copy recipients.
    /// MUST NOT appear in chunk text or embeddings.
    case bcc     = "bcc"
}

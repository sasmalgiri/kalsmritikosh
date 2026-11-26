//
//  TimestampAuthorityClient.swift
//  Kalsmritikosh
//
//  ALCOA ALC-12 (owner 2026-11-24) — the one way an RFC 3161 timestamp request leaves this Mac: through the network
//  door (NetworkHelperClient, purpose "timestamp"), which lets it reach only the time-stamping authority the person
//  named in Settings while timestamping is on; the helper accepts it only as a small application/timestamp-query POST.
//

import Foundation

public nonisolated enum TimestampAuthorityClient {
    public static func send(_ request: OutboundHTTPRequest) async throws -> OutboundHTTPResponse {
        try await NetworkHelperClient.send(request)
    }
}

//
//  KalsmritikoshNetworkHelper.swift
//  KalsmritikoshNetworkHelper (ExtensionKit, no UI)
//
//  O-2 — the ONLY Kalsmritikosh process allowed to open a network connection
//  (its sandbox alone has `network.client`). It does one thing: send an HTTPS
//  POST to one of three allowlisted hosts and return the status and body. It
//  keeps no state, stores nothing, logs no content, and refuses any other host,
//  scheme or method. The main app builds the request, shows the user exactly
//  what will be sent, records every send, and only then asks this helper to carry it.
//

import Foundation
import ExtensionFoundation

final class NetworkService: NSObject, KalsmritikoshNetworkProtocol, @unchecked Sendable {
    static let allowedHosts: Set<String> = ["api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com"]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral          // no cookies, no cache on disk
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func send(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let req = try? JSONDecoder().decode(OutboundHTTPRequest.self, from: request),
              let url = URL(string: req.url), url.scheme == "https",
              let host = url.host, Self.allowedHosts.contains(host) else {
            reply(nil, "Refused: not an allowed HTTPS destination.")
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = req.body
        for (k, v) in req.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
        session.dataTask(with: urlRequest) { data, response, error in
            if let error { reply(nil, error.localizedDescription); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            reply(try? JSONEncoder().encode(OutboundHTTPResponse(status: status, body: data ?? Data())), nil)
        }.resume()
    }
}

/// Bound to the host's extension point, which exists on macOS 26 and later; the host only
/// launches this helper there (NetworkHelperClient).
@available(macOS 26.0, *)
@main
final class KalsmritikoshNetworkHelper: AppExtension {
    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "ecosanskritiinnovation.Kalsmritikosh", name: "network-helper")
    }

    required init() {}

    var configuration: ConnectionHandler {
        ConnectionHandler(onConnection: { connection in
            connection.exportedInterface = NSXPCInterface(with: KalsmritikoshNetworkProtocol.self)
            connection.exportedObject = NetworkService()
            connection.resume()
            return true
        })
    }
}

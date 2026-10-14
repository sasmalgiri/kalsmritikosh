//
//  main.swift
//  KalsmritikoshNetwork (XPC service)
//
//  O-2 — the ONLY Kalsmritikosh process allowed to open a network connection.
//  It does one thing: send an HTTPS POST to one of three allowlisted hosts and
//  return the status and body. It keeps no state, stores nothing, logs no
//  content, and refuses any other host, scheme or method.
//
//  The main app (no network entitlement) builds the request, shows the user
//  exactly what will be sent, and records every send; this helper just carries it.
//

import Foundation

final class NetworkService: NSObject, KalsmritikoshNetworkProtocol {
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
            let out = OutboundHTTPResponse(status: status, body: data ?? Data())
            reply(try? JSONEncoder().encode(out), nil)
        }.resume()
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: KalsmritikoshNetworkProtocol.self)
        connection.exportedObject = NetworkService()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

//
//  OnlineToolsTests.swift
//  KalsmritikoshTests
//
//  A8–A11 — exchange rates, sanctions lists, registry and court lookups, web capture, recording
//  transcription: what may be sent where, what is previewed, what is recorded, how replies are read.
//  No network: scripted transports only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Online tools (A8–A11)")
struct OnlineToolsTests {

    // MARK: A10

    @Test("ECB: the request names the series and week; the last rate on or before the date is used and named; conversion goes through the euro")
    func exchangeRates() throws {
        let req = try ExchangeRates.request(currency: "USD", date: "2026-05-03")
        #expect(req.method == "GET" && req.url == "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?startPeriod=2026-04-26&endPeriod=2026-05-03&format=csvdata")
        #expect(throws: ExchangeRates.RateError.badCurrency("usd")) { try ExchangeRates.request(currency: "usd", date: "2026-05-03") }
        // 3 May 2026 is a Sunday: Friday 1 May's rate is used, and the date says so.
        let csv = "KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE\nEXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2026-04-30,1.0800\nEXR.D.USD.EUR.SP00.A,D,USD,EUR,SP00,A,2026-05-01,1.0850\n"
        let usd = try ExchangeRates.parse(Data(csv.utf8), currency: "USD", date: "2026-05-03")
        #expect(usd == .init(currency: "USD", observedOn: "2026-05-01", perEuro: Decimal(string: "1.085")!))
        #expect(throws: ExchangeRates.RateError.noRate("USD", "2026-05-03")) { try ExchangeRates.parse(Data(), currency: "USD", date: "2026-05-03") }
        let gbp = ExchangeRates.Rate(currency: "GBP", observedOn: "2026-05-01", perEuro: Decimal(string: "0.85")!)
        #expect(ExchangeRates.convert(1085, from: usd, to: nil) == 1000)                       // USD → EUR
        #expect(ExchangeRates.convert(1000, from: nil, to: gbp) == 850)                        // EUR → GBP
        #expect(ExchangeRates.convert(1085, from: usd, to: gbp) == 850)                        // USD → GBP through EUR
    }

    // MARK: A8 sanctions

    @Test("Sanctions lists are read from OFAC CSV (with aliases) and UN XML; a match needs every word, in any order; nothing fuzzier")
    func sanctionsParsingAndMatching() {
        let sdn = Data(#"""
        36,"AEROCARIBBEAN AIRLINES","-0- ","CUBA","-0- "
        306,"BANCO NACIONAL DE CUBA",-0- ,"CUBA",-0-
        2674,"HUSSEIN, Saddam","individual","IRAQ2",-0-
        """#.utf8)
        let alt = Data(#"2674,1543,"aka","AL-TIKRITI, Saddam Hussein",-0-"#.utf8)
        let un = Data("""
        <CONSOLIDATED_LIST><INDIVIDUALS><INDIVIDUAL><REFERENCE_NUMBER>QDi.001</REFERENCE_NUMBER><UN_LIST_TYPE>Al-Qaida</UN_LIST_TYPE>
        <FIRST_NAME>Abdul</FIRST_NAME><SECOND_NAME>Rahman</SECOND_NAME><INDIVIDUAL_ALIAS><ALIAS_NAME>Abu Rahman</ALIAS_NAME></INDIVIDUAL_ALIAS></INDIVIDUAL></INDIVIDUALS>
        <ENTITIES><ENTITY><REFERENCE_NUMBER>QDe.004</REFERENCE_NUMBER><FIRST_NAME>Al Rashid Trust</FIRST_NAME></ENTITY></ENTITIES></CONSOLIDATED_LIST>
        """.utf8)
        let entries = SanctionsLists.parseSDN(sdn) + SanctionsLists.parseAliases(alt) + SanctionsLists.parseUN(un)
        #expect(entries.count == 7)
        #expect(entries.contains { $0.name == "HUSSEIN, Saddam" && $0.detail == "individual · IRAQ2" && $0.reference == "2674" })
        #expect(entries.contains { $0.list == .unConsolidated && $0.name == "Abu Rahman" && $0.detail.contains("alias") })
        let saddam = SanctionsLists.match("Saddam Hussein", in: entries)
        #expect(saddam.count == 2 && saddam.first?.exact == true, "the primary name (reordered) and the alias holding both words")
        #expect(SanctionsLists.match("al rashid trust", in: entries).first?.entry.reference == "QDe.004", "case and punctuation are folded")
        #expect(SanctionsLists.match("Saddam Hussain", in: entries).isEmpty, "a different spelling is not a match — the person is told to check variants")
        #expect(SanctionsLists.match("a", in: entries).isEmpty)
    }

    // MARK: A8 registry and courts

    @Test("GLEIF and CourtListener: the searched name is encoded into a GET to their own host; replies are read tolerantly")
    func registryAndCourts() {
        let g = RegistryLookups.gleifRequest("Acme & Sons Ltd")
        #expect(g.method == "GET" && g.url.hasPrefix("https://api.gleif.org/api/v1/lei-records?filter%5Bfulltext%5D=Acme%20%26%20Sons%20Ltd"))
        let gj = Data(#"{"data":[{"attributes":{"lei":"5493001KJTIIGC8Y1R12","entity":{"legalName":{"name":"ACME & SONS LIMITED"},"legalAddress":{"city":"London","country":"GB"},"status":"ACTIVE","jurisdiction":"GB"},"registration":{"status":"ISSUED"}}}]}"#.utf8)
        let rec = RegistryLookups.parseGLEIF(gj)
        #expect(rec.count == 1 && rec[0].title == "ACME & SONS LIMITED" && rec[0].detail.contains("LEI 5493001KJTIIGC8Y1R12") && rec[0].detail.contains("London, GB"))
        let c = RegistryLookups.courtRequest("John Carter")
        #expect(c.url == "https://www.courtlistener.com/api/rest/v4/search/?q=%22John%20Carter%22&type=o")
        let cj = Data(#"{"results":[{"caseName":"United States v. Carter","court":"Court of Appeals for the Ninth Circuit","dateFiled":"2019-04-02","docketNumber":"17-10345","absolute_url":"/opinion/1/us-v-carter/"},{"caseName":""}]}"#.utf8)
        let courts = RegistryLookups.parseCourts(cj)
        #expect(courts.count == 1 && courts[0].link == "https://www.courtlistener.com/opinion/1/us-v-carter/" && courts[0].detail.contains("docket 17-10345"))
        #expect(RegistryLookups.parseGLEIF(Data("<html>".utf8)).isEmpty && RegistryLookups.parseCourts(Data()).isEmpty)
    }

    @Test("The network rule: POST only to AI hosts; GET only to the public-record hosts or a page the person asked to capture")
    func networkRule() {
        #expect(NetworkHelperClient.allows(host: "api.anthropic.com", method: nil, purpose: nil))
        #expect(!NetworkHelperClient.allows(host: "api.anthropic.com", method: "GET", purpose: nil))
        #expect(NetworkHelperClient.allows(host: "data-api.ecb.europa.eu", method: "GET", purpose: nil))
        #expect(!NetworkHelperClient.allows(host: "data-api.ecb.europa.eu", method: nil, purpose: nil), "no POST to a lookup host")
        #expect(!NetworkHelperClient.allows(host: "example.com", method: "GET", purpose: nil))
        #expect(NetworkHelperClient.allows(host: "example.com", method: "GET", purpose: "capture"))
        #expect(!NetworkHelperClient.allows(host: "example.com", method: "PUT", purpose: "capture"))
        #expect(PublicSource.allHosts == ["data-api.ecb.europa.eu", "sanctionslistservice.ofac.treas.gov", "scsanctions.un.org", "api.gleif.org", "www.courtlistener.com"],
                "keep identical to the helper's lookupHosts")
    }

    // MARK: the client

    nonisolated final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _p: [OutboundPreview] = [], _r: [OutboundHTTPRequest] = []
        func add(_ p: OutboundPreview) { lock.withLock { _p.append(p) } }
        func add(_ r: OutboundHTTPRequest) { lock.withLock { _r.append(r) } }
        var previews: [OutboundPreview] { lock.withLock { _p } }
        var requests: [OutboundHTTPRequest] { lock.withLock { _r } }
    }

    @Test("The client: offline sends nothing; a name lookup is previewed and recorded; a declined one is not sent; lists download unpreviewed, are cached, and the checked name never leaves")
    func client() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let lists = f.temp.appendingPathComponent("lists", isDirectory: true)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        let box = Box()
        func client(online: Bool = true, allow: Bool = true) -> OnlineLookupClient {
            OnlineLookupClient(outboundLog: OutboundLogRepository(database: f.db), listFolder: lists,
                               seams: .init(online: { online }, consent: { box.add($0); return allow }, transport: { req in
                                   box.add(req)
                                   if req.url.contains("gleif") { return OutboundHTTPResponse(status: 200, body: Data(#"{"data":[]}"#.utf8)) }
                                   if req.url.contains("SDN.CSV") { return OutboundHTTPResponse(status: 200, body: Data(#"2674,"HUSSEIN, Saddam","individual","IRAQ2",-0-"#.utf8)) }
                                   if req.url.contains("ALT.CSV") { return OutboundHTTPResponse(status: 200, body: Data()) }
                                   return OutboundHTTPResponse(status: 200, body: Data("<CONSOLIDATED_LIST/>".utf8))
                               }))
        }
        await #expect(throws: OnlineLookupClient.LookupError.offline) { _ = try await client(online: false).searchRegistry("Acme") }
        #expect(box.requests.isEmpty)
        _ = try await client().searchRegistry("Acme Holdings")
        #expect(box.previews.count == 1 && box.previews[0].text.contains("“Acme Holdings”") && box.requests.count == 1)
        await #expect(throws: OnlineLookupClient.LookupError.declined) { _ = try await client(allow: false).searchRegistry("Acme") }
        #expect(box.requests.count == 1, "declined: nothing sent")
        // Sanctions: three fixed downloads, no preview, nothing of the name in any request.
        let r = try await client().checkSanctions("Saddam Hussein")
        #expect(r.matches.count == 1 && r.listDates.count == 3)
        let downloads = box.requests.dropFirst()
        #expect(downloads.count == 3 && downloads.allSatisfy { !$0.url.lowercased().contains("saddam") && $0.method == "GET" })
        #expect(box.previews.count == 2, "only the two registry lookups were previewed")
        _ = try await client().checkSanctions("Someone Else")
        #expect(box.requests.count == 4, "lists under a day old are read from this Mac")
        let log = try await OutboundLogRepository(database: f.db).recent()
        #expect(log.contains { $0.outcome == "sent" && $0.host == "api.gleif.org" } && log.contains { $0.outcome == "declined" })
    }

    @Test("Web capture: https only, previewed, the page kept byte for byte with a record of address, time, status and digest")
    func capture() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let box = Box()
        let page = Data("<html><body>Notice of sale</body></html>".utf8)
        let c = OnlineLookupClient(outboundLog: OutboundLogRepository(database: f.db), listFolder: nil,
                                   seams: .init(online: { true }, consent: { box.add($0); return true },
                                                transport: { box.add($0); return OutboundHTTPResponse(status: 200, body: page) },
                                                now: { Date(timeIntervalSince1970: 1_800_000_000) }))
        await #expect(throws: OnlineLookupClient.LookupError.notHTTPS) { _ = try await c.capture("http://example.com/") }
        let cap = try await c.capture("https://example.com/notice")
        #expect(cap.body == page && cap.status == 200 && cap.sha256.count == 64)
        #expect(box.requests.first?.purpose == "capture" && box.requests.first?.method == "GET")
        #expect(box.previews.first?.text.contains("https://example.com/notice") == true)
        let record = OnlineToolDocuments.captureRecord(url: cap.url, status: cap.status, bytes: cap.body.count, sha256: cap.sha256,
                                                       at: cap.capturedAt, savedAs: "x.html")
        #expect(record.hasPrefix("WEB CAPTURE RECORD") && record.contains(cap.sha256) && record.contains("HTTP status: 200"))
    }

    @Test("Transcription: AI Included goes to the relay's transcription route, Gemini takes the audio inline, Claude and OpenAI refuse; the transcript says it is not the recording")
    func transcription() throws {
        let audio = OutboundImage(mediaType: "audio/mp4", data: Data([1, 2, 3]), label: "interview.m4a")
        let inc = try OnlineRequestBuilder.build(kind: .included, model: "claude-opus-5", apiKey: "eyJhbGciOiJFUzI1NiJ9.eyJ0ZXN0Ijp0cnVlfQ.dGVzdC1zaWduYXR1cmU", system: nil,
                                                 prompt: "Transcribe", maxTokens: 8192, images: [audio])
        #expect(inc.url.hasSuffix("/v1/transcribe"))
        let body = try #require(try JSONSerialization.jsonObject(with: inc.body) as? [String: Any])
        #expect(body["mimeType"] as? String == "audio/mp4" && body["audioBase64"] as? String == audio.data.base64EncodedString())
        let gem = try OnlineRequestBuilder.build(kind: .gemini, model: "gemini-2.5-flash", apiKey: "k", system: nil, prompt: "Transcribe", maxTokens: 8192, images: [audio])
        #expect(gem.url.contains(":generateContent"))
        #expect(throws: OnlineRequestBuilder.BuildError.audioNotSupported(OnlineProviderKind.anthropic.displayName)) {
            try OnlineRequestBuilder.build(kind: .anthropic, model: "m", apiKey: "k", system: nil, prompt: "p", maxTokens: 10, images: [audio])
        }
        let doc = OnlineToolDocuments.transcriptDocument(original: "interview.m4a", originalSHA256: "ff", provider: "AI Included (Claude Opus 5)",
                                                         model: "Gemini (AI Included)", at: Date(timeIntervalSince1970: 0), body: "[00:00] Speaker 1: Hello.")
        #expect(doc.hasPrefix("AI TRANSCRIPTION OF A RECORDING — NOT THE RECORDING") && doc.contains("guesses of who is speaking, not identifications"))
        #expect(OnlineToolDocuments.audioTypes["m4a"] == "audio/mp4" && OnlineToolDocuments.maxRecordingBytes == 18 * 1024 * 1024)
    }
}

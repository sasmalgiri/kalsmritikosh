//
//  CellebriteReportMapper.swift
//  Kalsmritikosh
//
//  E-6 — maps a Cellebrite UFED Reader report (`report.xml`, namespace
//  http://pa.cellebrite.com/report/2.0) into DiscussionRecords. This is analysis of
//  a report an examiner already produced: it does not acquire a device, does not
//  decrypt anything, and makes no network call.
//
//  HOW THE FILE ARRIVES. A `.ufdr` is a plain ZIP holding `report.xml` plus the
//  extracted media. Intake already reads ZIPs (ZIPReader through the container
//  coordinator), so a `.ufdr` is expanded like any other archive and `report.xml`
//  reaches this mapper as one member — and an already-unzipped report folder
//  reaches it the same way, as a file in a folder. The media files become their
//  own sources through the same expansion.
//
//  WHAT IS READ, from inside `<decodedData>`:
//    • `<modelType type="Chat">` — one thread per `<model type="Chat">`, one record
//      per `<model type="InstantMessage">` in its `Messages` field, with the sender
//      from `From` (a Party: Name / Identifier), the time from `TimeStamp`, the text
//      from `Body` and the app from the chat's `Source`.
//    • top-level `SMS` / `InstantMessage` (/ `MMS`) models — grouped into one thread
//      per app and counterpart.
//    • `<modelType type="Call">` — ONE call-log thread, each call an `activity`.
//    • `<modelType type="Contact">` — ONE contacts thread, each contact an `activity`.
//  Other model types (locations, cookies, web history …) are counted per type in an
//  info warning rather than dropped silently.
//
//  STREAMING. Foundation's XMLParser, SAX-style. Only the model currently being
//  read is held as a small node tree; a message inside a chat is converted and
//  discarded the moment it closes, so a chat with 100 000 messages never becomes
//  one 100 000-node tree. No DOM of the report is ever built.
//
//  TWO FORENSIC FACTS ARE KEPT, not normalised away:
//    • `deleted_state="Deleted"` — the record was RECOVERED, not live. It rides
//      into the message text so a cited line can never pass as a live message.
//    • a time with no zone is NOT assumed to be UTC: the record is undated and the
//      warning says how many, the same rule as every other mapper in this lane.
//

import Foundation

public struct CellebriteReportMapper: DiscussionExportMapper {
    public nonisolated var platform: String { "Cellebrite UFDR" }
    public nonisolated var mapperVersion: String { "1" }

    public nonisolated init() {}

    /// The report schema's namespace. Unique to Cellebrite's report format, so it
    /// is a content fingerprint on its own.
    public nonisolated static let reportNamespace = "pa.cellebrite.com/report"
    public nonisolated static let reportFileName = "report.xml"

    public nonisolated func claims(filename: String, sample: Data) -> Bool {
        guard let text = String(data: sample, encoding: .utf8)
                ?? String(data: sample, encoding: .isoLatin1) else { return false }
        let leading = text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        guard leading.first == "<" else { return false }
        return text.contains(Self.reportNamespace)
    }

    public nonisolated func map(data: Data, filename: String) -> DiscussionExport {
        let collector = UFDRReportCollector(platform: platform)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        let ok = parser.parse()

        var warnings: [ParserWarning] = []
        if !ok {
            let reason = parser.parserError.map { $0.localizedDescription } ?? "parse failed"
            warnings.append(ParserWarning(severity: collector.records.isEmpty ? .error : .warning,
                code: "ufdr.malformed_xml",
                message: "report.xml is not well-formed (\(reason)); \(collector.records.count) "
                       + "record(s) read before the fault are kept, nothing after it."))
        }
        if !collector.sawDecodedData && ok {
            warnings.append(ParserWarning(severity: .warning, code: "ufdr.no_decoded_data",
                message: "The report has no <decodedData> section, so it holds no messages, calls or contacts."))
        }
        if collector.skippedMessages > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "ufdr.messages_skipped",
                message: "\(collector.skippedMessages) message(s) had neither a body nor an attachment "
                       + "and were not indexed."))
        }
        if collector.undated > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "ufdr.no_absolute_time",
                message: "\(collector.undated) record(s) had no time stamp with a time zone; they are "
                       + "recorded WITHOUT a timestamp rather than assuming one."))
        }
        if collector.positionalIDs > 0 {
            warnings.append(ParserWarning(severity: .warning, code: "ufdr.positional_ids",
                message: "\(collector.positionalIDs) model(s) had no `id` attribute; they are identified "
                       + "by position in the report, which is stable only for this file."))
        }
        if !collector.otherModelTypes.isEmpty {
            let breakdown = collector.otherModelTypes.sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            warnings.append(ParserWarning(severity: .info, code: "ufdr.model_types_not_mapped",
                message: "Model types present in the report but not mapped to messages, calls or "
                       + "contacts: \(breakdown)."))
        }
        return DiscussionExport(platform: platform, artifact: filename,
                                records: collector.records, warnings: warnings)
    }

    /// ISO-8601 (`2019-03-14T09:12:34.000+00:00`, with or without fractions) or the
    /// older Reader form `3/14/2019 9:12:34 AM(UTC+0)`. A time with no zone → nil.
    nonisolated static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        // "3/14/2019 9:12:34 AM(UTC+0)" / "(UTC-5)" / "(UTC+5:30)".
        guard let open = trimmed.range(of: "(UTC", options: .backwards),
              let close = trimmed[open.upperBound...].firstIndex(of: ")") else { return nil }
        let local = trimmed[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        let offsetText = trimmed[open.upperBound..<close]
        guard let first = offsetText.first, first == "+" || first == "-" else { return nil }
        let parts = offsetText.dropFirst().split(separator: ":")
        guard let hours = parts.first.flatMap({ Int($0) }) else { return nil }
        let minutes = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let seconds = (hours * 3600 + minutes * 60) * (first == "-" ? -1 : 1)
        guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        // US month-first only: that is how Reader writes this form. A day-first
        // guess would silently swap day and month for the first twelve days.
        for format in ["M/d/yyyy h:mm:ss a", "M/d/yyyy H:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: local) { return date }
        }
        return nil
    }
}

// MARK: - SAX collector

/// One element of the model currently being read. Held only until its top-level
/// model closes.
private nonisolated final class UFDRNode {
    let name: String
    let attributes: [String: String]
    var children: [UFDRNode] = []
    var text = ""
    /// Messages converted and detached as they closed (Chat models only).
    var detachedMessages: [UFDRMessage] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var modelType: String? { name == "model" ? attributes["type"] : nil }

    /// `<field name="X"><value>…</value></field>` → the first non-empty value text.
    func field(_ fieldName: String) -> String? {
        for child in children where child.name == "field" && child.attributes["name"] == fieldName {
            let values = child.children.filter { $0.name == "value" }.map(\.trimmedText)
            if let value = values.first(where: { !$0.isEmpty }) { return value }
            let own = child.trimmedText
            if !own.isEmpty { return own }
        }
        return nil
    }

    /// `<modelField name="X"><model …/></modelField>` → that model.
    func modelField(_ fieldName: String) -> UFDRNode? {
        children.first { $0.name == "modelField" && $0.attributes["name"] == fieldName }?
            .children.first { $0.name == "model" }
    }

    /// `<multiModelField name="X"><model/>…</multiModelField>` → its models.
    func multiModelField(_ fieldName: String) -> [UFDRNode] {
        children.filter { $0.name == "multiModelField" && $0.attributes["name"] == fieldName }
            .flatMap { $0.children.filter { $0.name == "model" } }
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A Party (sender, recipient, call participant).
private nonisolated struct UFDRParty {
    let name: String?
    let identifier: String?
    let role: String?
    let isOwner: Bool

    init(_ node: UFDRNode) {
        name = node.field("Name")
        identifier = node.field("Identifier")
        role = node.field("Role")
        isOwner = (node.field("IsPhoneOwner") ?? "").lowercased() == "true"
    }

    var handle: String? { name ?? identifier }

    var described: String? {
        switch (name, identifier) {
        case let (n?, i?) where n != i: return "\(n) (\(i))"
        case let (n?, _): return n
        case let (nil, i?): return i
        default: return nil
        }
    }
}

/// A message reduced to what a record needs, so its node tree can be dropped.
private nonisolated struct UFDRMessage {
    let id: String?
    let timestamp: String?
    let body: String
    let sender: UFDRParty?
    let source: String?
    let deletedState: String?
}

private nonisolated final class UFDRReportCollector: NSObject, XMLParserDelegate {
    let platform: String
    private(set) var records: [DiscussionRecord] = []
    private(set) var skippedMessages = 0
    private(set) var undated = 0
    private(set) var positionalIDs = 0
    private(set) var otherModelTypes: [String: Int] = [:]
    private(set) var sawDecodedData = false

    private var decodedDataDepth = 0
    /// `type` of each open `<modelType>`.
    private var modelTypeStack: [String] = []
    /// Open elements of the model being read; empty outside a top-level model.
    private var stack: [UFDRNode] = []
    private var topLevelOrdinal = 0
    private var callOrdinal = 0
    private var contactOrdinal = 0

    private static let messageModelTypes: Set<String> = ["InstantMessage", "SMS", "MMS", "Message"]

    init(platform: String) { self.platform = platform }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "decodedData" { decodedDataDepth += 1; sawDecodedData = true; return }
        guard decodedDataDepth > 0 else { return }
        if stack.isEmpty {
            if elementName == "modelType" {
                modelTypeStack.append(attributeDict["type"] ?? "")
            } else if elementName == "model", !modelTypeStack.isEmpty {
                stack.append(UFDRNode(name: elementName, attributes: attributeDict))
            }
            return
        }
        stack.append(UFDRNode(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "decodedData" { decodedDataDepth = max(0, decodedDataDepth - 1); return }
        guard decodedDataDepth > 0 else { return }
        guard let node = stack.popLast() else {
            if elementName == "modelType", !modelTypeStack.isEmpty { modelTypeStack.removeLast() }
            return
        }
        guard let parent = stack.last else {
            topLevel(node, sectionType: modelTypeStack.last ?? "")
            return
        }
        // A message inside a chat's Messages field: convert now, keep nothing else.
        if let type = node.modelType, Self.messageModelTypes.contains(type),
           parent.name == "multiModelField", parent.attributes["name"] == "Messages",
           stack.count >= 2, stack[stack.count - 2].modelType == "Chat" {
            stack[stack.count - 2].detachedMessages.append(Self.message(from: node, chatSource: nil))
            return
        }
        parent.children.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    // MARK: - Top-level models

    private func topLevel(_ node: UFDRNode, sectionType: String) {
        topLevelOrdinal += 1
        let type = node.modelType ?? sectionType
        switch type {
        case "Chat": chat(node)
        case _ where Self.messageModelTypes.contains(type): looseMessage(node, type: type)
        case "Call": call(node)
        case "Contact": contact(node)
        default: otherModelTypes[type.isEmpty ? "(untyped)" : type, default: 0] += 1
        }
    }

    private func chat(_ node: UFDRNode) {
        let source = node.field("Source")
        let chatID = node.attributes["id"] ?? {
            positionalIDs += 1
            return "chat-\(topLevelOrdinal)"
        }()
        let threadID = "chat:\(chatID)"
        let participants = node.multiModelField("Participants").map(UFDRParty.init)
        let label = node.field("Name")
            ?? node.field("Subject")
            ?? {
                let names = participants.compactMap(\.handle)
                return names.isEmpty ? nil : names.joined(separator: ", ")
            }()
            ?? chatID
        let title = "\(source ?? "Chat") chat — \(label)"

        // Messages that were NOT detached (e.g. a schema variant with no Messages
        // field wrapper) are still read from the tree.
        let messages = node.detachedMessages
            + node.children.filter { $0.name == "model" && Self.messageModelTypes.contains($0.modelType ?? "") }
                .map { Self.message(from: $0, chatSource: source) }

        for (index, message) in messages.enumerated() {
            // The app is already in the thread title; repeating it per line is noise.
            append(message, index: index, threadID: threadID, title: title,
                   sourceLabel: nil, kind: .directMessage)
        }
    }

    /// A top-level SMS / InstantMessage: grouped by app and counterpart, because a
    /// conversation is the unit a person asks about.
    private func looseMessage(_ node: UFDRNode, type: String) {
        let message = Self.message(from: node, chatSource: nil)
        let parties = node.multiModelField("Parties").map(UFDRParty.init)
            + node.multiModelField("To").map(UFDRParty.init)
        let folder = (node.field("Folder") ?? "").lowercased()
        let outgoing = folder.contains("sent") || folder.contains("outbox")
            || (message.sender?.isOwner ?? false)
        let counterpart: UFDRParty? = outgoing
            ? parties.first { ($0.role ?? "").lowercased() != "from" && !$0.isOwner }
            : (message.sender ?? parties.first { !$0.isOwner })
        let app = message.source ?? (type == "InstantMessage" ? "Messages" : type)
        let who = counterpart?.identifier ?? counterpart?.name ?? "unknown counterpart"
        let threadID = "\(type.lowercased()):\(app):\(who)"
        let title = "\(app) \(type == "InstantMessage" ? "messages" : type) — \(counterpart?.described ?? who)"
        append(message, index: topLevelOrdinal, threadID: threadID, title: title,
               sourceLabel: nil, kind: .directMessage)
    }

    private func append(_ message: UFDRMessage, index: Int, threadID: String, title: String,
                        sourceLabel: String?, kind: DiscussionRecord.Kind) {
        guard !message.body.isEmpty else { skippedMessages += 1; return }
        let id: String = message.id ?? {
            positionalIDs += 1
            return "pos\(index + 1)"
        }()
        let date = message.timestamp.flatMap(CellebriteReportMapper.parseTimestamp)
        if date == nil { undated += 1 }
        var body = message.body
        if let sourceLabel { body = "[\(sourceLabel)] " + body }
        if let state = message.deletedState, state.lowercased() != "intact" {
            body += " [record state: \(state)]"
        }
        records.append(DiscussionRecord(
            platform: platform, kind: kind,
            recordID: "\(threadID)#\(id)",
            threadID: threadID, threadTitle: title,
            authorHandle: message.sender?.handle,
            authorID: message.sender?.identifier,
            timestamp: date, body: body, permalink: nil))
    }

    private func call(_ node: UFDRNode) {
        callOrdinal += 1
        let parties = node.multiModelField("Parties").map(UFDRParty.init)
        let direction = node.field("Type") ?? node.field("Direction")
        let from = parties.first { ($0.role ?? "").lowercased() == "from" }
        let others = parties.filter { ($0.role ?? "").lowercased() != "from" }
        var body = "\(direction.map { "\($0) call" } ?? "Call")"
        if let from = from?.described { body += " from \(from)" }
        let to = others.compactMap(\.described)
        if !to.isEmpty { body += " to \(to.joined(separator: ", "))" }
        if let duration = node.field("Duration") { body += ", duration \(duration)" }
        if let status = node.field("Status") { body += ", \(status)" }
        if let video = node.field("VideoCall"), video.lowercased() == "true" { body += ", video" }
        let message = UFDRMessage(
            id: node.attributes["id"], timestamp: node.field("TimeStamp"), body: body,
            sender: from ?? (direction?.lowercased() == "incoming" ? others.first : nil),
            source: node.field("Source"), deletedState: node.attributes["deleted_state"])
        append(message, index: callOrdinal - 1, threadID: "calls", title: "Call log",
               sourceLabel: message.source, kind: .activity)
    }

    private func contact(_ node: UFDRNode) {
        contactOrdinal += 1
        let name = node.field("Name")
        var details: [String] = []
        for entry in node.multiModelField("Entries") + node.multiModelField("PhoneNumbers")
            + node.multiModelField("EmailAddresses") {
            guard let value = entry.field("Value") else { continue }
            let kind = entry.modelType ?? "Entry"
            let category = entry.field("Category").map { " (\($0))" } ?? ""
            details.append("\(kind)\(category): \(value)")
        }
        for key in ["PhoneNumber", "Email", "Account", "Company", "Notes"] {
            if let value = node.field(key) { details.append("\(key): \(value)") }
        }
        var body = "Contact: \(name ?? "(no name)")"
        if !details.isEmpty { body += " — " + details.joined(separator: "; ") }
        let message = UFDRMessage(
            id: node.attributes["id"], timestamp: node.field("TimeCreated") ?? node.field("TimeModified"),
            body: body,
            sender: nil, source: node.field("Source"), deletedState: node.attributes["deleted_state"])
        // Contacts are usually undated; that is the address book's nature, not a
        // defect, so it does not count toward the undated warning.
        let undatedBefore = undated
        append(message, index: contactOrdinal - 1, threadID: "contacts", title: "Contacts",
               sourceLabel: message.source, kind: .activity)
        if message.timestamp == nil { undated = undatedBefore }
    }

    // MARK: - Conversion

    private static func message(from node: UFDRNode, chatSource: String?) -> UFDRMessage {
        var body = node.field("Body") ?? ""
        let attachments = node.multiModelField("Attachments") + node.multiModelField("Attachment")
        for attachment in attachments {
            guard let name = attachment.field("Filename") ?? attachment.field("Name")
                    ?? attachment.field("URL") else { continue }
            body += (body.isEmpty ? "" : "\n") + "[attachment: \(name)]"
        }
        var sender = node.modelField("From").map(UFDRParty.init)
        if sender == nil {
            sender = node.multiModelField("Parties").map(UFDRParty.init)
                .first { ($0.role ?? "").lowercased() == "from" }
        }
        return UFDRMessage(
            id: node.attributes["id"],
            timestamp: node.field("TimeStamp") ?? node.field("DateSent") ?? node.field("DateRead"),
            body: body, sender: sender,
            source: node.field("Source") ?? chatSource,
            deletedState: node.attributes["deleted_state"])
    }
}

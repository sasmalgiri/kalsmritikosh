//
//  TeamsCellebriteImportTests.swift
//  KalsmritikoshTests
//
//  E-6 — two evidence importers in the discussion lane:
//    • Microsoft Teams personal/consumer export (`messages.json`): one thread per
//      conversation, one record per text message, HTML reduced to plain text,
//      non-text entries skipped AND counted.
//    • Cellebrite UFDR / UFED Reader report (`report.xml` inside a `.ufdr` ZIP or an
//      unzipped folder): one thread per chat, one call log, one contacts list,
//      parsed with a streaming XMLParser.
//  Fixtures are synthetic, written to a fresh temp directory and removed after.
//  Nothing here opens a database, the Keychain or ~/Library.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Teams + Cellebrite UFDR importers (E-6)")
@MainActor
struct TeamsCellebriteImportTests {

    // MARK: - Fixtures

    private static let teamsExport = #"""
    {"userId":"8:live:owner","exportDate":"2026-03-20T10:00:00Z","conversations":[
      {"id":"19:delta@thread.v2","displayName":"Project Delta","version":1,
       "threadProperties":{"topic":"Delta contract"},
       "MessageList":[
         {"id":"1001","displayName":"Alice Shah","originalarrivaltime":"2026-03-14T09:12:34.123Z",
          "messagetype":"RichText/Html",
          "content":"<p>Q3 &amp; Q4 numbers are <b>final</b></p><p>see&nbsp;the&#32;sheet</p>",
          "from":"8:live:alice"},
         {"id":"1002","displayName":"Bob Lee","originalarrivaltime":"2026-03-14T09:13:00Z",
          "messagetype":"Text","content":"Signed it.",
          "from":"https://client-s.gateway.messenger.live.com/v1/users/ME/contacts/8:live:bob"},
         {"id":"1003","displayName":"Bob Lee","originalarrivaltime":"2026-03-14T09:14:00Z",
          "messagetype":"Event/Call","content":"<partlist type=\"started\"/>","from":"8:live:bob"},
         {"id":"1004","originalarrivaltime":"2026-03-14T09:15:00Z",
          "messagetype":"ThreadActivity/AddMember","content":"<addmember/>"}
       ]},
      {"id":"8:live:carol","displayName":"Carol","MessageList":[
         {"id":"2001","displayName":"Carol","originalarrivaltime":"2026-03-15T08:00:00Z",
          "content":"no messagetype, still text"}
       ]}
    ]}
    """#

    private static let cellebriteReport = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <project id="p1" name="Synthetic case" reportVersion="7.0.0.0" xmlns="http://pa.cellebrite.com/report/2.0">
      <metadata section="Extraction"><metadatafield name="DeviceInfoSelectedManufacturer"><![CDATA[Synthetic]]></metadatafield></metadata>
      <decodedData>
        <modelType type="Chat">
          <model type="Chat" id="chat-1" deleted_state="Intact">
            <field name="Source" type="String"><value type="String"><![CDATA[WhatsApp]]></value></field>
            <multiModelField name="Participants" type="Party">
              <model type="Party" id="p-a"><field name="Identifier"><value>15550001@s.whatsapp.net</value></field><field name="Name"><value>Alice</value></field></model>
              <model type="Party" id="p-b"><field name="Identifier"><value>15550002@s.whatsapp.net</value></field><field name="Name"><value>Bob</value></field></model>
            </multiModelField>
            <multiModelField name="Messages" type="InstantMessage">
              <model type="InstantMessage" id="m-1" deleted_state="Intact">
                <field name="TimeStamp" type="TimeStamp"><value type="TimeStamp">2019-03-14T09:12:34.000+00:00</value></field>
                <modelField name="From" type="Party">
                  <model type="Party"><field name="Identifier"><value>15550001@s.whatsapp.net</value></field><field name="Name"><value>Alice</value></field></model>
                </modelField>
                <field name="Body" type="String"><value type="String"><![CDATA[Meet at the dock & bring the papers]]></value></field>
              </model>
              <model type="InstantMessage" id="m-2" deleted_state="Deleted">
                <field name="TimeStamp" type="TimeStamp"><value type="TimeStamp">2019-03-14T09:20:00.000+00:00</value></field>
                <modelField name="From" type="Party">
                  <model type="Party"><field name="Identifier"><value>15550002@s.whatsapp.net</value></field><field name="Name"><value>Bob</value></field></model>
                </modelField>
                <field name="Body" type="String"><value type="String">Delete this after reading</value></field>
              </model>
              <model type="InstantMessage" id="m-3" deleted_state="Intact">
                <field name="TimeStamp" type="TimeStamp"><value type="TimeStamp">2019-03-14T09:25:00</value></field>
                <modelField name="From" type="Party">
                  <model type="Party"><field name="Name"><value>Alice</value></field></model>
                </modelField>
                <multiModelField name="Attachments" type="Attachment">
                  <model type="Attachment"><field name="Filename"><value>IMG_0042.jpg</value></field></model>
                </multiModelField>
              </model>
            </multiModelField>
          </model>
        </modelType>
        <modelType type="SMS">
          <model type="SMS" id="sms-1" deleted_state="Intact">
            <field name="Source"><value>Native Messages</value></field>
            <field name="TimeStamp"><value>2019-03-15T10:00:00.000-05:00</value></field>
            <field name="Folder"><value>Inbox</value></field>
            <field name="Body"><value>Payment received</value></field>
            <multiModelField name="Parties" type="Party">
              <model type="Party"><field name="Identifier"><value>+15550003</value></field><field name="Name"><value>Carol</value></field><field name="Role"><value>From</value></field></model>
            </multiModelField>
          </model>
        </modelType>
        <modelType type="Call">
          <model type="Call" id="call-1" deleted_state="Intact">
            <field name="Source"><value>Phone</value></field>
            <field name="Type"><value>Outgoing</value></field>
            <field name="TimeStamp"><value>2019-03-14T11:00:00.000+00:00</value></field>
            <field name="Duration"><value>00:01:23</value></field>
            <multiModelField name="Parties" type="Party">
              <model type="Party"><field name="Identifier"><value>+15550002</value></field><field name="Name"><value>Bob</value></field><field name="Role"><value>To</value></field></model>
            </multiModelField>
          </model>
        </modelType>
        <modelType type="Contact">
          <model type="Contact" id="contact-1" deleted_state="Intact">
            <field name="Name"><value>Bob Lee</value></field>
            <field name="Source"><value>Contacts</value></field>
            <multiModelField name="Entries" type="ContactEntry">
              <model type="PhoneNumber"><field name="Category"><value>Mobile</value></field><field name="Value"><value>+15550002</value></field></model>
            </multiModelField>
          </model>
        </modelType>
        <modelType type="Location">
          <model type="Location" id="loc-1"><field name="Name"><value>Dock</value></field></model>
        </modelType>
      </decodedData>
    </project>
    """#

    // MARK: - Helpers

    /// A fresh temp directory, removed by the caller's `defer`.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e6-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func parse(_ text: String, _ filename: String) async throws -> ParsedDocument {
        try await DiscussionStructuralParser().parse(
            data: Data(text.utf8), filename: filename, type: .discussionExport,
            logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func messages(_ doc: ParsedDocument) -> [EvidenceBlock] {
        doc.blocks.filter { $0.kind == .discussionMessage }
    }

    private func attribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let v)? = block.attributes[key]?.value { return v }
        return nil
    }

    // MARK: - Teams

    @Test("Teams: one thread per conversation, one block per text message")
    func teamsConversationsAndMessages() async throws {
        let doc = try await parse(Self.teamsExport, "messages.json")
        #expect(messages(doc).count == 3)
        let headings = doc.blocks.filter { $0.kind == .sectionHeading }.map(\.rawText)
        #expect(headings.count == 2)
        #expect(headings.contains { $0.contains("Microsoft Teams — Delta contract") })
        #expect(headings.contains { $0.contains("Carol") })
    }

    @Test("Teams: HTML content becomes plain text with entities decoded")
    func teamsHTMLIsStripped() async throws {
        let doc = try await parse(Self.teamsExport, "messages.json")
        let block = try #require(messages(doc).first { $0.rawText.contains("Q3") })
        #expect(block.rawText.contains("Q3 & Q4 numbers are final"))
        #expect(block.rawText.contains("see the sheet"))
        #expect(!block.rawText.contains("<p>"))
        #expect(!block.rawText.contains("&amp;"))
        #expect(TeamsExportMapper.plainText(fromHTML: "a<br/>b &lt;c&gt;") == "a\nb <c>")
    }

    @Test("Teams: sender, account id and arrival time are kept")
    func teamsAttribution() async throws {
        let doc = try await parse(Self.teamsExport, "messages.json")
        let alice = try #require(messages(doc).first { $0.rawText.contains("Q3") })
        #expect(attribute(alice, "authorHandle") == "Alice Shah")
        #expect(attribute(alice, "authorID") == "8:live:alice")
        #expect(attribute(alice, "timestamp") == "2026-03-14T09:12:34Z")
        // The contacts-URL form of `from` is reduced to the account id.
        let bob = try #require(messages(doc).first { $0.rawText.contains("Signed it.") })
        #expect(attribute(bob, "authorID") == "8:live:bob")
    }

    @Test("Teams: non-text entries are skipped and counted, never silently")
    func teamsNonTextCounted() async throws {
        let doc = try await parse(Self.teamsExport, "messages.json")
        #expect(!messages(doc).contains { $0.rawText.contains("partlist") })
        let warning = try #require(doc.warnings.first { $0.code == "teams.non_text_skipped" })
        #expect(warning.message.contains("2 non-text"))
        #expect(warning.message.contains("Event/Call ×1"))
        #expect(warning.message.contains("ThreadActivity/AddMember ×1"))
        // A message with no messagetype but real content is still read.
        #expect(messages(doc).contains { $0.rawText.contains("no messagetype, still text") })
    }

    @Test("Teams: an array-of-conversations root is accepted, missing fields tolerated")
    func teamsArrayRoot() {
        let array = #"[{"MessageList":[{"content":"hello"}]}]"#
        let export = TeamsExportMapper().map(data: Data(array.utf8), filename: "messages.json")
        #expect(export.records.count == 1)
        #expect(export.records.first?.body == "hello")
        #expect(export.records.first?.timestamp == nil)
        #expect(export.warnings.contains { $0.code == "teams.no_time" })
        #expect(export.warnings.contains { $0.code == "teams.positional_ids" })
    }

    @Test("Teams: the loader yields one KnowledgeObject per conversation")
    func teamsLoaderOneObjectPerConversation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("messages.json")
        try Data(Self.teamsExport.utf8).write(to: url)
        let objects = try await DiscussionExportLoader().ingestMany(fileAt: url, type: .discussionExport)
        #expect(objects.count == 2)
        #expect(objects.contains { $0.content.contains("Delta contract") && $0.content.contains("Alice Shah") })
    }

    @Test("Teams: a loose messages.json routes to the discussion lane at intake; plain JSON does not")
    func teamsIntakeRouting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let teams = dir.appendingPathComponent("messages.json")
        try Data(Self.teamsExport.utf8).write(to: teams)
        let routed = try SourceByteCapture.capture(teams)
        #expect(routed.detectedType == .discussionExport)
        #expect(routed.detectionBasis == .structuralProbe)

        // Same name, unrelated content: stays JSON.
        let other = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let plain = other.appendingPathComponent("messages.json")
        try Data(#"{"messages":["a","b"]}"#.utf8).write(to: plain)
        #expect(try SourceByteCapture.capture(plain).detectedType == .json)

        // Teams content under another name: stays JSON (the name gate is part of the rule).
        let renamed = dir.appendingPathComponent("export.json")
        try Data(Self.teamsExport.utf8).write(to: renamed)
        #expect(try SourceByteCapture.capture(renamed).detectedType == .json)
    }

    // MARK: - Cellebrite UFDR

    @Test("UFDR: one thread per chat, sender and timestamp per message")
    func ufdrChatMessages() async throws {
        let doc = try await parse(Self.cellebriteReport, "report.xml")
        let chat = messages(doc).filter { (attribute($0, "recordID") ?? "").hasPrefix("chat:chat-1#") }
        #expect(chat.count == 3)
        let first = try #require(chat.first { $0.rawText.contains("Meet at the dock") })
        #expect(attribute(first, "authorHandle") == "Alice")
        #expect(attribute(first, "authorID") == "15550001@s.whatsapp.net")
        #expect(attribute(first, "timestamp") == "2019-03-14T09:12:34Z")
        #expect(first.rawText.contains("Meet at the dock & bring the papers"))
        let headings = doc.blocks.filter { $0.kind == .sectionHeading }.map(\.rawText)
        #expect(headings.contains { $0.contains("WhatsApp chat — Alice, Bob") })
    }

    @Test("UFDR: a deleted record says so, an attachment-only message is kept")
    func ufdrDeletedAndAttachments() async throws {
        let doc = try await parse(Self.cellebriteReport, "report.xml")
        let deleted = try #require(messages(doc).first { $0.rawText.contains("Delete this after reading") })
        #expect(deleted.rawText.contains("[record state: Deleted]"))
        #expect(messages(doc).contains { $0.rawText.contains("[attachment: IMG_0042.jpg]") })
    }

    @Test("UFDR: a zone-less time stamp is recorded undated, and the warning says so")
    func ufdrZonelessTimeNotGuessed() async throws {
        let doc = try await parse(Self.cellebriteReport, "report.xml")
        let attachment = try #require(messages(doc).first { $0.rawText.contains("IMG_0042.jpg") })
        #expect(attachment.attributes["timestamp"] == nil)
        let warning = try #require(doc.warnings.first { $0.code == "ufdr.no_absolute_time" })
        #expect(warning.message.contains("1 record(s)"))
        #expect(CellebriteReportMapper.parseTimestamp("3/14/2019 9:12:34 AM(UTC+0)")
                == CellebriteReportMapper.parseTimestamp("2019-03-14T09:12:34Z"))
        #expect(CellebriteReportMapper.parseTimestamp("2019-03-14T09:12:34") == nil)
    }

    @Test("UFDR: one call-log thread and one contacts thread")
    func ufdrCallsAndContacts() async throws {
        let export = CellebriteReportMapper().map(data: Data(Self.cellebriteReport.utf8), filename: "report.xml")
        let calls = export.records.filter { $0.threadID == "calls" }
        #expect(calls.count == 1)
        #expect(calls.first?.kind == .activity)
        #expect(calls.first?.body.contains("Outgoing call to Bob (+15550002), duration 00:01:23") == true)
        #expect(calls.first?.threadTitle == "Call log")
        let contacts = export.records.filter { $0.threadID == "contacts" }
        #expect(contacts.count == 1)
        #expect(contacts.first?.body.contains("Contact: Bob Lee") == true)
        #expect(contacts.first?.body.contains("PhoneNumber (Mobile): +15550002") == true)
    }

    @Test("UFDR: a top-level SMS is threaded by its counterpart; unmapped model types are counted")
    func ufdrLooseSMSAndOtherTypes() {
        let export = CellebriteReportMapper().map(data: Data(Self.cellebriteReport.utf8), filename: "report.xml")
        let sms = export.records.filter { $0.body.contains("Payment received") }
        #expect(sms.count == 1)
        #expect(sms.first?.authorHandle == "Carol")
        #expect(sms.first?.threadID == "sms:Native Messages:+15550003")
        let other = export.warnings.first { $0.code == "ufdr.model_types_not_mapped" }
        #expect(other?.message.contains("Location ×1") == true)
    }

    @Test("UFDR: a malformed report keeps what was read and says where it stopped")
    func ufdrMalformedReport() {
        // Cut the report off inside the SMS section: the chat before it closed cleanly.
        let head = Self.cellebriteReport.components(separatedBy: "<modelType type=\"SMS\">")[0]
        let truncated = head + "<modelType type=\"SMS\"><model type=\"SMS\" id=\"x\">"
        let export = CellebriteReportMapper().map(data: Data(truncated.utf8), filename: "report.xml")
        #expect(export.records.count == 3)
        #expect(export.warnings.contains { $0.code == "ufdr.malformed_xml" })
    }

    @Test("UFDR: a .ufdr is a ZIP container whose report.xml the ZIP reader reaches")
    func ufdrZipContainer() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ufdr = dir.appendingPathComponent("phone.ufdr")
        try ZIPTestFixture.build([
            ZIPTestFixture.deflated("report.xml", Self.cellebriteReport),
            ZIPTestFixture.stored("files/Image/IMG_0042.jpg", "not really a jpeg")
        ]).write(to: ufdr)

        // Intake: ZIP magic + the .ufdr extension → an expandable ZIP container.
        #expect(SourceType.detect(from: ufdr) == .zip)
        #expect(try SourceByteCapture.capture(ufdr).detectedType == .zip)
        #expect(ContainerProcessingCoordinator.isExpandableZip(fileURL: ufdr, originName: "phone.ufdr"))

        // The container reader reaches report.xml, which maps as the report.
        let report = try ZIPReader(url: ufdr).read("report.xml")
        let export = CellebriteReportMapper().map(data: report, filename: "report.xml")
        #expect(export.records.filter { ($0.threadID ?? "").hasPrefix("chat:") }.count == 3)
    }

    @Test("UFDR: an unzipped report folder's report.xml routes to the discussion lane at intake")
    func ufdrUnzippedFolderRouting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("report.xml")
        try Data(Self.cellebriteReport.utf8).write(to: report)
        let captured = try SourceByteCapture.capture(report)
        #expect(captured.detectedType == .discussionExport)
        #expect(captured.detectionBasis == .structuralProbe)

        // An ordinary XML file of the same name stays XML.
        let plainDir = dir.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        let plain = plainDir.appendingPathComponent("report.xml")
        try Data(#"<?xml version="1.0"?><report><title>Q3</title></report>"#.utf8).write(to: plain)
        #expect(try SourceByteCapture.capture(plain).detectedType == .xml)
    }

    // MARK: - Registry

    @Test("Each new export is claimed by exactly one mapper")
    func registryIsDisjoint() {
        let registry = DiscussionExportRegistry.standard
        let samples: [(String, String, String)] = [
            ("messages.json", Self.teamsExport, "Microsoft Teams"),
            ("report.xml", Self.cellebriteReport, "Cellebrite UFDR")
        ]
        for (filename, text, platform) in samples {
            let sample = Data(text.utf8).prefix(DiscussionExportRegistry.sampleSize)
            let claimants = registry.allMappers.filter { $0.claims(filename: filename, sample: sample) }
            #expect(claimants.map(\.platform) == [platform],
                    "\(filename) claimed by \(claimants.map(\.platform))")
        }
    }
}

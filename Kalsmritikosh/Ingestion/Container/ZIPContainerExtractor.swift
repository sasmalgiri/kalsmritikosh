//
//  ZIPContainerExtractor.swift
//  Kalsmritikosh
//
//  USF-M2 (USF-006 §8/§9) — bounded, STREAMING member extraction + correct path-traversal handling.
//  A member is inflated CHUNK-BY-CHUNK to a temp file with a running uncompressed-byte cap, so a
//  potentially 1 GiB member is never materialized as one `Data`. Path safety normalizes components and
//  rejects only ACTUAL traversal/escape (a filename that merely CONTAINS ".." is legitimate). The
//  whole-member `ZIPReader.extract` API stays for small loader parts (DOCX/PPTX), never for expansion.
//

import Foundation
import Compression

public enum ZIPContainerExtractor {

    /// How a raw ZIP member path resolves for safe extraction.
    public nonisolated enum PathClassification: Sendable, Equatable {
        case directory                       // a directory marker (name ends with "/")
        case file(normalized: String)        // a safe relative file path
        case unsafe(reason: String)          // absolute / traversal / NUL / empty
    }

    /// Why a streamed extraction stopped short of success.
    public nonisolated enum ExtractionFailure: Error, Sendable, Equatable {
        case exceededCap            // member exceeded the per-member byte cap → blockedSizeLimit
        case unsupportedCompression // method other than STORED/DEFLATE → unsupported
        case decompressionFailed    // corrupt/undecodable payload → failedExtraction
        case unreadable             // could not open the destination / payload → failedExtraction
    }

    // MARK: - Path safety (§9)

    /// Normalize a member path and classify it. Rejects ONLY genuine escape conditions; a component
    /// literally named with dots inside a filename (e.g. "a..b.txt") is fine — only a path COMPONENT
    /// equal to ".." is traversal.
    public nonisolated static func classifyPath(_ raw: String) -> PathClassification {
        if raw.contains("\u{0}") { return .unsafe(reason: "NUL byte in path") }
        // Windows-authored zips can use backslashes; treat them as separators for safety analysis.
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        let isDirectory = unified.hasSuffix("/")
        if unified.hasPrefix("/") { return .unsafe(reason: "absolute path") }
        // A Windows drive letter (e.g. "C:...") is an absolute escape.
        if unified.count >= 2, unified[unified.index(unified.startIndex, offsetBy: 1)] == ":" {
            return .unsafe(reason: "drive-letter path")
        }
        var safe: [String] = []
        for component in unified.split(separator: "/", omittingEmptySubsequences: true) {
            let c = String(component)
            if c == "." { continue }
            if c == ".." { return .unsafe(reason: "parent-directory traversal") }
            safe.append(c)
        }
        if safe.isEmpty { return isDirectory ? .directory : .unsafe(reason: "empty path") }
        if isDirectory { return .directory }
        return .file(normalized: safe.joined(separator: "/"))
    }

    /// Whether a destination URL stays inside the extraction root once canonicalized (defense in depth
    /// against symlink/`..` escapes that survived normalization).
    public nonisolated static func isContained(_ destination: URL, inRoot root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path + "/"
        return destination.standardizedFileURL.path.hasPrefix(rootPath)
    }

    // MARK: - Streaming extraction (§8)

    /// Stream ONE entry's bytes to `destURL`, enforcing the per-member cap. Returns the uncompressed
    /// bytes written. STORED members are copied in windows; DEFLATE members are inflated chunk-by-chunk
    /// with the output (never the whole member) bounded. Throws `ExtractionFailure` on cap/format/corrupt.
    @discardableResult
    public nonisolated static func streamExtract(reader: ZIPReader, entry: ZIPEntry, to destURL: URL,
                                                 maxMemberBytes: Int64) throws -> Int64 {
        let range = try reader.payloadRange(for: entry)
        let backing = reader.backingData
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: destURL) else { throw ExtractionFailure.unreadable }
        defer { try? out.close() }

        switch entry.compressionMethod {
        case 0:   // STORED — copy the payload in bounded windows.
            var written: Int64 = 0
            let window = 1 << 18
            var pos = range.lowerBound
            while pos < range.upperBound {
                let end = min(pos + window, range.upperBound)
                let slice = backing.subdata(in: pos..<end)
                written += Int64(slice.count)
                if written > maxMemberBytes { throw ExtractionFailure.exceededCap }
                try out.write(contentsOf: slice)
                pos = end
            }
            return written
        case 8:   // DEFLATE — streaming inflate with a bounded output buffer.
            return try streamInflate(compressed: backing.subdata(in: range), to: out, maxMemberBytes: maxMemberBytes)
        default:
            throw ExtractionFailure.unsupportedCompression
        }
    }

    /// Streaming raw-DEFLATE inflate: the compressed payload (small) is fed in one shot, but the
    /// OUTPUT is produced into a fixed 256 KiB buffer and flushed to disk, so the uncompressed member
    /// is never held in memory. The running cap aborts a decompression bomb early.
    private nonisolated static func streamInflate(compressed: Data, to out: FileHandle, maxMemberBytes: Int64) throws -> Int64 {
        let dstCap = 1 << 18
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: dstCap,
                                        src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ExtractionFailure.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var written: Int64 = 0
        do {
            try compressed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                stream.src_ptr = base ?? UnsafePointer(dst)
                stream.src_size = raw.count
                var status = COMPRESSION_STATUS_OK
                repeat {
                    stream.dst_ptr = dst
                    stream.dst_size = dstCap
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = dstCap - stream.dst_size
                    if produced > 0 {
                        written += Int64(produced)
                        if written > maxMemberBytes { throw ExtractionFailure.exceededCap }
                        out.write(Data(bytes: dst, count: produced))
                    }
                    if status == COMPRESSION_STATUS_ERROR { throw ExtractionFailure.decompressionFailed }
                } while status == COMPRESSION_STATUS_OK
            }
        } catch let f as ExtractionFailure {
            throw f
        } catch {
            throw ExtractionFailure.decompressionFailed
        }
        return written
    }
}

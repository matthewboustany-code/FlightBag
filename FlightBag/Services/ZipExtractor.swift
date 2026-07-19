import Foundation
import Compression

/// Minimal zip reader for plate bundles (`plates_{region}_{cycle}.zip`).
///
/// iOS has no first-party zip-container API (Compression handles raw
/// streams, AppleArchive handles .aar), and the bundles are our own
/// server's `zip -r` output — classic central-directory zips of stored or
/// deflated PDFs. Zip64 (>4 GB or >65k entries) is rejected rather than
/// parsed; the bundler would have to produce one for that to matter.
nonisolated enum ZipExtractor {
    struct ZipError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    struct Entry {
        let path: String
        let compressionMethod: UInt16    // 0 = stored, 8 = deflate
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    /// Extracts every entry into `destination`, creating directories as
    /// needed. Returns the top-level directory names extracted (for plate
    /// bundles: the airport ids), so callers can track what a bundle owns.
    @discardableResult
    static func extract(zipAt zipURL: URL, to destination: URL) throws -> Set<String> {
        let data = try Data(contentsOf: zipURL, options: .alwaysMapped)
        let entries = try centralDirectory(in: data)
        var topLevel: Set<String> = []

        for entry in entries {
            // Zip paths are archive-relative; refuse anything that could
            // escape the destination.
            guard !entry.path.hasPrefix("/"), !entry.path.contains("..") else {
                throw ZipError("Unsafe path in zip: \(entry.path)")
            }
            if let first = entry.path.split(separator: "/").first {
                topLevel.insert(String(first))
            }
            let target = destination.appendingPathComponent(entry.path)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = try contents(of: entry, in: data)
            try contents.write(to: target, options: .atomic)
        }
        return topLevel
    }

    // MARK: Parsing

    private static func contents(of entry: Entry, in data: Data) throws -> Data {
        // Local header: 30 fixed bytes + name + extra field (whose lengths
        // can differ from the central directory's copies).
        let offset = Int(entry.localHeaderOffset)
        guard read32(data, offset) == 0x04034b50 else {
            throw ZipError("Bad local header for \(entry.path)")
        }
        let nameLength = Int(read16(data, offset + 26))
        let extraLength = Int(read16(data, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        guard start + Int(entry.compressedSize) <= data.count else {
            throw ZipError("Truncated data for \(entry.path)")
        }
        let compressed = data.subdata(in: start ..< start + Int(entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError("Unsupported compression method \(entry.compressionMethod) for \(entry.path)")
        }
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { outBuffer in
            compressed.withUnsafeBytes { inBuffer in
                compression_decode_buffer(
                    outBuffer.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    inBuffer.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else {
            throw ZipError("Inflate produced \(written) of \(expectedSize) bytes")
        }
        return output
    }

    private static func centralDirectory(in data: Data) throws -> [Entry] {
        // End-of-central-directory record: scan back for its signature
        // (the record has a variable-length trailing comment).
        let eocdSignature: UInt32 = 0x06054b50
        let minEOCD = 22
        guard data.count >= minEOCD else { throw ZipError("Not a zip file") }
        var eocdOffset = -1
        let scanFloor = max(0, data.count - minEOCD - 65_535)
        var cursor = data.count - minEOCD
        while cursor >= scanFloor {
            if read32(data, cursor) == eocdSignature {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError("No end-of-central-directory record") }

        let entryCount = Int(read16(data, eocdOffset + 10))
        let directoryOffset = Int(read32(data, eocdOffset + 16))
        guard entryCount != 0xFFFF, directoryOffset != 0xFFFF_FFFF else {
            throw ZipError("Zip64 archives are not supported")
        }

        var entries: [Entry] = []
        var position = directoryOffset
        for _ in 0..<entryCount {
            guard read32(data, position) == 0x02014b50 else {
                throw ZipError("Bad central-directory entry")
            }
            let method = read16(data, position + 10)
            let compressedSize = read32(data, position + 20)
            let uncompressedSize = read32(data, position + 24)
            let nameLength = Int(read16(data, position + 28))
            let extraLength = Int(read16(data, position + 30))
            let commentLength = Int(read16(data, position + 32))
            let localOffset = read32(data, position + 42)
            guard compressedSize != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw ZipError("Zip64 entries are not supported")
            }
            let nameData = data.subdata(in: position + 46 ..< position + 46 + nameLength)
            let name = String(decoding: nameData, as: UTF8.self)
            entries.append(Entry(
                path: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            position += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(read16(data, offset)) | UInt32(read16(data, offset + 2)) << 16
    }
}

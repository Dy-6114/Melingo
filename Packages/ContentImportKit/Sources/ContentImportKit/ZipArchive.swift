import Foundation
import zlib

/// Minimal ZIP reader for EPUB/DOCX (stored + deflate entries).
enum ZipArchive {
    struct Entry: Sendable {
        var name: String
        var compressionMethod: UInt16
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var localHeaderOffset: UInt32
    }

    static func entries(in data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.truncated }
        // Find End of Central Directory (EOCD) signature 0x06054b50
        var eocd = data.count - 22
        while eocd >= 0 {
            if data.u32LE(at: eocd) == 0x0605_4b50 { break }
            eocd -= 1
        }
        guard eocd >= 0, data.u32LE(at: eocd) == 0x0605_4b50 else {
            throw ZipError.invalidCentralDirectory
        }

        let entryCount = Int(data.u16LE(at: eocd + 10))
        let centralOffset = Int(data.u32LE(at: eocd + 16))
        var offset = centralOffset
        var result: [Entry] = []
        result.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, data.u32LE(at: offset) == 0x0201_4b50 else {
                throw ZipError.invalidCentralDirectory
            }
            let method = data.u16LE(at: offset + 10)
            let compSize = data.u32LE(at: offset + 20)
            let uncompSize = data.u32LE(at: offset + 24)
            let nameLen = Int(data.u16LE(at: offset + 28))
            let extraLen = Int(data.u16LE(at: offset + 30))
            let commentLen = Int(data.u16LE(at: offset + 32))
            let localOffset = data.u32LE(at: offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLen <= data.count,
                  let name = String(
                    data: data.subdata(in: nameStart..<(nameStart + nameLen)),
                    encoding: .utf8
                  )
            else { throw ZipError.invalidCentralDirectory }

            result.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset
            ))
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    static func data(for entry: Entry, in archive: Data) throws -> Data {
        let local = Int(entry.localHeaderOffset)
        guard local + 30 <= archive.count, archive.u32LE(at: local) == 0x0403_4b50 else {
            throw ZipError.invalidLocalHeader
        }
        let nameLen = Int(archive.u16LE(at: local + 26))
        let extraLen = Int(archive.u16LE(at: local + 28))
        let dataStart = local + 30 + nameLen + extraLen
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= archive.count else { throw ZipError.truncated }

        let compressed = archive.subdata(in: dataStart..<dataEnd)
        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflateRaw(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    static func entryData(named name: String, in archive: Data) throws -> Data {
        let all = try entries(in: archive)
        let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let entry = all.first(where: {
            $0.name == name
                || $0.name == normalized
                || $0.name.hasSuffix("/\(normalized)")
        }) else { throw ZipError.missingEntry(name) }
        return try data(for: entry, in: archive)
    }

    /// ZIP uses raw DEFLATE (RFC 1951); zlib windowBits = -15.
    private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        var status = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw ZipError.inflateFailed }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunk = max(expectedSize, 64 * 1024)
        var buffer = [UInt8](repeating: 0, count: chunk)

        try input.withUnsafeBytes { srcBuf in
            guard let src = srcBuf.bindMemory(to: UInt8.self).baseAddress else {
                throw ZipError.inflateFailed
            }
            stream.next_in = UnsafeMutablePointer(mutating: src)
            stream.avail_in = uInt(input.count)

            repeat {
                let capacity = buffer.count
                try buffer.withUnsafeMutableBytes { destBuf in
                    guard let dest = destBuf.bindMemory(to: UInt8.self).baseAddress else {
                        throw ZipError.inflateFailed
                    }
                    stream.next_out = dest
                    stream.avail_out = uInt(capacity)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw ZipError.inflateFailed
                    }
                    let produced = capacity - Int(stream.avail_out)
                    output.append(dest, count: produced)
                }
            } while status != Z_STREAM_END
        }
        return output
    }

    enum ZipError: Error, Equatable {
        case truncated
        case invalidCentralDirectory
        case invalidLocalHeader
        case unsupportedCompression(UInt16)
        case missingEntry(String)
        case inflateFailed
    }
}

private extension Data {
    func u16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

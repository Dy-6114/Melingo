import Foundation

/// Builds ZIP archives with stored (uncompressed) entries — for fixtures/tests only.
enum ZipBuilder {
    static func build(entries: [(name: String, data: Data)]) -> Data {
        var localFiles = Data()
        var central = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let offset = UInt32(localFiles.count)
            offsets.append(offset)

            // Local file header
            localFiles.appendU32(0x0403_4b50)
            localFiles.appendU16(20) // version needed
            localFiles.appendU16(0) // flags
            localFiles.appendU16(0) // method = store
            localFiles.appendU16(0) // time
            localFiles.appendU16(0) // date
            localFiles.appendU32(crc32(entry.data))
            localFiles.appendU32(UInt32(entry.data.count))
            localFiles.appendU32(UInt32(entry.data.count))
            localFiles.appendU16(UInt16(nameData.count))
            localFiles.appendU16(0) // extra
            localFiles.append(nameData)
            localFiles.append(entry.data)

            // Central directory header
            central.appendU32(0x0201_4b50)
            central.appendU16(20) // version made by
            central.appendU16(20) // version needed
            central.appendU16(0)
            central.appendU16(0)
            central.appendU16(0)
            central.appendU16(0)
            central.appendU32(crc32(entry.data))
            central.appendU32(UInt32(entry.data.count))
            central.appendU32(UInt32(entry.data.count))
            central.appendU16(UInt16(nameData.count))
            central.appendU16(0) // extra
            central.appendU16(0) // comment
            central.appendU16(0) // disk
            central.appendU16(0) // int attr
            central.appendU32(0) // ext attr
            central.appendU32(offset)
            central.append(nameData)
        }

        var result = Data()
        result.append(localFiles)
        let centralOffset = UInt32(result.count)
        result.append(central)
        // EOCD
        result.appendU32(0x0605_4b50)
        result.appendU16(0)
        result.appendU16(0)
        result.appendU16(UInt16(entries.count))
        result.appendU16(UInt16(entries.count))
        result.appendU32(UInt32(central.count))
        result.appendU32(centralOffset)
        result.appendU16(0)
        return result
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

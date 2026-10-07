import Foundation

#if canImport(zlib)
import zlib
#endif

/// Small ZIP reader for EPUB ingest. Supports stored entries everywhere and
/// raw DEFLATE where the platform provides zlib. ZIP64 and split archives are unsupported.
enum MinimalZipArchive {
    struct Entry: Equatable, Sendable {
        var name: String
        var data: Data
    }

    // Bound both declared expansion and actual output before retaining it in memory.
    static let maximumEntryBytes = 64 * 1024 * 1024
    static let maximumArchiveBytes = 256 * 1024 * 1024
    private static let maximumEntries = 10_000

    enum Error: Swift.Error, Equatable, LocalizedError {
        case notAZip
        case truncated
        case invalidArchive
        case tooLarge
        case unsupportedCompression(UInt16)

        var errorDescription: String? {
            switch self {
            case .notAZip:
                return "That file is not a readable EPUB/ZIP."
            case .truncated:
                return "The EPUB archive is truncated."
            case .invalidArchive:
                return "The EPUB archive contains damaged or unsupported ZIP data."
            case .tooLarge:
                return "This EPUB exceeds the import limit: 64 MiB per file, 256 MiB in total, or 10,000 files."
            case .unsupportedCompression:
                return "This EPUB uses a compression method GenBooks cannot unpack. Paste the text instead."
            }
        }
    }

    private struct Record {
        let name: String
        let nameBytes: Data
        let flags: UInt16
        let method: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    static func entries(from archive: Data) throws -> [Entry] {
        guard archive.count <= maximumArchiveBytes else { throw Error.tooLarge }
        // Data slices can have a nonzero startIndex; ZIP offsets start at zero.
        let data = Data(archive)
        guard data.count >= 22 else { throw Error.truncated }
        guard let eocd = findEOCD(in: data) else { throw Error.notAZip }
        let count = Int(readU16(data, eocd + 10))
        guard readU16(data, eocd + 4) == 0, readU16(data, eocd + 6) == 0,
              Int(readU16(data, eocd + 8)) == count else { throw Error.invalidArchive }
        guard count <= maximumEntries else { throw Error.tooLarge }
        let centralStart = Int(readU32(data, eocd + 16))
        let centralSize = Int(readU32(data, eocd + 12))
        guard centralStart <= eocd, centralSize == eocd - centralStart else { throw Error.truncated }
        var offset = centralStart
        var records: [Record] = []
        var names = Set<String>()
        var totalSize = 0

        // Check all advertised sizes before any decompression or output allocation.
        for _ in 0..<count {
            guard offset + 46 <= eocd else { throw Error.truncated }
            guard readU32(data, offset) == 0x0201_4B50 else { throw Error.notAZip }
            let flags = readU16(data, offset + 8)
            // Encryption (traditional, strong, or masked headers) is not ZIP decoding.
            guard flags & 0x2041 == 0, readU16(data, offset + 34) == 0 else { throw Error.invalidArchive }
            let compressedSize = Int(readU32(data, offset + 20))
            let uncompressedSize = Int(readU32(data, offset + 24))
            guard compressedSize <= maximumEntryBytes, uncompressedSize <= maximumEntryBytes,
                  uncompressedSize <= maximumArchiveBytes - totalSize else { throw Error.tooLarge }
            totalSize += uncompressedSize
            let nameLen = Int(readU16(data, offset + 28))
            let extraLen = Int(readU16(data, offset + 30))
            let commentLen = Int(readU16(data, offset + 32))
            let nameStart = offset + 46
            let nextOffset = nameStart + nameLen + extraLen + commentLen
            guard nameLen > 0, nextOffset <= eocd else { throw Error.truncated }
            let nameBytes = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard names.insert(name).inserted else { throw Error.invalidArchive }
            records.append(Record(name: name, nameBytes: nameBytes, flags: flags,
                method: readU16(data, offset + 10), checksum: readU32(data, offset + 16),
                compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                localOffset: Int(readU32(data, offset + 42))))
            offset = nextOffset
        }
        guard offset == eocd else { throw Error.invalidArchive }

        var result: [Entry] = []
        result.reserveCapacity(records.count)
        for record in records {
            let payload = try readLocalFile(data, record: record, centralStart: centralStart)
            if !record.name.hasSuffix("/") {
                result.append(Entry(name: record.name, data: payload))
            }
        }
        return result
    }

    static func fileMap(from data: Data) throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try entries(from: data).map { ($0.name, $0.data) })
    }

    // MARK: - Internals

    private static func findEOCD(in data: Data) -> Int? {
        let start = max(0, data.count - 22 - 0xFFFF)
        var index = data.count - 22
        while index >= start {
            if readU32(data, index) == 0x0605_4B50,
               index + 22 + Int(readU16(data, index + 20)) == data.count {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func readLocalFile(_ data: Data, record: Record, centralStart: Int) throws -> Data {
        let offset = record.localOffset
        guard offset + 30 <= centralStart else { throw Error.truncated }
        guard readU32(data, offset) == 0x0403_4B50,
              readU16(data, offset + 6) == record.flags,
              readU16(data, offset + 8) == record.method else { throw Error.invalidArchive }
        let nameLen = Int(readU16(data, offset + 26))
        let extraLen = Int(readU16(data, offset + 28))
        let dataStart = offset + 30 + nameLen + extraLen
        guard dataStart <= centralStart, record.compressedSize <= centralStart - dataStart else { throw Error.truncated }
        guard data.subdata(in: (offset + 30)..<(offset + 30 + nameLen)) == record.nameBytes else {
            throw Error.invalidArchive
        }
        // Bit 3 permits sizes/CRC to be deferred to a data descriptor. The central
        // record still supplies the sizes, and every decoded payload is CRC-checked.
        if record.flags & 0x0008 == 0 {
            guard readU32(data, offset + 14) == record.checksum,
                  Int(readU32(data, offset + 18)) == record.compressedSize,
                  Int(readU32(data, offset + 22)) == record.uncompressedSize else { throw Error.invalidArchive }
        } else {
            let descriptor = dataStart + record.compressedSize
            // The optional signature is not included in the entry's compressed size.
            // Check the unsigned form first because its CRC can equal the signature.
            func matchesDescriptor(at start: Int) -> Bool {
                start + 12 <= centralStart && readU32(data, start) == record.checksum
                    && Int(readU32(data, start + 4)) == record.compressedSize
                    && Int(readU32(data, start + 8)) == record.uncompressedSize
            }
            guard matchesDescriptor(at: descriptor)
                || (descriptor + 16 <= centralStart && readU32(data, descriptor) == 0x0807_4B50
                    && matchesDescriptor(at: descriptor + 4)) else { throw Error.invalidArchive }
        }
        let compressed = data.subdata(in: dataStart..<(dataStart + record.compressedSize))
        let payload: Data
        switch record.method {
        case 0:
            guard record.compressedSize == record.uncompressedSize else { throw Error.invalidArchive }
            payload = compressed
        case 8:
            payload = try inflate(compressed, uncompressedSize: record.uncompressedSize)
        default:
            throw Error.unsupportedCompression(record.method)
        }
        guard checksum(payload) == record.checksum else { throw Error.invalidArchive }
        return payload
    }

    private static func inflate(_ source: Data, uncompressedSize: Int) throws -> Data {
        #if canImport(zlib)
        // A ZIP method-8 entry is raw DEFLATE: no zlib header or Adler checksum.
        // z_stream imports nullable pointers, so zero initialization is valid.
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Error.invalidArchive
        }
        defer { inflateEnd(&stream) }
        guard !source.isEmpty else { throw Error.invalidArchive }
        return try source.withUnsafeBytes { input in
            guard let address = input.bindMemory(to: UInt8.self).baseAddress else { throw Error.invalidArchive }
            stream.next_in = UnsafeMutablePointer(mutating: address)
            stream.avail_in = uInt(source.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            return try buffer.withUnsafeMutableBufferPointer { destination in
                guard let address = destination.baseAddress else { throw Error.invalidArchive }
                while true {
                    let inputRemaining = stream.avail_in
                    stream.next_out = address
                    stream.avail_out = uInt(destination.count)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = destination.count - Int(stream.avail_out)
                    guard produced <= uncompressedSize - output.count else { throw Error.invalidArchive }
                    output.append(address, count: produced)
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0, output.count == uncompressedSize else { throw Error.invalidArchive }
                        return output
                    }
                    guard status == Z_OK, produced > 0 || stream.avail_in < inputRemaining else {
                        throw Error.invalidArchive
                    }
                }
            }
        }
        #else
        throw Error.unsupportedCompression(8)
        #endif
    }

    private static let checksumTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320 }
        return crc
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = (crc >> 8) ^ checksumTable[Int((crc ^ UInt32(byte)) & 0xFF)] }
        return crc ^ 0xFFFF_FFFF
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

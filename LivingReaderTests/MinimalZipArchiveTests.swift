import Foundation
import XCTest
@testable import LivingReader

final class MinimalZipArchiveTests: XCTestCase {
    private let chapter = Data("<html><body><h1>Physics</h1><p>Energy is conserved.</p></body></html>".utf8)
    // Independently encoded by Python zlib with wbits=-15 (raw DEFLATE).
    private let compressedChapter = Data(base64Encoded: "s8koyc2xs0nKT6m0s8kwtAvIqCzOTC620QeybQrsXPNSi9IrFTKLFZLz84pTi8pSU/Rs9AvsbPQhOvTB2gE=")!

    func testStoredEntriesAndEmptyFiles() throws {
        let data = ZipFixture.make([
            .init(name: "mimetype", original: Data("application/epub+zip".utf8)),
            .init(name: "empty", original: Data())
        ])
        let files = try MinimalZipArchive.fileMap(from: data)
        XCTAssertEqual(files["mimetype"], Data("application/epub+zip".utf8))
        XCTAssertEqual(files["empty"], Data())
    }

    #if canImport(zlib)
    func testRealRawDeflateAlongsideStoredEntry() throws {
        let data = ZipFixture.make([
            .init(name: "mimetype", original: Data("application/epub+zip".utf8)),
            .init(name: "OEBPS/ch1.xhtml", original: chapter, compressed: compressedChapter)
        ])
        XCTAssertEqual(try MinimalZipArchive.fileMap(from: data)["OEBPS/ch1.xhtml"], chapter)
    }

    func testDeflateStreamsAcrossMultipleOutputBuffers() throws {
        let original = Data(String(repeating: "physics ", count: 20_000).utf8)
        let compressed = Data(base64Encoded: "7cUxDQAwCAAwK/PGMz4SLtwjAQPt0/rTGf3Ktm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3btm3bto8X")!
        let zip = ZipFixture.make([.init(name: "large.xhtml", original: original, compressed: compressed)])
        XCTAssertEqual(try MinimalZipArchive.fileMap(from: zip)["large.xhtml"], original)
    }

    func testValidEmptyDeflateAndDataDescriptor() throws {
        let files = try MinimalZipArchive.fileMap(from: ZipFixture.make([
            .init(name: "empty", original: Data(), compressed: Data([0x03, 0x00])),
            .init(name: "chapter", original: chapter, compressed: compressedChapter, usesDescriptor: true)
        ]))
        XCTAssertEqual(files["empty"], Data())
        XCTAssertEqual(files["chapter"], chapter)
    }

    func testTruncatedDeflateIsRejected() {
        let zip = ZipFixture.make([.init(name: "chapter", original: chapter, compressed: compressedChapter.dropLast())])
        assertRejected(zip, as: .invalidArchive)
    }

    func testInvalidDeflateCannotFallBackToStoredBytesOfSameSize() {
        let bytes = Data([0xff, 0xff, 0xff, 0xff])
        assertRejected(ZipFixture.make([.init(name: "bad", original: bytes, compressed: bytes)]), as: .invalidArchive)
    }

    func testEmptyCompressedInputIsNotAnEmptyDeflateStream() {
        assertRejected(ZipFixture.make([.init(name: "empty", original: Data(), compressed: Data())]), as: .invalidArchive)
    }

    func testDeflateRejectsBothUnderstatedAndOverstatedOutputSize() {
        for size in [0, chapter.count - 1, chapter.count + 1] {
            let zip = ZipFixture.make([.init(name: "chapter", original: chapter, compressed: compressedChapter,
                                            declaredSize: UInt32(size))])
            assertRejected(zip, as: .invalidArchive)
        }
    }

    func testDeflateRejectsBytesAfterStreamEnd() {
        assertRejected(ZipFixture.make([.init(name: "chapter", original: chapter,
            compressed: compressedChapter + Data([0x00]))]), as: .invalidArchive)
    }

    func testDeflateRejectsWrongCRC() {
        assertRejected(ZipFixture.make([.init(name: "chapter", original: chapter,
            compressed: compressedChapter, crcOverride: 0)]), as: .invalidArchive)
    }
    #else
    func testDeflateWithoutPlatformDecoderIsExplicitlyUnsupported() {
        assertRejected(ZipFixture.make([.init(name: "chapter", original: chapter,
            compressed: compressedChapter)]), as: .unsupportedCompression(8))
    }
    #endif

    func testStoredPayloadCorruptionAndWrongSizeAreRejected() {
        var corrupted = ZipFixture.make([.init(name: "chapter", original: chapter)])
        corrupted[30 + "chapter".utf8.count] ^= 1
        assertRejected(corrupted, as: .invalidArchive)
        assertRejected(ZipFixture.make([.init(name: "chapter", original: chapter,
            declaredSize: UInt32(chapter.count + 1))]), as: .invalidArchive)
    }

    func testOversizedEntryIsRejectedBeforeDecompression() {
        assertRejected(ZipFixture.make([.init(name: "huge", original: Data(), compressed: Data(),
            declaredSize: UInt32(MinimalZipArchive.maximumEntryBytes + 1))]), as: .tooLarge)
    }

    func testCumulativeExpansionIsRejectedBeforeDecompression() {
        let files = (0..<5).map { index in
            ZipFixture.File(name: "part\(index)", original: Data(), compressed: Data(),
                declaredSize: UInt32(MinimalZipArchive.maximumEntryBytes))
        }
        assertRejected(ZipFixture.make(files), as: .tooLarge)
    }

    func testTruncatedCentralDirectoryAndPayloadAreRejected() {
        let zip = ZipFixture.make([.init(name: "chapter", original: chapter)])
        XCTAssertThrowsError(try MinimalZipArchive.entries(from: zip.dropLast()))
        var badCentral = zip
        let central = 30 + "chapter".utf8.count + chapter.count
        ZipFixture.set16(&badCentral, at: central + 30, value: 0xffff)
        assertRejected(badCentral, as: .truncated)
        var badPayload = zip
        ZipFixture.set32(&badPayload, at: central + 20, value: UInt32(chapter.count + 1))
        ZipFixture.set32(&badPayload, at: 18, value: UInt32(chapter.count + 1))
        assertRejected(badPayload, as: .truncated)
    }

    func testLocalHeaderCannotDisagreeWithCentralDirectory() {
        var zip = ZipFixture.make([.init(name: "chapter", original: chapter)])
        ZipFixture.set16(&zip, at: 8, value: 8)
        assertRejected(zip, as: .invalidArchive)
    }

    func testMissingOrCorruptedDataDescriptorIsRejected() {
        var zip = ZipFixture.make([.init(name: "chapter", original: chapter, usesDescriptor: true)])
        let descriptor = 30 + "chapter".utf8.count + chapter.count
        zip[descriptor + 4] ^= 1
        assertRejected(zip, as: .invalidArchive)
        var missing = ZipFixture.make([.init(name: "chapter", original: chapter)])
        let central = descriptor
        ZipFixture.set16(&missing, at: 6, value: 8)
        ZipFixture.set16(&missing, at: central + 8, value: 8)
        assertRejected(missing, as: .invalidArchive)
    }

    func testDuplicateNamesAreRejected() {
        assertRejected(ZipFixture.make([
            .init(name: "chapter", original: chapter), .init(name: "chapter", original: chapter)
        ]), as: .invalidArchive)
    }

    func testArchiveCommentAndNonzeroDataSliceIndex() throws {
        // An incidental signature inside the comment must not become the EOCD.
        var comment = Data([0x50, 0x4b, 0x05, 0x06])
        comment.append(Data(repeating: 0, count: 30))
        let zip = ZipFixture.make([.init(name: "chapter", original: chapter)], comment: comment)
        let prefixed = Data([0xff]) + zip
        let slice = prefixed.dropFirst()
        XCTAssertEqual(try MinimalZipArchive.fileMap(from: slice)["chapter"], chapter)
    }

    private func assertRejected(_ zip: Data, as expected: MinimalZipArchive.Error,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MinimalZipArchive.entries(from: zip), file: file, line: line) { error in
            XCTAssertEqual(error as? MinimalZipArchive.Error, expected, file: file, line: line)
        }
    }
}

private enum ZipFixture {
    struct File {
        let name: String
        let original: Data
        var compressed: Data? = nil
        var declaredSize: UInt32? = nil
        var crcOverride: UInt32? = nil
        var usesDescriptor = false
    }

    static func make(_ files: [File], comment: Data = Data()) -> Data {
        var local = Data()
        var central = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let payload = file.compressed ?? file.original
            let method: UInt16 = file.compressed == nil ? 0 : 8
            let flags: UInt16 = file.usesDescriptor ? 8 : 0
            let crc = file.crcOverride ?? checksum(file.original)
            let size = file.declaredSize ?? UInt32(file.original.count)
            let start = UInt32(local.count)
            append32(0x0403_4b50, to: &local)
            for value: UInt16 in [20, flags, method, 0, 0] { append16(value, to: &local) }
            for value in [file.usesDescriptor ? 0 : crc,
                          file.usesDescriptor ? 0 : UInt32(payload.count),
                          file.usesDescriptor ? 0 : size] { append32(value, to: &local) }
            append16(UInt16(name.count), to: &local)
            append16(0, to: &local)
            local.append(name)
            local.append(payload)
            if file.usesDescriptor {
                for value in [UInt32(0x0807_4b50), crc, UInt32(payload.count), size] { append32(value, to: &local) }
            }
            append32(0x0201_4b50, to: &central)
            for value: UInt16 in [20, 20, flags, method, 0, 0] { append16(value, to: &central) }
            for value in [crc, UInt32(payload.count), size] { append32(value, to: &central) }
            for value: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { append16(value, to: &central) }
            append32(0, to: &central)
            append32(start, to: &central)
            central.append(name)
        }
        var result = local + central
        append32(0x0605_4b50, to: &result)
        for value: UInt16 in [0, 0, UInt16(files.count), UInt16(files.count)] { append16(value, to: &result) }
        append32(UInt32(central.count), to: &result)
        append32(UInt32(local.count), to: &result)
        append16(UInt16(comment.count), to: &result)
        result.append(comment)
        return result
    }

    static func set16(_ data: inout Data, at offset: Int, value: UInt16) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    static func set32(_ data: inout Data, at offset: Int, value: UInt32) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        for index in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb8_8320 }
        }
        return crc ^ 0xffff_ffff
    }
}

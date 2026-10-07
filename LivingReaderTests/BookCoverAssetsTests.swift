import XCTest
@testable import LivingReader

final class BookCoverAssetsTests: XCTestCase {
    func testFixtureAccentsMapToCatalogImages() throws {
        let argentina = try BundleFixtureLoader.loadArgentinaMinimal()
        XCTAssertEqual(argentina.coverAccent, "argentina-sky")
        XCTAssertEqual(BookCoverAssets.imageName(for: argentina), "CoverArgentina")
        XCTAssertEqual(
            BookCoverAssets.fixtureFileName(forAccent: argentina.coverAccent),
            "cover-argentina-portrait.png"
        )

        // Cover routing needs only original metadata, not a licensed translation.
        let quran = Book(id: QuranFixtureIDs.book, title: "Protected sample metadata",
                         author: "Fixture", coverAccent: "quran-night", chapters: [])
        XCTAssertEqual(quran.coverAccent, "quran-night")
        XCTAssertEqual(BookCoverAssets.imageName(for: quran), "CoverQuran")
        XCTAssertEqual(
            BookCoverAssets.fixtureFileName(forAccent: quran.coverAccent),
            "cover-quran-portrait.png"
        )
    }

    func testGeneratedAndImportedCoverPipelineNames() {
        let generated = Book(
            id: UUID(),
            title: "Demo",
            author: "GenBooks",
            coverAccent: "generated",
            chapters: []
        )
        XCTAssertEqual(BookCoverAssets.imageName(for: generated), "CoverGenerated")

        let imported = Book(
            id: UUID(),
            title: "Import",
            author: "Reader",
            coverAccent: "imported",
            chapters: []
        )
        XCTAssertEqual(BookCoverAssets.imageName(for: imported), "CoverImported")
    }

    func testFixtureCoverFilesExistOnDisk() {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // LivingReaderTests
            .deletingLastPathComponent() // repo
        let covers = repoRoot.appendingPathComponent("Resources/Fixtures/covers")
        for name in [
            "cover-argentina-portrait.png",
            "cover-quran-portrait.png",
            "cover-generated.png",
            "cover-imported.png"
        ] {
            let url = covers.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing \(name)")
        }
    }
}

import XCTest
import UIKit
@testable import LivingReader

@MainActor
final class ReaderTypefaceTests: XCTestCase {
    func testGeorgiaResolvesItsFourFacesAtSupportedSizeBounds() {
        let faces: [(UIFont.Weight, Bool, String)] = [
            (.regular, false, "Georgia"),
            (.regular, true, "Georgia-Italic"),
            (.medium, false, "Georgia"),
            (.semibold, false, "Georgia-Bold"),
            (.semibold, true, "Georgia-BoldItalic"),
            (.bold, false, "Georgia-Bold"),
            (.bold, true, "Georgia-BoldItalic")
        ]
        for size in [ReaderTypography.minBodySize, ReaderTypography.defaultBodySize, ReaderTypography.maxBodySize] {
            for (weight, italic, name) in faces {
                let font = ReaderFontFamily.georgia.uiFont(size: size, weight: weight, italic: italic)
                XCTAssertEqual(font.fontName, name)
                XCTAssertEqual(font.familyName, "Georgia")
                XCTAssertEqual(font.pointSize, size, accuracy: 0.01)
                XCTAssertEqual(font.fontDescriptor.symbolicTraits.contains(.traitBold), weight >= .semibold)
                XCTAssertEqual(font.fontDescriptor.symbolicTraits.contains(.traitItalic), italic)
            }
        }
    }

    func testGeorgiaBodyHeadingAndQuotePreserveExistingNonFontStyling() throws {
        let original = ReaderTypography.make(
            bodyPointSize: 23, colorScheme: .sepia, lineHeightMultiple: 1.4, horizontalInset: 28
        )
        let georgia = ReaderTypography.make(
            bodyPointSize: 23, colorScheme: .sepia, fontFamily: .georgia,
            lineHeightMultiple: 1.4, horizontalInset: 28
        )
        let expected: [(ContentBlockKind, String, CGFloat)] = [
            (.paragraph, "Georgia", 23), (.heading, "Georgia-Bold", 31),
            (.quote, "Georgia-Italic", 23), (.callout, "Georgia", 22.5),
            (.imagePlaceholder, "Georgia", 22)
        ]
        for (kind, name, size) in expected {
            let old = original.attributes(for: kind)
            let updated = georgia.attributes(for: kind)
            let font = try XCTUnwrap(updated[.font] as? UIFont)
            XCTAssertEqual(font.fontName, name)
            XCTAssertEqual(font.pointSize, size, accuracy: 0.01)
            XCTAssertEqual(updated[.foregroundColor] as? UIColor, old[.foregroundColor] as? UIColor)
            XCTAssertEqual(updated[.paragraphStyle] as? NSParagraphStyle, old[.paragraphStyle] as? NSParagraphStyle)
            XCTAssertEqual(updated[.kern] as? Double, old[.kern] as? Double)
        }
        XCTAssertEqual(georgia.horizontalInset, original.horizontalInset)
        XCTAssertEqual(georgia.backgroundColor, original.backgroundColor)
    }

    func testExistingChoicesDefaultsAndRawValuesRemainCompatible() throws {
        XCTAssertEqual(ReaderFontFamily.allCases.map(\.rawValue), ["original", "serif", "sans", "georgia"])
        XCTAssertEqual(ReaderFontFamily.allCases.map(\.displayName), ["Original", "Serif", "Sans", "Georgia"])
        let suite = "LivingReaderTests.Typeface.Legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReaderSettingsStore(defaults: defaults).fontFamily, .original)
        XCTAssertEqual(ReaderSettingsStore(defaults: defaults).scrollMode, .scroll)
        for family in ReaderFontFamily.allCases {
            defaults.set(family.rawValue, forKey: "livingreader.reader.fontFamily")
            XCTAssertEqual(ReaderSettingsStore(defaults: defaults).fontFamily, family)
            let encoded = try JSONEncoder().encode(family)
            XCTAssertEqual(try JSONDecoder().decode(ReaderFontFamily.self, from: encoded), family)
        }
        defaults.set("unrecognized-future-font", forKey: "livingreader.reader.fontFamily")
        XCTAssertEqual(ReaderSettingsStore(defaults: defaults).fontFamily, .original)
        XCTAssertEqual(ReaderFontFamily.original.uiFont(size: 19).fontName, UIFont.systemFont(ofSize: 19).fontName)
        XCTAssertEqual(ReaderFontFamily.sans.uiFont(size: 19).fontName, UIFont.systemFont(ofSize: 19).fontName)
    }

    func testGeorgiaPersistsWithoutChangingOtherReadingPreferences() throws {
        let suite = "LivingReaderTests.Typeface.Persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettingsStore(defaults: defaults)
        settings.fontSize = 25
        settings.colorScheme = .sepia
        settings.lineSpacing = 1.4
        settings.marginInset = 28
        settings.pageDim = 0.2
        settings.wordsPerMinute = 190
        settings.scrollMode = .pages
        settings.searchScope = .wholeBook
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        settings.fontFamily = .georgia
        let reopened = ReaderSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.fontFamily, .georgia)
        XCTAssertEqual(reopened.typography.fontFamily, .georgia)
        XCTAssertEqual(defaults.string(forKey: "livingreader.reader.fontFamily"), "georgia")
        for (key, value) in before where key != "livingreader.reader.fontFamily" {
            XCTAssertTrue(try XCTUnwrap(defaults.object(forKey: key) as? NSObject).isEqual(value), key)
        }
        XCTAssertEqual(reopened.fontSize, 25)
        XCTAssertEqual(reopened.colorScheme, .sepia)
        XCTAssertEqual(reopened.lineSpacing, 1.4, accuracy: 0.001)
        XCTAssertEqual(reopened.marginInset, 28)
        XCTAssertEqual(reopened.pageDim, 0.2, accuracy: 0.001)
        XCTAssertEqual(reopened.wordsPerMinute, 190)
        XCTAssertEqual(reopened.scrollMode, .pages)
        XCTAssertEqual(reopened.searchScope, .wholeBook)
    }

    func testFontChoiceDoesNotChangeManuscriptTextAnchorsOrCheckpointMapping() throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manuscriptBefore = try encoder.encode(book)
        let revisions = Dictionary(uniqueKeysWithValues: try book.chapters.map { chapter in
            (chapter.id, try XCTUnwrap(chapter.activeRevision))
        })
        func document(_ family: ReaderFontFamily) -> ReaderDocument {
            ReaderDocumentBuilder.build(
                book: book, readableRevisions: revisions,
                typography: ReaderTypography.make(bodyPointSize: 23, colorScheme: .sepia, fontFamily: family)
            )
        }
        let original = document(.original)
        let target = ReaderLocation(
            chapterId: ArgentinaFixtureIDs.chapter1, blockId: ArgentinaFixtureIDs.block1Body,
            characterOffset: 37, progress: 0
        )
        let originalOffset = try XCTUnwrap(original.utf16Location(for: target))
        let location = try XCTUnwrap(original.location(atUtf16: originalOffset))
        let checkpoint = ReadingCheckpoint.from(location: location, bookId: book.id)
        let checkpointBytes = try encoder.encode(checkpoint)
        let restoredCheckpoint = try JSONDecoder().decode(ReadingCheckpoint.self, from: checkpointBytes)
        let restoredLocation = try XCTUnwrap(restoredCheckpoint.asLocation(progress: location.progress))

        for family in ReaderFontFamily.allCases {
            let updated = document(family)
            XCTAssertEqual(updated.attributedText.string, original.attributedText.string)
            XCTAssertEqual(updated.anchors, original.anchors)
            XCTAssertEqual(updated.length, original.length)
            XCTAssertEqual(updated.utf16Location(for: restoredLocation), originalOffset)
            XCTAssertEqual(updated.location(atUtf16: originalOffset), location)
            XCTAssertEqual(updated.search(query: ArgentinaFixtureIDs.searchablePhrase), original.search(query: ArgentinaFixtureIDs.searchablePhrase))
        }
        XCTAssertEqual(try encoder.encode(book), manuscriptBefore)
        XCTAssertEqual(try encoder.encode(checkpoint), checkpointBytes)
    }
}

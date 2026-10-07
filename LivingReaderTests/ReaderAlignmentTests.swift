import XCTest
import UIKit
@testable import LivingReader

@MainActor
final class ReaderAlignmentTests: XCTestCase {
    private let kinds: [ContentBlockKind] = [.paragraph, .heading, .quote, .callout, .imagePlaceholder]

    func testMissingPreferenceAndDefaultTypographyKeepNaturalAlignment() throws {
        let suite = "LivingReaderTests.Alignment.Default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = ReaderSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.justified)
        XCTAssertFalse(settings.typography.justified)
        XCTAssertNil(defaults.object(forKey: "livingreader.reader.justified"))
        let typography = ReaderTypography.make(bodyPointSize: 19, colorScheme: .light)
        XCTAssertFalse(typography.justified)
        for kind in kinds {
            let style = try XCTUnwrap(typography.attributes(for: kind)[.paragraphStyle] as? NSParagraphStyle)
            XCTAssertEqual(style.alignment, .natural)
            XCTAssertEqual(style.baseWritingDirection, .natural)
        }
    }

    func testAlignmentPersistsOnAndOffWithoutChangingOtherPreferences() throws {
        let suite = "LivingReaderTests.Alignment.Persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettingsStore(defaults: defaults)
        settings.fontSize = 25
        settings.fontFamily = .serif
        settings.colorScheme = .sepia
        settings.lineSpacing = 1.4
        settings.marginInset = 28
        settings.pageDim = 0.2
        settings.wordsPerMinute = 190
        settings.scrollMode = .pages
        settings.searchScope = .wholeBook
        let previous = defaults.persistentDomain(forName: suite) ?? [:]

        for value in [true, false] {
            settings.justified = value
            let reopened = ReaderSettingsStore(defaults: defaults)
            XCTAssertEqual(reopened.justified, value)
            XCTAssertEqual(reopened.typography.justified, value)
            XCTAssertEqual(defaults.object(forKey: "livingreader.reader.justified") as? Bool, value)
            for (key, priorValue) in previous {
                let current = try XCTUnwrap(defaults.object(forKey: key) as? NSObject)
                XCTAssertTrue(current.isEqual(priorValue), key)
            }
            XCTAssertEqual(reopened.fontSize, 25)
            XCTAssertEqual(reopened.fontFamily, .serif)
            XCTAssertEqual(reopened.colorScheme, .sepia)
            XCTAssertEqual(reopened.lineSpacing, 1.4, accuracy: 0.001)
            XCTAssertEqual(reopened.marginInset, 28)
            XCTAssertEqual(reopened.pageDim, 0.2, accuracy: 0.001)
            XCTAssertEqual(reopened.wordsPerMinute, 190)
            XCTAssertEqual(reopened.scrollMode, .pages)
            XCTAssertEqual(reopened.searchScope, .wholeBook)
        }
    }

    func testOnlyBodyParagraphAlignmentChangesAcrossTypefacesThemesAndSizes() throws {
        for family in ReaderFontFamily.allCases {
            for scheme in [ReaderColorScheme.light, .sepia, .dark] {
                for size in [ReaderTypography.minBodySize, ReaderTypography.defaultBodySize, ReaderTypography.maxBodySize] {
                    let natural = ReaderTypography.make(
                        bodyPointSize: size, colorScheme: scheme, fontFamily: family,
                        lineHeightMultiple: 1.4, horizontalInset: 28
                    )
                    var justified = natural
                    justified.justified = true
                    XCTAssertEqual(justified.backgroundColor, natural.backgroundColor)
                    XCTAssertEqual(justified.horizontalInset, natural.horizontalInset)
                    for kind in kinds {
                        let original = natural.attributes(for: kind)
                        let updated = justified.attributes(for: kind)
                        let originalStyle = try XCTUnwrap(original[.paragraphStyle] as? NSParagraphStyle)
                        let updatedStyle = try XCTUnwrap(updated[.paragraphStyle] as? NSParagraphStyle)
                        XCTAssertEqual(updatedStyle.alignment, kind == .paragraph ? .justified : .natural)
                        XCTAssertEqual(updatedStyle.baseWritingDirection, .natural)
                        let normalizedStyle = try XCTUnwrap(updatedStyle.mutableCopy() as? NSMutableParagraphStyle)
                        normalizedStyle.alignment = originalStyle.alignment
                        XCTAssertEqual(normalizedStyle, originalStyle, "Spacing and indentation must not change")
                        XCTAssertEqual(Set(updated.keys), Set(original.keys))
                        for key in original.keys where key != .paragraphStyle {
                            let attribute = try XCTUnwrap(updated[key] as? NSObject)
                            XCTAssertTrue(attribute.isEqual(try XCTUnwrap(original[key])), "Unexpected change to \(key.rawValue)")
                        }
                    }
                    let separatorStyle = try XCTUnwrap(justified.bodyAttributes[.paragraphStyle] as? NSParagraphStyle)
                    XCTAssertEqual(separatorStyle.alignment, .natural, "Layout-owned separators keep existing styling")
                }
            }
        }
    }

    func testAlignmentDoesNotChangeRealBookTextAnchorsSearchOrCheckpointMapping() throws {
        let book = try BundleFixtureLoader.loadArgentinaMinimal()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manuscriptBefore = try encoder.encode(book)
        let revisions = Dictionary(uniqueKeysWithValues: try book.chapters.map { chapter in
            (chapter.id, try XCTUnwrap(chapter.activeRevision))
        })
        func document(_ justified: Bool, family: ReaderFontFamily = .original) -> ReaderDocument {
            ReaderDocumentBuilder.build(
                book: book, readableRevisions: revisions,
                typography: ReaderTypography.make(
                    bodyPointSize: 23, colorScheme: .sepia, fontFamily: family, justified: justified
                )
            )
        }
        let original = document(false)
        let target = ReaderLocation(
            chapterId: ArgentinaFixtureIDs.chapter1, blockId: ArgentinaFixtureIDs.block1Body,
            characterOffset: 37, progress: 0
        )
        let offset = try XCTUnwrap(original.utf16Location(for: target))
        let location = try XCTUnwrap(original.location(atUtf16: offset))
        let checkpoint = ReadingCheckpoint.from(location: location, bookId: book.id)
        let checkpointBytes = try encoder.encode(checkpoint)
        let restored = try JSONDecoder().decode(ReadingCheckpoint.self, from: checkpointBytes)
        let restoredLocation = try XCTUnwrap(restored.asLocation(progress: location.progress))

        for family in ReaderFontFamily.allCases {
            for justified in [true, false] {
                let updated = document(justified, family: family)
                XCTAssertEqual(updated.attributedText.string, original.attributedText.string)
                XCTAssertEqual(updated.anchors, original.anchors)
                XCTAssertEqual(updated.length, original.length)
                XCTAssertEqual(updated.chapterStarts.map(\.chapterId), original.chapterStarts.map(\.chapterId))
                XCTAssertEqual(updated.chapterStarts.map(\.utf16Location), original.chapterStarts.map(\.utf16Location))
                XCTAssertEqual(updated.utf16Location(for: restoredLocation), offset)
                XCTAssertEqual(updated.location(atUtf16: offset), location)
                XCTAssertEqual(updated.search(query: ArgentinaFixtureIDs.searchablePhrase), original.search(query: ArgentinaFixtureIDs.searchablePhrase))
                let anchor = try XCTUnwrap(updated.anchor(blockId: target.blockId))
                let style = try XCTUnwrap(updated.attributedText.attribute(
                    .paragraphStyle, at: anchor.utf16Range.lowerBound, effectiveRange: nil
                ) as? NSParagraphStyle)
                XCTAssertEqual(style.alignment, justified ? .justified : .natural)
            }
        }
        XCTAssertEqual(try encoder.encode(book), manuscriptBefore)
        XCTAssertEqual(try encoder.encode(checkpoint), checkpointBytes)
    }

    func testReaderRebuildUsesAlignmentAndPreservesSavedReadingLocationWithoutAI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LR-Alignment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LivingReaderTests.Alignment.Rebuild.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let versioning = try ManuscriptVersioningService(rootDirectory: root)
        let book = try await BundleFixtureLoader.seedIfNeeded(into: versioning)
        let checkpoints = try FileReadingCheckpointStore(rootDirectory: root)
        let saved = ReadingCheckpoint(
            id: UUID(), bookId: book.id, chapterId: ArgentinaFixtureIDs.chapter2,
            blockId: ArgentinaFixtureIDs.block2Body, characterOffset: 37, updatedAt: Date()
        )
        try checkpoints.saveCheckpoint(saved)
        let persistedCheckpoint = try XCTUnwrap(checkpoints.loadCheckpoint(bookId: book.id))
        let settings = ReaderSettingsStore(defaults: defaults)
        let ai = MockAIService()
        let model = ReaderViewModel(
            book: book, versioning: versioning, checkpoints: checkpoints, settings: settings,
            annotations: try FileAnnotationStore(rootDirectory: root),
            vocabulary: try FileVocabularyStore(rootDirectory: root),
            bookmarks: try FileBookmarkStore(rootDirectory: root),
            feedbackStore: try FileFeedbackStore(directory: root.appendingPathComponent("feedback")),
            preferenceStore: try FileReaderPreferenceStore(directory: root.appendingPathComponent("preferences")),
            ai: ai
        )
        await model.open()
        XCTAssertTrue(model.isReady)
        XCTAssertNil(model.loadError)
        let original = try XCTUnwrap(model.document)
        let location = try XCTUnwrap(model.currentLocation)
        let offset = try XCTUnwrap(original.utf16Location(for: location))
        let ledgerBefore = try await versioning.ledgerSnapshot()

        for value in [true, false] {
            let oldEpoch = model.documentEpoch
            settings.justified = value
            model.rebuildDocumentPreservingLocation()
            let rebuilt = try XCTUnwrap(model.document)
            XCTAssertEqual(model.documentEpoch, oldEpoch + 1)
            XCTAssertEqual(model.currentLocation, location)
            XCTAssertEqual(model.restoreLocation, location)
            XCTAssertEqual(model.jumpUtf16, offset)
            XCTAssertFalse(model.jumpAnimated)
            XCTAssertEqual(rebuilt.attributedText.string, original.attributedText.string)
            XCTAssertEqual(rebuilt.anchors, original.anchors)
            let style = try XCTUnwrap(rebuilt.attributedText.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.alignment, value ? .justified : .natural)
            XCTAssertEqual(try checkpoints.loadCheckpoint(bookId: book.id), persistedCheckpoint)
        }
        let ledgerAfter = try await versioning.ledgerSnapshot()
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        XCTAssertEqual(ai.askCallCount, 0)
        XCTAssertEqual(ai.adaptCallCount, 0)
    }
}

import SwiftUI
import UIKit

/// Maps `Book.coverAccent` to catalog images under Resources/Assets.xcassets.
enum BookCoverAssets {
    static func imageName(for book: Book) -> String? {
        switch book.coverAccent {
        case "argentina-sky":
            return "CoverArgentina"
        case "quran-night", "quran-emerald":
            return "CoverQuran"
        case "generated":
            return "CoverGenerated"
        case "imported":
            return "CoverImported"
        default:
            return nil
        }
    }

    /// Accent → fixture file under Resources/Fixtures/covers.
    static func fixtureFileName(forAccent accent: String?) -> String? {
        switch accent {
        case "argentina-sky": return "cover-argentina-portrait.png"
        case "quran-night", "quran-emerald": return "cover-quran-portrait.png"
        case "generated": return "cover-generated.png"
        case "imported": return "cover-imported.png"
        default: return nil
        }
    }
}

/// Shared library cover chrome: catalog image when present, else accent gradient.
struct BookCoverView: View {
    let book: Book
    var width: CGFloat = 56
    var height: CGFloat = 78

    var body: some View {
        Group {
            if let name = BookCoverAssets.imageName(for: book),
               UIImage(named: name) != nil {
                Image(name)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [fallbackColor, fallbackColor.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    VStack(spacing: 2) {
                        Text(fallbackInitials)
                            .font(.caption.weight(.bold))
                        Text(fallbackSubline)
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var fallbackColor: Color {
        switch book.coverAccent {
        case "argentina-sky":
            return LRColor.mustard
        case "quran-night", "quran-emerald":
            return Color(red: 0.10, green: 0.34, blue: 0.30)
        case "imported":
            return Color(red: 0.36, green: 0.45, blue: 0.38)
        case "generated":
            return Color(red: 0.46, green: 0.32, blue: 0.58)
        default:
            return LRColor.mustard
        }
    }

    private var fallbackInitials: String {
        let words = book.title.split(separator: " ").filter { $0.count > 2 }
        if let first = words.first, let second = words.dropFirst().first {
            return String(first.prefix(1) + second.prefix(1)).uppercased()
        }
        return String(book.title.prefix(2)).uppercased()
    }

    private var fallbackSubline: String {
        String(book.author.prefix(4)).uppercased()
    }
}

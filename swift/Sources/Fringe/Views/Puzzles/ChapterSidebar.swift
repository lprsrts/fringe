import SwiftUI

/// The browser's sidebar: All, then one row per chapter with how many are solved.
/// Selecting a row scrolls the grid to that chapter.
struct ChapterSidebar: View {
    @Environment(AppState.self) private var model

    /// The tag of the All row (no chapter id can be empty).
    private static let all = ""

    var body: some View {
        let _ = PerfProbe.body("ChapterSidebar")
        let puzzles = model.puzzles
        List(selection: selection) {
            Section("Chapters") {
                ChapterRow(title: "All", symbol: "square.grid.2x2", solved: puzzles.solvedCount(), total: puzzles.catalog.count)
                    .tag(Self.all)
                ForEach(puzzles.chapters) { chapter in
                    ChapterRow(title: chapter.title, symbol: Self.symbol(chapter.id),
                               solved: puzzles.solvedCount(chapter.puzzles), total: chapter.puzzles.count)
                        .tag(chapter.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.puzzles.browserChapter ?? Self.all },
            set: { model.puzzles.browserChapter = ($0 ?? Self.all).isEmpty ? nil : $0 }
        )
    }

    static func symbol(_ chapter: String) -> String {
        switch chapter {
        case "steering": return "arrow.turn.up.right"
        case "interference": return "wave.3.right"
        case "logic": return "switch.2"
        case "metals": return "circle.lefthalf.filled"
        default: return "puzzlepiece"
        }
    }
}

private struct ChapterRow: View {
    let title: String
    let symbol: String
    let solved: Int
    let total: Int

    var body: some View {
        let _ = PerfProbe.body("ChapterRow")
        Label(title, systemImage: symbol)
            .badge(Text("\(solved)/\(total)").font(.caption).monospacedDigit())
            .accessibilityValue("\(solved) of \(total) solved")
    }
}

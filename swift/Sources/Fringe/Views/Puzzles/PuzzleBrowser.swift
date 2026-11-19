import SwiftUI

/// Every puzzle as a card, chapter by chapter. All are open; nothing is locked.
struct PuzzleBrowser: View {
    @Environment(AppState.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let top = "browser-top"
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 12, alignment: .top)]

    var body: some View {
        let _ = PerfProbe.body("PuzzleBrowser")
        let puzzles = model.puzzles
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.top)
                    if puzzles.catalog.isEmpty {
                        ContentUnavailableView("No Puzzles", systemImage: "puzzlepiece",
                                               description: Text("This build of the core has no puzzles."))
                    }
                    ForEach(puzzles.chapters) { chapter in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(chapter.title)
                                    .font(.title3.weight(.semibold))
                                Spacer()
                                PuzzleTally(
                                    solved: puzzles.solvedCount(chapter.puzzles), total: chapter.puzzles.count,
                                    stars: puzzles.starCount(chapter.puzzles), maxStars: puzzles.maxStars(chapter.puzzles)
                                )
                                .font(.callout)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(Array(chapter.puzzles.enumerated()), id: \.element.id) { index, summary in
                                    PuzzleCard(
                                        number: index + 1,
                                        title: summary.title.titleCased,
                                        task: puzzles.taskLine(summary.id),
                                        progress: puzzles.progress(summary.id)
                                    ) {
                                        model.openPuzzle(summary.id)
                                    }
                                }
                            }
                        }
                        .id(chapter.id)
                    }
                }
                .padding(20)
            }
            .onChange(of: puzzles.browserChapter) { _, chapter in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(chapter ?? Self.top, anchor: .top)
                }
            }
        }
        .background(.background)
    }
}

import SwiftUI

/// Three stars, `count` of them filled. Filled and empty differ in shape as well as colour,
/// and VoiceOver reads the whole row as one value.
struct StarsView: View {
    let count: Int
    var total = 3

    var body: some View {
        let _ = PerfProbe.body("StarsView")
        HStack(spacing: 2) {
            ForEach(0..<total, id: \.self) { i in
                Image(systemName: i < count ? "star.fill" : "star")
                    .foregroundStyle(i < count ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.tertiary))
            }
        }
        .imageScale(.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(min(count, total)) of \(total) stars")
    }
}

/// "7 of 20 solved · 15 of 60 ★", for the browser's toolbar and chapter headers.
struct PuzzleTally: View {
    let solved: Int
    let total: Int
    let stars: Int
    let maxStars: Int

    var body: some View {
        let _ = PerfProbe.body("PuzzleTally")
        HStack(spacing: 4) {
            Text("\(solved) of \(total) solved · \(stars) of \(maxStars)")
            Image(systemName: "star.fill")
                .imageScale(.small)
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(solved) of \(total) solved, \(stars) of \(maxStars) stars")
    }
}

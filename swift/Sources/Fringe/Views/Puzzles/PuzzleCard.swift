import SwiftUI

/// One puzzle in the browser: its number in the chapter, title, what to do in one short
/// line, stars and a check mark once passed. A button: a click or Return opens it.
struct PuzzleCard: View {
    let number: Int
    let title: String
    let task: String
    let progress: PuzzleProgress
    let open: () -> Void

    var body: some View {
        let _ = PerfProbe.body("PuzzleCard")
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(task)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                StarsView(count: progress.stars)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(12)
            // An overlay, so a passed card's text sits exactly where the others' does.
            .overlay(alignment: .topTrailing) {
                if progress.passed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PuzzleCardStyle())
        .help(task)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the puzzle")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityValue: String {
        var parts = [task, "\(progress.stars) of 3 stars"]
        if progress.passed { parts.append("passed") }
        return parts.joined(separator: ", ")
    }
}

/// Rounded quaternary fill, a little stronger under the pointer and while pressed.
struct PuzzleCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @UIState private var isHovered = false

        var body: some View {
            let _ = PerfProbe.body("CardBody")
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovered || configuration.isPressed ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary))
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
                .onHover { isHovered = $0 }
        }
    }
}

import SwiftUI

/// The results area under the canvas: the detector table and the |E|² profile along the
/// chosen line detector, side by side, or one at a time in a narrow column. Its top edge
/// is a handle that resizes it.
struct ResultsPanel: View {
    let model: AppState
    /// Height of the whole detail column, which limits the panel to half of it.
    let columnHeight: CGFloat
    @AppStorage("fringe.results.height") private var storedHeight = ResultsPanel.defaultHeight
    @UIState private var dragStartHeight: CGFloat?

    static let defaultHeight: CGFloat = 190
    static let minimumHeight: CGFloat = 140

    var body: some View {
        let _ = PerfProbe.body("ResultsPanel")
        let height = clamped(storedHeight)
        VStack(spacing: 0) {
            handle(height: height)
            Group {
                if model.scene.detectors.isEmpty {
                    ResultsEmptyState(model: model)
                } else {
                    ViewThatFits(in: .horizontal) {
                        SideBySideResults(model: model)
                            .frame(minWidth: 620)
                        StackedResults(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .background(.background)
    }

    private var maximumHeight: CGFloat {
        max(Self.minimumHeight, columnHeight * 0.5)
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(maximumHeight, max(Self.minimumHeight, value))
    }

    /// A divider with a taller hit area; dragging it up makes the panel taller.
    private func handle(height: CGFloat) -> some View {
        Divider()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? height
                        if dragStartHeight == nil { dragStartHeight = height }
                        storedHeight = clamped(start - value.translation.height)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .pointerStyle(.rowResize)
            .accessibilityHidden(true)
            .padding(.vertical, -3)
    }
}

/// A small panel title with an optional trailing accessory.
private struct PanelHeader<Accessory: View>: View {
    let title: String
    var stale = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let _ = PerfProbe.body("PanelHeader")
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if stale {
                Text("Out of date")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(red: 1, green: 0.75, blue: 0.2).opacity(0.92), in: Capsule())
                    .help("The readings belong to the scene before your last edits")
            }
            Spacer(minLength: 8)
            accessory()
        }
        .frame(height: 22)
    }
}

/// The table with its header and footnote.
private struct DetectorTableSection: View {
    let model: AppState
    var showsHeader = true

    var body: some View {
        let _ = PerfProbe.body("DetectorTableSection")
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                PanelHeader(title: "Detectors", stale: model.readingsAreStale) { HideResultsButton(model: model) }
            }
            DetectorTable(model: model)
            MathText(#"Line: power per µm in $z$ over $A^2$. Box: mean $|E|^2$ over $A^2$."#)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// The profile of the results detector, or why there is none. While a new profile is
/// sampled (the detector dragged, a new solve) the last curve of the same detector stays,
/// dimmed on its own axis, and the plot says "Updating…" if it takes a moment: the plot
/// never jumps or spins. Stale readings (an old solve) dim the curve too; the header says
/// so, and the plot carries no caption, so the two never look the same.
private struct ProfileSection: View {
    let model: AppState
    var showsHeader = true
    /// The last profile shown, per detector, to hold while the next one is sampled.
    @UIState private var held: HeldProfile?

    struct HeldProfile: Equatable {
        var detectorID: String
        var points: [ProfilePoint]
        /// The length of the line the points were sampled on: a held curve keeps its own
        /// axis while the moved or resized line is sampled again.
        var lengthUm: Double
    }

    private enum Content {
        case chart([ProfilePoint], PlotState, lengthUm: Double?)
        case message(String)
    }

    var body: some View {
        let _ = PerfProbe.body("ProfileSection")
        let detector = model.resultsDetector
        let content = self.content(for: detector)
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                PanelHeader(title: detector.flatMap { $0.kind == .line ? "Profile · \($0.displayName)" : nil } ?? "Profile", stale: model.readingsAreStale) {
                    EmptyView()
                }
            }
            Group {
                switch content {
                case .chart(let points, let state, let length):
                    LineProfileChart(points: points, detectorName: detector?.displayName ?? "", lengthUm: length ?? detector?.length ?? 1, state: state)
                        .plotSurface(Color(nsColor: .windowBackgroundColor))
                case .message(let text):
                    MathText(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: profileRequest) {
            if let line = profileRequest?.line { model.requestProfile(for: line) }
        }
        .onChange(of: currentPoints, initial: true) { _, points in
            if let points, !points.isEmpty, let detector {
                held = HeldProfile(detectorID: detector.id, points: points, lengthUm: detector.length)
            }
        }
    }

    private var currentPoints: [ProfilePoint]? {
        profileRequest.flatMap { model.profiles[$0] }
    }

    private func content(for detector: Detector?) -> Content {
        if let detector, case .line = detector.shape, detector.enabled, profileRequest != nil {
            // During a drag every move asks for a new curve: the newest one stays dimmed
            // until the drag ends, rather than blinking between full and held strength.
            if model.isTracking, let held, held.detectorID == detector.id {
                return .chart(held.points, .updating, lengthUm: held.lengthUm)
            }
            if let points = currentPoints {
                guard !points.isEmpty else { return .message("This line lies outside the solved field.") }
                return .chart(points, model.readingsAreStale ? .dimmed(0.45) : .live, lengthUm: nil)
            }
            if let held, held.detectorID == detector.id {
                return .chart(held.points, .updating, lengthUm: held.lengthUm)
            }
            return .chart([], .pending, lengthUm: nil)
        }
        if model.solver.shown == nil { return .message("Nothing solved yet") }
        if let detector, !detector.enabled { return .message("This detector is disabled.") }
        return .message(#"Select a line detector to see $|E|^2$ along it."#)
    }

    private var profileRequest: ProfileKey? {
        guard let detector = model.resultsDetector, detector.enabled, case .line(let line) = detector.shape else { return nil }
        return model.profileKey(for: line)
    }
}

private struct HideResultsButton: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("HideResultsButton")
        Button("Hide Results", systemImage: "chevron.down") { model.isResultsPresented = false }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Hide the results (⌥⌘R)")
    }
}

private struct SideBySideResults: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("SideBySideResults")
        HStack(alignment: .top, spacing: 0) {
            DetectorTableSection(model: model)
                .padding(12)
                .frame(minWidth: 340, idealWidth: 420, maxWidth: 520)
            Divider()
            ProfileSection(model: model)
                .padding(12)
                .frame(minWidth: 260, maxWidth: .infinity)
        }
    }
}

/// One part at a time, chosen with a segmented control.
private struct StackedResults: View {
    enum Part: Hashable { case table, profile }

    let model: AppState
    @UIState private var part = Part.table

    var body: some View {
        let _ = PerfProbe.body("StackedResults")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Results", selection: $part) {
                    Text("Table").tag(Part.table)
                    Text("Profile").tag(Part.profile)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show the detector table or the profile along the selected line detector")
                if model.readingsAreStale {
                    PanelHeader(title: "", stale: true) { EmptyView() }
                        .fixedSize()
                }
                Spacer(minLength: 8)
                HideResultsButton(model: model)
            }
            switch part {
            case .table: DetectorTableSection(model: model, showsHeader: false)
            case .profile: ProfileSection(model: model, showsHeader: false)
            }
        }
        .padding(12)
    }
}

/// No detectors yet: what they are for, and buttons to add one.
private struct ResultsEmptyState: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("ResultsEmptyState")
        VStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No detectors")
                .font(.headline)
            Text("Add a line detector to measure power through it, or a box detector to measure the field in an area.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Button("Add Line Detector") { model.addDetector(.line) }
                    .help("Add a line detector that measures the power through it")
                Button("Add Box Detector") { model.addDetector(.box) }
                    .help("Add a box detector that measures the mean intensity inside it")
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            HideResultsButton(model: model)
                .padding(8)
        }
    }
}

import SwiftUI

/// Every detector with its reading on the shown field. Selecting a row selects the
/// detector in the sidebar and on the canvas.
struct DetectorTable: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("DetectorTable")
        let rows = model.resultRows
        let stale = model.readingsAreStale
        let hasField = model.solver.shown != nil
        Table(rows, selection: selection) {
            // The kind shows as the sidebar's symbol, and in words for VoiceOver.
            TableColumn("Detector") { row in
                Label {
                    Text(row.name)
                        .lineLimit(1)
                        .foregroundStyle(row.enabled ? .primary : .secondary)
                } icon: {
                    Image(systemName: row.kind.symbol)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("\(row.name), \(row.kind.rowTitle.lowercased())")
            }
            .width(min: 90, ideal: 130)
            TableColumn("Total") { row in
                value(row.total, row: row, hasField: hasField, showsState: true)
            }
            .width(min: 56, ideal: 68)
            .alignment(.numeric)
            TableColumn("Incident") { row in
                value(row.incident, row: row, hasField: hasField, showsState: false)
            }
            .width(min: 56, ideal: 68)
            .alignment(.numeric)
            TableColumn("Ratio") { row in
                value(row.ratio, row: row, hasField: hasField, showsState: false, isRatio: true)
                    .help(ifAny: row.enabled && row.ratio == nil && row.total != nil ? "Nothing is incident on this detector, so there is no ratio" : nil)
            }
            .width(min: 44, ideal: 52)
            .alignment(.numeric)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .opacity(stale ? 0.5 : 1)
        .accessibilityLabel(stale ? "Detector readings, out of date" : "Detector readings")
    }

    /// A number right-aligned with monospaced digits; "Disabled" or "—" where there is none.
    @ViewBuilder
    private func value(_ number: Double?, row: DetectorResultRow, hasField: Bool, showsState: Bool, isRatio: Bool = false) -> some View {
        Group {
            if !row.enabled {
                Text(showsState ? "Disabled" : "")
            } else if let number {
                // Ratios as plain numbers to two decimals, as elsewhere in the app.
                Text(isRatio ? Format.number(number, digits: 2...2) : Format.significant(number))
            } else {
                Text(hasField || !showsState ? "—" : "Not solved")
            }
        }
        .monospacedDigit()
        .foregroundStyle(row.enabled && number != nil ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.resultsSelection },
            set: { id in
                model.resultsSelection = id
                if let id { model.selection = .detector(id) }
            }
        )
    }
}

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A value snapshot of the shown field at the output size, rendered to PNG only when it is
/// asked for.
public struct PNGExport: Transferable, Sendable {
    /// The solved field; nil until the first solve finishes.
    public var field: FieldHandle?
    public var viewJSON: String
    public var overlay: OverlayModel
    public var width: Int
    public var height: Int
    /// Told when rendering starts and ends, so the window can show progress.
    public var onBusyChange: @Sendable (Bool) async -> Void = { _ in }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { export in
            try await export.pngData()
        }
    }

    public func pngData() async throws -> Data {
        await onBusyChange(true)
        do {
            let data = try await ImageExportService.pngData(for: self)
            await onBusyChange(false)
            return data
        } catch {
            await onBusyChange(false)
            throw error
        }
    }
}

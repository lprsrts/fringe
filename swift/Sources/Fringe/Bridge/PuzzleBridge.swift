import CFringeCore
import Foundation

// Wrappers for the core's puzzle functions (list, get, evaluation job, per-source fields and
// their combination), detector re-measurement and the core's own v2 upgrade (ABI 3).

extension FringeBridge {
    /// Every bundled puzzle, sorted by chapter, then order.
    public static func puzzleList() -> [PuzzleSummary] {
        guard let json = takeString(fringe_puzzle_list()) else { return [] }
        return (try? decode([PuzzleSummary].self, from: json)) ?? []
    }

    /// The raw JSON of `fringe_puzzle_list()`.
    public static func puzzleListJSON() -> String {
        takeString(fringe_puzzle_list()) ?? "[]"
    }

    /// The whole puzzle JSON as the core has it; nil for an unknown id.
    public static func puzzleJSON(_ id: String) -> String? {
        takeString(fringe_puzzle_get(id))
    }

    public static func puzzle(_ id: String) -> Puzzle? {
        puzzleJSON(id).flatMap { try? decode(Puzzle.self, from: $0) }
    }

    /// The core's version 3 JSON for a version 2 scene.
    public static func sceneUpgradeJSON(_ json: String) -> String? {
        takeString(fringe_scene_upgrade(json))
    }
}

extension FieldHandle {
    /// Readings of `detectors` on this field without solving again; empty when the core
    /// cannot read the detectors.
    public func measure(_ detectors: [Detector]) -> [DetectorReading] {
        guard let json = try? FringeBridge.encode(detectors),
              let out = FringeBridge.takeString(fringe_field_measure(field, json)) else { return [] }
        return (try? FringeBridge.decode([DetectorReading].self, from: out)) ?? []
    }

    /// The sum of `fields` with complex `weights`, all on the same grid: how a puzzle shows
    /// any input case from its per-source fields without solving again.
    public static func combine(_ fields: [FieldHandle], weights: [(re: Double, im: Double)]) throws -> FieldHandle {
        guard !fields.isEmpty, fields.count == weights.count else {
            throw FringeError(code: "combine", message: "Each field needs one weight.")
        }
        let pointers: [OpaquePointer?] = fields.map { $0.field }
        let re = weights.map(\.re)
        let im = weights.map(\.im)
        var error: UnsafeMutablePointer<CChar>?
        let combined = pointers.withUnsafeBufferPointer { p in
            re.withUnsafeBufferPointer { r in
                im.withUnsafeBufferPointer { i in
                    fringe_field_combine(p.baseAddress, r.baseAddress, i.baseAddress, fields.count, &error)
                }
            }
        }
        guard let combined else { throw FringeError.take(error) }
        return FieldHandle(combined)
    }
}

/// A puzzle evaluation on a background thread: one solve per source, then every input
/// case measured. Poll it like `JobHandle`; take the result once it is done.
public final class PuzzleJobHandle: @unchecked Sendable {
    private let job: OpaquePointer

    /// `solutionJSON`: a JSON array of the player's elements.
    public init(puzzleID: String, solutionJSON: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let job = fringe_puzzle_job_start(puzzleID, solutionJSON, &error) else {
            throw FringeError.take(error)
        }
        self.job = job
    }

    deinit {
        fringe_job_free(job)
    }

    public func poll() -> FringeProgress {
        var progress = FringeProgress()
        fringe_job_poll(job, &progress)
        return progress
    }

    public var isRunning: Bool { poll().state == FRINGE_JOB_RUNNING }

    public func cancel() {
        fringe_job_cancel(job)
    }

    /// The result once the job is done; nil while it runs. Throws if it failed or was
    /// cancelled.
    public func takeResult() throws -> PuzzleResultHandle? {
        guard !isRunning else { return nil }
        var error: UnsafeMutablePointer<CChar>?
        guard let result = fringe_puzzle_job_take_result(job, &error) else {
            throw FringeError.take(error)
        }
        return PuzzleResultHandle(result)
    }
}

/// A finished puzzle evaluation: the scores and readings as JSON, and one field per source.
public final class PuzzleResultHandle: @unchecked Sendable {
    public let json: String
    public let evaluation: PuzzleEvaluation?
    /// Why `evaluation` is nil, if it is.
    public let decodingError: String?
    /// In the order of `evaluation.sources`.
    public let fields: [FieldHandle]

    private let result: OpaquePointer

    init(_ result: OpaquePointer) {
        self.result = result
        json = FringeBridge.takeString(fringe_puzzle_result_json(result)) ?? "{}"
        do {
            evaluation = try FringeBridge.decode(PuzzleEvaluation.self, from: json)
            decodingError = nil
        } catch {
            evaluation = nil
            decodingError = "\(error)"
        }
        let count = fringe_puzzle_result_field_count(result)
        fields = (0..<count).compactMap { i in fringe_puzzle_result_field(result, i).map(FieldHandle.init) }
    }

    deinit {
        fringe_puzzle_result_free(result)
    }
}

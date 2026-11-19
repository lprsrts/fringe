import Foundation
import os

/// What the player has done in one puzzle: kept on this Mac only, in UserDefaults.
public struct PuzzleProgress: Codable, Equatable, Sendable {
    /// The best score a Check gave, in the puzzle's unit.
    public var bestScore: Double?
    /// Stars of the best passing Check, 0…3.
    public var stars = 0
    public var passed = false
    public var hintsShown = 0
    /// The player's elements as they last were (starting parts included, locked ones not).
    public var design: [Element]?
    /// When the puzzle was first passed.
    public var solvedAt: Date?
    /// The stored design could not be decoded (not saved; see `PuzzleProgressStore.load`).
    var designUnreadable = false

    public init(bestScore: Double? = nil, stars: Int = 0, passed: Bool = false, hintsShown: Int = 0,
                design: [Element]? = nil, solvedAt: Date? = nil) {
        self.bestScore = bestScore
        self.stars = stars
        self.passed = passed
        self.hintsShown = hintsShown
        self.design = design
        self.solvedAt = solvedAt
    }

    enum CodingKeys: String, CodingKey {
        case bestScore = "best_score"
        case stars
        case passed
        case hintsShown = "hints_shown"
        case design
        case solvedAt = "solved_at"
    }

    // Lenient, so a store written by another build never loses the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bestScore = try? c.decodeIfPresent(Double.self, forKey: .bestScore)
        stars = min(3, max(0, (try? c.decodeIfPresent(Int.self, forKey: .stars)) ?? 0))
        passed = (try? c.decodeIfPresent(Bool.self, forKey: .passed)) ?? false
        hintsShown = max(0, (try? c.decodeIfPresent(Int.self, forKey: .hintsShown)) ?? 0)
        // A design another build wrote may not decode: the rest of the entry stays, and the
        // store copies its data aside before anything is saved over it.
        if c.contains(.design), (try? c.decodeNil(forKey: .design)) != true {
            design = try? c.decode([Element].self, forKey: .design)
            designUnreadable = design == nil
        }
        solvedAt = try? c.decodeIfPresent(Date.self, forKey: .solvedAt)
    }

    /// What a Check changed in the progress.
    public struct RecordOutcome: Equatable, Sendable {
        /// Anything changed (the store needs saving).
        public var changed = false
        /// The score beat a best that existed.
        public var newBest = false
        /// Passed for the first time.
        public var firstSolve = false
        /// Stars gained over the best before.
        public var newStars = 0
    }

    /// Takes in a Check: the score, stars and pass are kept when they are better.
    @discardableResult
    public mutating func record(score: Double?, stars newStars: Int, passed newPassed: Bool, at date: Date = Date()) -> RecordOutcome {
        let before = self
        var outcome = RecordOutcome()
        if let score, score.isFinite, bestScore.map({ score > $0 }) ?? true {
            outcome.newBest = bestScore != nil
            bestScore = score
        }
        stars = max(stars, min(3, max(0, newStars)))
        outcome.newStars = stars - before.stars
        if newPassed, !passed {
            passed = true
            solvedAt = date
            outcome.firstSolve = true
        }
        outcome.changed = self != before
        return outcome
    }
}

/// Puzzle progress by puzzle id, as JSON in UserDefaults. No network, no accounts. Ids the
/// core no longer lists are kept, in case a later core brings the puzzle back.
enum PuzzleProgressStore {
    static let key = "fringe.puzzles.progress.v1"
    private static let log = Logger(subsystem: "com.asympton.fringe", category: "puzzles")

    /// Where data that could not be read is kept, so a later save cannot destroy it.
    static let unreadableKey = "fringe.puzzles.progress.unreadable"

    /// Reads the store entry by entry, so one bad entry loses only itself. When anything
    /// cannot be read, the stored data is first copied to `unreadableKey` (once; an older
    /// copy is kept), since the next save writes only what was read.
    static func load(from defaults: UserDefaults = .standard) -> [String: PuzzleProgress] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        if let all = try? JSONDecoder().decode([String: PuzzleProgress].self, from: data) {
            if all.values.contains(where: \.designUnreadable) {
                // The next save drops the design that did not decode: keep the data first.
                if defaults.data(forKey: unreadableKey) == nil { defaults.set(data, forKey: unreadableKey) }
                log.error("A saved puzzle design could not be read; the stored data is copied to \(unreadableKey)")
            }
            return all
        }
        var progress: [String: PuzzleProgress] = [:]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (id, value) in object {
                guard JSONSerialization.isValidJSONObject([value]),
                      let entry = try? JSONSerialization.data(withJSONObject: [value]),
                      let decoded = try? JSONDecoder().decode([PuzzleProgress].self, from: entry).first
                else { continue }
                progress[id] = decoded
            }
        }
        if defaults.data(forKey: unreadableKey) == nil {
            defaults.set(data, forKey: unreadableKey)
        }
        log.error("Puzzle progress could not all be read; kept \(progress.count) puzzles, the stored data is copied to \(unreadableKey)")
        return progress
    }

    /// Chapters whose completion was celebrated once (the reveal's chapter line).
    static let celebratedKey = "fringe.puzzles.celebrated.v1"

    static func celebratedChapters(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: celebratedKey) ?? [])
    }

    static func markCelebrated(_ chapter: String, in defaults: UserDefaults = .standard) {
        var all = celebratedChapters(in: defaults)
        guard all.insert(chapter).inserted else { return }
        defaults.set(all.sorted(), forKey: celebratedKey)
    }

    static func save(_ progress: [String: PuzzleProgress], to defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(progress), forKey: key)
        } catch {
            log.error("Puzzle progress could not be saved: \(error.localizedDescription)")
        }
    }
}

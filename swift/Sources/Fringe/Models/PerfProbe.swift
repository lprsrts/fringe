import Foundation
import os

/// Debug counters for the headless profiler (scripts/perf.sh). Off unless that harness
/// turns them on: then each call costs one flag check.
public enum PerfProbe {
    nonisolated(unsafe) public static var enabled = false

    public struct Entry: Sendable {
        public var count = 0
        public var nanos: UInt64 = 0
    }

    private static let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())

    /// Counts one event.
    @inline(__always)
    public static func count(_ name: String, by n: Int = 1) {
        guard enabled else { return }
        entries.withLock { $0[name, default: Entry()].count += n }
    }

    /// Counts one evaluation of a view's body: `let _ = PerfProbe.body("Name")`.
    @inline(__always)
    public static func body(_ name: String) -> Int {
        guard enabled else { return 0 }
        count("body." + name)
        return 0
    }

    /// Runs `work`, counting it and adding its wall time to `name`.
    @inline(__always)
    public static func time<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            entries.withLock {
                $0[name, default: Entry()].count += 1
                $0[name, default: Entry()].nanos += elapsed
            }
        }
        return try work()
    }

    public static func snapshot() -> [String: Entry] {
        entries.withLock { $0 }
    }
}

import Foundation

/// Entry point. `--self-test-schema` checks the scene schema against the core and
/// `--reveal-self-test` the puzzle reveal plans; both exit before any window or AppKit state
/// exists. Everything else starts the app.
@main
enum FringeMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test-schema") {
            let failures = SchemaSelfTest.run()
            print(failures.isEmpty
                  ? "Schema self-test passed."
                  : "Schema self-test failed for \(failures.count) scene(s).")
            exit(failures.isEmpty ? 0 : 1)
        }
        if CommandLine.arguments.contains("--reveal-self-test") {
            let failures = RevealSelfTest.run()
            print(failures == 0 ? "Reveal self-test passed." : "Reveal self-test failed: \(failures) check(s).")
            exit(failures == 0 ? 0 : 1)
        }
        FringeApp.main()
    }
}

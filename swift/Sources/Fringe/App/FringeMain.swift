import Foundation

/// Entry point. `--self-test-schema` checks the scene schema against the core and exits
/// before any window or AppKit state exists; everything else starts the app.
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
        FringeApp.main()
    }
}

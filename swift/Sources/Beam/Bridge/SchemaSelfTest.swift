import Foundation

/// `Beam --self-test-schema`: checks that the Swift scene model and the core agree on the
/// JSON schema, without opening a window.
///
/// For the default scene and every example it decodes the core's JSON into `SimScene`,
/// re-encodes it, compares the two JSON trees, runs the core's check on the re-encoded
/// scene (it must be free of errors), decodes it again (it must equal the first decode)
/// and decodes the core's overlay outlines for it.
public enum SchemaSelfTest {
    public struct Failure: Sendable {
        public var scene: String
        public var message: String
    }

    /// Runs the test and returns the failures; empty means it passed.
    public static func run(log: (String) -> Void = { print($0) }) -> [Failure] {
        var failures: [Failure] = []
        var cases: [(String, String?)] = [("default", BeamBridge.defaultSceneJSON())]
        let examples = BeamBridge.examples()
        if examples.isEmpty {
            failures.append(Failure(scene: "examples", message: "the core lists no examples"))
        }
        for example in examples {
            cases.append((example.name, BeamBridge.exampleSceneJSON(example.name)))
        }

        for (name, json) in cases {
            guard let json else {
                failures.append(Failure(scene: name, message: "the core returned no JSON"))
                continue
            }
            if let problem = check(json: json) {
                failures.append(Failure(scene: name, message: problem))
                log("FAIL \(name): \(problem)")
            } else {
                log("ok   \(name)")
            }
        }
        return failures
    }

    /// nil when the scene round-trips; otherwise what went wrong.
    public static func check(json: String) -> String? {
        let first: SimScene
        do {
            first = try SimScene.decode(json: json)
        } catch {
            return "decoding failed: \(error)"
        }
        let encoded = first.jsonString()
        guard let original = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary,
              let again = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? NSDictionary else {
            return "the JSON is not an object"
        }
        if !original.isEqual(again) {
            return "re-encoding changed the JSON:\n  core:  \(json)\n  swift: \(encoded)"
        }
        let report = BeamBridge.check(json: encoded)
        if !report.ok {
            let messages = report.errors.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
            return "the core rejected the re-encoded scene: \(messages)"
        }
        let second: SimScene
        do {
            second = try SimScene.decode(json: encoded)
        } catch {
            return "decoding the re-encoded scene failed: \(error)"
        }
        if second != first {
            return "the second decode differs from the first"
        }
        // The overlay geometry decodes too, and its enabled bodies belong to exactly
        // the enabled elements (disabled ones are listed as well, flagged).
        guard let outlines = try? BeamBridge.decode(SceneOutlines.self, from: BeamBridge.outlinesJSON(encoded)) else {
            return "the core's outlines JSON does not decode"
        }
        let enabledIDs = Set(first.elements.filter(\.enabled).map(\.id))
        if Set(outlines.bodies.filter(\.enabled).map(\.elementId)) != enabledIDs {
            return "the outlines do not match the enabled elements"
        }
        return nil
    }
}

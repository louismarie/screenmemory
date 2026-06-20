import Foundation

/// Centralized on-disk locations. The recaps dir predates this and stays as-is; the new
/// proactive artifacts (coach, weekly, morning digests) get sibling dirs so retention and
/// the dashboard can find them. All under $HOME, all plaintext markdown (summaries only —
/// the raw screens stay encrypted in the .db).
enum Paths {
    static var home: String { NSHomeDirectory() }
    private static func sub(_ name: String) -> String {
        let p = (home as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    static var recaps: String { sub(".screenmemory.recaps") }
    static var coach: String { sub(".screenmemory.coach") }
    static var weekly: String { sub(".screenmemory.weekly") }
    static var digests: String { sub(".screenmemory.digests") }
    static var proactiveState: String { (home as NSString).appendingPathComponent(".screenmemory.proactive.json") }

    static func file(_ dir: String, _ name: String) -> String {
        (dir as NSString).appendingPathComponent(name)
    }
    static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    @discardableResult static func write(_ text: String, to path: String) -> Bool {
        (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}

import Foundation

/// Local macOS notifications for proactive insights. Uses `osascript display notification`,
/// which needs no entitlement and works whether launched as a .app or from the CLI — the
/// pragmatic, reliable path for a self-hosted tool. Notifications never contain memory
/// content beyond a short headline the user already authored by using their machine.
enum Notify {
    /// Post a banner. `subtitle`/`sound` optional. Best-effort: failures are swallowed.
    static func post(title: String, subtitle: String = "", body: String, sound: Bool = false) {
        func esc(_ s: String) -> String {
            // AppleScript string: escape backslash and double-quote, strip newlines.
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: " ")
        }
        var script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        if !subtitle.isEmpty { script += " subtitle \"\(esc(subtitle))\"" }
        if sound { script += " sound name \"Glass\"" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
    }
}

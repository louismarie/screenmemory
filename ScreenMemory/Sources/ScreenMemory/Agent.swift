import Foundation

/// Always-on delivery: a launchd LaunchAgent that runs `capture` in the background,
/// relaunched on logout/crash. This is what turns the CLI into an always-on service.
enum Agent {
    static let label = "com.screenmemory.agent"
    static var plistPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var logPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/screenmemory.log")
    }

    static func install(fps: Int) {
        guard let exe = Bundle.main.executableURL?.standardizedFileURL.path else {
            print("cannot resolve executable path"); return
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(exe)</string>
                <string>capture</string>
                <string>\(fps)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>StandardOutPath</key><string>\(logPath)</string>
            <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict>
        </plist>
        """
        let dir = (plistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            print("failed to write plist: \(error)"); return
        }
        _ = launchctl(["unload", plistPath])            // idempotent: drop any previous
        let rc = launchctl(["load", "-w", plistPath])
        print(rc == 0
            ? "installed + loaded: \(label) (capture @ \(fps)fps)\n  plist: \(plistPath)\n  log:   \(logPath)"
            : "plist written but launchctl load failed (rc \(rc))")
    }

    static func uninstall() {
        _ = launchctl(["unload", "-w", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
        print("uninstalled: \(label)")
    }

    static func status() {
        let out = launchctlOutput(["list"])
        let line = out.split(separator: "\n").first { $0.contains(label) }
        print(line.map { "running: \($0.trimmingCharacters(in: .whitespaces))" }
              ?? "not loaded (use 'agent-install')")
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private static func launchctlOutput(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

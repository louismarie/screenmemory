import Foundation

/// Productivity & focus analytics computed from the session timeline.
///
/// Everything is derived from the same `Recap.sessions` grouping (app + window + gaps),
/// so analytics, recap and coach all agree on what a "session" is. No new storage:
/// this is a pure read over decrypted chunks for a time window.
enum Analytics {

    /// Apps that count as distraction by default. Matched case-insensitively against the
    /// localized app name (substring). Extend/override via ~/.screenmemory.distract
    /// (one app-name fragment per line). Browsers are deliberately NOT here — too ambiguous.
    static func distractionApps() -> [String] {
        var apps = ["twitter", "x ", "instagram", "facebook", "reddit", "youtube",
                    "tiktok", "netflix", "twitch", "discord", "messages", "whatsapp"]
        let file = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.distract")
        if let txt = try? String(contentsOfFile: file, encoding: .utf8) {
            // A non-empty file REPLACES the defaults (lets the user fully own the list).
            let custom = txt.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            if !custom.isEmpty { apps = custom }
        }
        return apps
    }

    struct AppTime: Codable { let app: String; let minutes: Int }
    struct HourBucket: Codable { let hour: Int; let minutes: Int }

    /// A self-contained focus report for a window of days. Codable -> CLI JSON + dashboard.
    struct FocusReport: Codable {
        let days: Int
        let from: Double
        let to: Double
        let activeMinutes: Int            // total time the screen was being used
        let deepWorkMinutes: Int          // time in focused blocks (>= deepBlockMinutes, single app)
        let fragmentedMinutes: Int        // time in micro-sessions (< fragmentMaxMinutes)
        let distractionMinutes: Int       // time in distraction apps
        let focusScore: Int               // 0-100: deepWork / active
        let contextSwitchesPerHour: Double
        let peakHour: Int                 // hour-of-day (0-23) with the most activity, -1 if none
        let longestFocusMinutes: Int      // single longest uninterrupted same-app block
        let topApps: [AppTime]            // descending by minutes
        let byHour: [HourBucket]          // 0..23, minutes of activity per hour-of-day
        let sessionCount: Int
    }

    static let deepBlockMinutes = 15.0    // a session this long+ on one app = deep work
    static let fragmentMaxMinutes = 3.0   // a session this short = fragmented attention

    /// Window report ending now, spanning `days`.
    static func report(days: Int, store: Store) -> FocusReport {
        let now = Date().timeIntervalSince1970
        return report(from: now - Double(max(1, days)) * 86400, to: now, days: days, store: store)
    }

    /// Report over an explicit [from,to] range (used by Coach for a calendar day).
    /// Chunks with no app (legacy/reindex rows) are excluded: their time is unattributable
    /// and they duplicate the real captured chunks, which would otherwise inflate deep-work.
    static func report(from: Double, to: Double, days: Int, store: Store) -> FocusReport {
        let chunks = store.allChunks(from: from, to: to).filter { !$0.app.isEmpty }
        let sessions = Recap.sessions(chunks: chunks)
        let distract = distractionApps()
        let cal = Calendar.current

        var perApp = [String: Double]()        // seconds
        var byHour = [Int: Double]()           // hour-of-day -> seconds
        var active = 0.0, deep = 0.0, fragmented = 0.0, distraction = 0.0
        var longest = 0.0
        var switches = 0
        var lastApp: String? = nil

        for s in sessions {
            // A session shorter than the capture floor still represents real time on screen;
            // floor at 60s so a single captured screen counts as ~a minute, matching `analytics`.
            let dur = max(60, s.end - s.start)
            let app = s.app.isEmpty ? "(inconnu)" : s.app
            perApp[app, default: 0] += dur
            active += dur
            if dur >= deepBlockMinutes * 60 { deep += dur }
            if dur < fragmentMaxMinutes * 60 { fragmented += dur }
            if distract.contains(where: { app.lowercased().contains($0) }) { distraction += dur }
            longest = max(longest, dur)
            // Distribute the session's time across the hour buckets it spans.
            var t = s.start
            while t < s.end {
                let h = cal.component(.hour, from: Date(timeIntervalSince1970: t))
                let next = min(s.end, t + 3600)
                byHour[h, default: 0] += max(0, next - t)
                t = next
            }
            if let la = lastApp, la != app { switches += 1 }
            lastApp = app
        }

        let activeHours = max(active / 3600, 0.0001)
        let peak = byHour.max { $0.value < $1.value }?.key ?? -1
        let topApps = perApp.sorted { $0.value > $1.value }
            .prefix(12).map { AppTime(app: $0.key, minutes: Int($0.value / 60)) }
        let hourBuckets = (0..<24).map { HourBucket(hour: $0, minutes: Int((byHour[$0] ?? 0) / 60)) }

        return FocusReport(
            days: days, from: from, to: to,
            activeMinutes: Int(active / 60),
            deepWorkMinutes: Int(deep / 60),
            fragmentedMinutes: Int(fragmented / 60),
            distractionMinutes: Int(distraction / 60),
            focusScore: active > 0 ? Int((deep / active) * 100) : 0,
            contextSwitchesPerHour: (Double(switches) / activeHours * 10).rounded() / 10,
            peakHour: peak,
            longestFocusMinutes: Int(longest / 60),
            topApps: topApps,
            byHour: hourBuckets,
            sessionCount: sessions.count
        )
    }

    /// A compact human-readable brief of a report — fed to the on-device model (coach/weekly)
    /// and shown in the menubar. Deterministic, no LLM, always available.
    static func brief(_ r: FocusReport) -> String {
        func hm(_ m: Int) -> String { m >= 60 ? "\(m/60)h\(String(format: "%02d", m%60))" : "\(m)min" }
        var lines = [String]()
        lines.append("Temps actif: \(hm(r.activeMinutes)) sur \(r.days) j")
        lines.append("Deep work: \(hm(r.deepWorkMinutes)) (focus \(r.focusScore)/100), plus longue session \(hm(r.longestFocusMinutes))")
        lines.append("Fragmenté: \(hm(r.fragmentedMinutes)) · changements de contexte: \(r.contextSwitchesPerHour)/h")
        if r.distractionMinutes > 0 { lines.append("Distraction: \(hm(r.distractionMinutes))") }
        if r.peakHour >= 0 { lines.append("Pic de focus: \(r.peakHour)h") }
        let top = r.topApps.prefix(6).map { "\($0.app) \(hm($0.minutes))" }.joined(separator: ", ")
        if !top.isEmpty { lines.append("Top apps: \(top)") }
        return lines.joined(separator: "\n")
    }
}

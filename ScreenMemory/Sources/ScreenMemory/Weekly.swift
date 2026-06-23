import Foundation
import FoundationModels

@Generable
struct WeekDigest {
    @Guide(description: "A 3-4 sentence weekly synthesis: where time went and the main thread.")
    var summary: String
    @Guide(description: "3 to 6 notable achievements or advances from the week.")
    var achievements: [String]
    @Guide(description: "Open threads to resume next week, 0 to 5.")
    var openThreads: [String]
    @Guide(description: "1 to 3 observations about the week's work patterns.")
    var patterns: [String]
}

/// Weekly synthesis — a map-reduce over the week's daily recaps. Each finished day already
/// has a cached recap markdown (the permanent summary layer); we feed those digests (not the
/// raw screens) to the model for a roll-up. This keeps it cheap and works even after `prune`
/// has deleted the raw rows.
enum Weekly {

    struct Result {
        let from: Date
        let to: Date
        let report: Analytics.FocusReport
        let digest: WeekDigest?
        let dailySummaries: [(date: String, summary: String)]
    }

    static func generate(endingDay: Date,
                         store: Store,
                         summarize: Bool = true,
                         language: AppLanguage = .english) async -> Result {
        let cal = Calendar.current
        let end = cal.startOfDay(for: endingDay)
        let start = cal.date(byAdding: .day, value: -6, to: end)!
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        // Metrics for the 7 days ENDING on endingDay (not "last 7 days from now").
        let report = Analytics.report(from: start.timeIntervalSince1970,
                                      to: end.timeIntervalSince1970 + 86400, days: 7, store: store)
        guard summarize else {
            return Result(from: start, to: end, report: report, digest: nil, dailySummaries: [])
        }

        // Collect each day's recap summary — prefer the cached markdown, else generate on the fly.
        var daily = [(date: String, summary: String)]()
        for offset in 0..<7 {
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            if day > end { break }
            let summary = await daySummary(day: day, store: store, language: language)
            if !summary.isEmpty { daily.append((df.string(from: day), summary)) }
        }

        guard case .available = SystemLanguageModel.default.availability, !daily.isEmpty else {
            return Result(from: start, to: end, report: report, digest: nil, dailySummaries: daily)
        }

        let body = daily.map { "## \($0.date)\n\($0.summary)" }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: """
            Write a weekly synthesis for a knowledge worker from daily work journals and time
            metrics. Be factual and useful for reviewing the week and preparing the next one.
            Extract cross-day themes, not just a concatenation. Do not invent anything.
            \(language.modelInstruction)
            """)
        let prompt = """
            Weekly metrics:
            \(Analytics.brief(report))

            Daily journals:
            \(String(body.prefix(6000)))
            """
        let digest = try? await session.respond(to: prompt, generating: WeekDigest.self).content
        return Result(from: start, to: end, report: report, digest: digest, dailySummaries: daily)
    }

    /// One day's summary text: cached recap markdown's summary block if present, else a fresh recap.
    private static func daySummary(day: Date, store: Store, language: AppLanguage) async -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.recaps")
        let path = (dir as NSString).appendingPathComponent("\(df.string(from: day)).md")
        if let md = try? String(contentsOfFile: path, encoding: .utf8), !md.isEmpty {
            // Strip the markdown headers; keep the prose so the model gets the gist compactly.
            return md.replacingOccurrences(of: "# Recap — \(df.string(from: day))", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let r = await Recap.generate(day: day, store: store, language: language)
        return r.digest?.summary ?? ""
    }

    static func markdown(_ r: Result, language: AppLanguage = .english) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var md = "# Weekly synthesis — \(df.string(from: r.from)) → \(df.string(from: r.to))\n\n"
        if let d = r.digest {
            md += d.summary + "\n\n"
            if !d.achievements.isEmpty { md += "## \(language.heading(.achievements))\n" + d.achievements.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !d.openThreads.isEmpty { md += "## \(language.heading(.unfinished))\n" + d.openThreads.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !d.patterns.isEmpty { md += "## \(language.heading(.patterns))\n" + d.patterns.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        } else {
            md += "_\(language.notEnoughActivity)_\n\n"
        }
        md += "## \(language.heading(.time))\n```\n" + Analytics.brief(r.report) + "\n```\n"
        return md
    }
}

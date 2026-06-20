import Foundation
import FoundationModels

@Generable
struct WeekDigest {
    @Guide(description: "Synthèse de la semaine en 3-4 phrases (français) : sur quoi le temps est passé, fil conducteur.")
    var summary: String
    @Guide(description: "3 à 6 accomplissements ou avancées marquantes de la semaine.")
    var achievements: [String]
    @Guide(description: "Sujets restés ouverts / à reprendre la semaine prochaine (0 à 5).")
    var openThreads: [String]
    @Guide(description: "1 à 3 observations sur les habitudes de travail de la semaine (rythme, focus, dispersion).")
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

    static func generate(endingDay: Date, store: Store) async -> Result {
        let cal = Calendar.current
        let end = cal.startOfDay(for: endingDay)
        let start = cal.date(byAdding: .day, value: -6, to: end)!
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        // Metrics for the 7 days ENDING on endingDay (not "last 7 days from now").
        let report = Analytics.report(from: start.timeIntervalSince1970,
                                      to: end.timeIntervalSince1970 + 86400, days: 7, store: store)

        // Collect each day's recap summary — prefer the cached markdown, else generate on the fly.
        var daily = [(date: String, summary: String)]()
        for offset in 0..<7 {
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            if day > end { break }
            let summary = await daySummary(day: day, store: store)
            if !summary.isEmpty { daily.append((df.string(from: day), summary)) }
        }

        guard case .available = SystemLanguageModel.default.availability, !daily.isEmpty else {
            return Result(from: start, to: end, report: report, digest: nil, dailySummaries: daily)
        }

        let body = daily.map { "## \($0.date)\n\($0.summary)" }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: """
            Tu rédiges la synthèse hebdomadaire d'un travailleur du savoir à partir des \
            journaux de bord quotidiens et des métriques de temps. Français, factuel, utile \
            pour faire le point et préparer la semaine suivante. Dégage les fils conducteurs \
            transverses aux jours, pas une simple concaténation. N'invente rien.
            """)
        let prompt = """
            Métriques de la semaine:
            \(Analytics.brief(report))

            Journaux quotidiens:
            \(String(body.prefix(6000)))
            """
        let digest = try? await session.respond(to: prompt, generating: WeekDigest.self).content
        return Result(from: start, to: end, report: report, digest: digest, dailySummaries: daily)
    }

    /// One day's summary text: cached recap markdown's summary block if present, else a fresh recap.
    private static func daySummary(day: Date, store: Store) async -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.recaps")
        let path = (dir as NSString).appendingPathComponent("\(df.string(from: day)).md")
        if let md = try? String(contentsOfFile: path, encoding: .utf8), !md.isEmpty {
            // Strip the markdown headers; keep the prose so the model gets the gist compactly.
            return md.replacingOccurrences(of: "# Recap — \(df.string(from: day))", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let r = await Recap.generate(day: day, store: store)
        return r.digest?.summary ?? ""
    }

    static func markdown(_ r: Result) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var md = "# Synthèse hebdo — \(df.string(from: r.from)) → \(df.string(from: r.to))\n\n"
        if let d = r.digest {
            md += d.summary + "\n\n"
            if !d.achievements.isEmpty { md += "## Accomplissements\n" + d.achievements.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !d.openThreads.isEmpty { md += "## À reprendre\n" + d.openThreads.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            if !d.patterns.isEmpty { md += "## Habitudes\n" + d.patterns.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        } else {
            md += "_Pas assez de données cette semaine (ou Apple Intelligence indisponible)._\n\n"
        }
        md += "## Temps\n```\n" + Analytics.brief(r.report) + "\n```\n"
        return md
    }
}

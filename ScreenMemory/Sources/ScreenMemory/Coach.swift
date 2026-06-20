import Foundation
import FoundationModels

@Generable
struct CoachAdvice {
    @Guide(description: "Une phrase de constat factuel et bienveillant sur la journée de travail (français), basée sur les métriques fournies.")
    var observation: String
    @Guide(description: "2 à 3 suggestions concrètes et actionnables pour mieux travailler demain, formulées à la 2e personne (« Bloque tes matinées… »). Chaque suggestion = une action précise, pas un vœu pieux.")
    var suggestions: [String]
    @Guide(description: "Un point positif à conserver — ce qui a bien marché aujourd'hui.")
    var keepDoing: String
}

/// The proactive productivity coach. Takes the focus report (deterministic metrics) plus the
/// day's session summaries, and asks the on-device model for a short, grounded set of
/// suggestions to improve the next workday. Metrics are computed in Swift; the model only
/// phrases advice over them — it never invents numbers.
enum Coach {

    struct Result {
        let date: String
        let report: Analytics.FocusReport
        let advice: CoachAdvice?
    }

    static func generate(day: Date, store: Store) async -> Result {
        let cal = Calendar.current
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: day)

        // Single-day report (the coach is about *that* day; weekly handles the roll-up).
        let start = cal.startOfDay(for: day).timeIntervalSince1970
        let report = Analytics.report(from: start, to: start + 86400, days: 1, store: store)
        // Sessions (for the activity list) — include all chunks so titles/content show.
        let chunks = store.allChunks(from: start, to: start + 86400)
        let sessions = Recap.sessions(chunks: chunks.filter { !$0.app.isEmpty })

        guard case .available = SystemLanguageModel.default.availability, report.activeMinutes >= 5 else {
            return Result(date: dateStr, report: report, advice: nil)
        }

        // Context = deterministic metrics + a few session activity lines (what they were doing).
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let activity = sessions
            .filter { !$0.summary.isEmpty || ($0.end - $0.start) >= 600 }
            .prefix(20)
            .map { s -> String in
                let label = s.summary.isEmpty ? [s.app, s.title].filter { !$0.isEmpty }.joined(separator: " — ") : s.summary
                return "\(tf.string(from: Date(timeIntervalSince1970: s.start))) (\(s.minutes)min) \(label)"
            }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            Tu es un coach de productivité bienveillant et concret. À partir des métriques \
            d'une journée de travail (temps réellement passé par application, deep work vs \
            temps fragmenté, changements de contexte, distractions) et de la liste des \
            activités, tu donnes un retour utile et actionnable. Français. Pas de jargon, \
            pas de flatterie creuse. Appuie-toi UNIQUEMENT sur les chiffres et activités \
            fournis — n'invente aucune donnée. Sois spécifique : cite les apps/horaires réels.
            """)
        let prompt = """
            Métriques du \(dateStr):
            \(Analytics.brief(report))

            Activités de la journée:
            \(activity.isEmpty ? "(peu d'activité résumable)" : activity)
            """
        let advice = try? await session.respond(to: prompt, generating: CoachAdvice.self).content
        return Result(date: dateStr, report: report, advice: advice)
    }

    static func markdown(_ r: Result) -> String {
        var md = "# Coach — \(r.date)\n\n"
        if let a = r.advice {
            md += a.observation + "\n\n"
            if !a.suggestions.isEmpty {
                md += "## À améliorer\n" + a.suggestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
            if !a.keepDoing.isEmpty { md += "## À garder\n- \(a.keepDoing)\n\n" }
        } else {
            md += "_Pas assez d'activité ce jour-là (ou Apple Intelligence indisponible) pour un retour du coach._\n\n"
        }
        md += "## Chiffres\n```\n" + Analytics.brief(r.report) + "\n```\n"
        return md
    }
}

import Foundation
import FoundationModels

@Generable
struct CoachAdvice {
    @Guide(description: "Une phrase de constat factuel et bienveillant sur la journée de travail (français), basée sur les métriques et le contenu réellement vu.")
    var observation: String
    @Guide(description: "2 à 3 suggestions concrètes et actionnables pour mieux travailler demain, formulées à la 2e personne (« Bloque tes matinées… »). Chaque suggestion = une action précise, pas un vœu pieux.")
    var suggestions: [String]
    @Guide(description: "Un point positif à conserver — ce qui a bien marché aujourd'hui.")
    var keepDoing: String
    @Guide(description: "Radar techno : 0 à 4 lignes, chacune au format « <techno/framework/sujet réellement vu aujourd'hui> → <une piste concrète pour progresser ou approfondir> ». Appuie-toi UNIQUEMENT sur les titres et extraits fournis ; n'invente aucune techno ni actualité. Tableau vide si rien d'identifiable.")
    var techRadar: [String]
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

    static func generate(day: Date, store: Store, advise: Bool = true) async -> Result {
        let cal = Calendar.current
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: day)

        // Single-day report (the coach is about *that* day; weekly handles the roll-up).
        let start = cal.startOfDay(for: day).timeIntervalSince1970
        let report = Analytics.report(from: start, to: start + 86400, days: 1, store: store)
        guard advise else {
            return Result(date: dateStr, report: report, advice: nil)
        }
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

        // The tech radar needs *content*, not just time: the metrics can't reveal WHAT was
        // worked on. Feed distinct window titles + a short deduped OCR excerpt. Text was
        // already redacted at capture time, so no secrets reach the model.
        var seenTitle = Set<String>()
        let titles = chunks.compactMap { c -> String? in
            let t = c.title.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seenTitle.insert(t).inserted else { return nil }
            return t
        }.prefix(40).joined(separator: "\n")

        var seenTxt = Set<String>(); var excerpt = ""
        for c in chunks.sorted(by: { $0.ts < $1.ts }) {
            let line = c.text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard line.count > 20, seenTxt.insert(String(line.prefix(60))).inserted else { continue }
            if excerpt.count > 2500 { break }
            excerpt += "• " + line.prefix(220) + "\n"
        }

        let session = LanguageModelSession(instructions: """
            Tu es un coach de productivité et de veille techno, bienveillant et concret. À \
            partir des métriques d'une journée (temps par application, deep work vs temps \
            fragmenté, changements de contexte, distractions), de la liste des activités et \
            du CONTENU réellement vu à l'écran (titres de fenêtres, extraits OCR), tu donnes \
            un retour utile et actionnable. Français. Pas de jargon, pas de flatterie creuse. \
            Pour le radar techno, identifie les technologies, frameworks et sujets que la \
            personne a RÉELLEMENT consultés aujourd'hui et propose pour chacun une piste \
            concrète pour progresser. Appuie-toi UNIQUEMENT sur les données fournies — \
            n'invente aucun chiffre, aucune techno, aucune actualité absente du contenu. \
            Ne recommande JAMAIS un outil, produit, extension ou service précis que tu ne \
            vois pas explicitement dans les données (pas de « Forest », « Focus@Will », \
            d'extensions imaginaires, etc.) : propose des actions, pas des marques inventées. \
            Sois spécifique : cite les apps/sujets/horaires réels.
            """)
        let prompt = """
            Métriques du \(dateStr):
            \(Analytics.brief(report))

            Activités de la journée:
            \(activity.isEmpty ? "(peu d'activité résumable)" : activity)

            Fenêtres / onglets vus aujourd'hui:
            \(titles.isEmpty ? "(aucun titre)" : titles)

            Extraits de contenu à l'écran (OCR, bruité):
            \(excerpt.isEmpty ? "(pas d'extrait)" : excerpt)
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
            if !a.techRadar.isEmpty {
                md += "## Radar techno\n" + a.techRadar.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
        } else {
            md += "_Pas assez d'activité ce jour-là (ou Apple Intelligence indisponible) pour un retour du coach._\n\n"
        }
        md += "## Chiffres\n```\n" + Analytics.brief(r.report) + "\n```\n"
        return md
    }
}

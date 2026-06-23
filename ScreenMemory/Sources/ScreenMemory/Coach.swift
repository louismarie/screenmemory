import Foundation
import FoundationModels

@Generable
struct CoachAdvice {
    @Guide(description: "One factual and constructive observation about the workday, based on metrics and observed content.")
    var observation: String
    @Guide(description: "2 to 3 concrete suggestions for improving tomorrow. Each suggestion must be a precise action.")
    var suggestions: [String]
    @Guide(description: "One positive behavior to keep.")
    var keepDoing: String
    @Guide(description: "Tech radar: 0 to 4 lines, each in the format '<technology/framework/topic actually observed today> -> <one concrete learning or improvement path>'.")
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

    static func generate(day: Date,
                         store: Store,
                         advise: Bool = true,
                         language: AppLanguage = .english) async -> Result {
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
            You are a concrete productivity coach and technology radar analyst. Use only the
            provided daily metrics, activity list, window titles, and noisy OCR excerpts. Do not
            invent numbers, technologies, news, tools, products, extensions, or services that are
            absent from the data. Suggest actions, not made-up brands. Be specific: cite real
            apps, topics, and times from the data.
            \(language.modelInstruction)
            """)
        let prompt = """
            Metrics for \(dateStr):
            \(Analytics.brief(report))

            Day activities:
            \(activity.isEmpty ? "(little summarizable activity)" : activity)

            Windows / tabs observed today:
            \(titles.isEmpty ? "(no title)" : titles)

            On-screen content excerpts (noisy OCR):
            \(excerpt.isEmpty ? "(no excerpt)" : excerpt)
            """
        let advice = try? await session.respond(to: prompt, generating: CoachAdvice.self).content
        return Result(date: dateStr, report: report, advice: advice)
    }

    static func markdown(_ r: Result, language: AppLanguage = .english) -> String {
        var md = "# Coach — \(r.date)\n\n"
        if let a = r.advice {
            md += a.observation + "\n\n"
            if !a.suggestions.isEmpty {
                md += "## \(language.heading(.improve))\n" + a.suggestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
            if !a.keepDoing.isEmpty { md += "## \(language.heading(.keep))\n- \(a.keepDoing)\n\n" }
            if !a.techRadar.isEmpty {
                md += "## \(language.heading(.techRadar))\n" + a.techRadar.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
        } else {
            md += "_\(language.notEnoughActivity)_\n\n"
        }
        md += "## \(language.heading(.numbers))\n```\n" + Analytics.brief(r.report) + "\n```\n"
        return md
    }
}

import Foundation
import FoundationModels

@Generable
struct SessionSummary {
    @Guide(description: "Ce que l'utilisateur faisait, en une phrase factuelle en français (ex: « Révision d'une merge request sur le module de facturation »)")
    var activity: String
}

@Generable
struct DayDigest {
    @Guide(description: "Résumé de la journée en 2-3 phrases, en français, ton journal de bord")
    var summary: String
    @Guide(description: "3 à 6 points saillants de la journée (accomplissements, sujets traités)")
    var highlights: [String]
    @Guide(description: "Sujets visiblement non terminés ou à reprendre (0 à 3)")
    var unfinished: [String]
}

/// Daily Recap — the Dayflow/Limitless-style automatic work journal.
/// Map-reduce over the day's capture: sessions (app + window + time gaps) are
/// summarized one by one (each fits the 4k on-device context), then reduced
/// into a digest. Everything on-device via FoundationModels.
enum Recap {

    struct Session {
        let start: Double
        let end: Double
        let app: String
        let title: String
        var texts: [String]
        var summary: String = ""
        var minutes: Int { max(1, Int((end - start) / 60)) }
    }

    struct Result {
        let date: String
        let sessions: [Session]
        let digest: DayDigest?
    }

    static let gapSeconds: Double = 300
    static let maxSummarized = 12       // LLM budget: summarize the longest sessions only

    static func sessions(chunks: [Chunk]) -> [Session] {
        let sorted = chunks.sorted { $0.ts < $1.ts }
        var out = [Session]()
        for c in sorted {
            if var last = out.last,
               c.ts - last.end < gapSeconds,
               c.app == last.app, c.title == last.title {
                last = Session(start: last.start, end: c.ts, app: last.app, title: last.title,
                               texts: last.texts + [c.text], summary: "")
                out[out.count - 1] = last
            } else {
                out.append(Session(start: c.ts, end: c.ts, app: c.app, title: c.title, texts: [c.text]))
            }
        }
        // Merge micro-sessions (<60s) into the previous one when same app.
        var merged = [Session]()
        for s in out {
            if let prev = merged.last, s.end - s.start < 60, s.app == prev.app {
                merged[merged.count - 1] = Session(start: prev.start, end: s.end, app: prev.app,
                                                   title: prev.title, texts: prev.texts + s.texts)
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    static func generate(day: Date, store: Store) async -> Result {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day).timeIntervalSince1970
        let chunks = store.allChunks(from: start, to: start + 86400)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let dateStr = f.string(from: day)
        guard !chunks.isEmpty else { return Result(date: dateStr, sessions: [], digest: nil) }

        var sess = sessions(chunks: chunks)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return Result(date: dateStr, sessions: sess, digest: nil)
        }

        // — map: summarize the longest sessions —
        let byLength = sess.enumerated().sorted { ($0.1.end - $0.1.start) > ($1.1.end - $1.1.start) }
        for (i, _) in byLength.prefix(maxSummarized) {
            let s = sess[i]
            // dedupe block texts, cap context
            var seen = Set<String>(), ctx = ""
            for t in s.texts {
                let key = String(t.prefix(60))
                if seen.contains(key) { continue }
                seen.insert(key)
                if ctx.count + t.count > 2200 { break }
                ctx += t + "\n---\n"
            }
            let meta = [s.app, s.title].filter { !$0.isEmpty }.joined(separator: " — ")
            let session = LanguageModelSession(instructions:
                "Tu résumes une session de travail à partir de texte OCR d'écran (bruité). Sois factuel et concis, en français.")
            if let r = try? await session.respond(
                to: "Session (\(meta.isEmpty ? "app inconnue" : meta), \(sess[i].minutes) min):\n\(ctx)",
                generating: SessionSummary.self) {
                sess[i].summary = r.content.activity
            }
        }

        // — reduce: digest of the day —
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let lines = sess.compactMap { s -> String? in
            let label = s.summary.isEmpty
                ? [s.app, s.title].filter { !$0.isEmpty }.joined(separator: " — ")
                : s.summary
            guard !label.isEmpty else { return nil }
            let t0 = Date(timeIntervalSince1970: s.start)
            return "\(tf.string(from: t0)) (\(s.minutes) min) : \(label)"
        }
        var digest: DayDigest? = nil
        if !lines.isEmpty {
            let session = LanguageModelSession(instructions:
                "Tu rédiges le journal de bord d'une journée de travail à partir de la liste horodatée des sessions. Français, factuel, utile pour reprendre le travail demain.")
            let r = try? await session.respond(
                to: "Sessions du \(dateStr):\n" + lines.prefix(40).joined(separator: "\n"),
                generating: DayDigest.self)
            digest = r?.content
        }
        return Result(date: dateStr, sessions: sess, digest: digest)
    }

    static func markdown(_ r: Result) -> String {
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        var md = "# Recap — \(r.date)\n\n"
        if let d = r.digest {
            md += d.summary + "\n\n"
            if !d.highlights.isEmpty {
                md += "## Points saillants\n" + d.highlights.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
            if !d.unfinished.isEmpty {
                md += "## À reprendre\n" + d.unfinished.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
        }
        md += "## Sessions\n"
        for s in r.sessions where s.minutes >= 2 || !s.summary.isEmpty {
            let t0 = tf.string(from: Date(timeIntervalSince1970: s.start))
            let meta = [s.app, s.title].filter { !$0.isEmpty }.joined(separator: " — ")
            let label = s.summary.isEmpty ? meta : s.summary
            guard !label.isEmpty else { continue }
            md += "- **\(t0)** (\(s.minutes) min) \(label)\(s.summary.isEmpty || meta.isEmpty ? "" : "  _[\(meta)]_")\n"
        }
        return md
    }
}

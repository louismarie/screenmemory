import Foundation

/// The proactive engine: turns always-on capture into unprompted value.
///
/// `tick` is idempotent and time-aware — call it as often as you like (the menubar fires it
/// every few minutes; a cron/CLI can fire it too). It runs at most one of each artifact per
/// period: a morning digest (yesterday's recap + coach), an evening same-day recap snapshot,
/// and a Monday weekly synthesis. State is persisted so nothing double-fires.
enum Proactive {

    struct State: Codable {
        var lastMorningDigest: String?   // yyyy-MM-dd it last ran
        var lastEveningRecap: String?    // yyyy-MM-dd
        var lastWeekly: String?          // "yyyy-Www" ISO week key
    }

    static func loadState() -> State {
        guard let s = Paths.read(Paths.proactiveState),
              let d = s.data(using: .utf8),
              let st = try? JSONDecoder().decode(State.self, from: d) else { return State() }
        return st
    }
    static func saveState(_ st: State) {
        if let d = try? JSONEncoder().encode(st), let s = String(data: d, encoding: .utf8) {
            Paths.write(s, to: Paths.proactiveState)
        }
    }

    /// Run any proactive artifacts that are due right now. Returns labels of what it produced
    /// (empty if nothing was due). `notify` gates banner posting (off for silent CLI runs).
    @discardableResult
    static func tick(store: Store, notify: Bool = true, force: Bool = false) async -> [String] {
        let language = AppLanguage.preferred
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: now)
        var st = loadState()
        var produced = [String]()

        // — Morning digest: yesterday's recap + coach, once per day after 07:00 —
        if force || (hour >= 7 && hour < 12 && st.lastMorningDigest != today) {
            let yday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
            if let path = await buildMorningDigest(day: yday, store: store, language: language) {
                produced.append(language.t("proactiveMorningDigest", "morning digest"))
                st.lastMorningDigest = today; saveState(st)
                if notify {
                    let head = headlineFrom(path) ?? language.t("proactiveMorningReady", "Yesterday's digest is ready.")
                    Notify.post(title: "🧠 \(language.t("proactiveMorningTitle", "Yesterday's digest"))",
                                subtitle: df.string(from: yday),
                                body: head, sound: true)
                }
            }
        }

        // — Evening same-day recap snapshot, once per day after 18:00 —
        if force || (hour >= 18 && st.lastEveningRecap != today) {
            let r = await Recap.generate(day: now, store: store, language: language)
            if r.digest != nil || !r.sessions.isEmpty {
                Paths.write(Recap.markdown(r, language: language), to: Paths.file(Paths.recaps, "\(today).md"))
                produced.append(language.t("proactiveEveningRecap", "evening recap"))
                st.lastEveningRecap = today; saveState(st)
                if notify {
                    Notify.post(title: "🧠 \(language.t("proactiveEveningTitle", "Daily recap"))",
                                body: r.digest?.summary ?? language.t("proactiveEveningReady", "Your day is indexed."),
                                sound: false)
                }
            }
        }

        // — Weekly synthesis on Monday after 08:00, once per ISO week —
        let weekKey = isoWeekKey(now, cal)
        let isMonday = cal.component(.weekday, from: now) == 2
        if force || (isMonday && hour >= 8 && st.lastWeekly != weekKey) {
            let endDay = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!  // Sunday
            let w = await Weekly.generate(endingDay: endDay, store: store, language: language)
            Paths.write(Weekly.markdown(w, language: language), to: Paths.file(Paths.weekly, "\(df.string(from: w.to)).md"))
            produced.append(language.t("proactiveWeekly", "weekly synthesis"))
            st.lastWeekly = weekKey; saveState(st)
            if notify {
                Notify.post(title: "🧠 \(language.t("proactiveWeeklyTitle", "Weekly synthesis"))",
                            body: w.digest?.summary ?? language.t("proactiveWeeklyReady", "Your week is summarized."),
                            sound: true)
            }
        }

        return produced
    }

    /// Morning digest file = yesterday's recap summary + coach suggestions in one markdown.
    /// Returns the path on success (nil if the day had no data).
    @discardableResult
    static func buildMorningDigest(day: Date, store: Store, language: AppLanguage = .english) async -> String? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: day)

        // Ensure the day's recap is cached (the permanent summary layer).
        let recapPath = Paths.file(Paths.recaps, "\(dateStr).md")
        let recap = await Recap.generate(day: day, store: store, language: language)
        guard recap.digest != nil || !recap.sessions.isEmpty else { return nil }
        Paths.write(Recap.markdown(recap, language: language), to: recapPath)

        let coach = await Coach.generate(day: day, store: store, language: language)
        Paths.write(Coach.markdown(coach, language: language), to: Paths.file(Paths.coach, "\(dateStr).md"))

        var md = "# \(language.t("digestTitle", "Digest")) - \(dateStr)\n\n"
        if let d = recap.digest {
            md += d.summary + "\n\n"
            if !d.unfinished.isEmpty {
                md += "## \(language.t("digestResumeToday", "To resume today"))\n"
                    + d.unfinished.map { "- \($0)" }.joined(separator: "\n")
                    + "\n\n"
            }
        }
        if let a = coach.advice, !a.suggestions.isEmpty {
            md += "## \(language.t("digestSuggestionsToday", "Suggestions for today"))\n"
                + a.suggestions.map { "- \($0)" }.joined(separator: "\n")
                + "\n\n"
        }
        md += "## \(language.t("digestYesterdayTime", "Yesterday's time"))\n```\n" + Analytics.brief(coach.report) + "\n```\n"
        let path = Paths.file(Paths.digests, "\(dateStr).md")
        Paths.write(md, to: path)
        return path
    }

    /// One-line headline pulled from a markdown digest (first non-heading, non-empty line).
    static func headlineFrom(_ path: String) -> String? {
        guard let md = Paths.read(path) else { return nil }
        for line in md.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("#") && !t.hasPrefix("```") { return String(t.prefix(180)) }
        }
        return nil
    }

    /// The freshest insight headline for inline display (menubar). Prefers today's evening
    /// recap, then this morning's digest.
    static func currentHeadline() -> String? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let yday = df.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        for path in [Paths.file(Paths.recaps, "\(today).md"),
                     Paths.file(Paths.digests, "\(yday).md")] {
            if let h = headlineFrom(path) { return h }
        }
        return nil
    }

    private static func isoWeekKey(_ d: Date, _ cal: Calendar) -> String {
        var c = cal; c.firstWeekday = 2
        let comps = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
    }
}

/// In-app scheduler: a repeating timer that drives `Proactive.tick` while the menubar app is
/// alive. Lightweight — the timer just checks the clock; generation only fires when due.
@MainActor
final class ProactiveScheduler {
    private var timer: Timer?
    private let dbPath: String
    private var running = false
    var onProduced: (() -> Void)?   // menubar refresh hook

    init(dbPath: String) { self.dbPath = dbPath }

    func start() {
        // First check shortly after launch, then every 5 minutes.
        fire()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func fire() {
        guard !running else { return }
        running = true
        Task { @MainActor in
            defer { self.running = false }
            guard let store = try? Store(path: self.dbPath) else { return }
            let produced = await Proactive.tick(store: store, notify: true)
            if !produced.isEmpty { self.onProduced?() }
        }
    }
}

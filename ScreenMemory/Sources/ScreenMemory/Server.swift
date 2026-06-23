import Foundation
import Network
import CoreGraphics

/// Self-contained dashboard server, embedded in the menubar app — no Python, no shelling out.
/// Binds loopback only (127.0.0.1), serves the SPA + a JSON API backed by the same in-process
/// Swift (Store / Search / RAG / Coach / Weekly / Analytics). While the app runs, the dashboard
/// at http://127.0.0.1:8790 is always live.
final class DashboardServer: @unchecked Sendable {
    private let dbPath: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "screenmemory.dashboard", attributes: .concurrent)
    private var listener: NWListener?
    private let embLock = NSLock()
    private var _embedder: Embedder?

    init(dbPath: String, port: UInt16 = 8790) { self.dbPath = dbPath; self.port = port }

    /// One shared embedder (MLModel.prediction is thread-safe); lazily compiled on first search.
    private func embedder() throws -> Embedder {
        embLock.lock(); defer { embLock.unlock() }
        if let e = _embedder { return e }
        let e = try Embedder(); _embedder = e; return e
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback-only bind (privacy): set the local endpoint here, NOT via `on:` (which conflicts).
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l: NWListener
        do { l = try NWListener(using: params) }
        catch { NSLog("[ScreenMemory] dashboard listener error: \(error)"); return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    // MARK: - Connection plumbing

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, Data())
    }

    private func read(_ conn: NWConnection, _ acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { conn.cancel(); return }
            var buf = acc
            if let data { buf.append(data) }
            if let req = HTTPRequest(buf) {              // headers complete + full body present
                self.route(req, conn)
            } else if done || err != nil {
                conn.cancel()
            } else {
                self.read(conn, buf)                     // need more bytes
            }
        }
    }

    private func send(_ conn: NWConnection, _ body: Data, type: String, status: Int = 200) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "ERR")\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
    private func json(_ conn: NWConnection, _ v: some Encodable) {
        let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
        send(conn, (try? enc.encode(v)) ?? Data("{}".utf8), type: "application/json; charset=utf-8")
    }
    private func fail(_ conn: NWConnection, _ msg: String) {
        send(conn, Data("{\"error\":\(jsonString(msg))}".utf8), type: "application/json", status: 500)
    }
    private func jsonString(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }

    // MARK: - Routing

    private struct DayCount: Encodable { let day: String; let count: Int }
    private struct Stats: Encodable { let count: Int; let paused: Bool; let capturing: Bool; let permission: Bool }
    private struct JRecap: Encodable { let date: String; let summary: String; let highlights: [String]; let unfinished: [String]; let sessions: [JSess] }
    private struct JSess: Encodable { let start: Double; let end: Double; let app: String; let title: String; let summary: String }
    private struct JCoach: Encodable { let date: String; let observation: String; let suggestions: [String]; let keepDoing: String; let report: Analytics.FocusReport }
    private struct JWeekly: Encodable { let from: String; let to: String; let summary: String; let achievements: [String]; let openThreads: [String]; let patterns: [String]; let report: Analytics.FocusReport }
    private struct JTrendDay: Encodable { let day: String; let report: Analytics.FocusReport }
    private struct JTrendSummary: Encodable {
        let activeMinutes: Int
        let deepWorkMinutes: Int
        let avgFocus: Int
        let avgSwitches: Double
        let bestDay: String
        let bestFocus: Int
        let activeDelta: Int
        let focusDelta: Int
    }
    private struct JTrend: Encodable {
        let days: Int
        let from: String
        let to: String
        let daily: [JTrendDay]
        let summary: JTrendSummary
    }
    private struct JTrust: Encodable {
        let permission: Bool
        let capturing: Bool
        let paused: Bool
        let model: String
        let memories: Int
        let chunks: Int
        let latestTs: Double?
        let localOnly: Bool
        let encryptedAtRest: Bool
        let redaction: Bool
        let excludedApps: Int
    }
    private struct JSignal: Encodable { let level: String; let title: String; let detail: String; let action: String; let tab: String }
    private struct JAction: Encodable { let title: String; let detail: String; let query: String; let app: String; let ts: Double; let kind: String }
    private struct JTimeline: Encodable {
        let start: Double
        let end: Double
        let app: String
        let title: String
        let summary: String
        let snippet: String
        let chunks: Int
    }
    private struct JChunkView: Encodable { let ts: Double; let text: String }
    private struct JSessionDetail: Encodable { let session: JTimeline; let chunks: [JChunkView] }
    private struct JBrief: Encodable {
        let date: String
        let headline: String
        let actions: [JAction]
        let signals: [JSignal]
        let timeline: [JTimeline]
        let report: Analytics.FocusReport
        let trust: JTrust
    }
    private struct JOpusCoach: Encodable {
        let date: String
        let filter: String
        let output: String
        let model: String
        let usedSessions: Int
        let usedChunks: Int
        let historyDays: Int
        let promptChars: Int
    }
    private struct CoachPrompt {
        let date: String
        let filter: String
        let prompt: String
        let usedSessions: Int
        let usedChunks: Int
        let historyDays: Int
    }
    private enum ClaudeRunError: LocalizedError {
        case missingExecutable
        case timeout
        case failed(String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .missingExecutable:
                return "CLI claude introuvable dans ~/.local/bin, /opt/homebrew/bin, /usr/local/bin ou PATH"
            case .timeout:
                return "claude -p --model opus a depasse le delai"
            case .failed(let message):
                return message
            case .emptyOutput:
                return "claude -p --model opus n'a renvoye aucune reponse"
            }
        }
    }

    private func route(_ req: HTTPRequest, _ conn: NWConnection) {
        let path = req.path, q = req.query
        switch (req.method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            if let url = Bundle.module.url(forResource: "dashboard", withExtension: "html"),
               let html = try? Data(contentsOf: url) {
                send(conn, html, type: "text/html; charset=utf-8")
            } else { send(conn, Data("dashboard.html missing".utf8), type: "text/plain", status: 500) }

        case ("GET", "/api/stats"):
            let store = try? Store(path: dbPath)
            let recent = store.map { recentlyIndexed(store: $0) } ?? false
            json(conn, Stats(count: store?.count() ?? 0,
                             paused: Privacy.isPaused,
                             capturing: CaptureState.isCapturing || recent,
                             permission: CGPreflightScreenCaptureAccess() || recent))

        case ("GET", "/api/days"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            json(conn, store.dayCounts().map { DayCount(day: $0.day, count: $0.count) })

        case ("GET", "/api/trust"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            json(conn, trust(store: store))

        case ("GET", "/api/brief"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            json(conn, brief(day: dayFrom(q.str("date", "today")), store: store))

        case ("GET", "/api/timeline"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            json(conn, timeline(day: dayFrom(q.str("date", "today")),
                                store: store,
                                matching: q.str("q"),
                                limit: q.int("limit", 80)))

        case ("GET", "/api/session"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            guard let detail = sessionDetail(store: store,
                                             start: q.double("start"),
                                             end: q.double("end")) else {
                return fail(conn, "session not found")
            }
            json(conn, detail)

        case ("GET", "/api/list"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            let rows = store.list(limit: q.int("limit", 25), offset: q.int("offset", 0))
            json(conn, rows.map { JMemory(id: $0.id, ts: $0.ts, text: $0.text) })

        case ("GET", "/api/search"):
            Task {
                do {
                    let store = try Store(path: dbPath)
                    var opts = Search.Options(); opts.k = q.int("k", 8)
                    let hits = try Search.run(query: q.str("q"), store: store, embedder: try embedder(), opts: opts)
                    json(conn, hits.map { JHit(ts: $0.ts, score: $0.score, text: $0.text, app: $0.app, title: $0.title) })
                } catch { fail(conn, "\(error)") }
            }

        case ("POST", "/api/ask"):
            Task {
                do {
                    let b = req.jsonBody
                    let question = (b["q"] as? String) ?? ""
                    let k = (b["k"] as? Int) ?? 4
                    let store = try Store(path: dbPath)
                    var opts = Search.Options(); opts.k = k
                    let hits = try Search.run(query: question, store: store, embedder: try embedder(), opts: opts)
                    if hits.isEmpty { return json(conn, JAsk(answer: "Aucun souvenir trouvé pour cette période.", sources: [], used: [], notFound: true)) }
                    let a = await RAG.answerGrounded(question: question, context: hits)
                    let text = a.notFound ? "Je n'ai pas vu ça à l'écran (rien dans les extraits récupérés)." : a.text
                    json(conn, JAsk(answer: text, sources: hits.map { JHit(ts: $0.ts, score: $0.score, text: $0.text, app: $0.app, title: $0.title) }, used: a.sources, notFound: a.notFound))
                } catch { fail(conn, "\(error)") }
            }

        case ("GET", "/api/focus"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            json(conn, Analytics.report(days: q.int("days", 1), store: store))

        case ("GET", "/api/trends"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            json(conn, trends(days: q.int("days", 30), store: store))

        case ("GET", "/api/recap"):
            Task {
                guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
                let day = dayFrom(q.str("date", "yesterday"))
                let fast = q.str("fast") == "1"
                let r = await Recap.generate(day: day, store: store, summarize: !fast)
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                if !fast { Paths.write(Recap.markdown(r), to: Paths.file(Paths.recaps, "\(df.string(from: day)).md")) }
                json(conn, JRecap(date: r.date, summary: r.digest?.summary ?? "", highlights: r.digest?.highlights ?? [],
                                  unfinished: r.digest?.unfinished ?? [],
                                  sessions: r.sessions.map { JSess(start: $0.start, end: $0.end, app: $0.app, title: $0.title, summary: $0.summary) }))
            }

        case ("GET", "/api/coach"):
            Task {
                guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
                let fast = q.str("fast") == "1"
                let r = await Coach.generate(day: dayFrom(q.str("day", "yesterday")), store: store, advise: !fast)
                if !fast { Paths.write(Coach.markdown(r), to: Paths.file(Paths.coach, "\(r.date).md")) }
                json(conn, JCoach(date: r.date, observation: r.advice?.observation ?? "", suggestions: r.advice?.suggestions ?? [],
                                  keepDoing: r.advice?.keepDoing ?? "", report: r.report))
            }

        case ("POST", "/api/coach/opus"):
            Task {
                do {
                    guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
                    let body = req.jsonBody
                    let day = dayFrom((body["day"] as? String) ?? "yesterday")
                    let filter = ((body["filter"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let bundle = coachOpusPrompt(day: day, store: store, filter: filter)
                    let output = try runClaudeOpus(prompt: bundle.prompt, timeout: 300)
                    let md = "# Coach Opus — \(bundle.date)\n\n" + output + "\n\n" +
                        "## Contexte envoye\n" +
                        "- Filtre: \(bundle.filter.isEmpty ? "(aucun)" : bundle.filter)\n" +
                        "- Sessions: \(bundle.usedSessions)\n" +
                        "- Chunks OCR: \(bundle.usedChunks)\n"
                    Paths.write(md, to: Paths.file(Paths.coach, "\(bundle.date)-opus.md"))
                    json(conn, JOpusCoach(date: bundle.date,
                                          filter: bundle.filter,
                                          output: output,
                                          model: "opus",
                                          usedSessions: bundle.usedSessions,
                                          usedChunks: bundle.usedChunks,
                                          historyDays: bundle.historyDays,
                                          promptChars: bundle.prompt.count))
                } catch {
                    fail(conn, error.localizedDescription)
                }
            }

        case ("GET", "/api/weekly"):
            Task {
                guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
                let fast = q.str("fast") == "1"
                let r = await Weekly.generate(endingDay: dayFrom(q.str("end", "yesterday")), store: store, summarize: !fast)
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                if !fast { Paths.write(Weekly.markdown(r), to: Paths.file(Paths.weekly, "\(df.string(from: r.to)).md")) }
                json(conn, JWeekly(from: df.string(from: r.from), to: df.string(from: r.to), summary: r.digest?.summary ?? "",
                                   achievements: r.digest?.achievements ?? [], openThreads: r.digest?.openThreads ?? [],
                                   patterns: r.digest?.patterns ?? [], report: r.report))
            }

        case ("POST", "/api/permission"):
            CGRequestScreenCaptureAccess()
            json(conn, ["granted": CGPreflightScreenCaptureAccess()])

        default:
            send(conn, Data("not found".utf8), type: "text/plain", status: 404)
        }
    }

    private func trust(store: Store) -> JTrust {
        let recent = recentlyIndexed(store: store)
        return JTrust(permission: CGPreflightScreenCaptureAccess() || recent,
                      capturing: CaptureState.isCapturing || recent,
                      paused: Privacy.isPaused,
                      model: RAG.availabilityDescription(),
                      memories: store.count(),
                      chunks: store.chunkCount(),
                      latestTs: store.latestChunkTs(),
                      localOnly: true,
                      encryptedAtRest: true,
                      redaction: true,
                      excludedApps: Privacy.excludedBundleIDs().count)
    }

    private func recentlyIndexed(store: Store) -> Bool {
        guard let ts = store.latestChunkTs() else { return false }
        return Date().timeIntervalSince1970 - ts < 10 * 60
    }

    private func brief(day: Date, store: Store) -> JBrief {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = start.timeIntervalSince1970 + 86400
        let report = Analytics.report(from: start.timeIntervalSince1970, to: end, days: 1, store: store)
        let trust = trust(store: store)
        let date = dateString(start)
        let timeline = timeline(day: start, store: store, matching: "", limit: 12)
        let actions = resumeActions(date: date, timeline: timeline)
        let signals = productSignals(trust: trust, report: report)
        let headline: String
        if !trust.permission {
            headline = "Autorise l'enregistrement d'écran pour transformer ce dashboard en mémoire vivante."
        } else if trust.paused {
            headline = "La mémoire est en pause. Les anciens souvenirs restent consultables, mais rien de nouveau n'est indexé."
        } else if !trust.capturing {
            headline = "La capture est arrêtée. Tu peux encore fouiller l'historique, mais le flux n'est pas à jour."
        } else if !actions.isEmpty {
            headline = "\(actions.count) piste\(actions.count > 1 ? "s" : "") à reprendre depuis les traces récentes."
        } else if report.activeMinutes > 0 {
            headline = "\(minutes(report.activeMinutes)) indexées aujourd'hui. La timeline est prête à être interrogée."
        } else {
            headline = "Aucune activité exploitable pour ce jour. Lance la capture et reviens après quelques minutes."
        }
        return JBrief(date: date, headline: headline, actions: actions, signals: signals,
                      timeline: timeline, report: report, trust: trust)
    }

    private func trends(days requestedDays: Int, store: Store) -> JTrend {
        let days = min(max(requestedDays, 7), 120)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = Date().timeIntervalSince1970
        let startDay = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var daily = [JTrendDay]()

        for offset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: offset, to: startDay) else {
                continue
            }
            let from = day.timeIntervalSince1970
            let to = min(from + 86400, now)
            let report = Analytics.report(from: from, to: max(from, to), days: 1, store: store)
            daily.append(JTrendDay(day: dateString(day), report: report))
        }

        let active = daily.reduce(0) { $0 + $1.report.activeMinutes }
        let deep = daily.reduce(0) { $0 + $1.report.deepWorkMinutes }
        let activeDays = daily.filter { $0.report.activeMinutes > 0 }
        let avgFocus = activeDays.isEmpty
            ? 0
            : Int((Double(activeDays.reduce(0) { $0 + $1.report.focusScore }) / Double(activeDays.count)).rounded())
        let avgSwitches = activeDays.isEmpty
            ? 0
            : (activeDays.reduce(0.0) { $0 + $1.report.contextSwitchesPerHour } / Double(activeDays.count) * 10).rounded() / 10
        let best = activeDays.max {
            if $0.report.focusScore == $1.report.focusScore {
                return $0.report.activeMinutes < $1.report.activeMinutes
            }
            return $0.report.focusScore < $1.report.focusScore
        }

        let split = max(1, daily.count / 2)
        let previous = Array(daily.prefix(split))
        let recent = Array(daily.suffix(daily.count - split))
        let activeDelta = averageActive(recent) - averageActive(previous)
        let focusDelta = averageFocus(recent) - averageFocus(previous)
        let summary = JTrendSummary(activeMinutes: active,
                                    deepWorkMinutes: deep,
                                    avgFocus: avgFocus,
                                    avgSwitches: avgSwitches,
                                    bestDay: best?.day ?? "",
                                    bestFocus: best?.report.focusScore ?? 0,
                                    activeDelta: activeDelta,
                                    focusDelta: focusDelta)

        return JTrend(days: days,
                      from: dateString(startDay),
                      to: dateString(today),
                      daily: daily,
                      summary: summary)
    }

    private func averageActive(_ days: [JTrendDay]) -> Int {
        guard !days.isEmpty else { return 0 }
        let total = days.reduce(0) { $0 + $1.report.activeMinutes }
        return Int((Double(total) / Double(days.count)).rounded())
    }

    private func averageFocus(_ days: [JTrendDay]) -> Int {
        let active = days.filter { $0.report.activeMinutes > 0 }
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(0) { $0 + $1.report.focusScore }
        return Int((Double(total) / Double(active.count)).rounded())
    }

    private func timeline(day: Date, store: Store, matching query: String, limit: Int) -> [JTimeline] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day).timeIntervalSince1970
        let chunks = store.allChunks(from: start, to: start + 86400)
        let sessions = Recap.sessions(chunks: chunks)
        let qTokens = Set(BM25.tokenize(query))
        return sessions.reversed().compactMap { s -> JTimeline? in
            let corpus = ([s.app, s.title] + s.texts).joined(separator: " ")
            if !qTokens.isEmpty {
                let tokens = Set(BM25.tokenize(corpus))
                if tokens.intersection(qTokens).isEmpty { return nil }
            }
            let meta = [s.app, s.title].filter { !$0.isEmpty }.joined(separator: " — ")
            guard !meta.isEmpty || !s.texts.isEmpty else { return nil }
            return JTimeline(start: s.start, end: s.end, app: s.app, title: s.title,
                             summary: s.summary.isEmpty ? meta : s.summary,
                             snippet: snippet(from: s.texts),
                             chunks: s.texts.count)
        }.prefix(max(1, limit)).map { $0 }
    }

    private func sessionDetail(store: Store, start: Double?, end: Double?) -> JSessionDetail? {
        guard let start else { return nil }
        let end = max(end ?? start, start)
        let raw = store.allChunks(from: start - 1, to: end + 1)
        guard !raw.isEmpty else { return nil }
        let app = raw.first?.app ?? ""
        let title = raw.first?.title ?? ""
        let texts = raw.map(\.text)
        let session = JTimeline(start: start,
                                end: end,
                                app: app,
                                title: title,
                                summary: [app, title].filter { !$0.isEmpty }.joined(separator: " — "),
                                snippet: snippet(from: texts),
                                chunks: raw.count)
        let chunks = raw.map { JChunkView(ts: $0.ts, text: $0.text) }
        return JSessionDetail(session: session, chunks: chunks)
    }

    private func coachOpusPrompt(day: Date, store: Store, filter: String) -> CoachPrompt {
        let cal = Calendar.current
        let startDate = cal.startOfDay(for: day)
        let start = startDate.timeIntervalSince1970
        let end = start + 86400
        let date = dateString(startDate)
        let report = Analytics.report(from: start, to: end, days: 1, store: store)
        let chunks = store.allChunks(from: start, to: end)
            .filter { !$0.app.isEmpty || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sessions = Recap.sessions(chunks: chunks.filter { !$0.app.isEmpty })
        let selected = relevantCoachSessions(sessions, filter: filter)
        let selectedRanges = selected.map { ($0.start - 1, $0.end + 1) }
        let selectedChunks = chunks.filter { c in
            selectedRanges.contains { c.ts >= $0.0 && c.ts <= $0.1 }
        }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let sessionLines = selected.map { s -> String in
            let meta = [s.app, s.title].filter { !$0.isEmpty }.joined(separator: " — ")
            let text = snippet(from: s.texts)
            return "- \(tf.string(from: Date(timeIntervalSince1970: s.start))) (\(s.minutes) min) \(meta.isEmpty ? "session" : meta)\(text.isEmpty ? "" : " :: \(text)")"
        }.joined(separator: "\n")
        let excerpts = relevantCoachExcerpts(from: selectedChunks, filter: filter, limit: 9000)
        let history = monthlyCoachHistory(before: startDate, days: 30)
        let today = dateString(Date())
        let filterLine = filter.isEmpty
            ? "Aucun filtre explicite. Priorise les sessions longues, recentes et riches en contenu."
            : "Filtre utilisateur: \(filter). Priorise ce sujet et ignore le bruit non relie."
        let prompt = """
        Tu es un coach de productivite senior et un analyste de veille technique.
        Reponds en francais, en Markdown concis.

        Objectif: produire un coaching utile et actionnable pour la journee \(date).
        Base-toi uniquement sur les donnees ci-dessous. N'invente pas de projet, d'outil,
        de fait ni de chiffre absent des traces. Si les donnees sont minces, dis-le.

        Contraintes fortes:
        - Ne donne AUCUN conseil deja donne dans les 30 derniers jours, meme reformule.
        - Si un conseil evident est deja dans l'historique, remplace-le par un levier
          plus precis ou par une experience mesurable differente.
        - Les conseils doivent etre specifiques aux traces d'activite, pas des habitudes
          generiques.
        - Fais une recherche web approfondie et ciblee sur les technos, outils, libs,
          produits ou sujets detectes dans l'activite. Privilegie les annonces recentes,
          changelogs, releases, docs officielles, billets techniques et outils connexes.
        - Dans la veille, cite les sources avec URL et date quand tu les as.
        - Ne recommande un outil externe que si la recherche web ou les traces l'appuient.

        Format attendu:
        ## Diagnostic
        2-4 phrases factuelles sur le rythme de travail.

        ## Conseils nouveaux
        3 actions concretes non redondantes avec l'historique mensuel. Pour chaque action:
        signal observe -> action -> comment verifier demain.

        ## Veille connexe
        3 a 6 elements issus de la recherche web qui pourraient aider le travail observe:
        nouveaute / outil / techno -> pourquoi c'est pertinent -> lien source.

        ## Plan prochain bloc
        Un plan en 3 etapes pour reprendre le travail.

        ## Angle mort
        Une chose a surveiller demain.

        \(filterLine)

        Date actuelle pour la veille web: \(today)

        Historique des conseils deja donnes sur 30 jours, a ne pas repeter:
        \(history.text.isEmpty ? "(aucun historique disponible)" : history.text)

        Metriques:
        \(Analytics.brief(report))

        Sessions pertinentes:
        \(sessionLines.isEmpty ? "(aucune session pertinente)" : sessionLines)

        Extraits OCR pertinents selectionnes par ScreenMemory:
        \(excerpts.isEmpty ? "(aucun extrait exploitable)" : excerpts)
        """
        return CoachPrompt(date: date,
                           filter: filter,
                           prompt: prompt,
                           usedSessions: selected.count,
                           usedChunks: selectedChunks.count,
                           historyDays: history.days)
    }

    private func monthlyCoachHistory(before day: Date, days: Int) -> (text: String, days: Int) {
        let dir = Paths.coach
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            return ("", 0)
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let cutoff = cal.date(byAdding: .day, value: -days, to: start) else {
            return ("", 0)
        }
        let picked = files.compactMap { name -> (Date, String)? in
            guard name.hasSuffix(".md") else {
                return nil
            }
            let datePart = String(name.prefix(10))
            guard let date = df.date(from: datePart),
                  date >= cutoff,
                  date < start else {
                return nil
            }
            return (date, name)
        }.sorted { $0.0 > $1.0 }

        var out = [String]()
        var seenDays = Set<String>()
        for (_, name) in picked.prefix(16) {
            let path = Paths.file(dir, name)
            guard let raw = Paths.read(path) else {
                continue
            }
            let date = String(name.prefix(10))
            seenDays.insert(date)
            let clean = compactCoachArtifact(raw)
            guard !clean.isEmpty else {
                continue
            }
            out.append("### \(name)\n\(short(clean, 1200))")
        }
        return (out.joined(separator: "\n\n"), seenDays.count)
    }

    private func compactCoachArtifact(_ raw: String) -> String {
        let stopMarkers = ["\n## Contexte envoye", "\n## Chiffres", "\n## Temps"]
        var text = raw
        for marker in stopMarkers {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func relevantCoachSessions(_ sessions: [Recap.Session], filter: String) -> [Recap.Session] {
        let queryTokens = Set(BM25.tokenize(filter))
        let ranked = sessions.map { s -> (Recap.Session, Double) in
            let corpus = ([s.app, s.title] + s.texts.prefix(8)).joined(separator: " ")
            let tokens = Set(BM25.tokenize(corpus))
            let match = queryTokens.isEmpty ? 0 : tokens.intersection(queryTokens).count
            let duration = max(60, s.end - s.start) / 60
            let content = min(Double(corpus.count) / 600, 5)
            let recent = s.start / 100000000
            let score = queryTokens.isEmpty
                ? duration + content + recent
                : Double(match * 100) + duration + content
            return (s, score)
        }
        let filtered = ranked.filter { queryTokens.isEmpty || $0.1 >= 100 }
        let picked = (filtered.isEmpty ? ranked : filtered)
            .sorted { $0.1 > $1.1 }
            .prefix(18)
            .map(\.0)
            .sorted { $0.start < $1.start }
        return picked
    }

    private func relevantCoachExcerpts(from chunks: [Chunk], filter: String, limit: Int) -> String {
        let queryTokens = Set(BM25.tokenize(filter))
        var seen = Set<String>()
        var lines = [String]()
        var size = 0
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let ranked = chunks.map { c -> (Chunk, Int) in
            let corpus = [c.app, c.title, c.text].joined(separator: " ")
            let tokens = Set(BM25.tokenize(corpus))
            return (c, queryTokens.isEmpty ? 0 : tokens.intersection(queryTokens).count)
        }
        let ordered = queryTokens.isEmpty
            ? ranked.sorted { $0.0.ts < $1.0.ts }
            : ranked.sorted {
                if $0.1 == $1.1 { return $0.0.ts < $1.0.ts }
                return $0.1 > $1.1
            }
        for (chunk, score) in ordered {
            if !queryTokens.isEmpty && score == 0 { continue }
            let clean = chunk.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 30 else { continue }
            let key = String(clean.prefix(90))
            guard seen.insert(key).inserted else { continue }
            let meta = [chunk.app, chunk.title].filter { !$0.isEmpty }.joined(separator: " — ")
            let line = "- \(tf.string(from: Date(timeIntervalSince1970: chunk.ts))) \(meta.isEmpty ? "" : "[\(meta)] ")\(clean.prefix(480))"
            if size + line.count > limit { break }
            lines.append(line)
            size += line.count
        }
        if lines.isEmpty && !queryTokens.isEmpty {
            return relevantCoachExcerpts(from: chunks, filter: "", limit: min(limit, 3000))
        }
        return lines.joined(separator: "\n")
    }

    private func runClaudeOpus(prompt: String, timeout: TimeInterval) throws -> String {
        guard let launch = claudeLaunch() else { throw ClaudeRunError.missingExecutable }
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.prefix + [
            "-p",
            "--model", "opus",
            "--no-session-persistence",
            "--output-format", "text",
            "--permission-mode", "dontAsk",
            "--allowedTools", "WebSearch,WebFetch"
        ]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [env["PATH"], extraPath].compactMap { $0 }.joined(separator: ":")
        env["HOME"] = home
        process.environment = env

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            throw ClaudeRunError.timeout
        }
        let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeRunError.failed(message.isEmpty ? "claude -p --model opus a echoue" : short(message, 1200))
        }
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClaudeRunError.emptyOutput }
        return text
    }

    private func claudeLaunch() -> (executable: URL, prefix: [String])? {
        let fm = FileManager.default
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return (URL(fileURLWithPath: path), [])
        }
        guard fm.isExecutableFile(atPath: "/usr/bin/env") else { return nil }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["claude"])
    }

    private func resumeActions(date: String, timeline: [JTimeline]) -> [JAction] {
        var out = [JAction]()
        var seen = Set<String>()
        for item in unfinishedItems(date: date).prefix(4) {
            let key = item.lowercased()
            seen.insert(key)
            out.append(JAction(title: item,
                               detail: "Issu du dernier journal de bord généré.",
                               query: item,
                               app: "",
                               ts: Date().timeIntervalSince1970,
                               kind: "unfinished"))
        }
        for s in timeline where out.count < 5 {
            let raw = s.title.isEmpty ? s.app : s.title
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 3 else { continue }
            let key = title.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            let mins = max(1, Int((s.end - s.start) / 60))
            let app = s.app.isEmpty ? "app inconnue" : s.app
            out.append(JAction(title: "Reprendre \(short(title, 72))",
                               detail: "\(app) · \(minutes(mins)) · dernière trace \(clock(s.start))",
                               query: [s.app, s.title].filter { !$0.isEmpty }.joined(separator: " "),
                               app: s.app,
                               ts: s.start,
                               kind: "recent"))
        }
        return out
    }

    private func productSignals(trust: JTrust, report: Analytics.FocusReport) -> [JSignal] {
        var out = [JSignal]()
        if !trust.permission {
            out.append(JSignal(level: "critical",
                               title: "Capture non autorisée",
                               detail: "macOS bloque l'enregistrement d'écran. Rien de neuf ne sera indexé.",
                               action: "Autoriser",
                               tab: "reprendre"))
        }
        if trust.paused {
            out.append(JSignal(level: "warn",
                               title: "Indexation en pause",
                               detail: "La pause protège ton écran, mais le produit ne peut plus t'aider proactivement.",
                               action: "Reprendre",
                               tab: "reprendre"))
        } else if trust.permission && !trust.capturing {
            out.append(JSignal(level: "warn",
                               title: "Capture arrêtée",
                               detail: "Le dashboard consulte l'historique, mais la mémoire active est éteinte.",
                               action: "Démarrer",
                               tab: "reprendre"))
        }
        if let latest = trust.latestTs {
            let age = Date().timeIntervalSince1970 - latest
            if age > 12 * 3600 {
                out.append(JSignal(level: "warn",
                                   title: "Historique peu frais",
                                   detail: "Dernier souvenir indexé il y a \(minutes(Int(age / 60))).",
                                   action: "Vérifier",
                                   tab: "memoire"))
            }
        } else {
            out.append(JSignal(level: "info",
                               title: "Aucun chunk de recherche",
                               detail: "Lance la capture ou exécute une réindexation pour alimenter la recherche.",
                               action: "Mémoire",
                               tab: "memoire"))
        }
        if !trust.model.hasPrefix("READY") {
            out.append(JSignal(level: "info",
                               title: "Génération locale indisponible",
                               detail: "La recherche et les métriques restent utiles. Les résumés RAG attendent Apple Intelligence.",
                               action: "Chercher",
                               tab: "ask"))
        }
        if report.activeMinutes > 15 && report.contextSwitchesPerHour >= 20 {
            out.append(JSignal(level: "info",
                               title: "Journée très fragmentée",
                               detail: "\(report.contextSwitchesPerHour)/h changements de contexte. Le brief doit aider à reprendre le fil.",
                               action: "Focus",
                               tab: "focus"))
        }
        return out
    }

    private func unfinishedItems(date: String) -> [String] {
        guard let md = Paths.read(Paths.file(Paths.recaps, "\(date).md")) else { return [] }
        var items = [String]()
        var inside = false
        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## ") {
                inside = line.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                      locale: Locale(identifier: "fr_FR")).contains("reprendre")
                continue
            }
            guard inside else { continue }
            if line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return items.filter { !$0.isEmpty }
    }

    private func snippet(from texts: [String]) -> String {
        var seen = Set<String>()
        var out = ""
        for text in texts {
            let clean = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = String(clean.prefix(50))
            guard !clean.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            if out.count + clean.count > 360 { break }
            out += out.isEmpty ? clean : " · " + clean
        }
        return out
    }

    private func dateString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func clock(_ ts: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    private func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))" : "\(m) min"
    }

    private func short(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    private func dayFrom(_ s: String) -> Date {
        let cal = Calendar.current
        if s == "today" { return cal.startOfDay(for: Date()) }
        if s == "yesterday" { return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))! }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) ?? cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
    }
}

/// Shared capture-state flag so the server's /api/stats can report it without touching the engine.
enum CaptureState {
    nonisolated(unsafe) static var isCapturing = false
}

/// Minimal HTTP/1.1 request parser. Returns nil until headers (and any Content-Length body)
/// are fully present in `raw` — the caller keeps reading until it succeeds.
struct HTTPRequest {
    let method: String, path: String, query: Query, body: Data
    var jsonBody: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }

    init?(_ raw: Data) {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw.subdata(in: 0..<sep.lowerBound), encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.components(separatedBy: " ") ?? []
        guard parts.count >= 2 else { return nil }
        method = parts[0]
        let target = parts[1]
        if let qm = target.firstIndex(of: "?") {
            path = String(target[..<qm]); query = Query(String(target[target.index(after: qm)...]))
        } else { path = target; query = Query("") }
        // Body: honor Content-Length (POST). If not all bytes arrived yet, fail -> read more.
        var len = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            len = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = sep.upperBound
        let have = raw.count - bodyStart
        if have < len { return nil }
        body = len > 0 ? raw.subdata(in: bodyStart..<(bodyStart + len)) : Data()
    }

    /// Tiny query-string accessor with URL-decoding.
    struct Query {
        private var dict = [String: String]()
        init(_ s: String) {
            for pair in s.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let k = kv.first else { continue }
                let v = kv.count > 1 ? String(kv[1]) : ""
                dict[String(k)] = v.removingPercentEncoding?.replacingOccurrences(of: "+", with: " ") ?? v
            }
        }
        func str(_ k: String, _ d: String = "") -> String { dict[k] ?? d }
        func int(_ k: String, _ d: Int) -> Int { Int(dict[k] ?? "") ?? d }
        func double(_ k: String) -> Double? { Double(dict[k] ?? "") }
    }
}

import Foundation
import Network
import CoreGraphics

/// Self-contained dashboard server, embedded in the menubar app — no Python, no shelling out.
/// Binds loopback only (127.0.0.1), serves the SPA + a JSON API backed by the same in-process
/// Swift (Store / Search / RAG / Coach / Weekly / Analytics). While the app runs, the cockpit
/// at http://127.0.0.1:7790 is always live.
final class DashboardServer: @unchecked Sendable {
    private let dbPath: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "screenmemory.dashboard", attributes: .concurrent)
    private var listener: NWListener?
    private let embLock = NSLock()
    private var _embedder: Embedder?

    init(dbPath: String, port: UInt16 = 7790) { self.dbPath = dbPath; self.port = port }

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
            json(conn, Stats(count: store?.count() ?? 0, paused: Privacy.isPaused,
                             capturing: CaptureState.isCapturing, permission: CGPreflightScreenCaptureAccess()))

        case ("GET", "/api/days"):
            guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
            json(conn, store.dayCounts().map { DayCount(day: $0.day, count: $0.count) })

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

        case ("GET", "/api/recap"):
            Task {
                guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
                let day = dayFrom(q.str("date", "yesterday"))
                let r = await Recap.generate(day: day, store: store)
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                Paths.write(Recap.markdown(r), to: Paths.file(Paths.recaps, "\(df.string(from: day)).md"))
                json(conn, JRecap(date: r.date, summary: r.digest?.summary ?? "", highlights: r.digest?.highlights ?? [],
                                  unfinished: r.digest?.unfinished ?? [],
                                  sessions: r.sessions.map { JSess(start: $0.start, end: $0.end, app: $0.app, title: $0.title, summary: $0.summary) }))
            }

        case ("GET", "/api/coach"):
            Task {
                guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
                let r = await Coach.generate(day: dayFrom(q.str("day", "yesterday")), store: store)
                Paths.write(Coach.markdown(r), to: Paths.file(Paths.coach, "\(r.date).md"))
                json(conn, JCoach(date: r.date, observation: r.advice?.observation ?? "", suggestions: r.advice?.suggestions ?? [],
                                  keepDoing: r.advice?.keepDoing ?? "", report: r.report))
            }

        case ("GET", "/api/weekly"):
            Task {
                guard let store = try? Store(path: dbPath) else { return fail(conn, "db") }
                let r = await Weekly.generate(endingDay: dayFrom(q.str("end", "yesterday")), store: store)
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                Paths.write(Weekly.markdown(r), to: Paths.file(Paths.weekly, "\(df.string(from: r.to)).md"))
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
    }
}

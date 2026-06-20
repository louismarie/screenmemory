import Foundation

// ScreenMemory — ANE-powered semantic screen memory (capture -> OCR -> embed -> RAG).
//
// Subcommands:
//   capture [fps]        continuous screen capture (default 1 fps); needs Screen Recording permission
//   index <image>        OCR an image file, embed + store it          (headless-testable)
//   add "<text>"         embed + store raw text                       (headless-testable)
//   query "<question>"   retrieve top-k + answer via FoundationModels
//   stats                number of stored memories

let dbPath = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.db")
let args = Array(CommandLine.arguments.dropFirst())
// No subcommand (e.g. launched by macOS via `open`) -> run the menubar UI.
let cmd = args.first ?? "menubar"

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// JSON output for the local web UI (list / search / ask subcommands).
struct JMemory: Encodable { let id: Int; let ts: Double; let text: String }
struct JHit: Encodable { let ts: Double; let score: Float; let text: String; let app: String; let title: String }
struct JAsk: Encodable { let answer: String; let sources: [JHit]; let used: [Int]; let notFound: Bool }
func printJSON<T: Encodable>(_ v: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.withoutEscapingSlashes]
    if let d = try? enc.encode(v), let s = String(data: d, encoding: .utf8) { print(s) }
}

switch cmd {
case "capture":
    let fps = args.count > 1 ? Double(args[1]) ?? 1.0 : 1.0
    let store = try Store(path: dbPath)
    let embedder = try Embedder()
    let engine = CaptureEngine(store: store, embedder: embedder)
    try await engine.start(fps: fps)
    err("capturing... Ctrl-C to stop")
    while true { try await Task.sleep(for: .seconds(3600)) }

case "index":
    guard args.count > 1, let img = OCR.loadImage(URL(fileURLWithPath: args[1])) else {
        err("usage: index <image-file>"); exit(2)
    }
    let text = Privacy.redact(OCR.recognize(img))
    guard !text.isEmpty else { err("no text recognized"); exit(1) }
    let store = try Store(path: dbPath)
    let vec = try Embedder().embed(text)
    store.insert(ts: Date().timeIntervalSince1970, text: text, vec: vec)
    print("indexed \(text.count) chars; total \(store.count())")

case "add":
    guard args.count > 1 else { err("usage: add \"<text>\""); exit(2) }
    let text = Privacy.redact(args[1])
    let store = try Store(path: dbPath)
    let vec = try Embedder().embed(text)
    store.insert(ts: Date().timeIntervalSince1970, text: text, vec: vec)
    print("added; total \(store.count())")

case "query":
    guard args.count > 1 else { err("usage: query \"<question>\""); exit(2) }
    let store = try Store(path: dbPath)
    let hits = try Search.run(query: args[1], store: store, embedder: Embedder())
    guard !hits.isEmpty else { print("no memories stored yet"); break }
    let answer = await RAG.answer(question: args[1], context: hits)
    print("\n=== Answer ===\n\(answer)\n")
    for (i, h) in hits.enumerated() {
        let meta = [h.app, h.title].filter { !$0.isEmpty }.joined(separator: " — ")
        print("[\(i + 1)] \(RAG.stamp(h.ts))\(meta.isEmpty ? "" : " · " + meta)")
    }

case "reindex":   // chunk + embed the backlog of whole-screen memories
    let store = try Store(path: dbPath)
    let embedder = try Embedder()
    let ids = store.unchunkedMemoryIds()
    err("reindexing \(ids.count) memories into chunks...")
    var done = 0
    for id in ids {
        guard let row = store.memory(id: id) else { continue }
        for block in Chunker.blocks(fromPlainText: row.text) {
            let vec = try embedder.embed(block)
            store.insertChunk(memId: id, ts: row.ts, app: "", title: "", text: block, vec: vec)
        }
        done += 1
        if done % 50 == 0 { err("  \(done)/\(ids.count)") }
    }
    print("reindexed \(done) memories -> \(store.chunkCount()) chunks total")

case "list":   // list [limit] [offset] -> JSON, newest first (for the web UI)
    let limit = args.count > 1 ? Int(args[1]) ?? 50 : 50
    let offset = args.count > 2 ? Int(args[2]) ?? 0 : 0
    let store = try Store(path: dbPath)
    let rows = store.list(limit: limit, offset: offset)
    printJSON(rows.map { JMemory(id: $0.id, ts: $0.ts, text: $0.text) })

case "search":   // search "<q>" [k] -> JSON hits with scores, no generation
    guard args.count > 1 else { err("usage: search \"<q>\" [k]"); exit(2) }
    let k = args.count > 2 ? Int(args[2]) ?? 8 : 8
    let store = try Store(path: dbPath)
    var opts = Search.Options(); opts.k = k
    let hits = try Search.run(query: args[1], store: store, embedder: Embedder(), opts: opts)
    printJSON(hits.map { JHit(ts: $0.ts, score: $0.score, text: $0.text, app: $0.app, title: $0.title) })

case "ask":   // ask "<q>" [k] -> JSON {answer, sources, used, notFound} for the UI
    guard args.count > 1 else { err("usage: ask \"<q>\" [k]"); exit(2) }
    let k = args.count > 2 ? Int(args[2]) ?? 6 : 6
    let store = try Store(path: dbPath)
    var opts = Search.Options(); opts.k = k
    let hits = try Search.run(query: args[1], store: store, embedder: Embedder(), opts: opts)
    if hits.isEmpty {
        printJSON(JAsk(answer: "Aucun souvenir trouvé pour cette période.", sources: [], used: [], notFound: true))
        break
    }
    let a = await RAG.answerGrounded(question: args[1], context: hits)
    let text = a.notFound ? "Je n'ai pas vu ça à l'écran (rien dans les extraits récupérés)." : a.text
    printJSON(JAsk(answer: text,
                   sources: hits.map { JHit(ts: $0.ts, score: $0.score, text: $0.text, app: $0.app, title: $0.title) },
                   used: a.sources, notFound: a.notFound))

case "recap":   // recap [today|yesterday|YYYY-MM-DD] [--json] [--fresh]
    struct JSession: Encodable { let start: Double; let end: Double; let app: String; let title: String; let summary: String }
    struct JRecap: Encodable { let date: String; let summary: String; let highlights: [String]; let unfinished: [String]; let sessions: [JSession]; let markdown: String }
    let json = args.contains("--json")
    let fresh = args.contains("--fresh")
    let dayArg = args.dropFirst().first { !$0.hasPrefix("--") } ?? "yesterday"
    let cal = Calendar.current
    var day = cal.startOfDay(for: Date())
    if dayArg == "yesterday" { day = cal.date(byAdding: .day, value: -1, to: day)! }
    else if dayArg != "today" {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: dayArg) else { err("usage: recap [today|yesterday|YYYY-MM-DD]"); exit(2) }
        day = d
    }
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let recapDir = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.recaps")
    try? FileManager.default.createDirectory(atPath: recapDir, withIntermediateDirectories: true)
    let mdPath = (recapDir as NSString).appendingPathComponent("\(df.string(from: day)).md")
    // Cache: a finished day's recap never changes; today's is always regenerated.
    if !fresh && !json && dayArg != "today", let cached = try? String(contentsOfFile: mdPath, encoding: .utf8) {
        print(cached); break
    }
    let store = try Store(path: dbPath)
    let result = await Recap.generate(day: day, store: store)
    let md = Recap.markdown(result)
    try? md.write(toFile: mdPath, atomically: true, encoding: .utf8)
    if json {
        printJSON(JRecap(date: result.date,
                         summary: result.digest?.summary ?? "",
                         highlights: result.digest?.highlights ?? [],
                         unfinished: result.digest?.unfinished ?? [],
                         sessions: result.sessions.map { JSession(start: $0.start, end: $0.end, app: $0.app, title: $0.title, summary: $0.summary) },
                         markdown: md))
    } else {
        print(md)
    }

case "eval":   // eval make [n] -> synthetic golden set; eval run -> Recall@10 + MRR
    struct EvalItem: Codable { let q: String; let memId: Int }
    let evalPath = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.eval.json")
    let store = try Store(path: dbPath)
    if args.count > 1, args[1] == "make" {
        let n = args.count > 2 ? Int(args[2]) ?? 30 : 30
        let pool = store.allChunks().filter { $0.text.count >= 120 }.shuffled().prefix(n * 2)
        var items = [EvalItem]()
        for c in pool {
            guard items.count < n else { break }
            if let q = await RAG.makeQuestion(from: c.text) {
                items.append(EvalItem(q: q, memId: c.memId))
                err("  [\(items.count)/\(n)] \(q)")
            }
        }
        try JSONEncoder().encode(items).write(to: URL(fileURLWithPath: evalPath))
        print("golden set: \(items.count) questions -> \(evalPath)")
    } else {
        guard let data = FileManager.default.contents(atPath: evalPath),
              let items = try? JSONDecoder().decode([EvalItem].self, from: data), !items.isEmpty else {
            err("no golden set — run: eval make 30"); exit(1)
        }
        let embedder = try Embedder()
        var opts = Search.Options(); opts.k = 10
        var hitAt10 = 0, mrr = 0.0
        for item in items {
            let hits = try Search.run(query: item.q, store: store, embedder: embedder, opts: opts)
            if let rank = hits.firstIndex(where: { $0.memId == item.memId }) {
                hitAt10 += 1
                mrr += 1.0 / Double(rank + 1)
            }
        }
        let n = Double(items.count)
        print(String(format: "n=%d  Recall@10=%.2f  MRR=%.3f", items.count, Double(hitAt10) / n, mrr / n))
    }

case "bakeoff":   // compare distiluse vs Apple NLContextualEmbedding on the golden set
    let store = try Store(path: dbPath)
    let evalPath = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.eval.json")
    try Bakeoff.run(store: store, evalPath: evalPath)

case "analytics":   // analytics [days] -> JSON [{app, minutes}] from session grouping
    struct JApp: Encodable { let app: String; let minutes: Int }
    let days = args.count > 1 ? Int(args[1]) ?? 1 : 1
    let store = try Store(path: dbPath)
    let now = Date().timeIntervalSince1970
    let chunks = store.allChunks(from: now - Double(days) * 86400, to: now)
    var perApp = [String: Double]()
    for s in Recap.sessions(chunks: chunks) {
        let app = s.app.isEmpty ? "(inconnu)" : s.app
        perApp[app, default: 0] += max(60, s.end - s.start)
    }
    let sorted = perApp.sorted { $0.value > $1.value }.map { JApp(app: $0.key, minutes: Int($0.value / 60)) }
    printJSON(sorted)

case "days":   // days -> JSON [{day, count}] of local-calendar days with data, newest first
    struct JDay: Encodable { let day: String; let count: Int }
    let store = try Store(path: dbPath)
    printJSON(store.dayCounts().map { JDay(day: $0.day, count: $0.count) })

case "focus":   // focus [days] [--json] -> productivity/focus report
    let days = args.dropFirst().first { !$0.hasPrefix("-") }.flatMap { Int($0) } ?? 1
    let store = try Store(path: dbPath)
    let report = Analytics.report(days: days, store: store)
    if args.contains("--json") { printJSON(report) }
    else { print(Analytics.brief(report)) }

case "coach":   // coach [today|yesterday|YYYY-MM-DD] [--json] -> proactive suggestions
    struct JCoach: Encodable { let date: String; let observation: String; let suggestions: [String]; let keepDoing: String; let report: Analytics.FocusReport; let markdown: String }
    let json = args.contains("--json")
    let dayArg = args.dropFirst().first { !$0.hasPrefix("--") } ?? "yesterday"
    let cal = Calendar.current
    var day = cal.startOfDay(for: Date())
    if dayArg == "yesterday" { day = cal.date(byAdding: .day, value: -1, to: day)! }
    else if dayArg != "today" {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: dayArg) else { err("usage: coach [today|yesterday|YYYY-MM-DD]"); exit(2) }
        day = d
    }
    let store = try Store(path: dbPath)
    let result = await Coach.generate(day: day, store: store)
    let md = Coach.markdown(result)
    Paths.write(md, to: Paths.file(Paths.coach, "\(result.date).md"))
    if json {
        printJSON(JCoach(date: result.date,
                         observation: result.advice?.observation ?? "",
                         suggestions: result.advice?.suggestions ?? [],
                         keepDoing: result.advice?.keepDoing ?? "",
                         report: result.report, markdown: md))
    } else { print(md) }

case "weekly":   // weekly [YYYY-MM-DD end] [--json] -> 7-day synthesis
    struct JWeekly: Encodable { let from: String; let to: String; let summary: String; let achievements: [String]; let openThreads: [String]; let patterns: [String]; let report: Analytics.FocusReport; let markdown: String }
    let json = args.contains("--json")
    let cal = Calendar.current
    var end = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
    if let explicit = args.dropFirst().first(where: { !$0.hasPrefix("--") }) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: explicit) { end = d }
    }
    let store = try Store(path: dbPath)
    let result = await Weekly.generate(endingDay: end, store: store)
    let md = Weekly.markdown(result)
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    Paths.write(md, to: Paths.file(Paths.weekly, "\(df.string(from: result.to)).md"))
    if json {
        printJSON(JWeekly(from: df.string(from: result.from), to: df.string(from: result.to),
                          summary: result.digest?.summary ?? "",
                          achievements: result.digest?.achievements ?? [],
                          openThreads: result.digest?.openThreads ?? [],
                          patterns: result.digest?.patterns ?? [],
                          report: result.report, markdown: md))
    } else { print(md) }

case "digest":   // digest [yesterday|YYYY-MM-DD] -> build+print the morning digest
    let dayArg = args.dropFirst().first { !$0.hasPrefix("--") } ?? "yesterday"
    let cal = Calendar.current
    var day = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
    if dayArg != "yesterday" {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: dayArg) else { err("usage: digest [yesterday|YYYY-MM-DD]"); exit(2) }
        day = d
    }
    let store = try Store(path: dbPath)
    guard let path = await Proactive.buildMorningDigest(day: day, store: store) else {
        print("aucune donnée pour ce jour"); break
    }
    print(Paths.read(path) ?? "")
    err("-> \(path)")

case "tick":   // tick [--force] [--silent] -> run any due proactive artifacts (for cron/testing)
    let store = try Store(path: dbPath)
    let produced = await Proactive.tick(store: store,
                                        notify: !args.contains("--silent"),
                                        force: args.contains("--force"))
    print(produced.isEmpty ? "rien à produire maintenant" : "produit: " + produced.joined(separator: ", "))

case "login":   // login [on|off|status] -> SMAppService "run at login"
    let sub = args.count > 1 ? args[1] : "status"
    switch sub {
    case "on":  print(LoginItem.setEnabled(true))
    case "off": print(LoginItem.setEnabled(false))
    default:    print("login item: \(LoginItem.statusDescription())  ·  auto-capture: \(LoginItem.autoCaptureEnabled)")
    }

case "prune":   // prune <days> [--apply] — retention: raw rows go, recap markdowns stay
    guard args.count > 1, let keepDays = Int(args[1]) else { err("usage: prune <keep-days> [--apply]"); exit(2) }
    let store = try Store(path: dbPath)
    let cutoff = Date().timeIntervalSince1970 - Double(keepDays) * 86400
    let (mems, chks) = store.countOlderThan(ts: cutoff)
    if args.contains("--apply") {
        store.deleteOlderThan(ts: cutoff)
        print("pruned \(mems) memories + \(chks) chunks older than \(keepDays)d (recaps are kept forever)")
    } else {
        print("would prune \(mems) memories + \(chks) chunks older than \(keepDays)d — add --apply to do it")
    }

case "stats":
    let store = try Store(path: dbPath)
    print("memories: \(store.count())  db: \(dbPath)  paused: \(Privacy.isPaused)")

case "pause":
    FileManager.default.createFile(atPath: Privacy.pauseFlag, contents: nil)
    print("paused — capture will not index until 'resume'")

case "resume":
    try? FileManager.default.removeItem(atPath: Privacy.pauseFlag)
    print("resumed")

case "ready":
    print(RAG.availabilityDescription())

case "agent-install":
    // Deprecated: a background launchd daemon can't get an interactive Screen Recording
    // grant. The always-on host is now the menubar app (login item + auto-start capture).
    print("""
    ⚠️  'agent-install' est déprécié : un daemon launchd en arrière-plan ne peut pas
        obtenir l'autorisation Enregistrement d'écran (pas d'UI pour l'accorder).
        Always-on se fait désormais via l'app barre de menus :
          1. ./package.sh && open ~/Applications/ScreenMemory.app
          2. accorde Enregistrement de l'écran quand macOS le demande
          3. l'app s'enregistre au démarrage et relance la capture automatiquement
        (statut: 'ScreenMemory login status')
    """)

case "agent-uninstall":
    Agent.uninstall()

case "agent-status":
    Agent.status()

case "serve":   // serve the dashboard standalone (the menubar app does this in-process too)
    let port = args.count > 1 ? UInt16(args[1]) ?? 7790 : 7790
    let server = DashboardServer(dbPath: dbPath, port: port)
    server.start()
    err("dashboard -> http://127.0.0.1:\(port)  (Ctrl-C to stop)")
    while true { try await Task.sleep(for: .seconds(3600)) }

case "menubar":
    runMenuBar(dbPath: dbPath)   // runs the AppKit run loop (blocks)

default:
    print("""
    ScreenMemory — usage:
      capture [fps]        continuous screen capture (needs Screen Recording permission)
      index <image>        OCR + embed + store an image file
      add "<text>"         embed + store raw text
      query "<question>"   retrieve + answer (FoundationModels)
      stats                count stored memories
    """)
}

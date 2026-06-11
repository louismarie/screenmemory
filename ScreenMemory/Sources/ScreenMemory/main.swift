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
    let fps = args.count > 1 ? Int(args[1]) ?? 1 : 1
    Agent.install(fps: fps)

case "agent-uninstall":
    Agent.uninstall()

case "agent-status":
    Agent.status()

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

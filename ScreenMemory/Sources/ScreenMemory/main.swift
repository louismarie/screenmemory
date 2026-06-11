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
struct JHit: Encodable { let ts: Double; let score: Float; let text: String }
struct JAsk: Encodable { let answer: String; let sources: [JHit] }
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
    let q = try Embedder().embed(args[1])
    let hits = store.search(q, k: 4)
    guard !hits.isEmpty else { print("no memories stored yet"); break }
    let answer = await RAG.answer(question: args[1], context: hits)
    print("\n=== Answer ===\n\(answer)")

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
    let q = try Embedder().embed(args[1])
    printJSON(store.search(q, k: k).map { JHit(ts: $0.ts, score: $0.score, text: $0.text) })

case "ask":   // ask "<q>" [k] -> JSON {answer, sources} — sources let the UI expose hallucinations
    guard args.count > 1 else { err("usage: ask \"<q>\" [k]"); exit(2) }
    let k = args.count > 2 ? Int(args[2]) ?? 4 : 4
    let store = try Store(path: dbPath)
    let q = try Embedder().embed(args[1])
    let hits = store.search(q, k: k)
    let answer = hits.isEmpty ? "Aucun souvenir stocké pour l'instant."
                              : await RAG.answer(question: args[1], context: hits)
    printJSON(JAsk(answer: answer, sources: hits.map { JHit(ts: $0.ts, score: $0.score, text: $0.text) }))

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

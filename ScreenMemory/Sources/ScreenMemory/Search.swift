import Foundation

/// Hybrid retrieval over decrypted chunks: BM25 (lexical, in-memory — nothing plaintext
/// touches disk) + cosine (semantic), fused with Reciprocal Rank Fusion, recency prior,
/// query-time near-duplicate collapse, and hard time filters parsed from the question.
enum Search {

    struct Options {
        var k = 6
        var rrfK = 60.0          // standard RRF constant
        var recencyWeight = 0.008
        var recencyHalfLifeDays = 7.0
        var poolPerLeg = 50      // candidates per leg before fusion
    }

    static func run(query: String, store: Store, embedder: Embedder, opts: Options = Options()) throws -> [Hit] {
        let (range, cleaned) = TimeFilter.extract(from: query)
        var chunks = store.allChunks(from: range?.lowerBound, to: range?.upperBound)
        // A time-filtered query with an empty window: fall back to the full corpus
        // rather than answering "nothing" because of an overly strict parse.
        if chunks.isEmpty && range != nil { chunks = store.allChunks() }
        guard !chunks.isEmpty else { return [] }

        // — semantic leg —
        let qVec = try embedder.embed(cleaned)   // NB: add "query: " prefix when swapping to e5
        var cosRank: [(idx: Int, s: Float)] = chunks.enumerated().map { i, c in (i, dot(qVec, c.vec)) }
        cosRank.sort { $0.s > $1.s }

        // — lexical leg —
        // App + window title are first-class search signal (Rewind's `segment` lesson).
        let bm25 = BM25(corpus: chunks.map { "\($0.app) \($0.title) \($0.text)" })
        var lexRank: [(idx: Int, s: Double)] = bm25.scores(query: cleaned).enumerated().map { ($0, $1) }
        lexRank.sort { $0.s > $1.s }

        // — RRF fusion + recency prior —
        var fused = [Int: Double]()
        for (r, e) in cosRank.prefix(opts.poolPerLeg).enumerated() {
            fused[e.idx, default: 0] += 1.0 / (opts.rrfK + Double(r) + 1)
        }
        for (r, e) in lexRank.prefix(opts.poolPerLeg).enumerated() where e.s > 0 {
            fused[e.idx, default: 0] += 1.0 / (opts.rrfK + Double(r) + 1)
        }
        let now = Date().timeIntervalSince1970
        let ranked = fused.map { idx, score -> (Int, Double) in
            let ageDays = max(0, now - chunks[idx].ts) / 86400
            return (idx, score + opts.recencyWeight * pow(0.5, ageDays / opts.recencyHalfLifeDays))
        }.sorted { $0.1 > $1.1 }

        // — near-duplicate collapse: best chunk per (app|title|5-min bucket), plus text-overlap guard —
        var kept = [Hit]()
        var seenKeys = Set<String>()
        var keptTokens = [Set<String>]()
        for (idx, score) in ranked {
            let c = chunks[idx]
            let key = "\(c.app)|\(c.title)|\(Int(c.ts / 300))"
            if seenKeys.contains(key) { continue }
            let toks = BM25.tokenize(c.text)
            let tokSet = Set(toks)
            if keptTokens.contains(where: { jaccard($0, tokSet) > 0.8 }) { continue }
            seenKeys.insert(key)
            keptTokens.append(tokSet)
            kept.append(Hit(ts: c.ts, text: c.text, score: Float(score), app: c.app, title: c.title))
            if kept.count >= opts.k { break }
        }
        return kept
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

/// Okapi BM25 computed in memory over the decrypted corpus at query time.
struct BM25 {
    private let docs: [[String]]
    private let df: [String: Int]
    private let avgLen: Double
    private let k1 = 1.2, b = 0.75

    init(corpus: [String]) {
        docs = corpus.map(Self.tokenize)
        var df = [String: Int]()
        for d in docs { for t in Set(d) { df[t, default: 0] += 1 } }
        self.df = df
        avgLen = docs.isEmpty ? 0 : Double(docs.reduce(0) { $0 + $1.count }) / Double(docs.count)
    }

    func scores(query: String) -> [Double] {
        let qTokens = Self.tokenize(query)
        let n = Double(docs.count)
        return docs.map { d in
            guard !d.isEmpty, avgLen > 0 else { return 0 }
            var tf = [String: Int]()
            for t in d { tf[t, default: 0] += 1 }
            var s = 0.0
            for q in qTokens {
                guard let f = tf[q], let dfq = df[q] else { continue }
                let idf = log((n - Double(dfq) + 0.5) / (Double(dfq) + 0.5) + 1)
                let num = Double(f) * (k1 + 1)
                let den = Double(f) + k1 * (1 - b + b * Double(d.count) / avgLen)
                s += idf * num / den
            }
            return s
        }
    }

    /// Lowercase, diacritic-folded, alphanumeric tokens (≥2 chars) — FR/EN friendly.
    /// Trailing s/x folding is a poor man's FR/EN plural stemmer ("écrans" == "écran").
    static func tokenize(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
            .map { t in
                if t.count > 3, t.hasSuffix("s") || t.hasSuffix("x") { return String(t.dropLast()) }
                return t
            }
    }

    private static let stopwords: Set<String> = [
        "le", "la", "les", "un", "une", "des", "de", "du", "ce", "cette", "ces", "que", "qui",
        "quoi", "quel", "quelle", "quels", "quelles", "est", "sont", "etait", "il", "elle",
        "je", "tu", "on", "nous", "vous", "ils", "et", "ou", "mais", "dans", "sur", "pour",
        "par", "avec", "sans", "pas", "ne", "se", "sa", "son", "ses", "au", "aux", "en",
        "the", "a", "an", "of", "to", "in", "on", "at", "is", "are", "was", "were", "and",
        "or", "but", "for", "with", "what", "which", "who", "did", "do", "does", "my", "me",
    ]
}

/// Time-range extraction from the question ("hier", "ce matin", "mardi", "10 juin"...).
/// Applied as a hard SQL filter BEFORE ranking — the retrieval-SOTA consensus.
enum TimeFilter {
    static func extract(from query: String) -> (ClosedRange<Double>?, String) {
        let cal = Calendar.current
        let now = Date()
        let lower = query.lowercased()

        func dayRange(_ d: Date) -> ClosedRange<Double> {
            let start = cal.startOfDay(for: d)
            return start.timeIntervalSince1970...(start.timeIntervalSince1970 + 86400)
        }

        let keywords: [(String, ClosedRange<Double>)] = [
            ("avant-hier", dayRange(cal.date(byAdding: .day, value: -2, to: now)!)),
            ("hier", dayRange(cal.date(byAdding: .day, value: -1, to: now)!)),
            ("aujourd'hui", dayRange(now)), ("aujourd hui", dayRange(now)), ("today", dayRange(now)),
            ("yesterday", dayRange(cal.date(byAdding: .day, value: -1, to: now)!)),
            ("ce matin", morning(now, cal)), ("this morning", morning(now, cal)),
            ("cette semaine", lastDays(7, now)), ("this week", lastDays(7, now)),
            ("la semaine derniere", weekBefore(now, cal)), ("last week", weekBefore(now, cal)),
        ]
        for (kw, range) in keywords where lower.contains(kw) {
            let cleaned = lower.replacingOccurrences(of: kw, with: " ")
            return (range, cleaned)
        }

        // Explicit dates ("mardi 9 juin", "le 10/06") via NSDataDetector.
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let m = det.matches(in: query, range: NSRange(query.startIndex..., in: query))
            if let date = m.first?.date, date <= now {
                return (dayRange(date), query)
            }
        }
        return (nil, query)
    }

    private static func morning(_ d: Date, _ cal: Calendar) -> ClosedRange<Double> {
        let start = cal.startOfDay(for: d)
        return (start.timeIntervalSince1970 + 5 * 3600)...(start.timeIntervalSince1970 + 12 * 3600)
    }
    private static func lastDays(_ n: Double, _ now: Date) -> ClosedRange<Double> {
        (now.timeIntervalSince1970 - n * 86400)...now.timeIntervalSince1970
    }
    private static func weekBefore(_ now: Date, _ cal: Calendar) -> ClosedRange<Double> {
        let t = now.timeIntervalSince1970
        return (t - 14 * 86400)...(t - 7 * 86400)
    }
}

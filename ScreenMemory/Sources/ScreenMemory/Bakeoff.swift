import Foundation
import NaturalLanguage

/// Embedding bake-off: Apple's built-in NLContextualEmbedding (BERT-class, multilingual,
/// OS-managed assets, ANE) vs our distiluse CoreML model — judged on the eval golden set,
/// cosine-only on both sides. If the built-in wins, we can delete a 257MB model + tokenizer.
enum Bakeoff {

    /// Mean-pooled, L2-normalized sentence vector from NLContextualEmbedding.
    final class AppleEmbedder {
        private let emb: NLContextualEmbedding

        init?() {
            guard let e = NLContextualEmbedding(script: .latin) else { return nil }
            emb = e
            if !e.hasAvailableAssets {
                let sem = DispatchSemaphore(value: 0)
                e.requestAssets { _, _ in sem.signal() }
                _ = sem.wait(timeout: .now() + 120)
            }
            do { try e.load() } catch { return nil }
        }

        func embed(_ text: String) -> [Float]? {
            guard let r = try? emb.embeddingResult(for: String(text.prefix(1200)), language: nil) else { return nil }
            let dim = emb.dimension
            var sum = [Double](repeating: 0, count: dim)
            var n = 0
            r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
                for i in 0..<min(dim, vec.count) { sum[i] += vec[i] }
                n += 1
                return true
            }
            guard n > 0 else { return nil }
            var v = sum.map { Float($0 / Double(n)) }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { return nil }
            for i in 0..<v.count { v[i] /= norm }
            return v
        }
    }

    struct EvalItem: Codable { let q: String; let memId: Int }

    static func run(store: Store, evalPath: String) throws {
        guard let data = FileManager.default.contents(atPath: evalPath),
              let items = try? JSONDecoder().decode([EvalItem].self, from: data), !items.isEmpty else {
            print("no golden set — run: eval make 30"); return
        }
        let chunks = store.allChunks()
        print("corpus: \(chunks.count) chunks, \(items.count) questions")

        // — leg A: distiluse (stored vectors) —
        let distil = try Embedder()
        let a = score(items: items, chunks: chunks,
                      chunkVec: { $0.vec },
                      queryVec: { try? distil.embed($0) })
        print(String(format: "distiluse (cos-only) : Recall@10=%.2f  MRR=%.3f", a.0, a.1))

        // — leg B: NLContextualEmbedding (re-embed corpus in memory) —
        guard let apple = AppleEmbedder() else {
            print("NLContextualEmbedding unavailable (assets not downloadable?)"); return
        }
        print("re-embedding corpus with NLContextualEmbedding...")
        var appleVecs = [[Float]?]()
        appleVecs.reserveCapacity(chunks.count)
        for (i, c) in chunks.enumerated() {
            appleVecs.append(apple.embed(c.text))
            if (i + 1) % 1000 == 0 { FileHandle.standardError.write("  \(i + 1)/\(chunks.count)\n".data(using: .utf8)!) }
        }
        let b = score(items: items, chunks: chunks,
                      chunkVec: { appleVecs[$0.idx] ?? [] },
                      queryVec: { apple.embed($0) })
        print(String(format: "NLContextualEmbedding: Recall@10=%.2f  MRR=%.3f", b.0, b.1))
    }

    private struct IndexedChunk { let idx: Int; let memId: Int; let vec: [Float] }

    private static func score(items: [EvalItem], chunks: [Chunk],
                              chunkVec: (IndexedChunk) -> [Float],
                              queryVec: (String) -> [Float]?) -> (Double, Double) {
        let indexed = chunks.enumerated().map { IndexedChunk(idx: $0, memId: $1.memId, vec: $1.vec) }
        var hit = 0, mrr = 0.0
        for item in items {
            guard let q = queryVec(item.q), !q.isEmpty else { continue }
            var scored: [(memId: Int, s: Float)] = []
            for c in indexed {
                let v = chunkVec(c)
                guard v.count == q.count else { continue }
                var s: Float = 0
                for i in 0..<q.count { s += q[i] * v[i] }
                scored.append((c.memId, s))
            }
            scored.sort { $0.s > $1.s }
            // top-10 distinct screens
            var seen = Set<Int>(), ranks = [Int]()
            for e in scored {
                if seen.contains(e.memId) { continue }
                seen.insert(e.memId); ranks.append(e.memId)
                if ranks.count >= 10 { break }
            }
            if let r = ranks.firstIndex(of: item.memId) {
                hit += 1
                mrr += 1.0 / Double(r + 1)
            }
        }
        let n = Double(items.count)
        return (Double(hit) / n, mrr / n)
    }
}

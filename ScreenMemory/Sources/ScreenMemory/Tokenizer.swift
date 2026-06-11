import Foundation

/// Minimal BERT (uncased) WordPiece tokenizer — self-contained, loads vocab.txt.
/// Matches the preprocessing of sentence-transformers/all-MiniLM-L6-v2.
struct BertTokenizer {
    private let vocab: [String: Int]
    private let maxLen: Int
    private let lowercase: Bool
    private let unk = "[UNK]", cls = "[CLS]", sep = "[SEP]"

    /// lowercase=false for cased multilingual models (e.g. mBERT cased / distiluse).
    init(vocabURL: URL, maxLen: Int = 128, lowercase: Bool = false) throws {
        let text = try String(contentsOf: vocabURL, encoding: .utf8)
        var v = [String: Int]()
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let tok = line.trimmingCharacters(in: .whitespaces)
            if !tok.isEmpty { v[tok] = i }
        }
        self.vocab = v
        self.maxLen = maxLen
        self.lowercase = lowercase
    }

    /// Returns (inputIds, attentionMask), padded/truncated to maxLen.
    func encode(_ text: String) -> ([Int32], [Int32]) {
        var pieces = [cls]
        for word in basicTokenize(text) {
            pieces.append(contentsOf: wordpiece(word))
        }
        pieces.append(sep)
        if pieces.count > maxLen {                       // truncate, keep final [SEP]
            pieces = Array(pieces.prefix(maxLen - 1)) + [sep]
        }
        var ids = pieces.map { Int32(vocab[$0] ?? vocab[unk]!) }
        var mask = [Int32](repeating: 1, count: ids.count)
        while ids.count < maxLen { ids.append(0); mask.append(0) }   // [PAD]=0
        return (ids, mask)
    }

    // Split on whitespace + isolate punctuation. Lowercase/strip-accents only if uncased.
    private func basicTokenize(_ text: String) -> [String] {
        let normalized = lowercase
            ? text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            : text
        var out = [String]()
        var cur = ""
        for ch in normalized {
            if ch.isWhitespace {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else if ch.isPunctuation || ch.isSymbol {
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append(String(ch))
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // Greedy longest-match-first WordPiece.
    private func wordpiece(_ word: String) -> [String] {
        let chars = Array(word)
        if chars.count > 100 { return [unk] }
        var output = [String]()
        var start = 0
        while start < chars.count {
            var end = chars.count
            var match: String? = nil
            while start < end {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if vocab[sub] != nil { match = sub; break }
                end -= 1
            }
            guard let m = match else { return [unk] }   // any failure -> whole word UNK
            output.append(m)
            start = end
        }
        return output
    }
}

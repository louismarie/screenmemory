import Foundation
import CoreGraphics

/// Layout-aware chunking of OCR output. One whole-screen embedding buries the signal
/// (and seq_len 128 truncates it); spatial blocks of ~300 chars are what retrieval needs.
enum Chunker {
    static let maxChars = 350
    static let minChars = 12          // drop crumbs (lone menu words, page numbers)

    /// Group OCR lines into spatial blocks: consecutive lines join a block when they are
    /// vertically adjacent (gap < ~1.5 line heights) AND horizontally overlapping —
    /// this keeps sidebars, main content and dialogs apart without a layout model.
    static func blocks(from lines: [TextLine]) -> [String] {
        guard !lines.isEmpty else { return [] }
        // Reading order: top-to-bottom (Vision origin is bottom-left), then left-to-right.
        let sorted = lines.sorted { (a: TextLine, b: TextLine) -> Bool in
            let dy = a.box.midY - b.box.midY
            if abs(dy) > 0.005 { return dy > 0 }
            return a.box.minX < b.box.minX
        }
        let heights: [CGFloat] = sorted.map { $0.box.height }.sorted()
        let medianH = heights[heights.count / 2]
        let maxGap = max(0.004, medianH * 1.6)

        var blocks: [[TextLine]] = []
        for line in sorted {
            if var last = blocks.last, let prev = last.last,
               prev.box.minY - line.box.maxY < maxGap,        // vertically adjacent
               overlapX(prev.box, line.box) > 0.25 {          // same column
                last.append(line)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append([line])
            }
        }

        // Merge tiny neighbors, then cap block size.
        var texts: [String] = []
        var current = ""
        for b in blocks {
            let t = b.map(\.text).joined(separator: "\n")
            if current.isEmpty { current = t }
            else if current.count + t.count < maxChars { current += "\n" + t }
            else { texts.append(current); current = t }
        }
        if !current.isEmpty { texts.append(current) }

        return texts.flatMap(splitLong).filter { $0.count >= minChars }
    }

    /// Fallback for text without geometry (reindexing old whole-screen rows).
    static func blocks(fromPlainText text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count + 1 > maxChars && !current.isEmpty {
                out.append(current); current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { out.append(current) }
        return out.flatMap(splitLong).filter { $0.count >= minChars }
    }

    private static func splitLong(_ t: String) -> [String] {
        guard t.count > maxChars else { return [t] }
        var out: [String] = []
        var start = t.startIndex
        while start < t.endIndex {
            let end = t.index(start, offsetBy: maxChars, limitedBy: t.endIndex) ?? t.endIndex
            // backtrack to a whitespace to avoid mid-word cuts
            var cut = end
            if end < t.endIndex,
               let ws = t[start..<end].lastIndex(where: { $0.isWhitespace || $0.isNewline }),
               t.distance(from: start, to: ws) > maxChars / 2 {
                cut = t.index(after: ws)
            }
            out.append(String(t[start..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = cut
        }
        return out.filter { !$0.isEmpty }
    }

    private static func overlapX(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        guard inter > 0 else { return 0 }
        return inter / min(a.width, b.width)
    }
}

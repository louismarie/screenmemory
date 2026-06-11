import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia

/// Continuous screen capture with average-hash dedup.
/// Only frames that visually changed get OCR'd + embedded + stored — this is what
/// keeps the always-on ANE pipeline cheap (no re-embedding identical screens).
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let store: Store
    private let embedder: Embedder
    private let ciContext = CIContext()
    private var lastHash: UInt64 = 0
    private var haveLast = false
    private let hammingThreshold: Int
    private let minIndexInterval: Double
    private var lastIndexTime: Double = 0
    private var stream: SCStream?
    private var fps: Double = 1.0
    private var wantRunning = false   // survives stream death -> drives auto-restart

    init(store: Store, embedder: Embedder, hammingThreshold: Int = 6, minIndexInterval: Double = 2.0) {
        self.store = store
        self.embedder = embedder
        self.hammingThreshold = hammingThreshold
        self.minIndexInterval = minIndexInterval
    }

    func start(fps: Double) async throws {
        self.fps = fps
        wantRunning = true
        try await startStream()
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Err.noDisplay }

        let cfg = SCStreamConfiguration()
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.width = display.width            // points; Retina backing handled by SCK
        cfg.height = display.height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 3

        let excluded = Privacy.excludedBundleIDs()
        let excludedApps = content.applications.filter { excluded.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        if !excludedApps.isEmpty {
            FileHandle.standardError.write("excluding \(excludedApps.count) sensitive app(s) from capture\n".data(using: .utf8)!)
        }
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "capture.process"))
        try await stream.startCapture()
        self.stream = stream
        log("capture started on display \(display.width)x\(display.height) @ \(fps)fps")
    }

    // SCStreamOutput — called on the sample handler queue (serialized -> safe to process inline).
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              !Privacy.isPaused,                                                   // user pause flag
              let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Rate-limit: never index more than once per minIndexInterval, even if the
        // screen keeps changing -> caps OCR/embed work on busy screens.
        let now = Date().timeIntervalSince1970
        if now - lastIndexTime < minIndexInterval { return }

        let ci = CIImage(cvPixelBuffer: px)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

        let h = Self.avgHash(cg, ctx: ciContext)
        if haveLast && Self.hamming(h, lastHash) <= hammingThreshold { return }   // unchanged
        lastHash = h; haveLast = true

        let lines = OCR.recognizeLines(cg)
        let text = Privacy.redact(lines.map { $0.text }.joined(separator: "\n"))  // scrub secrets
        guard text.count >= 8 else { return }                                     // skip near-empty screens
        lastIndexTime = now
        let meta = Meta.frontmost()
        do {
            let ts = Date().timeIntervalSince1970
            let vec = try embedder.embed(text)
            store.insert(ts: ts, text: text, vec: vec)            // full screen, for display/recap
            let memId = store.lastInsertedId
            // Retrieval units: layout-aware blocks, each with its own embedding + context.
            var blocks = Chunker.blocks(from: lines).map(Privacy.redact)
            if blocks.isEmpty { blocks = Chunker.blocks(fromPlainText: text) }
            let ctx = [meta.app, meta.title].filter { !$0.isEmpty }.joined(separator: " — ")
            for block in blocks {
                // Embed with app/title context so the semantic leg sees it too.
                // NB: add "passage: " prefix when swapping to e5.
                let bvec = try embedder.embed(ctx.isEmpty ? block : ctx + "\n" + block)
                store.insertChunk(memId: memId, ts: ts, app: meta.app, title: meta.title,
                                  text: block, vec: bvec)
            }
            log("indexed \(text.count) chars, \(blocks.count) chunks [\(meta.app)] (screens \(store.count()))")
        } catch {
            log("embed error: \(error)")
        }
    }

    func stop() {
        wantRunning = false
        stream?.stopCapture { _ in }
        stream = nil
    }

    var isRunning: Bool { wantRunning }

    /// SCK streams die on sleep/lock/display changes. Always-on means: log it,
    /// then retry with backoff until the display is capturable again.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
        self.stream = nil
        guard wantRunning else { return }
        Task { [weak self] in
            var delay = 5.0
            while let self, self.wantRunning, self.stream == nil {
                try? await Task.sleep(for: .seconds(delay))
                guard self.wantRunning, self.stream == nil else { return }
                do {
                    try await self.startStream()
                    self.log("stream auto-restarted")
                } catch {
                    self.log("restart failed (\(error.localizedDescription)), retrying in \(Int(min(delay * 2, 60)))s")
                    delay = min(delay * 2, 60)
                }
            }
        }
    }

    /// stderr is invisible when running as a .app — also append to the log file
    /// that the menubar's "Ouvrir le log" opens.
    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) \(s)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        let path = Agent.logPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        }
    }

    // 8x8 grayscale average hash -> 64-bit fingerprint.
    static func avgHash(_ image: CGImage, ctx: CIContext) -> UInt64 {
        let n = 8
        let gray = CGColorSpaceCreateDeviceGray()
        guard let bmp = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        bmp.interpolationQuality = .low
        bmp.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = bmp.data else { return 0 }
        let p = data.bindMemory(to: UInt8.self, capacity: n * n)
        var sum = 0
        for i in 0..<(n * n) { sum += Int(p[i]) }
        let mean = UInt8(sum / (n * n))
        var bits: UInt64 = 0
        for i in 0..<(n * n) where p[i] > mean { bits |= (1 << UInt64(i)) }
        return bits
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    enum Err: Error { case noDisplay }
}

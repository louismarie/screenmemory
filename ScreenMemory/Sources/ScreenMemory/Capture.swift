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

    init(store: Store, embedder: Embedder, hammingThreshold: Int = 6, minIndexInterval: Double = 2.0) {
        self.store = store
        self.embedder = embedder
        self.hammingThreshold = hammingThreshold
        self.minIndexInterval = minIndexInterval
    }

    func start(fps: Double) async throws {
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
        FileHandle.standardError.write("capture started on display \(display.width)x\(display.height) @ \(fps)fps\n".data(using: .utf8)!)
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

        let text = Privacy.redact(OCR.recognize(cg))                              // scrub secrets
        guard text.count >= 8 else { return }                                     // skip near-empty screens
        lastIndexTime = now
        do {
            let vec = try embedder.embed(text)
            store.insert(ts: Date().timeIntervalSince1970, text: text, vec: vec)
            FileHandle.standardError.write("indexed \(text.count) chars (total \(store.count()))\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("embed error: \(error)\n".data(using: .utf8)!)
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    var isRunning: Bool { stream != nil }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("stream stopped: \(error)\n".data(using: .utf8)!)
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

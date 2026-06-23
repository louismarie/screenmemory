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
    private let hammingThreshold: Int
    private let minIndexInterval: Double
    private let processQueue = DispatchQueue(label: "capture.process")
    private let stateLock = NSLock()
    private var streams: [SCStream] = []
    private var streamStates: [ObjectIdentifier: DisplayState] = [:]
    private var restartScheduled = false
    private let snapshotMergeDelay: TimeInterval = 0.35
    private var latestScreens: [CGDirectDisplayID: ScreenSnapshot] = [:]
    private var pendingSnapshotFlush: DispatchWorkItem?
    private var lastCombinedSignature = ""
    private var fps: Double = 1.0
    private var wantRunning = false   // survives stream death -> drives auto-restart

    private struct DisplayState {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        var lastHash: UInt64 = 0
        var haveLast = false
        var lastIndexTime: Double = 0
    }

    private struct ScreenSnapshot {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let ts: Double
        let text: String
        let lines: [TextLine]
        let hash: UInt64
    }

    init(store: Store, embedder: Embedder, hammingThreshold: Int = 6, minIndexInterval: Double = 2.0) {
        self.store = store
        self.embedder = embedder
        self.hammingThreshold = hammingThreshold
        self.minIndexInterval = minIndexInterval
    }

    func start(fps: Double) async throws {
        self.fps = fps
        wantRunning = true
        try await startStreams()
    }

    private func startStreams() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw Err.noDisplay }

        let excluded = Privacy.excludedBundleIDs()
        let excludedApps = content.applications.filter { excluded.contains($0.bundleIdentifier) }
        if !excludedApps.isEmpty {
            FileHandle.standardError.write("excluding \(excludedApps.count) sensitive app(s) from capture\n".data(using: .utf8)!)
        }

        var started: [SCStream] = []
        var states: [ObjectIdentifier: DisplayState] = [:]
        do {
            for display in content.displays {
                let cfg = SCStreamConfiguration()
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                cfg.width = display.width            // points; Retina backing handled by SCK
                cfg.height = display.height
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.queueDepth = 3

                let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processQueue)
                states[ObjectIdentifier(stream)] = DisplayState(displayID: display.displayID,
                                                                width: display.width,
                                                                height: display.height)
                try await stream.startCapture()
                started.append(stream)
            }
        } catch {
            for stream in started {
                try? await stream.stopCapture()
            }
            throw error
        }

        stateLock.withLock {
            self.streams = started
            self.streamStates = states
            self.latestScreens = [:]
            self.pendingSnapshotFlush?.cancel()
            self.pendingSnapshotFlush = nil
            self.lastCombinedSignature = ""
        }
        CaptureState.isCapturing = true
        let displays = states.values
            .sorted { $0.displayID < $1.displayID }
            .map { "#\($0.displayID) \($0.width)x\($0.height)" }
            .joined(separator: ", ")
        log("capture started on \(started.count) display(s) @ \(fps)fps: \(displays)")
    }

    // SCStreamOutput — called on the sample handler queue (serialized -> safe to process inline).
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              !Privacy.isPaused,                                                   // user pause flag
              let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let streamID = ObjectIdentifier(stream)
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        guard let state = streamStates[streamID] else {
            stateLock.unlock()
            return
        }
        let displayID = state.displayID
        if now - state.lastIndexTime < minIndexInterval {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        // Rate-limit: never index more than once per minIndexInterval per display, even if the
        // screen keeps changing -> caps OCR/embed work on busy screens.
        let ci = CIImage(cvPixelBuffer: px)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

        let h = Self.avgHash(cg, ctx: ciContext)
        stateLock.lock()
        guard var current = streamStates[streamID] else {
            stateLock.unlock()
            return
        }
        if current.haveLast && Self.hamming(h, current.lastHash) <= hammingThreshold {
            stateLock.unlock()
            return
        }
        current.lastHash = h
        current.haveLast = true
        streamStates[streamID] = current
        stateLock.unlock()

        let lines = OCR.recognizeLines(cg)
        let text = Privacy.redact(lines.map { $0.text }.joined(separator: "\n"))  // scrub secrets
        guard text.count >= 8 else { return }                                     // skip near-empty screens
        stateLock.lock()
        if var updated = streamStates[streamID] {
            updated.lastIndexTime = now
            streamStates[streamID] = updated
        }
        stateLock.unlock()
        let snapshot = ScreenSnapshot(displayID: displayID,
                                      width: state.width,
                                      height: state.height,
                                      ts: now,
                                      text: text,
                                      lines: lines,
                                      hash: h)
        cacheAndSchedule(snapshot)
    }

    private func cacheAndSchedule(_ snapshot: ScreenSnapshot) {
        let work = DispatchWorkItem { [weak self] in
            self?.flushCombinedSnapshot()
        }
        stateLock.lock()
        latestScreens[snapshot.displayID] = snapshot
        pendingSnapshotFlush?.cancel()
        pendingSnapshotFlush = work
        stateLock.unlock()
        processQueue.asyncAfter(deadline: .now() + snapshotMergeDelay, execute: work)
    }

    private func flushCombinedSnapshot() {
        let snapshots: [ScreenSnapshot]? = stateLock.withLock {
            pendingSnapshotFlush = nil
            let ordered = latestScreens.values.sorted { $0.displayID < $1.displayID }
            let signature = ordered.map { "\($0.displayID):\($0.hash)" }.joined(separator: "|")
            guard !ordered.isEmpty, signature != lastCombinedSignature else {
                return nil
            }
            lastCombinedSignature = signature
            return ordered
        }
        guard let snapshots else { return }

        let meta = Meta.frontmost()
        do {
            let ts = snapshots.map(\.ts).max() ?? Date().timeIntervalSince1970
            let combined = combinedSnapshotText(snapshots: snapshots, meta: meta)
            let vec = try embedder.embed(combined)
            store.insert(ts: ts, text: combined, vec: vec)
            let memId = store.lastInsertedId
            let ctx = ([meta.app, meta.title].filter { !$0.isEmpty } + ["snapshot multi-ecrans"])
                .joined(separator: " — ")

            var chunkCount = 0
            let combinedChunk = compactCombinedChunk(snapshots)
            if combinedChunk.count >= Chunker.minChars {
                let cvec = try embedder.embed(ctx + "\n" + combinedChunk)
                store.insertChunk(memId: memId, ts: ts, app: meta.app, title: meta.title,
                                  text: combinedChunk, vec: cvec)
                chunkCount += 1
            }

            for screen in snapshots {
                // Retrieval units: layout-aware blocks, each with its own embedding + context.
                var blocks = Chunker.blocks(from: screen.lines).map(Privacy.redact)
                if blocks.isEmpty { blocks = Chunker.blocks(fromPlainText: screen.text) }
                for block in blocks {
                    let labelled = "Ecran #\(screen.displayID) (\(screen.width)x\(screen.height))\n\(block)"
                    // Embed with app/title context so the semantic leg sees it too.
                    // NB: add "passage: " prefix when swapping to e5.
                    let bvec = try embedder.embed(ctx + "\n" + labelled)
                    store.insertChunk(memId: memId, ts: ts, app: meta.app, title: meta.title,
                                      text: labelled, vec: bvec)
                    chunkCount += 1
                }
            }
            let ids = snapshots.map { "#\($0.displayID)" }.joined(separator: ",")
            log("indexed multi-display snapshot [\(ids)] \(combined.count) chars, \(chunkCount) chunks [\(meta.app)] (screens \(store.count()))")
        } catch {
            log("embed error: \(error)")
        }
    }

    private func combinedSnapshotText(snapshots: [ScreenSnapshot], meta: (app: String, title: String)) -> String {
        var parts = ["Snapshot multi-ecrans (\(snapshots.count) ecran\(snapshots.count > 1 ? "s" : ""))"]
        let foreground = [meta.app, meta.title].filter { !$0.isEmpty }.joined(separator: " — ")
        if !foreground.isEmpty {
            parts.append("App active: \(foreground)")
        }
        for screen in snapshots {
            parts.append("""
            ## Ecran #\(screen.displayID) (\(screen.width)x\(screen.height))
            \(screen.text)
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    private func compactCombinedChunk(_ snapshots: [ScreenSnapshot]) -> String {
        snapshots.map { screen in
            let clean = screen.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "Ecran #\(screen.displayID): " + short(clean, 1200)
        }.joined(separator: "\n\n")
    }

    private func short(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(max(0, n - 1))) + "…" : s
    }

    func stop() {
        wantRunning = false
        stateLock.lock()
        let active = streams
        streams = []
        streamStates = [:]
        restartScheduled = false
        latestScreens = [:]
        pendingSnapshotFlush?.cancel()
        pendingSnapshotFlush = nil
        lastCombinedSignature = ""
        stateLock.unlock()
        for stream in active {
            stream.stopCapture { _ in }
        }
        CaptureState.isCapturing = false
    }

    var isRunning: Bool { wantRunning }

    /// SCK streams die on sleep/lock/display changes. Always-on means: log it,
    /// then retry with backoff until the display is capturable again.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
        stateLock.lock()
        let stoppedID = ObjectIdentifier(stream)
        streams.removeAll { ObjectIdentifier($0) == stoppedID }
        streamStates.removeValue(forKey: stoppedID)
        let remaining = streams
        streams = []
        streamStates = [:]
        latestScreens = [:]
        pendingSnapshotFlush?.cancel()
        pendingSnapshotFlush = nil
        lastCombinedSignature = ""
        let shouldRestart = wantRunning && !restartScheduled
        if shouldRestart {
            restartScheduled = true
        }
        stateLock.unlock()

        for activeStream in remaining {
            activeStream.stopCapture { _ in }
        }
        CaptureState.isCapturing = false
        guard shouldRestart else { return }
        Task { [weak self] in
            var delay = 5.0
            while let self, self.wantRunning {
                try? await Task.sleep(for: .seconds(delay))
                guard self.wantRunning else {
                    self.setRestartScheduled(false)
                    return
                }
                do {
                    try await self.startStreams()
                    self.setRestartScheduled(false)
                    self.log("streams auto-restarted")
                    return
                } catch {
                    self.log("restart failed (\(error.localizedDescription)), retrying in \(Int(min(delay * 2, 60)))s")
                    delay = min(delay * 2, 60)
                }
            }
            self?.setRestartScheduled(false)
        }
    }

    private func setRestartScheduled(_ value: Bool) {
        stateLock.lock()
        restartScheduled = value
        stateLock.unlock()
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

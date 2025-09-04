import AVFoundation
import UniformTypeIdentifiers

import CoreMedia

protocol PlaybackControllerDelegate: AnyObject {
    func playbackController(_ c: PlaybackController, didUpdateStatus text: String)
    func playbackController(_ c: PlaybackController, didUpdateProgress processed: Int, total: Int)
    func playbackController(_ c: PlaybackController, didStartPlaying fileName: String)
    func playbackControllerDidPlay(_ c: PlaybackController)
    func playbackControllerDidPause(_ c: PlaybackController)
    func playbackControllerDidStop(_ c: PlaybackController)
}

final class PlaybackController: NSObject {
    weak var delegate: PlaybackControllerDelegate?

    // Core
    private let fm = FileManager.default
    private let synthQueue = OperationQueue()
    private var player = AVQueuePlayer()
    private var itemEndObserver: Any?

    // Session state
    private var currentMode: PlaybackMode = .sequential
    private var folderURL: URL?
    private var files: [URL] = []
    private var settings: PlaybackSettings?
    private var processedCount = 0
    private var totalCount = 0
    
    private var timeObs: NSKeyValueObservation?
    private var itemStatusObs: NSKeyValueObservation?


    // Random loop
    private var randomTimer: Timer?

    private var cacheDir: URL {
        try! fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenCache", isDirectory: true)
    }

    override init() {
        synthQueue.maxConcurrentOperationCount = 1
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance   // <— be explicit
        
        // KVO: if timeControl flips to paused/idle while the queue still has items, resume.
        timeObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            if player.timeControlStatus != .playing, !self.player.items().isEmpty {
                self.resumeIfNeeded("timeControl KVO")
            }
        }
        
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        observePlaybackEnd()
        configureAudioSession()
    }

    private func resumeIfNeeded(_ context: String) {
        guard player.currentItem != nil, player.timeControlStatus != .playing else { return }
        ensureActiveAudioSession()
        player.playImmediately(atRate: 1.0)
        print("▶️ Resumed (\(context)). status=\(player.timeControlStatus.rawValue) rate=\(player.rate)")
    }

    private func attachItemReadyObserver(_ item: AVPlayerItem) {
        itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .readyToPlay {
                self.resumeIfNeeded("item ready")
            }
        }
    }
    
    deinit {
        randomTimer?.invalidate()
        if let o = itemEndObserver { NotificationCenter.default.removeObserver(o) }
    }
    
    private func debugListCache() {
        do {
            let urls = try fm.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
            let entries = try urls.map { url -> (String, Int64, Date) in
                let rv = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return (url.lastPathComponent, Int64(rv.fileSize ?? 0), rv.creationDate ?? .distantPast)
            }
            .sorted { $0.2 < $1.2 }

            print("📁 Cache contains \(entries.count) file(s):")
            for (name, size, date) in entries {
                print("  • \(name) – \(size) bytes – \(date)")
            }
        } catch {
            print("Cache list error:", error)
        }
    }

    private func debugListQueue(_ prefix: String) {
        let items = player.items().compactMap { $0.asset as? AVURLAsset }
        let names = items.map { $0.url.lastPathComponent }
        let durations = items.map { String(format: "%.2fs", CMTimeGetSeconds($0.duration)) }
        print("🎵 \(prefix) queue [\(items.count)]:", zip(names, durations).map { "\($0) (\($1))" })
    }


    // MARK: Public API

    func start(folderURL: URL, mode: PlaybackMode, settings: PlaybackSettings) {
        stop() // reset any prior session
        self.folderURL = folderURL
        self.currentMode = mode
        self.settings = settings

        files = textFiles(in: folderURL)

        switch mode {
        case .sequential:
            startSequential()
        case .randomLoop(let minDelay, let maxDelay, _):
            startRandomLoop(minDelay: minDelay, maxDelay: maxDelay)
        }
    }

    func pauseResume() {
        if player.timeControlStatus == .paused {
            ensureActiveAudioSession()
            player.playImmediately(atRate: 1.0)
            delegate?.playbackControllerDidPlay(self)
        } else {
            player.pause()
            delegate?.playbackControllerDidPause(self)
        }
    }

    func stop() {
        randomTimer?.invalidate()
        randomTimer = nil

        player.pause()
        player.removeAllItems()
        player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false

        processedCount = 0
        totalCount = 0

        // Clear cache for a fresh run
        try? fm.removeItem(at: cacheDir)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        delegate?.playbackControllerDidStop(self)
    }

    // MARK: - Sequential (MVP)

    private func startSequential() {
        guard !files.isEmpty else {
            delegate?.playbackController(self, didUpdateStatus: "No .txt or .rtf files")
            return
        }

        processedCount = 0
        totalCount = files.count
        delegate?.playbackController(self, didUpdateProgress: 0, total: totalCount)
        delegate?.playbackController(self, didUpdateStatus: "Rendering 1/\(totalCount)…")

        let first = files[0]
        synthOne(fileURL: first) { [weak self] audioURL in
            guard let self else { return }
            self.enqueueAndMaybePlay(audioURL)
            self.delegate?.playbackController(self, didStartPlaying: first.deletingPathExtension().lastPathComponent)
            self.processedCount = 1
            self.delegate?.playbackController(self, didUpdateProgress: self.processedCount, total: self.totalCount)
            self.delegate?.playbackController(self, didUpdateStatus: "Rendered \(self.processedCount)/\(self.totalCount).")
            self.delegate?.playbackControllerDidPlay(self)
        }

        for (idx, file) in files.dropFirst().enumerated() {
            synthQueue.addOperation { [weak self] in
                guard let self else { return }
                self.synthOne(fileURL: file) { url in
                    DispatchQueue.main.async {
                        self.enqueueAndMaybePlay(url)
                        self.processedCount = idx + 2
                        self.delegate?.playbackController(self, didUpdateProgress: self.processedCount, total: self.totalCount)
                        if self.processedCount == self.totalCount {
                            self.delegate?.playbackController(self, didUpdateStatus: "All rendered.")
                        } else {
                            self.delegate?.playbackController(self, didUpdateStatus: "Rendering \(self.processedCount+1)/\(self.totalCount)…")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Random Loop (infinite)

    private func startRandomLoop(minDelay: TimeInterval, maxDelay: TimeInterval) {
        guard !files.isEmpty else {
            delegate?.playbackController(self, didUpdateStatus: "No .txt or .rtf files")
            return
        }
        delegate?.playbackController(self, didUpdateStatus: "Random loop…")
        // Kick off the first item immediately
        scheduleNextRandom(after: 0)
    }

    private func scheduleNextRandom(after delay: TimeInterval) {
        randomTimer?.invalidate()
        if delay > 0 {
            delegate?.playbackController(self, didUpdateStatus: "Next in \(format(delay))…")
            randomTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.produceAndEnqueueRandomFile()
            }
        } else {
            produceAndEnqueueRandomFile()
        }
    }

    private func produceAndEnqueueRandomFile() {
        guard let file = files.randomElement() else { return }
        synthOne(fileURL: file) { [weak self] url in
            guard let self else { return }
            self.enqueueAndMaybePlay(url)
            self.delegate?.playbackController(self, didStartPlaying: file.deletingPathExtension().lastPathComponent)
            self.delegate?.playbackControllerDidPlay(self)
        }
    }

    // MARK: - Helpers shared

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func ensureActiveAudioSession() {
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { print("setActive(true) failed: \(error)") }
    }

    private func enqueueAndMaybePlay(_ url: URL) {
        let item = AVPlayerItem(url: url)

        // Append after current tail
        let tail = player.items().last
        if player.canInsert(item, after: tail) {
            player.insert(item, after: tail)
        } else {
            player.insert(item, after: nil) // empty queue fallback
        }

        // If this was the first item, observe readiness
        if player.items().count == 1 {
            attachItemReadyObserver(item)
        }

        // Debug (optional)
        // debugListQueue("After enqueue")

        // Kick off playback if idle
        if player.timeControlStatus != .playing {
            ensureActiveAudioSession()
            player.playImmediately(atRate: 1.0)
            print("▶️ Started playback. status=\(player.timeControlStatus.rawValue) rate=\(player.rate)")
        }
    }



    private func observePlaybackEnd() {
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard let self else { return }

            if let ended = n.object as? AVPlayerItem,
               let url = (ended.asset as? AVURLAsset)?.url {
                print("✅ Finished:", url.lastPathComponent)
                self.deleteIfInCache(url)

                // If the finished item is still at head, force-advance
                if self.player.items().first === ended {
                    self.player.advanceToNextItem()
                }
            }

            // If there’s a next item, observe its readiness and resume
            if let next = self.player.items().first {
                self.attachItemReadyObserver(next)
                self.resumeIfNeeded("end-of-item")

                // Extra tiny nudge for timing races
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.resumeIfNeeded("post-advance nudge")
                }
            } else {
                // Queue empty (sequential)
                self.delegate?.playbackController(self, didUpdateStatus: "Finished all.")
                self.delegate?.playbackControllerDidPause(self)
            }

            // Random-loop scheduling is unchanged
            if case .randomLoop(let minDelay, let maxDelay, _) = self.currentMode {
                let delay = Double.random(in: minDelay...maxDelay)
                self.scheduleNextRandom(after: delay)
            }
        }
    }


    private func deleteIfInCache(_ url: URL) {
        let inCache = url.standardizedFileURL.path.hasPrefix(cacheDir.standardizedFileURL.path)
        print("🗑️ Cleanup check:", url.lastPathComponent, "inCache=\(inCache)")
        if inCache {
            try? fm.removeItem(at: url)
            print("🗑️ Deleted:", url.lastPathComponent)
            debugListCache()                 // <— see what remains
        }
    }


    private func textFiles(in folder: URL) -> [URL] {
        guard folder.startAccessingSecurityScopedResource() else { return [] }
        defer { folder.stopAccessingSecurityScopedResource() }
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey, .contentTypeKey]
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let filtered = urls.filter { u in
            u.pathExtension.lowercased() == "txt" || u.pathExtension.lowercased() == "rtf"
        }
        return filtered.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func synthOne(fileURL: URL, completion: @escaping (URL) -> Void) {
        guard let settings = settings else { return }
        let raw = (try? Self.extractText(from: fileURL)) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // write into cache with unique name (avoid collisions)
        let base = fileURL.deletingPathExtension().lastPathComponent
        let uniq = UUID().uuidString.prefix(8)
        let outURL = cacheDir.appendingPathComponent("\(base)-\(uniq).m4a")

        TTSSynthesizer.shared.synthesizeToFile(
            text: text,
            languageCode: settings.languageCode,
            voiceIdentifier: settings.voiceIdentifier,
            rate: settings.rate,
            pitch: settings.pitch,
            outputURL: outURL
        ) { success in
            if success {
                print("✅ Synth OK →", outURL.lastPathComponent)
                self.debugListCache()            // <— add this
                completion(outURL)
            }
        }
    }

    private static func extractText(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == "txt" {
            return try String(contentsOf: url, encoding: .utf8)
        } else {
            let data = try Data(contentsOf: url)
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
            let attr = try NSAttributedString(data: data, options: opts, documentAttributes: nil)
            return attr.string
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let mPart = s / 60
        let sPart = s % 60
        return String(format: "%d:%02d", mPart, sPart)
    }
}

import AVFoundation
import UniformTypeIdentifiers

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

    private let fm = FileManager.default
    private let synthQueue = OperationQueue()
    private var player = AVQueuePlayer()
    private var itemEndObserver: Any?

    private var cacheDir: URL {
        try! fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenCache", isDirectory: true)
    }

    override init() {
        synthQueue.maxConcurrentOperationCount = 1
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        observePlaybackEnd()
        configureAudioSession()
    }

    deinit {
        if let o = itemEndObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Public API

    func start(folderURL: URL, mode: PlaybackMode, settings: PlaybackSettings) {
        switch mode {
        case .sequential:
            startSequential(folderURL: folderURL, settings: settings)
        case .randomLoop:
            // not implemented yet; scaffold left for future
            startSequential(folderURL: folderURL, settings: settings)
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
        player.pause()
        player.removeAllItems()
        player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        try? fm.removeItem(at: cacheDir)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        delegate?.playbackControllerDidStop(self)
    }

    // MARK: Private – MVP (sequential)

    private func startSequential(folderURL: URL, settings: PlaybackSettings) {
        stop() // reset queue/cache

        let files = textFiles(in: folderURL)
        guard !files.isEmpty else {
            delegate?.playbackController(self, didUpdateStatus: "No .txt or .rtf files")
            return
        }

        delegate?.playbackController(self, didUpdateProgress: 0, total: files.count)
        delegate?.playbackController(self, didUpdateStatus: "Rendering 1/\(files.count)…")

        let first = files[0]
        synthOne(fileURL: first, settings: settings) { [weak self] audioURL in
            guard let self else { return }
            self.enqueueAndMaybePlay(audioURL)
            self.delegate?.playbackController(self, didStartPlaying: first.deletingPathExtension().lastPathComponent)
            self.delegate?.playbackController(self, didUpdateProgress: 1, total: files.count)
            self.delegate?.playbackController(self, didUpdateStatus: "Rendered 1/\(files.count).")
            self.delegate?.playbackControllerDidPlay(self)
        }

        for (idx, file) in files.dropFirst().enumerated() {
            synthQueue.addOperation { [weak self] in
                guard let self else { return }
                self.synthOne(fileURL: file, settings: settings) { audioURL in
                    DispatchQueue.main.async {
                        self.enqueueAndMaybePlay(audioURL)
                        let processed = idx + 2
                        self.delegate?.playbackController(self, didUpdateProgress: processed, total: files.count)
                        if processed == files.count {
                            self.delegate?.playbackController(self, didUpdateStatus: "All rendered.")
                        } else {
                            self.delegate?.playbackController(self, didUpdateStatus: "Rendering \(processed+1)/\(files.count)…")
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers (moved from VM)

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
        player.insert(item, after: nil)
        if player.timeControlStatus != .playing {
            ensureActiveAudioSession()
            player.playImmediately(atRate: 1.0)
        }
    }

    private func observePlaybackEnd() {
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // In future, schedule next item or notify; for MVP we rely on queue.
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

    private func synthOne(fileURL: URL, settings: PlaybackSettings, completion: @escaping (URL) -> Void) {
        let raw = (try? Self.extractText(from: fileURL)) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Treat empty files as “rendered” by calling completion with a silent file, or skip.
                // For MVP we skip and still advance progress via delegate at call site.
            }
            return
        }
        let outURL = cacheDir.appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).m4a")
        TTSSynthesizer.shared.synthesizeToFile(
            text: text,
            languageCode: settings.languageCode,
            voiceIdentifier: settings.voiceIdentifier,
            rate: settings.rate,
            pitch: settings.pitch,
            outputURL: outURL
        ) { success in
            if success { completion(outURL) }
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
}

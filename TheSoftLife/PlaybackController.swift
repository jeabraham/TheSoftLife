import AVFoundation
import UniformTypeIdentifiers

import CoreMedia

import UserNotifications



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
    private var lastEnqueuedItem: AVPlayerItem?


    // Session state
    private var currentMode: PlaybackMode = .sequential
    private var folderURL: URL?
    private var files: [URL] = []
    private var settings: PlaybackSettings?
    private var processedCount = 0
    private var totalCount = 0
    
    private var timeObs: NSKeyValueObservation?
    private var itemStatusObs: NSKeyValueObservation?
    private var itemFailObserver: Any?


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
        
        itemFailObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard let self, let item = n.object as? AVPlayerItem else { return }
            self.logItemFailure(item, where: "FailedToPlayToEndTime")
        }
        
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        observePlaybackEnd()
        configureAudioSession()
    }
    
    private func itemName(_ item: AVPlayerItem?) -> String {
        guard let u = (item?.asset as? AVURLAsset)?.url else { return "nil" }
        return u.lastPathComponent
    }

    private func logItemFailure(_ item: AVPlayerItem, where context: String) {
        let name = (item.asset as? AVURLAsset)?.url.lastPathComponent ?? "<?>"
        print("❌ AVPlayerItem failed (\(context)): \(name) — \(item.error?.localizedDescription ?? "no item.error")")
        if let el = item.errorLog() {
            for ev in el.events {
                print("   ⋯ errorLog: status=\(ev.errorStatusCode) '\(ev.errorComment ?? "")' server=\(ev.serverAddress ?? "—")")
            }
        }
    }
    
    func scheduleNextNotification(after seconds: TimeInterval, fileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Reinforcement cue"
        content.body = "Ready for “\(fileName)”"
        content.categoryIdentifier = "NEXT_FILE_CATEGORY"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let req = UNNotificationRequest(identifier: "next-file-\(UUID().uuidString)", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { print("Notif schedule error:", err) }
        }
    }

    private func dumpQueue(_ label: String) {
        let items = player.items()
        for it in items {
            let nm = (it.asset as? AVURLAsset)?.url.lastPathComponent ?? "<?>"
            let d  = CMTimeGetSeconds(it.asset.duration)
            let dur = d.isFinite ? String(format: "%.2fs", d) : "indef"
            print("  \(it === player.currentItem ? "◀︎" : " ") \(nm)  dur=\(dur)  status=\(it.status.rawValue)")
            if it.status == .failed { logItemFailure(it, where: "dumpQueue") }
        }
        let names = items.compactMap { ($0.asset as? AVURLAsset)?.url.lastPathComponent }
        // mark current item in the list
        let marked = items.enumerated().map { idx, it -> String in
            let name = (it.asset as? AVURLAsset)?.url.lastPathComponent ?? "<?>"
            return (it === player.currentItem ? "◀︎ " : "  ") + "[\(idx)] " + name
        }

        let durStr: (AVPlayerItem) -> String = { it in
            let d = CMTimeGetSeconds(it.asset.duration)
            return d.isFinite ? String(format: "%.2fs", d) : "indef"
        }

        print("━━━━━━━━ QUEUE @ \(label) ━━━━━━━━")
        print("currentItem:", itemName(player.currentItem),
              "| timeControl:", player.timeControlStatus.rawValue,
              "| rate:", player.rate,
              "| count:", items.count)
        for it in items {
            let nm = (it.asset as? AVURLAsset)?.url.lastPathComponent ?? "<?>"
            print("  \(it === player.currentItem ? "◀︎" : " ") \(nm)  dur=\(durStr(it))  status=\(it.status.rawValue)")
        }
        if names.isEmpty { print("  (empty)") }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
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
        if let o = itemFailObserver { NotificationCenter.default.removeObserver(o) }
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
        lastEnqueuedItem = nil

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

        let group = DispatchGroup()

        // First file
        group.enter()
        let first = files[0]
        synthOne(fileURL: first) { [weak self] maybeURL in
            guard let self = self else { group.leave(); return }
            // Completion should already be on main

            if let url = maybeURL {
                self.enqueueAndMaybePlay(url)
                self.delegate?.playbackController(self,
                    didStartPlaying: first.deletingPathExtension().lastPathComponent)
                self.delegate?.playbackControllerDidPlay(self)
            } else {
                print("⚠️ First file produced no audio, skipping.")
            }

            self.processedCount = 1
            self.delegate?.playbackController(self,
                didUpdateProgress: self.processedCount, total: self.totalCount)
            self.delegate?.playbackController(self,
                didUpdateStatus: "Rendered \(self.processedCount)/\(self.totalCount).")
            group.leave()
        }


        for (idx, file) in files.dropFirst().enumerated() {
            group.enter()
            self.synthOne(fileURL: file) { [weak self] maybeURL in
                guard let self = self else { group.leave(); return }
                if let url = maybeURL {
                    self.enqueueAndMaybePlay(url)
                }
                self.processedCount = idx + 2
                self.delegate?.playbackController(self,
                                                  didUpdateProgress: self.processedCount,
                                                  total: self.totalCount)
                if self.processedCount == self.totalCount {
                    self.delegate?.playbackController(self, didUpdateStatus: "All rendered.")
                } else {
                    self.delegate?.playbackController(self,
                                                      didUpdateStatus: "Rendering \(self.processedCount + 1)/\(self.totalCount)…")
                }
                group.leave()
            }
        }




        // Append trailing silence ONLY after all enqueues have completed
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.enqueueSilence(seconds: 3.0)   // <- now guaranteed to be the true tail
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

        synthOne(fileURL: file) { [weak self] maybeURL in
            guard let self = self else { return }

            if let url = maybeURL {
                self.enqueueAndMaybePlay(url)
                self.delegate?.playbackController(self,
                                                  didStartPlaying: file.deletingPathExtension().lastPathComponent)
                self.delegate?.playbackControllerDidPlay(self)
            } else {
                // Synthesis failed or file was empty — don't stall; try again soon.
                print("⚠️ Random synth produced no audio for \(file.lastPathComponent); retrying shortly.")
                if case .randomLoop(let minDelay, _, _) = self.currentMode {
                    // Backoff a little; keep it snappy but not tight-looping.
                    let backoff: TimeInterval = max(0.3, min(0.5, minDelay))
                    self.scheduleNextRandom(after: backoff)
                }
            }
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

    private func enqueueSilence(seconds: TimeInterval) {
        guard let url = SilenceFactory.url(for: seconds, in: cacheDir) else { return }
        print("🎧 Silence ready:", url.lastPathComponent)
        _ = enqueueAndMaybePlay(url)
        dumpQueue("after enqueue SILENCE")
    }




    private func ensureActiveAudioSession() {
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { print("setActive(true) failed: \(error)") }
    }

    @discardableResult
    private func enqueueAndMaybePlay(_ url: URL) -> AVPlayerItem? {
        let item = AVPlayerItem(url: url)
        let tail = player.items().last
        if player.canInsert(item, after: tail) { player.insert(item, after: tail) }
        else { player.insert(item, after: nil) }

        print("Enqueued:", url.lastPathComponent, "after:", itemName(tail))
        dumpQueue("after enqueue \(url.lastPathComponent)")

        if player.timeControlStatus != .playing {
            ensureActiveAudioSession()
            player.playImmediately(atRate: 1.0)
            print("▶️ Started/resumed. status=\(player.timeControlStatus.rawValue) rate=\(player.rate)")
        }
        return item
    }


    private func observePlaybackEnd() {
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard let self = self else { return }

            // 1) Log & delete the item that just finished
            if let ended = n.object as? AVPlayerItem,
               let url = (ended.asset as? AVURLAsset)?.url {
                print("✅ Finished:", url.lastPathComponent)
                self.deleteIfInCache(url)
            }

            self.dumpQueue("on end BEFORE advance")

            // 2) If the finished item was the head, advance to next
            if let ended = n.object as? AVPlayerItem,
               self.player.items().first === ended {
                print("advanceToNextItem() because head ended")
                self.player.advanceToNextItem()
            }

            // 3) If the new head is already failed (e.g., unplayable), skip it
            while let head = self.player.items().first, head.status == .failed {
                self.logItemFailure(head, where: "head failed after advance")
                print("Skipping failed head via advanceToNextItem()")
                self.player.advanceToNextItem()
            }

            self.dumpQueue("on end AFTER advance")

            // 4) Mode-specific follow-up
            switch self.currentMode {
            case .randomLoop:
                // Keep the random look-ahead buffer topped up
                self.fillRandomBufferIfNeeded()

                // If there are still items (speech or silence), keep playback alive
                if !self.player.items().isEmpty {
                    self.ensureActiveAudioSession()
                    if self.player.timeControlStatus != .playing {
                        self.player.playImmediately(atRate: 1.0)
                        print("▶️ Nudge play (random)")
                    }
                    self.dumpQueue("after nudge (random)")
                } else {
                    // Nothing left — report paused so UI can reflect the idle state
                    self.delegate?.playbackControllerDidPause(self)
                }

            case .sequential:
                // If queue not empty, keep rolling
                if !self.player.items().isEmpty {
                    self.ensureActiveAudioSession()
                    if self.player.timeControlStatus != .playing {
                        self.player.playImmediately(atRate: 1.0)
                        print("▶️ Nudge play (sequential)")
                    }
                    self.dumpQueue("after nudge (sequential)")
                } else {
                    // All done
                    self.delegate?.playbackController(self, didUpdateStatus: "Finished all.")
                    self.delegate?.playbackControllerDidPause(self)
                }
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

    private func synthOne(fileURL: URL, completion: @escaping (URL?) -> Void) {
        let raw = (try? Self.extractText(from: fileURL)) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { completion(nil); return }

        let base = fileURL.deletingPathExtension().lastPathComponent
        let uniq = UUID().uuidString.prefix(8)
        // NOTE: you're currently writing PCM buffers. .caf is the correct container for PCM.
        // If you insist on .m4a here, many files will be rejected as "Cannot Open".
        let outURL = cacheDir.appendingPathComponent("\(base)-\(uniq).caf") // <- safer than .m4a

        TTSSynthesizer.shared.synthesizeToFile(
            text: text,
            languageCode: settings?.languageCode ?? "en-US",
            voiceIdentifier: settings?.voiceIdentifier,
            rate: settings?.rate ?? 0.3,
            pitch: settings?.pitch ?? 1.0,
            outputURL: outURL
        ) { success in
            guard success else { completion(nil); return }
            self.validatePlayableAsset(url: outURL, retries: 6, delay: 0.08) { ok in
                completion(ok ? outURL : nil)
            }
        }
    }

    // MARK: - Playability validation with tiny retry
    private func validatePlayableAsset(url: URL,
                                       retries: Int,
                                       delay: TimeInterval,
                                       completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) {
            var err: NSError?
            let playableStatus = asset.statusOfValue(forKey: "playable", error: &err)
            let durationStatus = asset.statusOfValue(forKey: "duration", error: &err)
            let dur = CMTimeGetSeconds(asset.duration)
            let ok = (playableStatus == .loaded && asset.isPlayable) &&
                     (durationStatus == .loaded && dur > 0.05)

            if ok {
                DispatchQueue.main.async {
                    print("✅ Asset OK:", url.lastPathComponent, String(format: "dur=%.2fs", dur))
                    completion(true)
                }
            } else if retries > 0 {
                // A tiny backoff covers the occasional “metadata not ready yet” blip.
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.validatePlayableAsset(url: url, retries: retries - 1, delay: min(delay * 1.6, 0.5), completion: completion)
                }
            } else {
                DispatchQueue.main.async {
                    print("⚠️ Asset NOT playable, skipping:", url.lastPathComponent,
                          "playableStatus=\(playableStatus.rawValue)",
                          "durationStatus=\(durationStatus.rawValue)",
                          String(format: "dur=%.2f", dur),
                          "error=\(err?.localizedDescription ?? "nil")")
                    completion(false)
                }
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

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class PlayerVM: NSObject, ObservableObject {
    @Published var folderURL: URL?
    @Published var currentFileName: String = "—"
    @Published var isPlaying: Bool = false
    @Published var showStopConfirm: Bool = false

    @Published var statusText: String = "Idle"
    @Published var totalFiles: Int = 0
    @Published var processedFiles: Int = 0

    @Published var rate: Float = 0.3
    @Published var pitch: Float = 1.0
    @Published var languageCode: String = "en-CA"
    @Published var voiceIdentifier: String? = nil
    @Published var canControlPlayback: Bool = false
    
    @Published var voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()

    private var player = AVQueuePlayer()
    private var itemEndObserver: Any?

    private let synthQueue = OperationQueue()
    private let fm = FileManager.default
    private var cacheDir: URL {
        try! fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenCache", isDirectory: true)
    }

    func reloadVoices() {
        voices = AVSpeechSynthesisVoice.speechVoices()
    }

    
    private let bookmarkKey = "chosenFolderBookmark"

    override init() {
        synthQueue.maxConcurrentOperationCount = 1
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false // PATCH: start immediately
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        configureAudioSession()
        restoreBookmarkedFolderIfAny()
        observePlaybackEnd()
        reloadVoices()
        refreshDefaultVoiceIfNeeded()
    }

    deinit {
        if let obs = itemEndObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Allow Bluetooth (A2DP/LE) and AirPlay; do NOT default to speaker.
            try session.setCategory(.playback,
                                    mode: .default,
                                    options: [.allowBluetooth, .allowAirPlay])
            try session.setActive(true)
            print("AVAudioSession: category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
        } catch {
            print("Audio session error: \(error)")
        }
    }


    func pickFolder(presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func restoreBookmarkedFolderIfAny() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            if url.startAccessingSecurityScopedResource() {
                folderURL = url
            }
        }
    }

    private func saveBookmark(for url: URL) {
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    func startSession() {
        guard let folderURL else { return }
        let files = textFiles(in: folderURL)
        guard !files.isEmpty else { statusText = "No .txt or .rtf files"; return }

        totalFiles = files.count
        processedFiles = 0
        statusText = "Rendering 1/\(totalFiles)…"

        stopSession(resetUIOnly: true)

        let first = files[0]
        synthOne(fileURL: first) { [weak self] audioURL in
            guard let self else { return }
            self.enqueueAndMaybePlay(audioURL)
            // PATCH: update name as soon as item becomes current
            self.currentFileName = first.deletingPathExtension().lastPathComponent
            self.isPlaying = true
            self.processedFiles += 1
            self.statusText = "Rendered \(self.processedFiles)/\(self.totalFiles)."
        }

        for (idx, file) in files.dropFirst().enumerated() {
            synthQueue.addOperation { [weak self] in
                guard let self else { return }
                self.synthOne(fileURL: file) { audioURL in
                    DispatchQueue.main.async {
                        self.enqueueAndMaybePlay(audioURL)
                        self.processedFiles += 1
                        if self.processedFiles == self.totalFiles {
                            self.statusText = "All rendered."
                        } else {
                            self.statusText = "Rendering \(idx+2)/\(self.totalFiles)…"
                        }
                    }
                }
            }
        }
    }

    func pauseResume() {
        logPlayerState(prefix: "before toggle")
        if player.timeControlStatus == .paused {
            ensureActiveAudioSession()
            player.playImmediately(atRate: 1.0)
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        logPlayerState(prefix: "after toggle")
    }

    private func logPlayerState(prefix: String) {
        let status: String = {
            switch player.timeControlStatus {
            case .paused: return "paused"
            case .playing: return "playing"
            case .waitingToPlayAtSpecifiedRate: return "waiting"
            @unknown default: return "unknown"
            }
        }()
        let hasItem = player.currentItem != nil
        print("[\(prefix)] status=\(status) rate=\(player.rate) hasItem=\(hasItem) queueCount=\(player.items().count)")
    }

    func stopTapped() { showStopConfirm = true }
    func stopConfirmed() { stopSession(resetUIOnly: false) }

    private func stopSession(resetUIOnly: Bool) {
        player.pause()
        player.removeAllItems()
        player = AVQueuePlayer() // PATCH: fresh player after stop
        player.automaticallyWaitsToMinimizeStalling = false

        if !resetUIOnly {
            statusText = "Idle"
            totalFiles = 0
            processedFiles = 0
            isPlaying = false
            currentFileName = "—"
        }
        canControlPlayback = false

        try? fm.removeItem(at: cacheDir)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func ensureActiveAudioSession() {
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { print("setActive(true) failed: \(error)") }
    }

    private func enqueueAndMaybePlay(_ audioURL: URL) {
        let item = AVPlayerItem(url: audioURL)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] n in
            guard let self, let urlAsset = (n.object as? AVPlayerItem)?.asset as? AVURLAsset else { return }
            // PATCH: when an item ends, advance displayed name to the next item if any
            if let next = self.player.items().first,
               let nextAsset = next.asset as? AVURLAsset {
                self.currentFileName = nextAsset.url.deletingPathExtension().lastPathComponent
            } else {
                self.currentFileName = urlAsset.url.deletingPathExtension().lastPathComponent
            }
        }

        player.insert(item, after: nil)
        canControlPlayback = true

        // If nothing was playing, start immediately
        if player.timeControlStatus != .playing {
            ensureActiveAudioSession()
            player.playImmediately(atRate: 1.0)
            isPlaying = true
            // PATCH: set current file name when first item actually starts
            if let asset = item.asset as? AVURLAsset {
                currentFileName = asset.url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func observePlaybackEnd() {
        itemEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let next = self.player.items().first,
               let urlAsset = next.asset as? AVURLAsset {
                self.currentFileName = urlAsset.url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func textFiles(in folder: URL) -> [URL] {
        guard folder.startAccessingSecurityScopedResource() else { return [] }
        defer { folder.stopAccessingSecurityScopedResource() }
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey, .contentTypeKey]
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let filtered = urls.filter { url in
            (url.pathExtension.lowercased() == "txt") || (url.pathExtension.lowercased() == "rtf")
        }
        return filtered.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func synthOne(fileURL: URL, completion: @escaping (URL) -> Void) {
        let raw = (try? Self.extractText(from: fileURL)) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let outURL = cacheDir.appendingPathComponent("\(baseName).m4a")

        // PATCH: if file is empty, skip but keep progress flowing
        guard !text.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processedFiles += 1
                if self.processedFiles == self.totalFiles { self.statusText = "All rendered." }
            }
            return
        }

        TTSSynthesizer.shared.synthesizeToFile(text: text,
                                               languageCode: languageCode,
                                               voiceIdentifier: voiceIdentifier,
                                               rate: rate,
                                               pitch: pitch,
                                               outputURL: outURL) { success in
            if success { completion(outURL) }
        }
    }

    static func extractText(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == "txt" {
            return try String(contentsOf: url, encoding: .utf8)
        } else {
            let data = try Data(contentsOf: url)
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
            let attr = try NSAttributedString(data: data, options: opts, documentAttributes: nil)
            return attr.string
        }
    }
}

extension PlayerVM: UIDocumentPickerDelegate {
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        _ = url.startAccessingSecurityScopedResource()
        folderURL = url
        saveBookmark(for: url)
    }
}

extension PlayerVM {
    var languagesAvailable: [String] {
        let langs = Set(voices.map { $0.language })
        // put current language first
        return [languageCode] + langs.filter { $0 != languageCode }.sorted()
    }

    var voicesForSelectedLanguage: [AVSpeechSynthesisVoice] {
        voices
            .filter { $0.language == languageCode }
            .sorted { lhs, rhs in
                (qualityRank(lhs.quality), lhs.name) < (qualityRank(rhs.quality), rhs.name)
            }
    }

    private func qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium: return 0
        case .enhanced: return 1
        default: return 2
        }
    }

    func refreshDefaultVoiceIfNeeded() {
        // Keep explicit choice if it still exists
        if let id = voiceIdentifier, AVSpeechSynthesisVoice(identifier: id) != nil { return }

        // 1) Stephanie (Enhanced) en-GB
        if let steph = voices.first(where: { $0.name == "Stephanie" && $0.language.hasPrefix("en-GB") && $0.quality == .enhanced }) {
            languageCode = steph.language
            voiceIdentifier = steph.identifier
            return
        }
        // 2) Zoe (Premium) en-US
        if let zoe = voices.first(where: { $0.name == "Zoe" && $0.language.hasPrefix("en-US") && $0.quality == .premium }) {
            languageCode = zoe.language
            voiceIdentifier = zoe.identifier
            return
        }
        // 3) Any Enhanced en-GB
        if let enGBEnh = voices.first(where: { $0.language.hasPrefix("en-GB") && $0.quality == .enhanced }) {
            languageCode = enGBEnh.language
            voiceIdentifier = enGBEnh.identifier
            return
        }
        // 4) Any en-GB
        if let enGBAny = voices.first(where: { $0.language.hasPrefix("en-GB") }) {
            languageCode = enGBAny.language
            voiceIdentifier = enGBAny.identifier
            return
        }
        // 5) Fallback
        if let first = voices.first {
            languageCode = first.language
            voiceIdentifier = first.identifier
        }
    }
}

// Utility to format a voice's display label with quality
extension AVSpeechSynthesisVoice {
    var qualityLabel: String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}

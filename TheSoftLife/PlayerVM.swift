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
        print("Reloaded voices: count=\(voices.count)")
        for v in voices { print("Voice: \(v.name) | id=\(v.identifier) | lang=\(v.language) | quality=\(v.quality.rawValue)") }
    }

    private let bookmarkKey = "chosenFolderBookmark"

    override init() {
        synthQueue.maxConcurrentOperationCount = 1
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
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
            try session.setCategory(.playback,
                                    mode: .default,
                                    options: [.allowBluetooth, .allowAirPlay])
            try session.setActive(true)
            print("AVAudioSession: category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
            let route = session.currentRoute
            print("Audio route outputs:", route.outputs.map { $0.portType.rawValue })
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
        player = AVQueuePlayer()
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
        print("Enqueue: \(audioURL.lastPathComponent)")
        print("Queue count before: \(player.items().count)")
        
        let item = AVPlayerItem(url: audioURL)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] n in
            guard let self, let urlAsset = (n.object as? AVPlayerItem)?.asset as? AVURLAsset else { return }
            if let next = self.player.items().first,
               let nextAsset = next.asset as? AVURLAsset {
                self.currentFileName = nextAsset.url.deletingPathExtension().lastPathComponent
            } else {
                self.currentFileName = urlAsset.url.deletingPathExtension().lastPathComponent
            }
        }

        player.insert(item, after: nil)
        canControlPlayback = true

        print("Queue count after: \(player.items().count)")
        if player.timeControlStatus != .playing {
            ensureActiveAudioSession()
            player.playImmediately(atRate: 1.0)
            print("Attempted to playImmediately")
            isPlaying = true
            if let asset = item.asset as? AVURLAsset {
                currentFileName = asset.url.deletingPathExtension().lastPathComponent
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            print("Player status: \(self.player.timeControlStatus.rawValue) rate=\(self.player.rate) currentItem=\(String(describing: (self.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent))")
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
            print("Synth finished → \(outURL.lastPathComponent), success=\(success)")
            if let attrs = try? self.fm.attributesOfItem(atPath: outURL.path) {
                print("File size:", attrs[.size] ?? "nil")
            }
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
        return [languageCode] + langs.filter { $0 != languageCode }.sorted()
    }
    
    var voicesForSelectedLanguage: [AVSpeechSynthesisVoice] {
        voices
            .filter { $0.language == languageCode }
            .sorted { lhs, rhs in
                (qualityRank(lhs.quality.rawValue), lhs.name) <
                    (qualityRank(rhs.quality.rawValue), rhs.name)
            }
    }
    
    
    private func qualityRank(_ q: Int) -> Int {
        switch q {
        case AVSpeechSynthesisVoiceQuality.premium.rawValue: return 0
        case AVSpeechSynthesisVoiceQuality.enhanced.rawValue: return 1
        default: return 2
        }
    }
    
    
    func refreshDefaultVoiceIfNeeded() {
        if let id = voiceIdentifier, AVSpeechSynthesisVoice(identifier: id) != nil { return }
        
        // 1) Stephanie (Enhanced) en-GB
        if let steph = voices.first(where: {
            $0.name == "Stephanie" &&
            $0.language.hasPrefix("en-GB") &&
            $0.quality == .enhanced
        }) {
            languageCode = steph.language
            voiceIdentifier = steph.identifier
            return
        }
        
        // 2) Zoe (Premium) en-US
        if let zoe = voices.first(where: {
            $0.name == "Zoe" &&
            $0.language.hasPrefix("en-US") &&
            $0.quality == .premium
        }) {
            languageCode = zoe.language
            voiceIdentifier = zoe.identifier
            return
        }
        
        // 3) Any Enhanced en-GB
        if let enGBEnh = voices.first(where: {
            $0.language.hasPrefix("en-GB") &&
            $0.quality == .enhanced
        }) {
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
    
    extension AVSpeechSynthesisVoice {
        var qualityLabel: String {
            switch quality {
            case .premium:  return "Premium"
            case .enhanced: return "Enhanced"
            default:        return "Default"
            }
        }
    }
    

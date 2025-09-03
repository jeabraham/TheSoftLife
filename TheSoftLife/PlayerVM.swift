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
    
    @Published var rate: Float = 0.48
    @Published var pitch: Float = 1.0
    @Published var languageCode: String = "en-CA"
    @Published var voiceIdentifier: String? = nil
    @Published var canControlPlayback: Bool = false
    
    private var player = AVQueuePlayer()
    private var itemEndObserver: Any?
    
    private let synthQueue = OperationQueue()
    private let fm = FileManager.default
    private var cacheDir: URL {
        try! fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenCache", isDirectory: true)
    }
    
    private let bookmarkKey = "chosenFolderBookmark"
    
    override init() {
        synthQueue.maxConcurrentOperationCount = 1
        super.init()
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        configureAudioSession()
        restoreBookmarkedFolderIfAny()
        observePlaybackEnd()
    }
    
    deinit {
        if let obs = itemEndObserver { NotificationCenter.default.removeObserver(obs) }
    }
    
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .duckOthers])
            try session.setActive(true)
        } catch {
            print("Audio session error (spokenAudio): \(error) — retrying with .default")
            do {
                try session.setCategory(.playback, mode: .default, options: [.allowBluetooth])
                try session.setActive(true)
            } catch {
                print("Audio session error (fallback): \(error)")
            }
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
            self.currentFileName = first.lastPathComponent
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
        // Helpful debug
        logPlayerState(prefix: "before toggle")

        if player.timeControlStatus == .paused {
            // Some devices deactivate the session on pause; reactivate before resuming
            do { try AVAudioSession.sharedInstance().setActive(true) } catch {
                print("AVAudioSession setActive(true) failed: \(error)")
            }
            // Resume immediately at normal rate (more reliable than .play() after a pause)
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
        print("[\(prefix)] status=\(status) rate=\(player.rate) hasItem=\(hasItem)")
    }

    
    func stopTapped() {
        showStopConfirm = true
    }
    
    func stopConfirmed() {
        stopSession(resetUIOnly: false)
    }
    
    private func stopSession(resetUIOnly: Bool) {
        // Tear down old player completely
        player.pause()
        player.removeAllItems()
        // Replace with a fresh instance to avoid stale state after Stop
        player = AVQueuePlayer()

        if !resetUIOnly {
            statusText = "Idle"
            totalFiles = 0
            processedFiles = 0
            isPlaying = false
            currentFileName = "—"
        }
        canControlPlayback = false

        // optional: clear cache folder
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
            self.currentFileName = urlAsset.url.deletingPathExtension().lastPathComponent
        }

        player.insert(item, after: nil)
        canControlPlayback = true

        // If we're not playing, kick the engine back on
        if player.timeControlStatus != .playing {
            ensureActiveAudioSession()
            player.playImmediately(atRate: 1.0)   // <-- stronger than .play() after Stop
            isPlaying = true
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
        let text = (try? Self.extractText(from: fileURL)) ?? ""
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let outURL = cacheDir.appendingPathComponent("\(baseName).m4a")
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

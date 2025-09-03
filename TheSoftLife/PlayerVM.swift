
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class PlayerVM: NSObject, ObservableObject {
    // UI state
    @Published var folderURL: URL?
    @Published var currentFileName: String = "—"
    @Published var isPlaying: Bool = false
    @Published var showStopConfirm: Bool = false

    // Settings (persist as you like)
    @Published var rate: Float = 0.48
    @Published var pitch: Float = 1.0
    @Published var languageCode: String = "en-CA"
    @Published var voiceIdentifier: String? = nil  // optional specific voice

    // Playback
    private var player = AVQueuePlayer()
    private var itemEndObserver: Any?

    // Synthesis queue
    private let synthQueue = OperationQueue()
    private let fm = FileManager.default
    private var cacheDir: URL {
        try! fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenCache", isDirectory: true)
    }

    // Security-scoped bookmark persistence
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
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.allowBluetooth, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    // MARK: - Folder selection / bookmark
    func pickFolder(presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func restoreBookmarkedFolderIfAny() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data,
                              options: [],                    // ← no .withSecurityScope on iOS
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            if url.startAccessingSecurityScopedResource() {
                folderURL = url
            }
        }
    }

    private func saveBookmark(for url: URL) {
        if let data = try? url.bookmarkData(                   // ← no .withSecurityScope on iOS
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    // MARK: - Main flow
    func startSession() {
        guard let folderURL else { return }
        let files = textFiles(in: folderURL)
        guard !files.isEmpty else { return }

        stopSession(resetUIOnly: true)  // clear any prior queue, keep session active

        // Synthesize first file immediately, start playback when ready
        let first = files[0]
        synthOne(fileURL: first) { [weak self] audioURL in
            guard let self else { return }
            self.enqueueAndMaybePlay(audioURL)
            self.currentFileName = first.lastPathComponent
            self.isPlaying = true
        }

        // Queue background synthesis for remaining files (in order)
        for file in files.dropFirst() {
            synthQueue.addOperation { [weak self] in
                guard let self else { return }
                let sema = DispatchSemaphore(value: 0)
                self.synthOne(fileURL: file) { audioURL in
                    DispatchQueue.main.async {
                        self.enqueueAndMaybePlay(audioURL)
                    }
                    sema.signal()
                }
                sema.wait()
            }
        }
    }

    func pauseResume() {
        if player.timeControlStatus == .paused {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func stopTapped() {
        showStopConfirm = true
    }

    func stopConfirmed() {
        stopSession(resetUIOnly: false)
    }

    private func stopSession(resetUIOnly: Bool) {
        player.pause()
        player.removeAllItems()
        if !resetUIOnly {
            isPlaying = false
            currentFileName = "—"
        }
        // optional: clear cache folder
        try? fm.removeItem(at: cacheDir)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func enqueueAndMaybePlay(_ audioURL: URL) {
        let item = AVPlayerItem(url: audioURL)
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] n in
            guard let self, let urlAsset = (n.object as? AVPlayerItem)?.asset as? AVURLAsset else { return }
            self.currentFileName = urlAsset.url.deletingPathExtension().lastPathComponent
        }
        player.insert(item, after: nil)
        if player.timeControlStatus != .playing { player.play() }
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

    // MARK: - File listing
    private func textFiles(in folder: URL) -> [URL] {
        guard folder.startAccessingSecurityScopedResource() else { return [] }
        defer { folder.stopAccessingSecurityScopedResource() }
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey, .contentTypeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let filtered = urls.filter { url in
            (url.pathExtension.lowercased() == "txt") || (url.pathExtension.lowercased() == "rtf")
        }
        return filtered.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Synthesis
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

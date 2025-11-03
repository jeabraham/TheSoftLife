import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class PlayerVM: NSObject, ObservableObject {
    // UI state
    
    static weak var shared: PlayerVM?
    
    @Published var folderURL: URL?
    @Published var currentFileName = "—"
    @Published var isPlaying = false
    @Published var showStopConfirm = false
    @Published var statusText = "Idle"
    @Published var totalFiles = 0
    @Published var processedFiles = 0
    @Published var canControlPlayback = false

    // Voice/rate settings
    @Published var rate: Float = 0.3 {
        didSet { updateControllerSettingsIfNeeded() }
    }
    @Published var pitch: Float = 1.0 {
        didSet { updateControllerSettingsIfNeeded() }
    }
    @Published var languageCode = "en-CA" {
        didSet { updateControllerSettingsIfNeeded() }
    }
    @Published var voiceIdentifier: String? = nil {
        didSet { updateControllerSettingsIfNeeded() }
    }
    @Published var voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()

    // Add next to your other @Published settings
    @Published var randomLoopEnabled: Bool = false
    @Published var minDelaySec: Double = 5 {
        didSet { updateControllerDelayRangeIfNeeded() }
    }
    @Published var maxDelaySec: Double = 20 {
        didSet { updateControllerDelayRangeIfNeeded() }
    }
    @Published var useNotificationForLongGaps: Bool = false   // for later; not used yet
    
    @Published var activeTasks: [String] = []  // <- for TTS/mixing/silence tasks

    
    var minGapSeconds: TimeInterval = 60   // example
    var maxGapSeconds: TimeInterval = 3600 // example
    var shortGapThreshold: TimeInterval = 180 // ≤3 minutes -> use silence
    
    // New: mode + services
    @Published var mode: PlaybackMode = .sequential
    private let tracker = AnalyticsTracker() // placeholder for future use
    private let controller = PlaybackController()

    // Bookmark key
    private let bookmarkKey = "chosenFolderBookmark"

    override init() {
        super.init()
        controller.delegate = self
        reloadVoices()
        refreshDefaultVoiceIfNeeded()
        restoreBookmarkedFolderIfAny()
    }
    
    // MARK: - Status updates
    func updateStatus(nowPlaying: String? = nil, tasks: [String]? = nil) {
        if let n = nowPlaying { currentFileName = n }
        if let t = tasks { activeTasks = t }
        statusText = buildStatusLine()
    }

    private func buildStatusLine() -> String {
        var parts: [String] = []
        if !activeTasks.isEmpty {
            parts.append("Processing: " + activeTasks.joined(separator: ", "))
        }
        return parts.isEmpty ? "Idle" : parts.joined(separator: " • ")
    }

    // MARK: - Session controls (delegate to controller)
    func startSession() {
        guard let folderURL else { return }
        processedFiles = 0
        totalFiles = 0
        statusText = "Preparing…"

        // Build settings as before
        let settings = PlaybackSettings(
            rate: rate,
            pitch: pitch,
            languageCode: languageCode,
            voiceIdentifier: voiceIdentifier
        )

        // Decide the playback mode
        let selectedMode: PlaybackMode
        if randomLoopEnabled {
            // validate and normalize the range
            let a = minDelaySec, b = maxDelaySec
            let (lo, hi) = a <= b ? (a, b) : (b, a)
            selectedMode = .randomLoop(minDelay: lo, maxDelay: hi, useNotification: false)
        } else {
            selectedMode = .sequential
        }

        controller.start(folderURL: folderURL, mode: selectedMode, settings: settings)
        canControlPlayback = true
    }


    func pauseResume() { controller.pauseResume() }
    func stopTapped() { showStopConfirm = true }
    func stopConfirmed() { controller.stop() }

    // MARK: - Dynamic Settings Update
    
    /// Updates the controller's playback settings when voice/rate/pitch settings change
    private func updateControllerSettingsIfNeeded() {
        // Only update if playback is active
        guard canControlPlayback else { return }
        
        let settings = PlaybackSettings(
            rate: rate,
            pitch: pitch,
            languageCode: languageCode,
            voiceIdentifier: voiceIdentifier
        )
        controller.updateSettings(settings)
    }
    
    /// Updates the controller's random delay range when minDelay/maxDelay settings change
    private func updateControllerDelayRangeIfNeeded() {
        // Only update if playback is active and in random loop mode
        guard canControlPlayback, randomLoopEnabled else { return }
        
        let a = minDelaySec, b = maxDelaySec
        let (lo, hi) = a <= b ? (a, b) : (b, a)
        controller.updateRandomDelayRange(minDelay: lo, maxDelay: hi)
    }

    // MARK: - Voices
    func reloadVoices() {
        voices = AVSpeechSynthesisVoice.speechVoices()
        print("Reloaded voices: count=\(voices.count)")
        for v in voices { print("Voice: \(v.name) | id=\(v.identifier) | lang=\(v.language) | quality=\(v.quality.rawValue)") }
    }

    var languagesAvailable: [String] {
        let langs = Set(voices.map { $0.language })
        return [languageCode] + langs.filter { $0 != languageCode }.sorted()
    }

    var voicesForSelectedLanguage: [AVSpeechSynthesisVoice] {
        voices
            .filter { $0.language == languageCode }
            .sorted { lhs, rhs in
                (qualityOrder(lhs), lhs.name) < (qualityOrder(rhs), rhs.name)
            }
    }

    private func qualityOrder(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium:  return 0
        case .enhanced: return 1
        default:        return 2
        }
    }

    func refreshDefaultVoiceIfNeeded() {
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

    // MARK: - Folder picker / bookmarking
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
            if url.startAccessingSecurityScopedResource() { folderURL = url }
        }
    }

    private func saveBookmark(for url: URL) {
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }
}

// MARK: - UIDocumentPickerDelegate
extension PlayerVM: UIDocumentPickerDelegate {
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        _ = url.startAccessingSecurityScopedResource()
        folderURL = url
        saveBookmark(for: url)
    }
}

// MARK: - Voice helpers
extension AVSpeechSynthesisVoice {
    var qualityLabel: String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Default"
        }
    }
}

// MARK: - PlaybackControllerDelegate
extension PlayerVM: PlaybackControllerDelegate {
    func playbackController(_ c: PlaybackController, didUpdateStatus text: String) {
        statusText = text
    }
    func playbackController(_ c: PlaybackController, didUpdateProgress processed: Int, total: Int) {
        processedFiles = processed
        totalFiles = total
    }
    func playbackController(_ c: PlaybackController, didStartPlaying fileName: String) {
        currentFileName = fileName
    }
    func playbackControllerDidPlay(_ c: PlaybackController) { isPlaying = true }
    func playbackControllerDidPause(_ c: PlaybackController) { isPlaying = false }
    func playbackControllerDidStop(_ c: PlaybackController) {
        isPlaying = false
        canControlPlayback = false
        statusText = "Idle"
        currentFileName = "—"
        totalFiles = 0
        processedFiles = 0
    }
}

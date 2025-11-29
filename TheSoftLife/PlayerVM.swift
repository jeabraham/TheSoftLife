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
    private let savedVoiceKey = "PlayerVM.savedVoiceIdentifier"
    private let initialVoiceChosenKey = "PlayerVM.initialVoiceChosen"

    @Published var voiceIdentifier: String? = nil {
        didSet {
            updateControllerSettingsIfNeeded()
            // Persist the user's chosen voice identifier (cleared when nil).
            let ud = UserDefaults.standard
            if let id = voiceIdentifier {
                ud.set(id, forKey: savedVoiceKey)
            } else {
                ud.removeObject(forKey: savedVoiceKey)
            }
        }
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
    
    let synthQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.thesoftlife.synthQueue"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1 // serialize synth tasks so foreground work queues behind subliminal builds
        return q
    }()

    // Bookmark key
    private let bookmarkKey = "chosenFolderBookmark"

    override init() {
        super.init()
        controller.delegate = self
        reloadVoices()
        // Restore persisted voice if valid
        if let saved = UserDefaults.standard.string(forKey: savedVoiceKey),
           let v = AVSpeechSynthesisVoice(identifier: saved) {
            voiceIdentifier = v.identifier
            languageCode = v.language
            // mark initial choice done so we don't auto-pick again
            UserDefaults.standard.set(true, forKey: initialVoiceChosenKey)
        } else {
            refreshDefaultVoiceIfNeeded()
        }
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
    
    /// Syncs the isPlaying state with the actual playback state.
    /// Call this when the app returns to foreground to update the UI.
    func syncPlaybackState() {
        controller.syncPlaybackState()
    }
    
    /// Reconfigures the audio session after settings change (e.g., duckOthers toggle)
    func reconfigureAudioSession() {
        controller.reconfigureAudioSession()
    }

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
    
    

    // Choose a sensible default only once (first install). Uses robust fallbacks.
    func refreshDefaultVoiceIfNeeded() {
        let ud = UserDefaults.standard
        if ud.bool(forKey: initialVoiceChosenKey) { return } // already picked once

        // Prefer: Stephanie (enhanced en-GB) if present, otherwise fallbacks.
        var chosen: AVSpeechSynthesisVoice?

        // 1) Try explicit Stephanie match first (if present)
        chosen = voices.first(where: { $0.name == "Stephanie" && $0.language.hasPrefix("en-GB") && $0.quality == .enhanced })

        // 2) Any enhanced en-GB
        if chosen == nil {
            chosen = voices.first(where: { $0.language.hasPrefix("en-GB") && $0.quality == .enhanced })
        }

        // 3) Premium en-US (Zoe) or similar
        if chosen == nil {
            chosen = voices.first(where: { $0.language.hasPrefix("en-US") && $0.quality == .premium })
        }

        // 4) Any enhanced voice (any locale)
        if chosen == nil {
            chosen = voices.first(where: { $0.quality == .enhanced })
        }

        // 5) Any English voice
        if chosen == nil {
            chosen = voices.first(where: { $0.language.hasPrefix("en") })
        }

        // 6) Last resort: any available voice
        if chosen == nil {
            chosen = voices.first
        }

        if let v = chosen {
            languageCode = v.language
            voiceIdentifier = v.identifier
        }

        // Mark that we performed the initial-choice step (even if no voice found)
        ud.set(true, forKey: initialVoiceChosenKey)
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

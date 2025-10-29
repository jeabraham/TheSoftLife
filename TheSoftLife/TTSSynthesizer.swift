import AVFoundation

final class TTSSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSSynthesizer()
    private let synthesizer = AVSpeechSynthesizer()
    private override init() { super.init(); synthesizer.delegate = self }
    
    func synthesizeToFile(text: String,
                          languageCode: String,
                          voiceIdentifier: String?,
                          rate: Float,
                          pitch: Float,
                          outputURL: URL,
                          completion: @escaping (Bool) -> Void) {
        PlayerVM.shared.updateStatus(tasks: ["TTS: \(outputURL.lastPathComponent)"])
        try? FileManager.default.removeItem(at: outputURL)
        
        let utt = AVSpeechUtterance(string: text)
        utt.rate = rate
        utt.pitchMultiplier = pitch
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            utt.voice = v
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: languageCode)
        }
        
        print("Voice:", utt.voice?.name ?? "nil", "| id:", utt.voice?.identifier ?? "nil",
              "| lang:", utt.voice?.language ?? "nil", "| quality:", utt.voice?.quality.rawValue)
        
        var audioFile: AVAudioFile?
        var succeeded = false
        var completed = false        // ← guard flag to prevent duplicate callbacks
        
        synthesizer.write(utt) { (buffer: AVAudioBuffer) in
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                do {
                    if audioFile == nil {
                        try FileManager.default.createDirectory(
                            at: outputURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        audioFile = try AVAudioFile(forWriting: outputURL, settings: pcm.format.settings)
                    }
                    try audioFile?.write(from: pcm)
                    succeeded = true
                } catch {
                    print("Write error:", error)
                }
            } else {
                // end-of-stream marker
                guard !completed else { return }   // ← prevent duplicate call
                completed = true
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path) {
                    print("Synthesized file size:", attrs[.size] ?? "nil")
                }
                PlayerVM.shared.updateStatus(tasks: [])
                DispatchQueue.main.async {
                    completion(succeeded)
                }
            }
        }
    }
}

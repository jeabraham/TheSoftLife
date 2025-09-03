
import AVFoundation

final class TTSSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSSynthesizer()
    private let synthesizer = AVSpeechSynthesizer()
    private override init() { super.init(); synthesizer.delegate = self }

    // Synthesize a single block of text into an .m4a file
    func synthesizeToFile(text: String,
                          languageCode: String,
                          voiceIdentifier: String?,
                          rate: Float,
                          pitch: Float,
                          outputURL: URL,
                          completion: @escaping (Bool) -> Void) {
        // Remove old file if present
        try? FileManager.default.removeItem(at: outputURL)

        let utt = AVSpeechUtterance(string: text)
        utt.rate = rate
        utt.pitchMultiplier = pitch
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            utt.voice = v
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: languageCode)
        }

        var audioFile: AVAudioFile?
        var succeeded = false

        let renderSemaphore = DispatchSemaphore(value: 0)

        synthesizer.write(utt) { (buffer: AVAudioBuffer) in
            guard let pcm = buffer as? AVAudioPCMBuffer,
                  pcm.frameLength > 0 else {
                // A zero-length / end marker arrives at completion
                renderSemaphore.signal()
                return
            }
            do {
                if audioFile == nil {
                    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    audioFile = try AVAudioFile(forWriting: outputURL, settings: pcm.format.settings)
                }
                try audioFile?.write(from: pcm)
                succeeded = true
            } catch {
                print("Write error: \(error)")
            }
        }

        // Wait for completion callback to drain
        renderSemaphore.wait()
        completion(succeeded)
    }
}

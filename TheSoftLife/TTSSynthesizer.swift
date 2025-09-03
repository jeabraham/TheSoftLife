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
        
        synthesizer.write(utt) { (buffer: AVAudioBuffer) in
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
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
            } else {
                DispatchQueue.main.async {
                    completion(succeeded)
                }
            }
        }
    }
}

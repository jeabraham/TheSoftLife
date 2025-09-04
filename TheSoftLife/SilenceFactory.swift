import AVFoundation

enum SilenceFactory {
    // Cache by (duration-ms + directory path) to avoid regenerating
    private static var memo: [String: URL] = [:]

    static func url(for duration: TimeInterval, in directory: URL) -> URL? {
        let ms = max(1, Int((duration * 1000).rounded()))
        let key = "\(ms)@\(directory.standardizedFileURL.path)"
        if let u = memo[key], FileManager.default.fileExists(atPath: u.path) { return u }

        let name = "silence-\(ms)ms.m4a"
        let outURL = directory.appendingPathComponent(name)

        // If already exists on disk, reuse
        if FileManager.default.fileExists(atPath: outURL.path) {
            memo[key] = outURL
            return outURL
        }

        // Tiny AAC file (iOS-friendly)
        let sr: Double = 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return nil }

        do {
            let file = try AVAudioFile(forWriting: outURL, settings: settings)
            let totalFrames = Int(duration * sr)
            let chunk = 1024
            guard let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(chunk)) else { return nil }
            var written = 0
            while written < totalFrames {
                let this = min(chunk, totalFrames - written)
                buf.frameLength = AVAudioFrameCount(this) // zeroed = silence
                try file.write(from: buf)
                written += this
            }
            memo[key] = outURL
            return outURL
        } catch {
            print("SilenceFactory error:", error)
            return nil
        }
    }
}

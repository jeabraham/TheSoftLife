import AVFoundation

/// Generates background noise with optional subliminal phrase overlays,
/// cached by (duration + directory) just like SilenceFactory.
enum BackgroundSubliminalFactory {
    // MARK: - Tunables (adjust as you like)
    /// Choose "white" or "pink" (simple 1-pole filtered white) noise
    static var noiseKind: NoiseKind = .pink

    /// Overall noise loudness (linear 0.0 ... 1.0); ~0.15–0.25 is comfy
    static var noiseGain: Float = 0.20

    /// Insert subliminals? If false, you just get noise.
    static var enableSubliminals = true

    /// Subliminal level relative to full scale (linear). -24 dB ≈ 0.063
    static var subliminalGain: Float = 0.063

    /// Interval between subliminals (seconds, inclusive range)
    static var subliminalIntervalRange: ClosedRange<Double> = 1.0...10.0

    /// Where to look for phrase clips (m4a/wav). If not found here,
    /// code will also try main bundle resources.
    static var subliminalsFolderName = "subliminals"

    // MARK: - Public API (mirrors SilenceFactory)
    private static var memo: [String: URL] = [:]

    static func url(for duration: TimeInterval, in directory: URL) -> URL? {
        // Cache key and existence check (matches SilenceFactory)
        let ms = max(1, Int((duration * 1000).rounded()))
        let key = "\(ms)@\(directory.standardizedFileURL.path)"
        if let u = memo[key], FileManager.default.fileExists(atPath: u.path) { return u }

        let name = "subliminal-\(ms)ms.m4a"
        let outURL = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: outURL.path) {
            memo[key] = outURL
            return outURL
        }

        // Writer format/settings (same AAC style as SilenceFactory)
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
            let chunk = 2048

            guard let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(chunk)) else { return nil }

            // Preload subliminal clips (optional)
            let phrases = enableSubliminals ? loadSubliminalFiles(sampleRate: sr) : []
            var nextInsertFrame = enableSubliminals ? scheduleNextInsert(from: 0, sr: sr) : Int.max

            // Pink noise state
            var lastPinkSample: Float = 0

            var written = 0
            while written < totalFrames {
                let this = min(chunk, totalFrames - written)
                buf.frameLength = AVAudioFrameCount(this)

                // 1) Synthesize noise into buffer
                if let ch = buf.floatChannelData?[0] {
                    switch noiseKind {
                    case .white:
                        for i in 0..<this {
                            let w = whiteSample() * noiseGain
                            ch[i] = w
                        }
                    case .pink:
                        for i in 0..<this {
                            // crude pink-ish: 1-pole lowpass over white, then a little tilt
                            let w = whiteSample()
                            let y = 0.98 * lastPinkSample + 0.02 * w
                            lastPinkSample = y
                            ch[i] = Float(y * 0.9 + w * 0.1) * noiseGain
                        }
                    }
                }

                // 2) If it’s time for a subliminal, mix one at low gain
                if enableSubliminals, !phrases.isEmpty {
                    let frameStart = written
                    let frameEnd = written + this

                    if nextInsertFrame >= frameStart && nextInsertFrame < frameEnd {
                        // Pick a random phrase
                        let phrase = phrases.randomElement()!

                        // Load frames from the phrase file (mono resampled already)
                        // and mix them starting at nextInsertFrame
                        let startOffset = nextInsertFrame - frameStart
                        mixPhrase(phrase,
                                  into: buf,
                                  startFrameOffsetInBuffer: startOffset,
                                  gain: subliminalGain)

                        // Schedule next insertion
                        nextInsertFrame = scheduleNextInsert(from: nextInsertFrame, sr: sr)
                    }
                }

                // 3) Write
                try file.write(from: buf)
                written += this
            }

            memo[key] = outURL
            return outURL
        } catch {
            print("BackgroundSubliminalFactory error:", error)
            return nil
        }
    }

    // MARK: - Helpers

    enum NoiseKind { case white, pink }

    /// Uniform white noise in [-1, 1]
    private static func whiteSample() -> Float {
        let u = Float.random(in: 0..<1)
        return 2 * u - 1
    }

    /// Schedule the next phrase insertion, randomizing within the range.
    private static func scheduleNextInsert(from currentFrame: Int, sr: Double) -> Int {
        let gap = Double.random(in: subliminalIntervalRange)
        return currentFrame + Int(gap * sr)
    }

    // A lightweight container for a mono phrase clip already at target sample rate.
    private struct Phrase {
        let samples: [Float]
        let sampleRate: Double
    }

    /// Try to load mono phrase clips from (directory/subliminals/*.{m4a,wav})
    /// If none found, also try main bundle resources with the same folder name.
    private static func loadSubliminalFiles(sampleRate sr: Double) -> [Phrase] {
        var urls: [URL] = []

        func addURLsFound(at dir: URL) {
            if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for u in items where (u.pathExtension.lowercased() == "m4a" || u.pathExtension.lowercased() == "wav") {
                    urls.append(u)
                }
            }
        }

        // First: external folder (caller-provided directory/subliminals)
        if let docDir = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            // not used directly, but shows where you'd commonly put assets
            _ = docDir // no-op
        }

        // The caller's output directory’s sibling "subliminals"
        // Note: the `in directory` path is where we write the output. We'll look for
        // a subfolder with phrase clips beside it. If you prefer, you can pass a shared cache dir.
        // For simplicity we try the folder relative to the output’s parent.
        // (The url(for:in:) only gives us 'directory'—we don't have it here, so we rely on the app to
        // keep the subliminals folder in a known shared location like app Support or Bundle.)
        // As a practical approach, we’ll try Bundle first, then app’s Application Support.

        // Try main bundle resource subfolder
        if let bundleFolder = Bundle.main.url(forResource: subliminalsFolderName, withExtension: nil) {
            addURLsFound(at: bundleFolder)
        }

        // Try Application Support/subliminals
        if let appSup = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let sub = appSup.appendingPathComponent(subliminalsFolderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: sub.path) {
                addURLsFound(at: sub)
            }
        }

        // Decode to mono float @ target SR
        var phrases: [Phrase] = []
        for u in urls {
            if let p = decodeMono(url: u, targetSR: sr) {
                phrases.append(p)
            }
        }
        return phrases
    }

    /// Decode an audio file, convert to mono target sample rate, and return floats.
    private static func decodeMono(url: URL, targetSR: Double) -> Phrase? {
        do {
            let inFile = try AVAudioFile(forReading: url)
            guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: inFile.fileFormat.sampleRate,
                                            channels: inFile.fileFormat.channelCount,
                                            interleaved: false) else { return nil }

            // Read entire file
            let frameCount = AVAudioFrameCount(inFile.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frameCount) else { return nil }
            try inFile.read(into: buf)

            // Mixdown to mono if needed
            var mono: [Float] = []
            if let ch0 = buf.floatChannelData?[0] {
                if inFmt.channelCount == 1 {
                    mono = Array(UnsafeBufferPointer(start: ch0, count: Int(buf.frameLength)))
                } else {
                    // average channels
                    let chN = Int(inFmt.channelCount)
                    let frames = Int(buf.frameLength)
                    mono = .init(repeating: 0, count: frames)
                    for c in 0..<chN {
                        if let ch = buf.floatChannelData?[c] {
                            vDSP_vadd(mono, 1, ch, 1, &mono, 1, vDSP_Length(frames))
                        }
                    }
                    var inv = 1.0 / Float(chN)
                    vDSP_vsmul(mono, 1, &inv, &mono, 1, vDSP_Length(frames))
                }
            }

            // Resample if the SR mismatches (simple linear; good enough for whispers)
            let srcSR = inFmt.sampleRate
            if abs(srcSR - targetSR) > 0.5 {
                let ratio = targetSR / srcSR
                let outCount = Int(Double(mono.count) * ratio)
                var out = [Float](repeating: 0, count: outCount)
                for i in 0..<outCount {
                    let x = Double(i) / ratio
                    let i0 = Int(floor(x))
                    let i1 = min(i0 + 1, mono.count - 1)
                    let t = Float(x - Double(i0))
                    out[i] = (1 - t) * mono[i0] + t * mono[i1]
                }
                mono = out
            }

            return Phrase(samples: mono, sampleRate: targetSR)
        } catch {
            print("decodeMono error:", error)
            return nil
        }
    }

    /// Mix a phrase’s samples into `buf` starting at `startFrameOffsetInBuffer`
    /// (clip-safe add with small gain).
    private static func mixPhrase(_ phrase: Phrase,
                                  into buf: AVAudioPCMBuffer,
                                  startFrameOffsetInBuffer: Int,
                                  gain: Float)
    {
        guard let ch = buf.floatChannelData?[0] else { return }
        let dstCount = Int(buf.frameLength)
        let src = phrase.samples
        let srcCount = src.count

        var i = 0
        while i < srcCount && (startFrameOffsetInBuffer + i) < dstCount {
            let mixed = ch[startFrameOffsetInBuffer + i] + gain * src[i]
            // Simple soft clip
            ch[startFrameOffsetInBuffer + i] = max(-1.0, min(1.0, mixed))
            i += 1
        }
    }
}

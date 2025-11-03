import AVFoundation

/// Renders an explicit TTS file layered over your background noise+subliminal bed,
/// ducking the bed so the foreground is intelligible.
enum ExplicitOverBedRenderer {

    struct MixOptions {
        /// Foreground narration gain (linear). 1.0 is full-scale from the file.
        var fgGain: Float = 0.6
        /// Background bed base gain multiplier applied to the rendered bed file.
        var bedBaseGain: Float = 0.95
        /// Multiplier applied to the bed **while** speech is present (ducking).
        /// e.g. 0.35 means ~−9 dB when the foreground is active.
        var bedDuckWhileSpeech: Float = 0.9
        /// Threshold to consider "speech present" on the foreground (linear).
        var speechDetectAbsThreshold: Float = 0.001
        /// Fade length at start/end of fg & duck transitions (seconds).
        var fadeSeconds: Double = 0.015
    }

    static var enableLogging = true
    private static func log(_ items: Any...) {
        guard enableLogging else { return }
        print("[ExplicitOverBed]", items.map { "\($0)" }.joined(separator: " "))
    }

    /// Build a narrated clip over a subliminal bed and write to `outURL`.
    /// - Parameters:
    ///   - text: explicit narration text
    ///   - tts: preferred TTS parameters
    ///   - directory: where to place intermediate (TTS) and final output
    ///   - outputName: final file name (".m4a" will be appended if not present)
    ///   - options: mix gains & thresholds
    ///   - completion: returns the final URL on success
    static func render(text: String,
                       tts: (lang: String, voice: String?, rate: Float, pitch: Float) = ("en-US", nil, 0.30, 1.0),
                       in directory: URL,
                       outputName: String = "explicit_over_bed.m4a",
                       options: MixOptions = MixOptions(),
                       completion: @escaping (URL?) -> Void)
    {
        // 1) TTS foreground file
        let fgName = "explicit-\(UUID().uuidString.prefix(8)).m4a"
        let fgURL = directory.appendingPathComponent(fgName)

        log("TTS start:", "rate=\(tts.rate)", "pitch=\(tts.pitch)")

        TTSSynthesizer.shared.synthesizeToFile(
            text: text,
            languageCode: tts.lang,
            voiceIdentifier: tts.voice,
            rate: tts.rate,
            pitch: tts.pitch,
            outputURL: fgURL
        ) { ok in
            guard ok else { completion(nil); return }

            self.validatePlayableAsset(url: fgURL, retries: 6, delay: 0.08) { validated in
                guard validated else { completion(nil); return }

                // 2) Get foreground duration
                let fgAsset = AVURLAsset(url: fgURL)
                let fgDurSec = CMTimeGetSeconds(fgAsset.duration)
                let pad: Double = 0.15 // a touch of tail headroom
                let bedDur = max(0.5, fgDurSec + pad)
                log("TTS ok:", String(format: "%.2fs", fgDurSec), "→ bed dur:", String(format: "%.2fs", bedDur))

                // 3) Bed (noise + subliminal)
                guard let bedURL = BackgroundSubliminalFactory.build_Audio(for: bedDur, in: directory) else {
                    log("Bed generation failed")
                    completion(nil)
                    return
                }
                log("Bed:", bedURL.lastPathComponent)

                // 4) Mix offline
                let out = directory.appendingPathComponent(outputName.hasSuffix(".m4a") ? outputName : outputName + ".m4a")
                self.offlineMix(fgURL: fgURL,
                                bedURL: bedURL,
                                outURL: out,
                                options: options) { done in
                    // Cleanup foreground temp if you like
                    try? FileManager.default.removeItem(at: fgURL)
                    completion(done ? out : nil)
                }
            }
        }
    }

    // MARK: - Mixing (offline)

private static func offlineMix(fgURL: URL,
                       bedURL: URL,
                       outURL: URL,
                       options: MixOptions,
                       completion: @escaping (Bool) -> Void)
    {
        do {
            let sr: Double = 44_100
            let outSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { completion(false); return }

            let fgFile = try AVAudioFile(forReading: fgURL)
            let bedFile = try AVAudioFile(forReading: bedURL)
            let outFile = try AVAudioFile(forWriting: outURL, settings: outSettings)

            // Read entire files into memory (narration is short; safe & simplest)
            func readMonoFloat(_ file: AVAudioFile, targetSR: Double) throws -> [Float] {
                let inSR = file.fileFormat.sampleRate
                let inCh = Int(file.fileFormat.channelCount)
                let frames = Int(file.length)

                guard let buf = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                                          sampleRate: inSR,
                                                                          channels: file.fileFormat.channelCount,
                                                                          interleaved: false)!,
                                                 frameCapacity: AVAudioFrameCount(frames)) else { throw NSError() }
                try file.read(into: buf)

                // mixdown to mono
                var mono = [Float](repeating: 0, count: Int(buf.frameLength))
                if inCh == 1, let ch0 = buf.floatChannelData?[0] {
                    mono = Array(UnsafeBufferPointer(start: ch0, count: Int(buf.frameLength)))
                } else {
                    let n = Int(buf.frameLength)
                    for c in 0..<inCh {
                        if let ch = buf.floatChannelData?[c] {
                            for i in 0..<n { mono[i] += ch[i] }
                        }
                    }
                    let inv = 1.0 / Float(inCh)
                    for i in 0..<n { mono[i] *= inv }
                }

                // resample if needed (linear)
                if abs(inSR - targetSR) > 0.5 {
                    let ratio = targetSR / inSR
                    let outCount = Int(Double(mono.count) * ratio)
                    var out = [Float](repeating: 0, count: outCount)
                    for i in 0..<outCount {
                        let x = Double(i) / ratio
                        let i0 = Int(x)
                        let i1 = min(i0 + 1, mono.count - 1)
                        let t = Float(x - Double(i0))
                        out[i] = (1 - t) * mono[i0] + t * mono[i1]
                    }
                    return out
                }
                return mono
            }

            let fg = try readMonoFloat(fgFile, targetSR: sr)
            let bed = try readMonoFloat(bedFile, targetSR: sr)

            log("Mix sizes:", "fg=\(fg.count) frames", "bed=\(bed.count) frames")

            // simple alignment: bed starts at 0; fg at 0
            let n = min(bed.count, fg.count)
            var out = [Float](repeating: 0, count: n)

            // fades / ducking
            let fade = max(8, Int(options.fadeSeconds * sr))
            let speechThr = options.speechDetectAbsThreshold
            let baseBed = options.bedBaseGain
            let duckBed = options.bedDuckWhileSpeech
            let fgGain = options.fgGain

            // Precompute where speech is present (simple abs threshold)
            var speechMask = [Bool](repeating: false, count: n)
            for i in 0..<n { speechMask[i] = abs(fg[i]) >= speechThr }

            // Smooth the mask a bit to avoid rapid toggling
            let smooth = fade
            if smooth > 1 {
                var run = 0
                for i in 0..<n {
                    if speechMask[i] { run = smooth }
                    if run > 0 { speechMask[i] = true; run -= 1 }
                }
                run = 0
                for i in stride(from: n-1, through: 0, by: -1) {
                    if speechMask[i] { run = smooth }
                    if run > 0 { speechMask[i] = true; run -= 1 }
                }
            }

            // Build bed gain envelope with ducking & short ramps
            var bedEnv = [Float](repeating: baseBed, count: n)
            var target: Float = baseBed
            var current: Float = baseBed
            let step = max(1, n / 10_000) // small-ish ramp granularity

            for i in 0..<n {
                target = speechMask[i] ? baseBed * duckBed : baseBed
                // small one-pole-ish ramp
                if i % step == 0 {
                    current += (target - current) * 0.25
                }
                bedEnv[i] = current
            }

            // Short fades on FG start/end to avoid clicks
            var fgEnv = [Float](repeating: fgGain, count: n)
            // fade-in
            for i in 0..<min(fade, n) { fgEnv[i] = fgGain * Float(i) / Float(fade) }
            // fade-out
            for k in 0..<min(fade, n) {
                let i = n - 1 - k
                fgEnv[i] = min(fgEnv[i], fgGain * Float(k) / Float(fade))
            }

            // Mix with soft-clip safety
            for i in 0..<n {
                let v = bed[i] * bedEnv[i] + fg[i] * fgEnv[i]
                // soft limit
                out[i] = max(-1, min(1, v))
            }

            // Write out
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { completion(false); return }
            buf.frameLength = AVAudioFrameCount(n)
            if let ch = buf.floatChannelData?[0] {
                out.withUnsafeBufferPointer { src in
                    ch.assign(from: src.baseAddress!, count: n)
                }
            }

            try outFile.write(from: buf)
            log("Wrote:", outURL.lastPathComponent, "frames:", n)
            completion(true)

        } catch {
            log("ERROR mix:", error.localizedDescription)
            completion(false)
        }
    }

    // Small retry helper (matches your style)
    private static func validatePlayableAsset(url: URL, retries: Int, delay: TimeInterval, done: @escaping (Bool)->Void) {
        var left = retries
        func check() {
            let a = AVURLAsset(url: url)
            if a.isPlayable { done(true); return }
            left -= 1
            if left <= 0 { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { check() }
        }
        check()
    }
}

extension ExplicitOverBedRenderer {
    static func offlineMixPublic(fgURL: URL,
                                 bedURL: URL,
                                 outURL: URL,
                                 options: MixOptions,
                                 completion: @escaping (Bool)->Void) {
        // Calls the internal/private mixer
        self.offlineMix(fgURL: fgURL, bedURL: bedURL, outURL: outURL, options: options, completion: completion)
    }
}

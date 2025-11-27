// swift
import AVFoundation
import Accelerate




/// Generates background noise with optional subliminal phrase overlays,
/// cached by (duration + directory) just like SilenceFactory.
enum BackgroundSubliminalFactory {
    // MARK: - Tunables (adjust as you like)
    /// Choose "white" or "pink" (simple 1-pole filtered white) noise
    static var noiseKind: NoiseKind = .pink

    /// Overall noise loudness (linear 0.0 ... 1.0); ~0.15–0.25 is comfy
    static var noiseGain: Float = 0.10

    /// Insert subliminals? If false, you just get noise.
    static var enableSubliminals = true

    /// Subliminal level relative to full scale (linear). -24 dB ≈ 0.063
    static var subliminalGain: Float = 0.05

    /// Interval between subliminals (seconds, inclusive range)
    static var subliminalIntervalRange: ClosedRange<Double> = 2.0...7.0

    // At the top of your BackgroundSubliminalFactory:
    static var enableLogging = true
    private static func log(_ items: Any...) {
        guard enableLogging else { return }
        print("[BackgroundSubliminalFactory]", items.map { "\($0)" }.joined(separator: " "))
    }

    /// Where to look for phrase clips (m4a/wav). If not found here,
    /// code will also try main bundle resources.
    static var subliminalsFolderName = "subliminals"

    // MARK: - Public API (mirrors SilenceFactory)
    // Replace single-URL memo with multi-URL memo and helpers
    private static var memo: [String: [URL]] = [:]
    private static let maxMemoItems = 50

    // Add these near your other state vars (top of url(for:in:))
    private static var activePhrase: Phrase? = nil
    static var activeIndex: Int = 0 // how many samples already mixed for the active phrase

    // Cached decoded subliminal phrases. These are expensive to decode, so we keep
    // them in memory and refresh on demand (off the main queue) via
    // `refreshPhrases(sampleRate:completion:)`.
    private static var _cachedPhrases: [Phrase] = []
    private static let phrasesQueue = DispatchQueue(label: "BackgroundSubliminalFactory.phrasesQueue")

    /// Refresh the cached subliminal phrases. This runs the decode work off the
    /// main queue. Callers can provide an optional completion that is invoked on
    /// the main queue with the number of phrases loaded.
    static func refreshPhrases(sampleRate: Double = 44_100, completion: ((Int)->Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let loaded = loadSubliminalFiles(sampleRate: sampleRate)
            phrasesQueue.sync { _cachedPhrases = loaded }
            DispatchQueue.main.async { completion?(loaded.count) }
        }
    }

    /// Build or return a cached background audio file for `duration` seconds in `directory`.
    static func build_Audio(for duration: TimeInterval, in directory: URL) -> URL? {
        let ms = max(1, Int((duration * 1000).rounded()))
        let key = "\(ms)@\(directory.standardizedFileURL.path)"

        // Ask helper for either an existing cached file or a unique path to create.
        let (candidateURL, isExisting) = cachedOrUniqueOutURL(ms: ms, key: key, directory: directory)
        if isExisting {
            log("Cache hit:", candidateURL.lastPathComponent)
            PlayerVM.shared?.updateStatus(tasks: [])
            return candidateURL
        }

        // If not existing, candidateURL is the new path we'll write.
        let name = candidateURL.lastPathComponent
        PlayerVM.shared?.updateStatus(tasks: ["Building bed: \(name)"])
        let outURL = candidateURL

        // Writer format/settings
        let sr: Double = 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return nil }

        do {
            log("Create:", name, "| dur=\(String(format: "%.3f", duration))s",
                "| sr=\(Int(sr))",
                "| noiseGain=\(noiseGain)",
                "| subliminalGain=\(subliminalGain)",
                "| enableSubliminals=\(enableSubliminals)")

            let file = try AVAudioFile(forWriting: outURL, settings: settings)
            let totalFrames = Int(duration * sr)
            let chunk = 2048

            guard let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(chunk)) else { return nil }

            // Preload subliminal clips (optional). Use cached phrases if available
            // so we don't re-decode every time. If cache is empty, fall back to
            // decoding synchronously (preserves previous behavior).
            let phrases: [Phrase]
            if enableSubliminals {
                let cached = phrasesQueue.sync { _cachedPhrases }
                if !cached.isEmpty {
                    phrases = cached
                } else {
                    // Synchronous fallback: decode now (was previous behavior).
                    let decoded = loadSubliminalFiles(sampleRate: sr)
                    phrasesQueue.sync { _cachedPhrases = decoded }
                    phrases = decoded
                }
            } else {
                phrases = []
            }
            log("Phrases loaded:", phrases.count)
            if phrases.isEmpty && enableSubliminals {
                log("WARN: enableSubliminals=true but no phrases loaded")
            }
            var nextInsertFrame = enableSubliminals ? scheduleNextInsert(from: 0, sr: sr) : Int.max
            log("First insert scheduled at frame:", nextInsertFrame, "(\(String(format: "%.2f", Double(nextInsertFrame)/sr))s)")

            // Pink noise state
            var lastPinkSample: Float = 0

            var written = 0
            var insertCount = 0

            while written < totalFrames {
                let this = min(chunk, totalFrames - written)
                buf.frameLength = AVAudioFrameCount(this)

                // 1) Synthesize noise
                if let ch = buf.floatChannelData?[0] {
                    switch noiseKind {
                    case .white:
                        for i in 0..<this { ch[i] = whiteSample() * noiseGain }
                    case .pink:
                        for i in 0..<this {
                            let w = whiteSample()
                            let y = 0.98 * lastPinkSample + 0.02 * w
                            lastPinkSample = y
                            ch[i] = Float(y * 0.9 + w * 0.1) * noiseGain
                        }
                    }
                }

                let frameStart = written
                let frameEnd   = written + this

                // 2a) Continue mixing any active phrase across this whole buffer
                if let phrase = activePhrase, let ch = buf.floatChannelData?[0] {
                    let mixedNow = mixPhraseChunk(
                        phrase: phrase,
                        into: ch,
                        bufferFrameCount: this,
                        dstStart: 0,                 // continuing always starts at beginning of this chunk
                        srcStart: activeIndex,       // continue from where we left off
                        gain: subliminalGain,
                        sampleRate: sr
                    )
                    activeIndex += mixedNow
                    if activeIndex >= phrase.samples.count {
                        log("Insert finished (spillover complete) at abs frame:", frameStart + this)
                        activePhrase = nil
                        activeIndex = 0
                    }
                }

                // 2b) Check if a NEW insert begins inside this buffer (only if none is active)
                if enableSubliminals, activePhrase == nil, !phrases.isEmpty,
                   nextInsertFrame < frameEnd
                {
                    if nextInsertFrame < frameStart {
                        nextInsertFrame = frameStart
                    }
                    let phrase = phrases.randomElement()!
                    log("Insert \(insertCount+1) START @ frame \(nextInsertFrame) ... phrase=\(phrase.name)")
                    let startOffset = nextInsertFrame - frameStart
                    let phraseFrames = phrase.samples.count
                    let secs = Double(phraseFrames) / sr

                    log("Insert \(insertCount+1) START @ frame \(nextInsertFrame) (\(String(format: "%.2f", Double(nextInsertFrame)/sr))s) | phraseFrames=\(phraseFrames) (~\(String(format: "%.2f", secs))s) | startOffsetInChunk=\(startOffset)")

                    if let ch = buf.floatChannelData?[0] {
                        // Mix whatever fits in this buffer, starting at startOffset
                        let mixedNow = mixPhraseChunk(
                            phrase: phrase,
                            into: ch,
                            bufferFrameCount: this,
                            dstStart: startOffset,
                            srcStart: 0,                // start of phrase
                            gain: subliminalGain,
                            sampleRate: sr
                        )

                        if mixedNow < phraseFrames {
                            // Keep spillover for next chunk(s)
                            activePhrase = phrase
                            activeIndex  = mixedNow
                            log("Insert spillover queued: mixed \(mixedNow) / \(phraseFrames) frames in this chunk")
                        } else {
                            log("Insert finished within single chunk")
                        }

                        insertCount += 1
                    }

                    // Schedule next insertion from this start time (as before)
                    nextInsertFrame = scheduleNextInsert(from: nextInsertFrame, sr: sr)
                    log("Next insert scheduled:", nextInsertFrame, "(\(String(format: "%.2f", Double(nextInsertFrame)/sr))s)")
                }

                // 3) Write
                try file.write(from: buf)
                written += this
            }
            log("Finished:", name, "| totalFrames=\(totalFrames)", "| inserts=\(insertCount)")
            PlayerVM.shared?.updateStatus(tasks: [])

            // Register newly created cached file (may evict an older one)
            registerNewCachedFile(outURL, forKey: key)
            return outURL
        } catch {
            print("BackgroundSubliminalFactory error:", error)
            return nil
        }
    }

    // MARK: - Cache helpers

    /// Try to return either an existing cached file (if cache-full or exact existing files found)
    /// or a unique new outURL to create. The boolean indicates whether the returned URL already exists.
    private static func cachedOrUniqueOutURL(ms: Int, key: String, directory: URL) -> (URL, Bool) {
        // Ensure memo has any existing variants on disk for this duration
        if memo[key] == nil {
            if let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let hits = items.filter {
                    $0.pathExtension.lowercased() == "m4a" &&
                    $0.lastPathComponent.hasPrefix("subliminal-\(ms)ms")
                }
                if !hits.isEmpty {
                    memo[key] = hits
                    log("Found existing cached variants for", "\(ms)ms:", hits.map { $0.lastPathComponent }.joined(separator: ", "))
                }
            }
        }

        // Calculate current total cached count
        let totalCached = memo.values.reduce(0) { $0 + $1.count }

        // If cache is full and we have candidates for this duration, return a random existing one.
        if let candidates = memo[key], !candidates.isEmpty, totalCached >= maxMemoItems {
            let chosen = candidates.randomElement()!
            log("Cache hit (random):", chosen.lastPathComponent)
            return (chosen, true)
        }

        // Otherwise return a unique new path to create (5-char suffix)
        let suffix = String(UUID().uuidString.prefix(5))
        var name = "subliminal-\(ms)ms-\(suffix).m4a"
        var outURL = directory.appendingPathComponent(name)

        // Ensure unique filename
        var attempt = 0
        while FileManager.default.fileExists(atPath: outURL.path) && attempt < 8 {
            let s = String(UUID().uuidString.prefix(5))
            name = "subliminal-\(ms)ms-\(s).m4a"
            outURL = directory.appendingPathComponent(name)
            attempt += 1
        }

        // If by chance the chosen outURL already exists on disk (very unlikely), ensure memo tracks it and treat as existing.
        if FileManager.default.fileExists(atPath: outURL.path) {
            memo[key, default: []].append(outURL)
            log("Found existing file after uniqueness loop:", outURL.lastPathComponent)
            return (outURL, true)
        }

        return (outURL, false)
    }

    /// Register a newly created cached file and evict a random old entry if we exceed maxMemoItems.
    private static func registerNewCachedFile(_ outURL: URL, forKey key: String) {
        memo[key, default: []].append(outURL)
        var totalCached = memo.values.reduce(0) { $0 + $1.count }

        if totalCached > maxMemoItems {
            // Build eviction pool excluding the newly added file when possible
            var evictionPool = memo.flatMap { (k, urls) -> [(String, URL)] in
                urls.map { (k, $0) }
            }.filter { $0.1 != outURL }

            if evictionPool.isEmpty {
                // fallback: allow evicting from same key but not the new file
                evictionPool = memo.flatMap { (k, urls) -> [(String, URL)] in
                    urls.filter { $0 != outURL }.map { (k, $0) }
                }
            }

            if let (evictKey, evictURL) = evictionPool.randomElement() {
                do {
                    try FileManager.default.removeItem(at: evictURL)
                    if let idx = memo[evictKey]?.firstIndex(of: evictURL) {
                        memo[evictKey]?.remove(at: idx)
                        if memo[evictKey]?.isEmpty == true { memo.removeValue(forKey: evictKey) }
                    }
                    log("Evicted cached file to maintain size:", evictURL.lastPathComponent)
                    totalCached -= 1
                } catch {
                    log("Failed to evict cached file:", evictURL.lastPathComponent, error.localizedDescription)
                }
            }
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
        let name: String
        let samples: [Float]
        let sampleRate: Double
    }

    /// Try to load mono phrase clips from (directory/subliminals/*.{m4a,wav})
    /// If none found, also try main bundle resources with the same folder name.
    private static func loadSubliminalFiles(sampleRate sr: Double) -> [Phrase] {
        log("Looking for subliminal audio files…")
        var urls: [URL] = []

        func addFlatFiles(in dir: URL, label: String) {
            if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let hits = items.filter { ["m4a","wav"].contains($0.pathExtension.lowercased()) }
                if !hits.isEmpty {
                    log("Found \(hits.count) file(s) in", label, "→", dir.path)
                    for (i,u) in hits.prefix(5).enumerated() { log("  [\(i+1)]", u.lastPathComponent) }
                    if hits.count > 5 { log("  …and \(hits.count - 5) more") }
                    urls.append(contentsOf: hits)
                } else {
                    log("No audio files in", label, "→", dir.path)
                }
            } else {
                log("Unable to list", label, "→", dir.path)
            }
        }

        func addRecursiveFiles(in root: URL, label: String) {
            guard let e = FileManager.default.enumerator(at: root,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else {
                log("Unable to enumerate", label, "→", root.path)
                return
            }
            var found = 0
            for case let u as URL in e {
                let ext = u.pathExtension.lowercased()
                if ext == "m4a" || ext == "wav" {
                    urls.append(u); found += 1
                }
            }
            if found > 0 {
                log("Found \(found) file(s) recursively in", label, "→", root.path)
                for (i,u) in urls.suffix(min(found,5)).enumerated() { log("  [\(i+1)]", u.lastPathComponent) }
                if found > 5 { log("  …and \(found - 5) more") }
            } else {
                log("No audio files (recursive) in", label, "→", root.path)
            }
        }

        // (Optional) Documents dir print
        if let docDir = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            log("Documents dir:", docDir.path)
        }

        // Try main bundle subfolder (folder reference)
        if let bundleFolder = Bundle.main.url(forResource: subliminalsFolderName, withExtension: nil) {
            addRecursiveFiles(in: bundleFolder, label: "Bundle/\(subliminalsFolderName)")
        } else {
            log("Bundle subfolder not found:", subliminalsFolderName)
        }

        // Try Application Support / subliminals (your clips are here in category subfolders)
        if let appSup = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let sub = appSup.appendingPathComponent(subliminalsFolderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: sub.path) {
                addRecursiveFiles(in: sub, label: "Application Support/\(subliminalsFolderName)")
            } else {
                log("No Application Support folder yet at:", sub.path)
            }
        } else {
            log("ERROR: Could not resolve Application Support directory")
        }

        // Sort for stable order, log total
        urls.sort { $0.path < $1.path }
        log("Total candidate files found:", urls.count)

        // Decode to mono @ target SR with light logging
        var phrases: [Phrase] = []
        var failCount = 0
        for (i, u) in urls.enumerated() {
            DispatchQueue.main.async {
                let name = u.lastPathComponent
                PlayerVM.shared?.updateStatus(tasks: ["Decoding \(i + 1)/\(urls.count): \(name)"])
            }

            if let p = decodeMono(url: u, targetSR: sr) {
                let q = subliminalAudioFilter(p: p)
                phrases.append(q)
                if i < 5 { log("Decoded OK:", u.lastPathComponent, "(\(p.samples.count) samples)") }
            } else {
                failCount += 1
                if failCount <= 5 { log("Decode FAILED:", u.lastPathComponent) }
            }
        }
        if failCount > 5 { log("…and \(failCount - 5) more decode failures") }

        log("Decoded phrases:", phrases.count)
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

            return Phrase(name: url.lastPathComponent, samples: mono, sampleRate: targetSR)
        } catch {
            print("decodeMono error:", error)
            return nil
        }
    }

    /// Mix a phrase’s samples into `buf` starting at `startFrameOffsetInBuffer`.
    /// Adds a short 5 ms fade-in/out and soft-clips to [-1, 1].
    /// Mix as many samples as fit in the current buffer chunk.
    /// Returns how many source samples were mixed.
    /// Applies a 5 ms fade-in/out across the *entire* phrase (not just this chunk).
    private static func mixPhraseChunk(
        phrase: Phrase,
        into dst: UnsafeMutablePointer<Float>,
        bufferFrameCount: Int,
        dstStart: Int,
        srcStart: Int,
        gain: Float,
        sampleRate sr: Double
    ) -> Int {
        let total = phrase.samples.count
        if total == 0 || dstStart >= bufferFrameCount { return 0 }

        // How many source samples *could* we mix in this chunk?
        let maxInDst = bufferFrameCount - dstStart
        let remainingSrc = total - srcStart
        let count = max(0, min(maxInDst, remainingSrc))
        if count == 0 { return 0 }

        // 5 ms fade across the full phrase
        let fade = max(8, Int(0.005 * sr))

        for i in 0..<count {
            let srcPos = srcStart + i
            var env: Float = 1.0
            if srcPos < fade { env = Float(srcPos) / Float(fade) }                 // fade-in at absolute start
            else if srcPos > (total - fade) {                                      // fade-out near absolute end
                let tail = total - srcPos
                env = Float(max(tail, 0)) / Float(fade)
            }

            let add = gain * env * phrase.samples[srcPos]
            let dstIdx = dstStart + i
            let mixed = dst[dstIdx] + add

            // Soft clamp just in case
            dst[dstIdx] = max(-1.0, min(1.0, mixed))
        }
        return count
    }


    // MARK: - Biquad + helpers
    private struct Biquad {
        var b0, b1, b2, a1, a2: Float
        var z1: Float = 0, z2: Float = 0

        mutating func process(_ x: Float) -> Float {
            let y = b0*x + z1
            z1 = b1*x - a1*y + z2
            z2 = b2*x - a2*y
            return y
        }
    }

    private static func biquadHighPass(sr: Double, fc: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2.0 * .pi * fc / sr
        let alpha = sin(w0)/(2.0*q)
        let cosw = cos(w0)
        let b0 =  (1 + cosw)/2
        let b1 = -(1 + cosw)
        let b2 =  (1 + cosw)/2
        let a0 =   1 + alpha
        let a1 =  -2*cosw
        let a2 =   1 - alpha
        return Biquad(
            b0: Float(b0/a0), b1: Float(b1/a0), b2: Float(b2/a0),
            a1: Float(a1/a0), a2: Float(a2/a0)
        )
    }
    private static func biquadLowPass(sr: Double, fc: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2.0 * .pi * fc / sr
        let alpha = sin(w0)/(2.0*q)
        let cosw = cos(w0)
        let b0 = (1 - cosw)/2
        let b1 =  1 - cosw
        let b2 = (1 - cosw)/2
        let a0 =  1 + alpha
        let a1 = -2*cosw
        let a2 =  1 - alpha
        return Biquad(
            b0: Float(b0/a0), b1: Float(b1/a0), b2: Float(b2/a0),
            a1: Float(a1/a0), a2: Float(a2/a0)
        )
    }
    private static func highShelf(sr: Double, fc: Double, gainDB: Double) -> Biquad {
        let A = pow(10.0, gainDB/40.0)
        let w0 = 2.0 * .pi * fc / sr
        let alpha = sin(w0)/2.0 * sqrt((A + 1/A) * (1/0.707 - 1) + 2)
        let cosw = cos(w0)
        let b0 =    A*((A+1) + (A-1)*cosw + 2*sqrt(A)*alpha)
        let b1 = -2*A*((A-1) + (A+1)*cosw)
        let b2 =    A*((A+1) + (A-1)*cosw - 2*sqrt(A)*alpha)
        let a0 =       (A+1) - (A-1)*cosw + 2*sqrt(A)*alpha
        let a1 =   2*((A-1) - (A+1)*cosw)
        let a2 =       (A+1) - (A-1)*cosw - 2*sqrt(A)*alpha
        return Biquad(
            b0: Float(b0/a0), b1: Float(b1/a0), b2: Float(b2/a0),
            a1: Float(a1/a0), a2: Float(a2/a0)
        )
    }

    @inline(__always) private static func white() -> Float { Float.random(in: -1...1) }

    // MARK: - Main filter
    private static func subliminalAudioFilter(p: Phrase,
                               hpHz: Double = 300,
                               lpHz: Double = 3500,
                               airShelfHz: Double = 6000,
                               airShelfGainDB: Double = 5,
                               noiseGain: Float = 0.05,
                               envAttackMs: Double = 15,
                               envReleaseMs: Double = 80) -> Phrase {

        let sr = p.sampleRate

        var hp = biquadHighPass(sr: sr, fc: hpHz)
        var lp = biquadLowPass(sr: sr, fc: lpHz)
        var shelf = highShelf(sr: sr, fc: airShelfHz, gainDB: airShelfGainDB)

        var out = [Float](repeating: 0, count: p.samples.count)

        // Simple envelope follower to gate noise where speech energy exists
        let atk = Float(exp(-1.0 / (sr * envAttackMs / 1000.0)))
        let rel = Float(exp(-1.0 / (sr * envReleaseMs / 1000.0)))
        var env: Float = 0

        for i in 0..<p.samples.count {
            var x = p.samples[i]
            x = hp.process(x)
            x = lp.process(x)
            x = shelf.process(x)

            // envelope
            let a = abs(x)
            env = (a > env) ? (atk*env + (1 - atk)*a) : (rel*env + (1 - rel)*a)

            // add a whisper of noise, shaped by envelope (subtle!)
            let n = white() * noiseGain * min(env * 1.5, 1.0)

            out[i] = x + n
        }
        return Phrase(name: p.name, samples: out, sampleRate: sr)
    }

    /// Clear the in-memory phrase cache. Safe to call from any thread.
    static func clearCachedPhrases() {
        phrasesQueue.sync { _cachedPhrases.removeAll() }
    }

    /// Number of phrases currently cached in memory (thread-safe).
    static var cachedPhrasesCount: Int {
        phrasesQueue.sync { _cachedPhrases.count }
    }
}

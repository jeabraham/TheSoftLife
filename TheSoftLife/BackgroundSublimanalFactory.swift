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
    static var subliminalGain: Float = 0.06
    
    /// Interval between subliminals (seconds, inclusive range)
    static var subliminalIntervalRange: ClosedRange<Double> = 1.0...5.0
    
    // At the top of your BackgroundSubliminalFactory:
    static var enableLogging = false
    private static func log(_ items: Any...) {
        guard enableLogging else { return }
        print("[BackgroundSubliminalFactory]", items.map { "\($0)" }.joined(separator: " "))
    }
    
    /// Where to look for phrase clips (m4a/wav). If not found here,
    /// code will also try main bundle resources.
    static var subliminalsFolderName = "subliminals"
    
    // MARK: - Public API (mirrors SilenceFactory)
    private static var memo: [String: URL] = [:]
    // Add these near your other state vars (top of url(for:in:))
    private static var activePhrase: Phrase? = nil
    static var activeIndex: Int = 0 // how many samples already mixed for the active phrase
    
    static func url(for duration: TimeInterval, in directory: URL) -> URL? {
        let ms = max(1, Int((duration * 1000).rounded()))
        let key = "\(ms)@\(directory.standardizedFileURL.path)"
        if let u = memo[key], FileManager.default.fileExists(atPath: u.path) {
            log("Cache hit:", u.lastPathComponent)
            return u
        }
        
        let name = "subliminal-\(ms)ms.m4a"
        let outURL = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: outURL.path) {
            log("Existing file:", outURL.lastPathComponent)
            memo[key] = outURL
            return outURL
        }
        
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
            
            // Preload subliminal clips (optional)
            let phrases = enableSubliminals ? loadSubliminalFiles(sampleRate: sr) : []
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
                    } else {
                        log("Insert continuing, mixed \(mixedNow) more frames, progress \(activeIndex)/\(phrase.samples.count)")
                    }
                }
                
                // 2b) Check if a NEW insert begins inside this buffer (only if none is active)
                if enableSubliminals, activePhrase == nil, !phrases.isEmpty,
                   nextInsertFrame >= frameStart && nextInsertFrame < frameEnd
                {
                    let phrase = phrases.randomElement()!
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
                // Log category folders for sanity
                if let cats = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: [.isDirectoryKey]) {
                    let folderNames = cats.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
                    if !folderNames.isEmpty { log("Categories:", folderNames.joined(separator: ", ")) }
                }
                // RECURSIVE scan to pick up files inside each category
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
            if let p = decodeMono(url: u, targetSR: sr) {
                phrases.append(p)
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
            
            return Phrase(samples: mono, sampleRate: targetSR)
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
}

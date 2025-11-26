// swift
import Foundation
import AVFoundation

/// Builds subliminal clips from every .txt in a bundle subfolder (e.g. "subliminal_phrases").
/// Each file is treated as a category. One line = one spoken .m4a clip.
///
/// Bundle structure (example):
///   Resources/subliminal_phrases/her_focused.txt
///   Resources/subliminal_phrases/mind_focused.txt
///
/// Output structure:
///   Application Support / subliminals / <category> / 001_<slug>.m4a
///
/// Heavy work runs off the main queue (or on the provided `synthQueue`). `completion` and `progress` are called on the main queue.
final class SubliminalFolderBuilder {

    /// Turn console logging on/off globally for this builder.
    static var enableLogging = true
    private static func log(_ items: Any...) {
        guard enableLogging else { return }
        print("[SubliminalFolderBuilder]", items.map { "\($0)" }.joined(separator: " "))
    }

    struct VoiceOptions {
        var languageCode: String = "en-US"
        var voiceIdentifier: String? = nil
        var rate: Float = 0.40     // slower is nicer for subliminal
        var pitch: Float = 0.85    // slightly lower/softer
    }

    enum BuilderError: Error {
        case bundleFolderMissing(String)
        case couldNotAccessAppSupport
        case noTextFilesFound
    }

    /// Build all clips from every .txt in `bundleFolderName` inside the main bundle.
    /// - Parameters:
    ///   - bundleFolderName: e.g. "subliminal_phrases"
    ///   - overwrite: if true, regenerates files; if false, skips existing
    ///   - includeExisting: if true, existing files are included in the returned list
    ///   - backgroundQoS: background queue QoS (used when synthQueue is not provided)
    ///   - voice: TTS voice settings
    ///   - synthQueue: optional `OperationQueue` to run the entire build on (use this to serialize with foreground builds)
    ///   - progress: optional closure called on the main queue with status messages
    ///   - completion: called on main queue with all generated (and optionally existing) URLs
    static func buildFromBundleFolder(_ bundleFolderName: String = "subliminal_phrases",
                                      overwrite: Bool = false,
                                      includeExisting: Bool = true,
                                      backgroundQoS: DispatchQoS.QoSClass = .utility,
                                      voice: VoiceOptions = VoiceOptions(),
                                      synthQueue: OperationQueue? = nil,
                                      progress: ((String) -> Void)? = nil,
                                      completion: @escaping (Result<[URL], Error>) -> Void)
    {
        func sendProgress(_ s: String) {
            DispatchQueue.main.async { progress?(s) }
        }

        let work: () -> Void = {
            let t0 = CFAbsoluteTimeGetCurrent()
            log("BEGIN buildFromBundleFolder:",
                "folder=\(bundleFolderName)",
                "overwrite=\(overwrite)",
                "includeExisting=\(includeExisting)",
                "qos=\(backgroundQoS)")
            sendProgress("Starting subliminal build…")

            do {
                // Locate the folder in the bundle
                guard let folderURL = Bundle.main.url(forResource: bundleFolderName, withExtension: nil) else {
                    log("ERROR: bundle subfolder not found:", bundleFolderName)
                    throw BuilderError.bundleFolderMissing(bundleFolderName)
                }
                log("Bundle:", Bundle.main.bundlePath)
                log("Found bundle folder:", folderURL.path)

                // Find all .txt files
                let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
                let txtFiles = contents
                    .filter { $0.pathExtension.lowercased() == "txt" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }

                guard !txtFiles.isEmpty else {
                    log("ERROR: no .txt files found in", folderURL.path)
                    throw BuilderError.noTextFilesFound
                }
                log("Text files (\(txtFiles.count)):")
                for u in txtFiles { log(" •", u.lastPathComponent) }

                // Ensure Application Support / subliminals exists
                let appSup = try FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true)
                let rootOut = appSup.appendingPathComponent("subliminals", isDirectory: true)
                // Clear old output to avoid partial or invalid files
                if FileManager.default.fileExists(atPath: rootOut.path) {
                    do {
                        try FileManager.default.removeItem(at: rootOut)
                        log("Removed previous subliminals directory:", rootOut.path)
                    } catch {
                        log("WARN: Could not clear old subliminals directory:", error.localizedDescription)
                    }
                }
                try FileManager.default.createDirectory(at: rootOut, withIntermediateDirectories: true)

                log("Output root:", rootOut.path)

                let group = DispatchGroup()
                let lock = NSLock()
                var outputURLs: [URL] = []
                var firstError: Error?
                var generatedCount = 0
                var skippedCount = 0
                var queuedCount = 0

                // Process each category file
                for txt in txtFiles {
                    let category = txt.deletingPathExtension().lastPathComponent
                    let categoryOut = rootOut.appendingPathComponent(category, isDirectory: true)
                    try FileManager.default.createDirectory(at: categoryOut, withIntermediateDirectories: true)
                    log("Category:", category, "→", categoryOut.lastPathComponent)
                    sendProgress("Processing category: \(category)")

                    // Read lines
                    let raw = try String(contentsOf: txt, encoding: .utf8)
                    let lines = raw
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

                    log("  Lines to synthesize:", lines.count)
                    sendProgress("Lines to synthesize: \(lines.count) in \(category)")

                    for (idx, phrase) in lines.enumerated() {
                        let fname = String(format: "%03d_%@", idx + 1, slug(phrase))
                        let outURL = categoryOut.appendingPathComponent(fname).appendingPathExtension("m4a")

                        if FileManager.default.fileExists(atPath: outURL.path), !overwrite {
                            if includeExisting {
                                lock.lock(); outputURLs.append(outURL); lock.unlock()
                            }
                            skippedCount += 1
                            if (idx % 25) == 0 { log("  Skipping existing (sample):", outURL.lastPathComponent) }
                            continue
                        }

                        queuedCount += 1
                        if (idx % 25) == 0 {
                            log("  Queue synth:", "\"\(phrase)\"",
                                "→", outURL.lastPathComponent)
                        }
                        if queuedCount % 10 == 0 { sendProgress("Queued \(queuedCount) subliminal clips…") }

                        group.enter()

                        // TTSSynthesizer calls completion on MAIN. We rely on the DispatchGroup to wait for them below.
                        TTSSynthesizer.shared.synthesizeToFile(
                            text: phrase,
                            languageCode: voice.languageCode,
                            voiceIdentifier: voice.voiceIdentifier,
                            rate: voice.rate,
                            pitch: voice.pitch,
                            outputURL: outURL
                        ) { ok in
                            if ok {
                                lock.lock()
                                outputURLs.append(outURL)
                                generatedCount += 1
                                lock.unlock()
                                if (generatedCount % 20) == 0 {
                                    log("  Synth complete (\(generatedCount)):", outURL.lastPathComponent)
                                    sendProgress("Synthesized \(generatedCount) clips…")
                                }
                            } else if firstError == nil {
                                let err = NSError(domain: "SubliminalFolderBuilder",
                                                  code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey: "TTS write failed: \(outURL.lastPathComponent)"])
                                firstError = err
                                log("ERROR:", err.localizedDescription)
                                sendProgress("Error synthesizing: \(outURL.lastPathComponent)")
                            }
                            group.leave()
                        }
                    }
                }

                // Wait for the TTS callbacks to finish before returning from the work block.
                group.wait()

                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                log("DONE buildFromBundleFolder.",
                    "generated=\(generatedCount)",
                    "skipped=\(skippedCount)",
                    "queued=\(queuedCount)",
                    String(format: "elapsed=%.2fs", elapsed))
                sendProgress("Subliminal build complete: \(generatedCount) generated.")
                // Return results on MAIN for UI safety
                DispatchQueue.main.async {
                    if let e = firstError { completion(.failure(e)) }
                    else { completion(.success(outputURLs.sorted { $0.path < $1.path })) }
                }
            } catch {
                log("FATAL:", error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }

        // If a synthQueue is provided, run the entire build as an Operation so other work can be queued behind it.
        if let opQueue = synthQueue {
            opQueue.addOperation { work() }
        } else {
            DispatchQueue.global(qos: backgroundQoS).async { work() }
        }
    }

    /// Build all clips from every .txt in a user-chosen folder.
    /// See `buildFromBundleFolder` for explanations of `synthQueue` and `progress`.
    static func buildFromFolder(
        _ folderURL: URL,
        overwrite: Bool = false,
        includeExisting: Bool = true,
        backgroundQoS: DispatchQoS.QoSClass = .utility,
        voice: VoiceOptions = VoiceOptions(),
        synthQueue: OperationQueue? = nil,
        progress: ((String) -> Void)? = nil,
        completion: @escaping (Result<[URL], Error>) -> Void
    ) {
        func sendProgress(_ s: String) {
            DispatchQueue.main.async { progress?(s) }
        }

        let work: () -> Void = {
            let t0 = CFAbsoluteTimeGetCurrent()
            log("BEGIN buildFromFolder:", folderURL.path)
            sendProgress("Starting subliminal build from folder…")

            do {

                guard FileManager.default.fileExists(atPath: folderURL.path) else {
                    throw BuilderError.bundleFolderMissing(folderURL.path)
                }

                let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
                let txtFiles = contents.filter { $0.pathExtension.lowercased() == "txt" }

                guard !txtFiles.isEmpty else {
                    throw BuilderError.noTextFilesFound
                }

                let appSup = try FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true)
                let rootOut = appSup.appendingPathComponent("subliminals", isDirectory: true)

                // Clear old output to avoid partial or invalid files
                if FileManager.default.fileExists(atPath: rootOut.path) {
                    do {
                        try FileManager.default.removeItem(at: rootOut)
                        log("Removed previous subliminals directory:", rootOut.path)
                    } catch {
                        log("WARN: Could not clear old subliminals directory:", error.localizedDescription)
                    }
                }
                try FileManager.default.createDirectory(at: rootOut, withIntermediateDirectories: true)

                let group = DispatchGroup()
                let lock = NSLock()
                var outURLs: [URL] = []
                var firstError: Error?
                var generatedCount = 0
                var queuedCount = 0

                for txt in txtFiles {
                    let category = txt.deletingPathExtension().lastPathComponent
                    let categoryOut = rootOut.appendingPathComponent(category, isDirectory: true)
                    try FileManager.default.createDirectory(at: categoryOut, withIntermediateDirectories: true)

                    let raw = try String(contentsOf: txt, encoding: .utf8)
                    let lines = raw
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

                    sendProgress("Processing category: \(category) (\(lines.count) lines)")

                    for (idx, phrase) in lines.enumerated() {
                        let fname = String(format: "%03d_%@", idx + 1, slug(phrase))
                        let outURL = categoryOut.appendingPathComponent(fname).appendingPathExtension("m4a")

                        if FileManager.default.fileExists(atPath: outURL.path), !overwrite {
                            if includeExisting {
                                lock.lock(); outURLs.append(outURL); lock.unlock()
                            }
                            continue
                        }

                        queuedCount += 1
                        if queuedCount % 10 == 0 { sendProgress("Queued \(queuedCount) subliminal clips…") }

                        group.enter()
                        TTSSynthesizer.shared.synthesizeToFile(
                            text: phrase,
                            languageCode: voice.languageCode,
                            voiceIdentifier: voice.voiceIdentifier,
                            rate: voice.rate,
                            pitch: voice.pitch,
                            outputURL: outURL
                        ) { ok in
                            if ok {
                                lock.lock()
                                outURLs.append(outURL)
                                generatedCount += 1
                                lock.unlock()
                                if (generatedCount % 20) == 0 {
                                    log("  Synth complete (\(generatedCount)):", outURL.lastPathComponent)
                                    sendProgress("Synthesized \(generatedCount) clips…")
                                }
                            } else if firstError == nil {
                                let err = NSError(domain: "SubliminalFolderBuilder",
                                                  code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey: "TTS write failed: \(outURL.lastPathComponent)"])
                                firstError = err
                                log("ERROR:", err.localizedDescription)
                                sendProgress("Error synthesizing: \(outURL.lastPathComponent)")
                            }
                            group.leave()
                        }
                    }
                }

                group.wait()

                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                log("DONE buildFromFolder.", "elapsed=\(String(format: "%.2fs", elapsed))")
                sendProgress("Subliminal build complete: \(generatedCount) generated.")
                DispatchQueue.main.async {
                    if let e = firstError {
                        completion(.failure(e))
                    } else {
                        completion(.success(outURLs.sorted { $0.path < $1.path }))
                    }
                }

            } catch {
                log("FATAL:", error.localizedDescription)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }

        if let opQueue = synthQueue {
             opQueue.addOperation { work() }
         } else {
             DispatchQueue.global(qos: backgroundQoS).async { work() }
         }
     }


     // MARK: - Helpers

     /// Simple file-name slugger: lowercase, ascii, short, safe
     private static func slug(_ s: String) -> String {
         let lowered = s.lowercased()
         let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
         var out = lowered
             .replacingOccurrences(of: "’", with: "")
             .replacingOccurrences(of: "‘", with: "")
             .replacingOccurrences(of: "“", with: "")
             .replacingOccurrences(of: "”", with: "")
             .replacingOccurrences(of: "'", with: "")
             .replacingOccurrences(of: "\"", with: "")
             .replacingOccurrences(of: ",", with: "")
             .replacingOccurrences(of: ".", with: "")
             .replacingOccurrences(of: ":", with: "")
             .replacingOccurrences(of: ";", with: "")
             .replacingOccurrences(of: "?", with: "")
             .replacingOccurrences(of: "!", with: "")
             .replacingOccurrences(of: "/", with: "-")
             .replacingOccurrences(of: "\\", with: "-")
             .replacingOccurrences(of: "&", with: "and")
             .replacingOccurrences(of: "+", with: "plus")
             .replacingOccurrences(of: " ", with: "-")

         out.unicodeScalars.removeAll { !allowed.contains($0) }
         if out.count > 40 { out = String(out.prefix(40)) }
         if out.isEmpty { out = "clip" }
         return out
     }
 }

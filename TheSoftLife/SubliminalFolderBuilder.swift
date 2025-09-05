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
/// Heavy work runs off the main queue. Completion is called on the main queue.
final class SubliminalFolderBuilder {

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
    ///   - backgroundQoS: background queue QoS
    ///   - voice: TTS voice settings
    ///   - completion: called on main queue with all generated (and optionally existing) URLs
    static func buildFromBundleFolder(_ bundleFolderName: String = "subliminal_phrases",
                                      overwrite: Bool = false,
                                      includeExisting: Bool = true,
                                      backgroundQoS: DispatchQoS.QoSClass = .utility,
                                      voice: VoiceOptions = VoiceOptions(),
                                      completion: @escaping (Result<[URL], Error>) -> Void)
    {
        // Jump off the main queue immediately
        DispatchQueue.global(qos: backgroundQoS).async {
            do {
                // Locate the folder in the bundle
                guard let folderURL = Bundle.main.url(forResource: bundleFolderName, withExtension: nil) else {
                    throw BuilderError.bundleFolderMissing(bundleFolderName)
                }

                // Find all .txt files
                let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
                let txtFiles = contents.filter { $0.pathExtension.lowercased() == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !txtFiles.isEmpty else { throw BuilderError.noTextFilesFound }

                // Ensure Application Support / subliminals exists
                let appSup = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let rootOut = appSup.appendingPathComponent("subliminals", isDirectory: true)
                try FileManager.default.createDirectory(at: rootOut, withIntermediateDirectories: true)

                let group = DispatchGroup()
                let lock = NSLock()
                var outputURLs: [URL] = []
                var firstError: Error?

                // Process each category file
                for txt in txtFiles {
                    let category = txt.deletingPathExtension().lastPathComponent
                    let categoryOut = rootOut.appendingPathComponent(category, isDirectory: true)
                    try FileManager.default.createDirectory(at: categoryOut, withIntermediateDirectories: true)

                    // Read lines
                    let raw = try String(contentsOf: txt, encoding: .utf8)
                    let lines = raw
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

                    for (idx, phrase) in lines.enumerated() {
                        let fname = String(format: "%03d_%@", idx + 1, slug(phrase))
                        let outURL = categoryOut.appendingPathComponent(fname).appendingPathExtension("m4a")

                        if FileManager.default.fileExists(atPath: outURL.path), !overwrite {
                            if includeExisting {
                                lock.lock(); outputURLs.append(outURL); lock.unlock()
                            }
                            continue
                        }

                        group.enter()

                        // Your TTSSynthesizer completion fires on MAIN—bridge it safely.
                        TTSSynthesizer.shared.synthesizeToFile(
                            text: phrase,
                            languageCode: voice.languageCode,
                            voiceIdentifier: voice.voiceIdentifier,
                            rate: voice.rate,
                            pitch: voice.pitch,
                            outputURL: outURL
                        ) { ok in
                            // We’re now on MAIN because TTSSynthesizer calls completion on main. Hop back to bg queue:
                            DispatchQueue.global(qos: backgroundQoS).async {
                                if ok {
                                    lock.lock(); outputURLs.append(outURL); lock.unlock()
                                } else if firstError == nil {
                                    firstError = NSError(domain: "SubliminalFolderBuilder",
                                                         code: -1,
                                                         userInfo: [NSLocalizedDescriptionKey: "TTS write failed: \(outURL.lastPathComponent)"])
                                }
                                group.leave()
                            }
                        }
                    }
                }

                group.notify(queue: .global(qos: backgroundQoS)) {
                    // Return results on MAIN for UI safety
                    DispatchQueue.main.async {
                        if let e = firstError { completion(.failure(e)) }
                        else { completion(.success(outputURLs.sorted { $0.path < $1.path })) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
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

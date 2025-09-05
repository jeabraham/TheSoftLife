import Foundation
import AVFoundation

/// Reads bundled phrase lists and renders one m4a file per line using TTSSynthesizer.
/// Output layout:
///   Application Support / subliminals / <category> / <index>_<slug>.m4a
///
/// Categories expected in the app bundle (plain UTF-8, one phrase per line):
///   her_focused.txt
///   body_focused.txt
///   mind_focused.txt
///   pride_humiliation.txt
///   risk_excited.txt
///   dumbing_down.txt
///
/// Notes:
/// - Blank lines and lines starting with '#' are ignored.
/// - Voice defaults are whispery/slow; override via parameters as needed.
/// - Safe to call repeatedly; it will skip files that already exist unless `overwrite = true`.
final class SubliminalClipBuilder {

    struct VoiceOptions {
        var languageCode: String = "en-US"
        /// Pass a system voice identifier if you want a specific voice; nil uses language default.
        var voiceIdentifier: String? = nil
        /// iOS TTS "rate" ~ 0.40–0.52 is natural; go slower for subliminals.
        var rate: Float = 0.40
        /// Slightly lower pitch keeps it soft/subdued.
        var pitch: Float = 0.85
    }

    enum BuilderError: Error {
        case bundleFileMissing(String)
        case appSupportUnavailable
    }

    /// Build ALL categories found in the bundle into Application Support/subliminals.
    /// Returns URLs of generated clips (including ones that already existed if `includeExisting` is true).
    static func buildAllFromBundle(overwrite: Bool = false,
                                   includeExisting: Bool = true,
                                   voice: VoiceOptions = VoiceOptions(),
                                   completion: @escaping (Result<[URL], Error>) -> Void)
    {
        do {
            let appSup = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true)
            let rootOut = appSup.appendingPathComponent("subliminals", isDirectory: true)
            try FileManager.default.createDirectory(at: rootOut, withIntermediateDirectories: true)

            let categories = [
                "her_focused",
                "body_focused",
                "mind_focused",
                "pride_humiliation",
                "risk_excited",
                "dumbing_down"
            ]

            var allURLs: [URL] = []
            let group = DispatchGroup()

            // Serial gate to append safely
            let lock = NSLock()
            var firstError: Error?

            for cat in categories {
                guard let txtURL = Bundle.main.url(forResource: cat, withExtension: "txt") else {
                    // If a file is missing, we fail the whole run so the caller knows.
                    firstError = BuilderError.bundleFileMissing("\(cat).txt")
                    break
                }
                let catOut = rootOut.appendingPathComponent(cat, isDirectory: true)
                try FileManager.default.createDirectory(at: catOut, withIntermediateDirectories: true)

                // Load, split, sanitize
                let raw = try String(contentsOf: txtURL, encoding: .utf8)
                let lines = raw
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }

                for (idx, line) in lines.enumerated() {
                    let fname = String(format: "%03d_%@", idx + 1, slug(line))
                    let outURL = catOut.appendingPathComponent(fname).appendingPathExtension("m4a")

                    if FileManager.default.fileExists(atPath: outURL.path), !overwrite {
                        if includeExisting {
                            lock.lock(); allURLs.append(outURL); lock.unlock()
                        }
                        continue
                    }

                    group.enter()
                    TTSSynthesizer.shared.synthesizeToFile(
                        text: line,
                        languageCode: voice.languageCode,
                        voiceIdentifier: voice.voiceIdentifier,
                        rate: voice.rate,
                        pitch: voice.pitch,
                        outputURL: outURL
                    ) { ok in
                        if ok {
                            lock.lock(); allURLs.append(outURL); lock.unlock()
                        } else if firstError == nil {
                            firstError = NSError(domain: "SubliminalClipBuilder",
                                                 code: -1,
                                                 userInfo: [NSLocalizedDescriptionKey: "TTS write failed for \(outURL.lastPathComponent)"])
                        }
                        group.leave()
                    }
                }
            }

            // Finish callback
            group.notify(queue: .main) {
                if let e = firstError { completion(.failure(e)) }
                else { completion(.success(allURLs.sorted { $0.path < $1.path })) }
            }
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - Helpers

    /// Lowercase, ASCII-only file slugs; keep short for path friendliness.
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

// VoiceSettingsView.swift

import SwiftUI
import AVFoundation
import UIKit

struct VoiceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: PlayerVM

    // Precompute to help the type-checker
    private var langs: [String] { vm.languagesAvailable }
    private var voices: [AVSpeechSynthesisVoice] { vm.voicesForSelectedLanguage }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Language")) {
                    Picker("Language", selection: Binding<String>(
                        get: { vm.languageCode },
                        set: { newLang in
                            vm.languageCode = newLang
                            // choose best voice for the language
                            let best = vm.voices
                                .filter { $0.language == newLang }
                                .sorted { (vmQualityRank($0.quality), $0.name) < (vmQualityRank($1.quality), $1.name) }
                                .first
                            vm.voiceIdentifier = best?.identifier
                        }
                    )) {
                        ForEach(langs, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                }

                Section(header: Text("Voice")) {
                    Picker("Voice", selection: Binding<String>(
                        get: { vm.voiceIdentifier ?? "" },
                        set: { vm.voiceIdentifier = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(voices, id: \.identifier) { v in
                            Text("\(v.name) — \(v.language)\(voiceQualitySuffix(v.quality))")
                                .tag(v.identifier)
                        }
                    }
                }

                Section(header: Text("Speech Tuning")) {
                    HStack {
                        Text("Rate")
                        Slider(value: Binding(get: { Double(vm.rate) },
                                              set: { vm.rate = Float($0) }),
                               in: 0.1...0.6)
                        Text(String(format: "%.2f", vm.rate)).monospacedDigit()
                    }
                    HStack {
                        Text("Pitch")
                        Slider(value: Binding(get: { Double(vm.pitch) },
                                              set: { vm.pitch = Float($0) }),
                               in: 0.5...2.0)
                        Text(String(format: "%.2f", vm.pitch)).monospacedDigit()
                    }
                }

                Section {
                    Button("Get more voices…") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Text("Install voices in Settings → Accessibility → Spoken Content → Voices.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Voice & Speech")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                vm.reloadVoices()
                vm.refreshDefaultVoiceIfNeeded()
            }
        }
    }
}

// helpers (same as in your ContentView today)
private func voiceQualitySuffix(_ q: AVSpeechSynthesisVoiceQuality) -> String {
    switch q {
    case .premium:  return " (Premium)"
    case .enhanced: return " (Enhanced)"
    default:        return ""
    }
}
private func vmQualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
    switch q {
    case .premium:  return 0
    case .enhanced: return 1
    default:        return 2
    }
}

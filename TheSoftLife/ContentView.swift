import SwiftUI
import UIKit
import AVFoundation   // <-- add this


struct ContentView: View {
    @EnvironmentObject var vm: PlayerVM
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Folder: \(vm.folderURL?.lastPathComponent ?? "—")")
                    Text("Now Playing: \(vm.currentFileName)")
                    Text(vm.statusText).font(.subheadline).foregroundColor(.secondary)
                    ProgressView(value: Double(vm.processedFiles), total: Double(max(vm.totalFiles, 1)))
                }
                .font(.headline)
                
                HStack(spacing: 12) {
                    Button("Choose Folder") { presentFolderPicker() }
                    Button(vm.isPlaying ? "Pause" : "Resume") { vm.pauseResume() }
                        .disabled(!vm.canControlPlayback)
                    
                    Button("Stop") { vm.stopTapped() }
                        .disabled(!vm.canControlPlayback)
                    
                }
                
                Divider()
                settings
                Spacer()
            }
            .padding()
            .navigationTitle("The Soft Life")
            .alert("Stop playback?", isPresented: $vm.showStopConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Stop", role: .destructive) { vm.stopConfirmed() }
            } message: {
                Text("This will clear the queue.")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    RoutePicker().frame(width: 28, height: 28)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Start") { vm.startSession() }
                        .disabled(vm.folderURL == nil)
                }
            }
        }
    }
    
    @ViewBuilder
    private var settings: some View {
        // Precompute to help the type-checker
        let langs: [String] = vm.languagesAvailable
        let voices = vm.voicesForSelectedLanguage   // voices filtered for vm.languageCode
        
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.title3).bold()
            
            // LANGUAGE
            Picker("Language", selection: Binding<String>(
                get: { vm.languageCode },
                set: { newLang in
                    vm.languageCode = newLang
                    // pick best voice for this language (highest quality first)
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
            .pickerStyle(.menu)
            
            // VOICE
            Picker("Voice", selection: Binding<String>(
                get: { vm.voiceIdentifier ?? "" },
                set: { newID in vm.voiceIdentifier = newID.isEmpty ? nil : newID }
            )) {
                ForEach(voices, id: \.identifier) { v in
                    // Display name only; we store v.identifier
                    Text("\(v.name) — \(v.language)\(voiceQualitySuffix(v.quality))")
                        .tag(v.identifier)
                }
            }
            .pickerStyle(.menu)
            
            // RATE
            HStack {
                Text("Rate")
                Slider(value: Binding<Double>(
                    get: { Double(vm.rate) },
                    set: { vm.rate = Float($0) }
                ), in: 0.1...0.6)
                Text(String(format: "%.2f", vm.rate)).monospacedDigit()
            }
            
            // PITCH
            HStack {
                Text("Pitch")
                Slider(value: Binding<Double>(
                    get: { Double(vm.pitch) },
                    set: { vm.pitch = Float($0) }
                ), in: 0.5...2.0)
                Text(String(format: "%.2f", vm.pitch)).monospacedDigit()
            }
            
            // SETTINGS LINK
            Button("Get more voices…") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.body)
            
            Text("Install voices in Settings → Accessibility → Spoken Content → Voices.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        // Attach .onReceive to the container, not the Button
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            vm.reloadVoices()
            vm.refreshDefaultVoiceIfNeeded()
        }
    }
    
    
    private func presentFolderPicker() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.keyWindow?.rootViewController else { return }
        vm.pickFolder(presenter: root)
    }

   
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first(where: { $0.isKeyWindow }) }
}

// Tiny helpers (put in the same file, outside the View body)
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

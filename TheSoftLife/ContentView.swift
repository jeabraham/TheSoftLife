import SwiftUI
import UIKit
import AVFoundation   // <-- add this

fileprivate func formatRange(_ lo: Double, _ hi: Double) -> String {
    func fmt(_ s: Double) -> String {
        if s >= 120 { return "\(Int(s/60))m" }
        if s >= 60  { return "1m \(Int(s.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(s))s"
    }
    return "\(fmt(lo))–\(fmt(hi))"
}

// ContentView.swift

struct ContentView: View {
    @EnvironmentObject var vm: PlayerVM
    @State private var showVoiceSheet = false   // <- add this

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Folder: \(vm.folderURL?.lastPathComponent ?? "—")")
                    Text("Now Playing: \(vm.currentFileName)")
                    Text(vm.statusText).font(.subheadline).foregroundColor(.secondary)
                    ProgressView(value: Double(vm.processedFiles), total: Double(max(vm.totalFiles, 1)))
                }
                .font(.headline)                // … your header / status UI …

                HStack(spacing: 12) {
                    Button("Choose Folder") { presentFolderPicker() }
                    Button(vm.isPlaying ? "Pause" : "Resume") { vm.pauseResume() }
                        .disabled(!vm.canControlPlayback)
                    Button("Stop") { vm.stopTapped() }
                        .disabled(!vm.canControlPlayback)
                }

                Divider()
                randomControls
                Spacer()
                
                Button("Voice & Speech…") { showVoiceSheet = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)

                Spacer()
            }
            .padding()
            .navigationTitle("The Soft Life")
            .sheet(isPresented: $showVoiceSheet) {
                VoiceSettingsView()
                    .environmentObject(vm) // pass the same VM
            }
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
                    Button(vm.randomLoopEnabled
                           ? "Start Random (\(Int(vm.minDelaySec))–\(Int(vm.maxDelaySec))s)"
                           : "Start") {
                        vm.startSession()
                    }
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

    @ViewBuilder
    private var randomControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Random loop").font(.title3).bold()
                Spacer()
                Toggle("", isOn: $vm.randomLoopEnabled)
                    .labelsHidden()
            }

            Group {
                HStack {
                    Text("Min silence")
                    Slider(value: $vm.minDelaySec, in: 1...600, step: 1)
                    Text("\(Int(vm.minDelaySec))s").monospacedDigit()
                }
                HStack {
                    Text("Max silence")
                    Slider(value: $vm.maxDelaySec, in: 1...600, step: 1)
                    Text("\(Int(vm.maxDelaySec))s").monospacedDigit()
                }
            }
            .disabled(!vm.randomLoopEnabled)

            // Keep min ≤ max automatically (gentle nudge)
            .onChange(of: vm.minDelaySec) { newMin in
                if newMin > vm.maxDelaySec { vm.maxDelaySec = newMin }
            }
            .onChange(of: vm.maxDelaySec) { newMax in
                if newMax < vm.minDelaySec { vm.minDelaySec = newMax }
            }

            // Quick presets
            HStack(spacing: 8) {
                Group {
                    Button("5–20s")  { vm.minDelaySec = 5;   vm.maxDelaySec = 20 }
                    Button("30–90s") { vm.minDelaySec = 30;  vm.maxDelaySec = 90 }
                    Button("2–5m")   { vm.minDelaySec = 120; vm.maxDelaySec = 300 }
                }
                .buttonStyle(.bordered)
                .disabled(!vm.randomLoopEnabled)
            }

            // Tiny status line
            Text(vm.randomLoopEnabled
                 ? "Random gaps: \(formatRange(vm.minDelaySec, vm.maxDelaySec))"
                 : "Sequential mode")
            .font(.footnote)
            .foregroundColor(.secondary)
        }
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


enum AppAudioSettings {
    private static let key = "backgroundsBehindFiles"

    static var backgroundsBehindFiles: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}


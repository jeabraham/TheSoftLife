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
    @State private var showVoiceSheet = false
    @State private var showInterruptionsSheet = false

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Folder: \(vm.folderURL?.lastPathComponent ?? "—")")
                    Text("Now Playing: \(vm.currentFileName)")
                    Text(vm.statusText).font(.subheadline).foregroundColor(.secondary)
                    if !vm.activeTasks.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Active Tasks:")
                                .font(.subheadline).bold()
                            ForEach(vm.activeTasks, id: \.self) { task in
                                Text("• \(task)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
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
                randomControls
                
                Spacer()
                
                // Subliminal backgrounds toggle stays on main page
                Toggle("Subliminal backgrounds", isOn: Binding(
                    get: { AppAudioSettings.subliminalBackgrounds },
                    set: { newValue in
                        AppAudioSettings.subliminalBackgrounds = newValue
                        print("[Settings] subliminalBackgrounds →", newValue)
                        if newValue {
                            DispatchQueue.global(qos: .background).async {
                                rebuildSubliminalsIfNeeded(folderURL: vm.folderURL, vm: vm)
                            }
                        }
                    }
                ))

                Spacer()
            }
            .padding()
            .navigationTitle("The Soft Life")
            .sheet(isPresented: $showVoiceSheet) {
                VoiceSettingsView()
                    .environmentObject(vm)
            }
            .sheet(isPresented: $showInterruptionsSheet) {
                InterruptionSettingsView()
                    .environmentObject(vm)
            }
            .alert("Stop playback?", isPresented: $vm.showStopConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Stop", role: .destructive) { vm.stopConfirmed() }
            } message: {
                Text("This will clear the queue.")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            showVoiceSheet = true
                        } label: {
                            Label("Voice & Speech", systemImage: "waveform")
                        }
                        Button {
                            showInterruptionsSheet = true
                        } label: {
                            Label("Interruptions", systemImage: "bell.badge")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .imageScale(.large)
                    }
                }
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
        .onChange(of: vm.folderURL) { newFolder in
            rebuildSubliminalsIfNeeded(folderURL: newFolder, vm: vm)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            vm.updateStatus()
            vm.syncPlaybackState()
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
            //vm.refreshDefaultVoiceIfNeeded()
        }
    }
    
    
    private func presentFolderPicker() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.keyWindow?.rootViewController else { return }
        vm.pickFolder(presenter: root)
    }
    
    struct InterruptionSettingsView: View {
        @EnvironmentObject var vm: PlayerVM
        @Environment(\.dismiss) private var dismiss
        @AppStorage(InterruptionSettings.autoResumeKey) private var autoResume: Bool = false
        @AppStorage(InterruptionSettings.duckOthersKey) private var duckOthers: Bool = false
        
        var body: some View {
            NavigationView {
                Form {
                    Section {
                        Toggle("Auto-resume after interruption", isOn: $autoResume)
                    } footer: {
                        Text("Automatically resume playback after phone calls, Siri, or other audio interruptions end.")
                    }
                    
                    Section {
                        Toggle("Duck audio instead of pausing", isOn: $duckOthers)
                            .onChange(of: duckOthers) { _ in
                                vm.reconfigureAudioSession()
                            }
                    } footer: {
                        Text("Lower volume when other apps play audio instead of pausing playback.")
                    }
                }
                .navigationTitle("Interruptions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
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

// Replace the free function with this updated implementation:
// Swift
private func rebuildSubliminalsIfNeeded(folderURL: URL?, vm: PlayerVM) {
    guard AppAudioSettings.subliminalBackgrounds else { return }
    guard let base = folderURL else { return }

    BackgroundSubliminalFactory.clearCachedPhrases()
    print("[Builder] Cleared cached subliminal phrases")

    // Helper to forward builder progress into the VM status on the main thread
    let progress: (String) -> Void = { msg in
        DispatchQueue.main.async {
            vm.statusText = msg
        }
    }

    // Centralized main-thread setter to avoid publishing from background threads
    func setStatus(_ text: String) {
        DispatchQueue.main.async {
            vm.statusText = text
        }
    }

    // Use the VM's synth queue if available so foreground work queues behind these builds.
    let synthQueue = vm.synthQueue

    let userSub = base.appendingPathComponent("subliminals", isDirectory: true)
    if FileManager.default.fileExists(atPath: userSub.path) {
        print("[Builder] Found user subliminals folder → rebuilding audio cache…")
        setStatus("Rebuilding user subliminals…")
        SubliminalFolderBuilder.buildFromFolder(
            userSub,
            synthQueue: synthQueue,
            progress: progress
        ) { result in
            switch result {
            case .success(let urls):
                print("[Builder] Built \(urls.count) subliminal clips from user folder.")
                setStatus("Built \(urls.count) subliminal clips.")
            case .failure(let error):
                print("[Builder] Failed to build user subliminals:", error.localizedDescription)
                setStatus("Subliminal build failed: \(error.localizedDescription)")
            }
        }
    } else {
        print("[Builder] No /subliminals folder → rebuilding from bundle.")
        setStatus("Rebuilding bundle subliminals…")
        SubliminalFolderBuilder.buildFromBundleFolder(
            synthQueue: synthQueue,
            progress: progress
        ) { result in
            switch result {
            case .success(let urls):
                print("[Builder] Rebuilt bundle subliminals (\(urls.count) clips).")
                setStatus("Rebuilt bundle subliminals (\(urls.count)).")
            case .failure(let error):
                print("[Builder] Bundle rebuild failed:", error.localizedDescription)
                setStatus("Bundle rebuild failed: \(error.localizedDescription)")
            }
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
    private static let key = "subliminalBackgrounds"

    static var subliminalBackgrounds: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Settings for handling audio interruptions (phone calls, Siri, etc.)
enum InterruptionSettings {
    static let autoResumeKey = "interruptionAutoResume"
    static let duckOthersKey = "interruptionDuckOthers"
    
    /// When true, automatically resume playback after an interruption ends
    static var autoResume: Bool {
        get { UserDefaults.standard.bool(forKey: autoResumeKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoResumeKey) }
    }
    
    /// When true, duck (lower volume) instead of pausing when other audio plays
    static var duckOthers: Bool {
        get { UserDefaults.standard.bool(forKey: duckOthersKey) }
        set { UserDefaults.standard.set(newValue, forKey: duckOthersKey) }
    }
}


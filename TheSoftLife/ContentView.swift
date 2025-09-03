import SwiftUI
import UIKit

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
            .navigationTitle("TheSoftLife")
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.title3).bold()

            Picker("Language", selection: Binding(get: { vm.languageCode }, set: { newLang in
                vm.languageCode = newLang
                vm.voiceIdentifier = vm.voicesForSelectedLanguage.first?.identifier
            })) {
                ForEach(vm.languagesAvailable, id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }
            .pickerStyle(.menu)

            Picker("Voice", selection: Binding(get: { vm.voiceIdentifier ?? "" }, set: { newID in
                vm.voiceIdentifier = newID.isEmpty ? nil : newID
            })) {
                ForEach(vm.availableVoices, id: \.identifier) { voice in
                    Text("\(voice.name) — \(voice.language)")
                        .tag(voice.identifier)
                }
            }
            .pickerStyle(.menu)

            // Rate & pitch sliders unchanged
            HStack {
                Text("Rate")
                Slider(value: Binding(get: { Double(vm.rate) }, set: { vm.rate = Float($0) }), in: 0.1...0.6)
                Text(String(format: "%.2f", vm.rate)).monospacedDigit()
            }
            HStack {
                Text("Pitch")
                Slider(value: Binding(get: { Double(vm.pitch) }, set: { vm.pitch = Float($0) }), in: 0.5...2.0)
                Text(String(format: "%.2f", vm.pitch)).monospacedDigit()
            }

            // Get more voices (opens Settings for the device; no deep link to the Voices page exists publicly)
            Button("Get more voices…") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.body)

            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                vm.reloadVoices()
                vm.refreshDefaultVoiceIfNeeded()
            }

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

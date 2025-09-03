
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
                }
                .font(.headline)

                HStack(spacing: 12) {
                    Button("Choose Folder") { presentFolderPicker() }
                    Button(vm.isPlaying ? "Pause" : "Resume") { vm.pauseResume() }
                        .disabled(vm.folderURL == nil)
                    Button("Stop") { vm.stopTapped() }
                        .disabled(vm.folderURL == nil)
                }

                Divider()
                settings
                Spacer()
            }
            .padding()
            .navigationTitle("TheSoftLife")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Start") { vm.startSession() }
                        .disabled(vm.folderURL == nil)
                }
            }
            .alert("Stop playback?", isPresented: $vm.showStopConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Stop", role: .destructive) { vm.stopConfirmed() }
            } message: {
                Text("This will clear the queue.")
            }
        }
    }

    @ViewBuilder
    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.title3).bold()
            HStack {
                Text("Rate")
                Slider(value: Binding(get: { Double(vm.rate) }, set: { vm.rate = Float($0) }),
                       in: 0.3...0.6)
                Text(String(format: "%.2f", vm.rate))
                    .monospacedDigit()
            }
            HStack {
                Text("Pitch")
                Slider(value: Binding(get: { Double(vm.pitch) }, set: { vm.pitch = Float($0) }),
                       in: 0.5...2.0)
                Text(String(format: "%.2f", vm.pitch))
                    .monospacedDigit()
            }
            TextField("Language (e.g. en-CA)", text: Binding(
                get: { vm.languageCode },
                set: { vm.languageCode = $0 }
            ))
            TextField("Voice Identifier (optional)", text: Binding(
                get: { vm.voiceIdentifier ?? "" },
                set: { vm.voiceIdentifier = $0.isEmpty ? nil : $0 }
            ))
            .textInputAutocapitalization(.never)
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

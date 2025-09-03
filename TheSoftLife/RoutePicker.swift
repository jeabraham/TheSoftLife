import SwiftUI
import AVKit

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView(frame: .zero)
        v.prioritizesVideoDevices = false   // prioritize audio targets (headphones)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

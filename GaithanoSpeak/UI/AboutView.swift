import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.primary)
            Text("Gaithano Speak")
                .font(.title2.weight(.semibold))
            Text("Local-first voice dictation for macOS")
                .font(.callout).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            VStack(spacing: 4) {
                Text("Speech recognition by NVIDIA Parakeet TDT (CC-BY-4.0)")
                Text("via FluidAudio · On-device formatting by Apple Intelligence")
            }
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 380, height: 260)
    }
}

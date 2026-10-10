import SwiftUI

/// Press and hold to talk; release to send. While held, `liveText` shows what's being heard.
struct HoldToTalkButton: View {
    @Binding var liveText: String
    let onFinish: (String) -> Void

    @State private var voice = AppleSpeechTranscriber()
    @State private var pressing = false
    @State private var error: String?

    var body: some View {
        Image(systemName: voice.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
            .font(.system(size: 34))
            .symbolEffect(.variableColor.iterative, isActive: voice.isRecording)
            .foregroundStyle(voice.isRecording ? Theme.accent : .secondary)
            .scaleEffect(voice.isRecording ? 1.2 : 1)
            .animation(.snappy, value: voice.isRecording)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        begin()
                    }
                    .onEnded { _ in
                        pressing = false
                        finish()
                    }
            )
            .onChange(of: voice.transcript) { _, text in
                if voice.isRecording { liveText = text }
            }
            .sensoryFeedback(.impact, trigger: voice.isRecording)
            .alert("Can't listen", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .accessibilityLabel("Hold to talk to your agent")
    }

    private func begin() {
        Task {
            do {
                try await voice.start()
                // Released before the mic was ready.
                if !pressing { finish() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func finish() {
        Task {
            guard voice.isRecording else { return }
            let text = await voice.stop()
            liveText = ""
            if !text.isEmpty { onFinish(text) }
        }
    }
}

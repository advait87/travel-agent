import AVFoundation
import Speech

/// Turns speech into text. Apple's recognizer today; a Wispr Flow transcriber can conform later
/// (record the same audio, send it to their API) without touching the UI.
@MainActor
protocol SpeechTranscriber: AnyObject {
    /// Live transcript while recording.
    var transcript: String { get }
    var isRecording: Bool { get }
    func start() async throws
    /// Stops recording and returns the final text.
    func stop() async -> String
}

enum VoiceInputError: LocalizedError {
    case notAuthorized, unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Allow microphone and speech recognition in Settings to talk to your agent."
        case .unavailable: "Speech recognition isn't available right now."
        }
    }
}

/// Hold-to-talk dictation with Apple's Speech framework (no key needed, punctuation included).
@MainActor @Observable
final class AppleSpeechTranscriber: SpeechTranscriber {
    private(set) var transcript = ""
    private(set) var isRecording = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN")) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finished: CheckedContinuation<Void, Never>?

    func start() async throws {
        guard !isRecording else { return }
        guard await Self.authorize() else { throw VoiceInputError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw VoiceInputError.unavailable }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        transcript = ""

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if done {
                    self.finished?.resume()
                    self.finished = nil
                }
            }
        }
    }

    func stop() async -> String {
        guard isRecording else { return transcript }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // Wait briefly for the final result, then give up and use what we have.
        await withCheckedContinuation { continuation in
            finished = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.finished?.resume()
                self.finished = nil
            }
        }
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

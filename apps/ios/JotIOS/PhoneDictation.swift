@preconcurrency import AVFoundation
@preconcurrency import Speech
import Observation

/// Speech recognition is required to remain on the device; unsupported locales fail explicitly.
@MainActor @Observable
final class PhoneDictation {
    enum State { case idle, preparing, recording, finishing }
    private(set) var state = State.idle
    var onMessage: (@MainActor ([String: Any]) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var transcript = ""
    private var recognitionCompleted = false
    private var hasTap = false
    private var finishTimeout: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    var active: Bool { state != .idle }

    func start() {
        guard !active else { return }
        let token = UUID()
        generation = token
        state = .preparing
        onMessage?(["version": 1, "type": "dictationState", "status": "downloading", "message": "Preparing dictation…"])
        Task {
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard generation == token else { return }
            guard speech else { fail("Allow speech access for Jot in Settings to use dictation."); return }
            let microphone = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard generation == token else { return }
            guard microphone else {
                fail("Allow microphone access for Jot in Settings to use dictation.")
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition else {
                fail("On-device dictation isn’t available for this language. Enable your language’s dictation in Settings and try again.")
                return
            }
            self.recognizer = recognizer
            do { try beginRecognition(recognizer, token: token) }
            catch { fail("Dictation couldn’t start. Check that your microphone is available and try again.") }
        }
    }

    private func beginRecognition(_ recognizer: SFSpeechRecognizer, token: UUID) throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audio.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request
        transcript = ""
        recognitionCompleted = false
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        let sink = PhoneSpeechAudioSink(request: request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        hasTap = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let text {
                    self.transcript = text
                    self.onMessage?(["version": 1, "type": "dictationPartial", "text": text])
                }
                if self.state == .finishing && (final || failed) {
                    self.commit()
                } else if final {
                    self.recognitionCompleted = true
                    // Recognition can finish automatically. Preserve the preview until Keep or Cancel.
                    self.stopAudio()
                } else if failed {
                    self.fail("Dictation was interrupted. Please try again; your saved jot is unchanged.")
                }
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: audio, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.active else { return }
                    self.fail("Dictation was interrupted. Your saved jot is unchanged.")
                }
            }
        engine.prepare()
        try engine.start()
        state = .recording
        onMessage?(["version": 1, "type": "dictationState", "status": "recording"])
    }

    func finish() {
        guard state == .recording else { return }
        if recognitionCompleted { commit(); return }
        state = .finishing
        onMessage?(["version": 1, "type": "dictationState", "status": "transcribing"])
        stopAudio()
        request?.endAudio()
        let token = generation
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.generation == token, self.state == .finishing else { return }
            self.commit()
        }
    }

    func cancel() {
        guard active else { return }
        cleanup()
        onMessage?(["version": 1, "type": "dictationState", "status": "idle"])
    }

    func interrupted() {
        guard active else { return }
        fail("Dictation stopped when Jot left the screen. Your saved jot is unchanged.")
    }

    private func commit() {
        let text = transcript
        cleanup()
        onMessage?(["version": 1, "type": "dictationResult", "text": text])
        onMessage?(["version": 1, "type": "dictationState", "status": "idle"])
    }

    private func fail(_ message: String) {
        cleanup()
        onMessage?(["version": 1, "type": "dictationState", "status": "error", "message": message])
        onError?(message)
    }

    private func stopAudio() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
    }

    private func cleanup() {
        generation = UUID()
        finishTimeout?.cancel()
        finishTimeout = nil
        stopAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        recognizer = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        transcript = ""
    }
}

private final class PhoneSpeechAudioSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}

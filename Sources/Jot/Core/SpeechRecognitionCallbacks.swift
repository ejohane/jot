@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Only immutable values cross from Speech's callback queue to the UI actor.
struct SpeechRecognitionUpdate: Sendable {
    let text: String?
    let isFinal: Bool
    let failed: Bool
}

enum SpeechRecognitionCallbacks {
    // Construct callbacks outside MainActor isolation. Both frameworks invoke
    // them on their own queues, even when recording starts on the main actor.
    static func recognition(
        deliver: @escaping @MainActor @Sendable (SpeechRecognitionUpdate) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let update = SpeechRecognitionUpdate(
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal == true,
                failed: error != nil
            )
            Task { @MainActor in deliver(update) }
        }
    }
}

final class SpeechAudioSink: @unchecked Sendable {
    private let append: @Sendable (AVAudioPCMBuffer) -> Void

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        append = { buffer in request.append(buffer) }
    }

    init(append: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.append = append
    }

    func callback() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in append(buffer) }
    }
}

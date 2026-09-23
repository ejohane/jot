import AppKit
import AVFoundation
import CryptoKit
import Foundation

enum VoiceFailure: LocalizedError {
    case microphoneDenied
    case recordingFailed
    case helperMissing
    case invalidModel
    case modelUnavailable
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Enable it for Jot in System Settings → Privacy & Security → Microphone."
        case .recordingFailed: "Jot could not start recording from the microphone."
        case .helperMissing: "This Jot build does not contain the voice transcription helper."
        case .invalidModel: "The downloaded voice model did not pass its integrity check. Try again."
        case .modelUnavailable: "Jot could not download the voice model from GitHub. Check your connection and try again."
        case .transcriptionFailed: "Jot could not transcribe this recording. Try again."
        }
    }
}

actor VoiceModelStore {
    static let shared = VoiceModelStore()
    static let downloadURL = URL(string: "https://github.com/ejohane/jot-voice-models/releases/download/v1/ggml-small.en.bin")!
    static let sha256 = "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"

    private var verifiedURL: URL?

    func prepare() async throws -> URL {
        if let verifiedURL { return verifiedURL }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jot/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let destination = support.appendingPathComponent("ggml-small.en-v1.bin")
        if FileManager.default.fileExists(atPath: destination.path) {
            if try Self.matchesChecksum(destination) {
                verifiedURL = destination
                return destination
            }
            try FileManager.default.removeItem(at: destination)
        }
        let (download, response): (URL, URLResponse)
        do {
            (download, response) = try await URLSession.shared.download(from: Self.downloadURL)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceFailure.modelUnavailable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceFailure.modelUnavailable }
        guard try Self.matchesChecksum(download) else { throw VoiceFailure.invalidModel }
        try FileManager.default.moveItem(at: download, to: destination)
        verifiedURL = destination
        return destination
    }

    private static func matchesChecksum(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }
}

@MainActor
final class VoiceDictation {
    enum State: String { case idle, downloading, recording, transcribing, error }

    var onStateChange: ((State, String?) -> Void)?
    var onResult: ((String) -> Void)?
    private(set) var state: State = .idle
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var modelURL: URL?
    private var preparation: Task<Void, Never>?

    func toggle() {
        switch state {
        case .idle, .error:
            start()
        case .downloading:
            preparation?.cancel()
            preparation = nil
            update(.idle)
        case .recording:
            stop()
        case .transcribing:
            break
        }
    }

    private func start() {
        update(.downloading, message: "Preparing voice model (~465 MB on first use)…")
        preparation = Task {
            do {
                let model = try await VoiceModelStore.shared.prepare()
                try Task.checkCancellation()
                modelURL = model
                guard await microphoneAllowed() else { throw VoiceFailure.microphoneDenied }
                try Task.checkCancellation()
                let audio = FileManager.default.temporaryDirectory
                    .appendingPathComponent("jot-voice-\(UUID().uuidString).wav")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                let recorder = try AVAudioRecorder(url: audio, settings: settings)
                guard recorder.prepareToRecord(), recorder.record() else { throw VoiceFailure.recordingFailed }
                self.recorder = recorder
                recordingURL = audio
                update(.recording, message: "Recording… press the microphone to finish")
            } catch is CancellationError {
                update(.idle)
            } catch {
                update(.error, message: error.localizedDescription)
            }
            preparation = nil
        }
    }

    private func stop() {
        guard let recorder, let audio = recordingURL, let model = modelURL else { return }
        recorder.stop()
        self.recorder = nil
        recordingURL = nil
        update(.transcribing, message: "Transcribing locally…")
        Task {
            defer { try? FileManager.default.removeItem(at: audio) }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.transcribe(audio: audio, model: model)
                }.value
                if !result.isEmpty { onResult?(result) }
                update(.idle)
            } catch {
                update(.error, message: error.localizedDescription)
            }
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func update(_ state: State, message: String? = nil) {
        self.state = state
        onStateChange?(state, message)
    }

    nonisolated private static func transcribe(audio: URL, model: URL) throws -> String {
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("jot-whisper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw VoiceFailure.helperMissing }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("jot-transcript-\(UUID().uuidString)")
        let log = output.appendingPathExtension("log")
        defer {
            try? FileManager.default.removeItem(at: output.appendingPathExtension("txt"))
            try? FileManager.default.removeItem(at: log)
        }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["-m", model.path, "-f", audio.path, "-l", "en", "-otxt", "-of", output.path, "-nt", "-t", "4"]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VoiceFailure.transcriptionFailed }
        return try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

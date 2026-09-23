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
    case audioOverloaded

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Enable it for Jot in System Settings → Privacy & Security → Microphone."
        case .recordingFailed: "Jot could not start recording from the microphone."
        case .helperMissing: "This Jot build does not contain the voice transcription helper."
        case .invalidModel: "The downloaded voice model did not pass its integrity check. Try again."
        case .modelUnavailable: "Jot could not download the voice model from GitHub. Check your connection and try again."
        case .transcriptionFailed: "Jot could not transcribe this recording. Try again."
        case .audioOverloaded: "Dictation could not keep up with the microphone. Try again."
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
        defer { try? FileManager.default.removeItem(at: download) }
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
    var onPartial: ((String) -> Void)?
    var onResult: ((String) -> Void)?
    private(set) var state: State = .idle
    private(set) var currentPartial = ""
    private var engine: AVAudioEngine?
    private var sink: VoiceAudioSink?
    private var worker: Process?
    private var workerInput: FileHandle?
    private var workerOutput: FileHandle?
    private var workerLog: URL?
    private var outputBuffer = Data()
    private var finalPhrases: [String] = []
    private var generation = 0
    private var preparation: Task<Void, Never>?

    func toggle() {
        switch state {
        case .idle, .error: start()
        case .downloading: cancel()
        case .recording: stop()
        case .transcribing: break
        }
    }

    func cancel() {
        generation += 1
        preparation?.cancel()
        preparation = nil
        stopEngine()
        workerOutput?.readabilityHandler = nil
        if worker?.isRunning == true { worker?.terminate() }
        cleanup()
        update(.idle)
    }

    private func start() {
        generation += 1
        let currentGeneration = generation
        update(.downloading, message: "Preparing voice model (~465 MB on first use)…")
        preparation = Task {
            do {
                let model = try await VoiceModelStore.shared.prepare()
                try Task.checkCancellation()
                guard await microphoneAllowed() else { throw VoiceFailure.microphoneDenied }
                try Task.checkCancellation()
                guard currentGeneration == generation else { return }
                try startWorker(model: model, generation: currentGeneration)
                update(.downloading, message: "Loading local voice model…")
            } catch is CancellationError {
                if currentGeneration == generation { update(.idle) }
            } catch {
                if currentGeneration == generation { fail(error) }
            }
            preparation = nil
        }
    }

    private func stop() {
        guard engine != nil else { return }
        stopEngine()
        update(.transcribing, message: "Finishing locally…")
    }

    private func stopEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        sink?.finish()
        sink = nil
    }

    private func startWorker(model: URL, generation: Int) throws {
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("jot-whisper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw VoiceFailure.helperMissing }
        let input = Pipe()
        let output = Pipe()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("jot-whisper-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["-m", model.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = logHandle
        do { try process.run() }
        catch {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: log)
            throw VoiceFailure.transcriptionFailed
        }
        try? logHandle.close()
        worker = process
        workerInput = input.fileHandleForWriting
        workerOutput = output.fileHandleForReading
        workerLog = log
        finalPhrases = []
        currentPartial = ""
        outputBuffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                if data.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self, generation == self.generation else { return }
                        if self.state != .idle && self.state != .error { self.fail(VoiceFailure.transcriptionFailed) }
                    }
                } else {
                    self.consume(data)
                }
            }
        }
    }

    private func startCapture() throws {
        guard let input = workerInput else { throw VoiceFailure.transcriptionFailed }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        let captureGeneration = generation
        let sink = try VoiceAudioSink(inputFormat: format, handle: input) { [weak self] failure in
            Task { @MainActor [weak self] in
                guard let self, captureGeneration == self.generation else { return }
                self.fail(failure)
            }
        }
        self.sink = sink
        engine.inputNode.installTap(onBus: 0, bufferSize: 1600, format: format) { buffer, _ in
            sink.receive(buffer)
        }
        do { try engine.start() }
        catch {
            engine.inputNode.removeTap(onBus: 0)
            throw VoiceFailure.recordingFailed
        }
        self.engine = engine
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = String(decoding: outputBuffer[..<end], as: UTF8.self)
            outputBuffer.removeSubrange(...end)
            guard line.count >= 2, line.dropFirst().first == "\t" else { continue }
            let value = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            switch line.first {
            case "R":
                do {
                    try startCapture()
                    update(.recording, message: "Listening locally… press the microphone to finish")
                } catch { fail(error); return }
            case "P":
                currentPartial = (finalPhrases + [value]).filter { !$0.isEmpty }.joined(separator: " ")
                onPartial?(currentPartial)
            case "F":
                if !value.isEmpty { finalPhrases.append(value) }
                currentPartial = finalPhrases.joined(separator: " ")
                onPartial?(currentPartial)
            case "D":
                let result = finalPhrases.joined(separator: " ")
                if !result.isEmpty { onResult?(result) }
                cleanup()
                update(.idle)
            case "E": fail(VoiceFailure.audioOverloaded)
            default: break
            }
        }
    }

    private func fail(_ error: any Error) {
        generation += 1
        stopEngine()
        workerOutput?.readabilityHandler = nil
        if worker?.isRunning == true { worker?.terminate() }
        cleanup()
        update(.error, message: error.localizedDescription)
    }

    private func cleanup() {
        workerOutput?.readabilityHandler = nil
        workerOutput = nil
        workerInput = nil
        worker = nil
        if let workerLog { try? FileManager.default.removeItem(at: workerLog) }
        workerLog = nil
        outputBuffer = Data()
        finalPhrases = []
        currentPartial = ""
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
}

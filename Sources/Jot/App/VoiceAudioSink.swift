import AVFoundation
import Foundation

private final class VoiceInputProvider: @unchecked Sendable {
    private var input: AVAudioPCMBuffer?
    init(_ input: AVAudioPCMBuffer) { self.input = input }
    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let input else {
            status.pointee = .noDataNow
            return nil
        }
        self.input = nil
        status.pointee = .haveData
        return input
    }
}

// Microphone callbacks never wait for inference. If the helper cannot accept
// five seconds of audio, fail instead of silently dropping spoken words.
final class VoiceAudioSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "Jot.voice.audio")
    private let lock = NSLock()
    private let onLevel: @Sendable (Float) -> Void
    private let onFailure: @Sendable (VoiceFailure) -> Void
    private var pendingBytes = 0
    private var lastLevelSent: UInt64 = 0
    private var closed = false

    init(inputFormat: AVAudioFormat, handle: FileHandle, onLevel: @escaping @Sendable (Float) -> Void, onFailure: @escaping @Sendable (VoiceFailure) -> Void) throws {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoiceFailure.recordingFailed
        }
        self.outputFormat = outputFormat
        self.converter = converter
        self.handle = handle
        self.onLevel = onLevel
        self.onFailure = onFailure
    }

    // AVAudio calls the tap on its own queue. Construct its callback outside
    // VoiceDictation's MainActor isolation so Swift does not assert at runtime.
    func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat) {
        inputNode.installTap(onBus: 0, bufferSize: 1600, format: format) { [self] buffer, _ in
            receive(buffer)
        }
    }

    func receive(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            onFailure(.recordingFailed)
            return
        }
        let provider = VoiceInputProvider(input)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            provider.take(status)
        }
        guard error == nil, let samples = converted.floatChannelData?[0] else {
            onFailure(.recordingFailed)
            return
        }
        let count = Int(converted.frameLength) * MemoryLayout<Float>.size
        guard count > 0 else { return }
        let data = Data(bytes: samples, count: count)
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if closed { lock.unlock(); return }
        if pendingBytes + count > 16_000 * MemoryLayout<Float>.size * 5 {
            closed = true
            lock.unlock()
            onFailure(.audioOverloaded)
            return
        }
        pendingBytes += count
        let publishLevel = now &- lastLevelSent >= 50_000_000
        if publishLevel { lastLevelSent = now }
        lock.unlock()
        if publishLevel {
            var power: Double = 0
            for index in 0..<Int(converted.frameLength) {
                let sample = Double(samples[index])
                power += sample * sample
            }
            let rms = sqrt(power / Double(converted.frameLength))
            let level = Float(max(0, min(1, (20 * log10(max(rms, 0.00001)) + 55) / 40)))
            onLevel(level)
        }
        queue.async { [self] in
            do { try handle.write(contentsOf: data) }
            catch { onFailure(.transcriptionFailed) }
            lock.lock()
            pendingBytes -= count
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        queue.async { [self] in try? handle.close() }
    }
}

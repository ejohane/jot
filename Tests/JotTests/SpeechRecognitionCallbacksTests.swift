import AVFoundation
import Speech
import XCTest
@testable import Jot

final class SpeechRecognitionCallbacksTests: XCTestCase {
    @MainActor
    func testAudioCallbackCreatedOnMainActorAcceptsBackgroundBuffers() async {
        let received = expectation(description: "Audio reaches the request on its callback queue")
        let sink = SpeechAudioSink { buffer in
            dispatchPrecondition(condition: .notOnQueue(.main))
            XCTAssertEqual(buffer.frameLength, 32)
            XCTAssertEqual(buffer.floatChannelData?[0][0], 0.25)
            received.fulfill()
        }
        let callback = sink.callback()
        DispatchQueue.global().async {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
            buffer.frameLength = 32
            buffer.floatChannelData?[0][0] = 0.25
            callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        }
        await fulfillment(of: [received], timeout: 2)
    }

    @MainActor
    func testRecognitionCallbackCreatedOnMainActorDeliversBackgroundErrorOnMainActor() async {
        let delivered = expectation(description: "Recognition error returns to the UI actor")
        let callback = SpeechRecognitionCallbacks.recognition { update in
            MainActor.assertIsolated()
            XCTAssertNil(update.text)
            XCTAssertFalse(update.isFinal)
            XCTAssertTrue(update.failed)
            delivered.fulfill()
        }
        DispatchQueue.global().async {
            callback(nil, NSError(domain: "SpeechRecognitionCallbacksTests", code: 1))
        }
        await fulfillment(of: [delivered], timeout: 2)
    }
}

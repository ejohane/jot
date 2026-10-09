import Foundation
import XCTest
import WebKit
@testable import Jot

@MainActor
final class AttachmentLoadingTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("attachments/photo.png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, file)
    }

    func testLocalAttachmentStreamsBytesAndCompletes() async throws {
        let (root, _) = try fixture()
        let handler = LocalResourceSchemeHandler()
        handler.configureAttachmentRoot(root)
        let task = RecordingAttachmentTask()
        let webView = WKWebView()
        handler.webView(webView, start: task)
        for _ in 0..<100 where !task.finished && task.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(task.finished)
        XCTAssertNil(task.failure)
        XCTAssertEqual(task.bytes, Data([1, 2, 3]))
        XCTAssertEqual(task.response?.mimeType, "image/png")
    }

    func testStoppedAttachmentCannotCallWebKitTaskAgain() async throws {
        let (root, _) = try fixture()
        let handler = LocalResourceSchemeHandler()
        handler.configureAttachmentRoot(root)
        let task = RecordingAttachmentTask()
        let webView = WKWebView()
        handler.webView(webView, start: task)
        handler.webView(webView, stop: task)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(task.finished)
        XCTAssertNil(task.failure)
        XCTAssertNil(task.response)
        XCTAssertTrue(task.bytes.isEmpty)
    }
}

private final class RecordingAttachmentTask: NSObject, WKURLSchemeTask {
    let request = URLRequest(url: URL(string: "jot://attachment/attachments/photo.png")!)
    var bytes = Data()
    var response: URLResponse?
    var failure: (any Error)?
    var finished = false
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { bytes.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: any Error) { failure = error }
}

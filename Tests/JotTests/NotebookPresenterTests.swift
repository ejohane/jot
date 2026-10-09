import Foundation
import XCTest
@testable import Jot

@MainActor
final class NotebookPresenterTests: XCTestCase {
    func testCoordinatedExternalWriteNotifiesNotebookPresenter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var notifications = 0
        let presenter = NotebookPresenter(root: root) { notifications += 1 }
        defer { presenter.stop() }
        let file = root.appendingPathComponent("incoming.md")
        try await Task.detached { try LocalJotFileSystem().writeAtomically(Data("Incoming phone note".utf8), to: file) }.value
        for _ in 0..<200 where notifications == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data("Incoming phone note".utf8))
    }
}

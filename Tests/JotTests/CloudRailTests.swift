import Foundation
import XCTest
@testable import Jot

final class CloudRailTests: XCTestCase {
    func testCloudOnlyJotIsNavigableAndDownloadReplacesPlaceholder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("2026/10/03/06-00-00-000--incoming.md")
        let index = NoteRailIndex(root: root)
        let pending = await index.refresh(discoveredURLs: [url])
        XCTAssertEqual(pending?.map(\.id), ["incoming"])
        XCTAssertTrue(pending?.first?.excerpt.contains("iCloud") == true)
        let entry = await index.entry(id: "incoming")
        XCTAssertEqual(entry?.path, url.path)
        try LocalJotFileSystem().writeAtomically(Data("From the phone".utf8), to: url)
        let arrived = await index.refresh(discoveredURLs: [url])
        XCTAssertEqual(arrived?.count, 1)
        XCTAssertEqual(arrived?.first?.excerpt, "From the phone")
    }
}

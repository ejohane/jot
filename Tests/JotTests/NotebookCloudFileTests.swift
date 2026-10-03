import Foundation
import XCTest
@testable import Jot

final class NotebookCloudFileTests: XCTestCase {
    func testLocalFileNeedsNoCloudAccess() async throws {
        try await NotebookCloudFile.prepare(URL(fileURLWithPath: "/local/note.md"), availability: { _ in .local },
            request: { _ in XCTFail("Local notes must not request an iCloud download") },
            pause: { XCTFail("Local notes must not wait for a download") })
    }

    func testCurrentCloudCopyNeedsNoRepeatedRefreshRequest() async throws {
        try await NotebookCloudFile.prepare(URL(fileURLWithPath: "/cloud/note.md"), availability: { _ in .current },
            request: { _ in XCTFail("A current cloud copy must not create a refresh notification loop") },
            pause: { XCTFail("Current copies must open immediately") })
    }

    func testCachedCopyCanOpenOffline() async throws {
        try await NotebookCloudFile.prepare(URL(fileURLWithPath: "/cloud/note.md"), availability: { _ in .cached },
            request: { _ in throw URLError(.notConnectedToInternet) },
            pause: { XCTFail("Offline cached notes must remain immediately available") })
    }

    func testDownloadBecomesAvailableBeforeOpening() async throws {
        let fixture = DownloadFixture()
        try await NotebookCloudFile.prepare(URL(fileURLWithPath: "/cloud/note.md"),
            availability: { _ in fixture.availability }, request: { _ in fixture.requested = true },
            pause: { fixture.complete() })
        XCTAssertTrue(fixture.requested)
        XCTAssertEqual(fixture.availability, .cached)
    }

    func testRemoteOnlyCopyCannotOpenAfterTimeout() async {
        do {
            try await NotebookCloudFile.prepare(URL(fileURLWithPath: "/cloud/note.md"), availability: { _ in .remote },
                request: { _ in }, attempts: 2, pause: {})
            XCTFail("An unavailable cloud note must not be opened as a missing file")
        } catch is NotebookCloudFile.DownloadError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationDoesNotOpenRemoteCopy() async {
        do {
            try await NotebookCloudFile.prepare(URL(fileURLWithPath: "/cloud/note.md"), availability: { _ in .remote },
                request: { _ in }, pause: { throw CancellationError() })
            XCTFail("Cancelled download must not advance to opening")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class DownloadFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var downloaded = false
    private var didRequest = false
    var requested: Bool {
        get { lock.withLock { didRequest } }
        set { lock.withLock { didRequest = newValue } }
    }
    var availability: NotebookCloudFile.Availability { lock.withLock { downloaded ? .cached : .remote } }
    func complete() { lock.withLock { if didRequest { downloaded = true } } }
}

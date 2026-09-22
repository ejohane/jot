import Foundation
import XCTest
@testable import Jot

final class PerformanceTests: XCTestCase {
    func testLocalAtomicWriteP95Budgets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JotPerformance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalJotFileSystem()
        let allocator = JotPathAllocator()
        var allocationSamples: [Double] = []

        for index in 0..<1_000 {
            let start = ContinuousClock.now
            let allocation = allocator.allocate(root: root, id: ULID.make())
            try fileSystem.writeAtomically(Data("sample \(index)".utf8), to: allocation.fileURL)
            allocationSamples.append(milliseconds(since: start))
        }

        let activeURL = root.appendingPathComponent("active.md")
        try fileSystem.writeAtomically(Data(), to: activeURL)
        var replacementSamples: [Double] = []
        for index in 0..<1_000 {
            let start = ContinuousClock.now
            try fileSystem.writeAtomically(Data("replacement \(index)".utf8), to: activeURL)
            replacementSamples.append(milliseconds(since: start))
        }

        let allocationP95 = percentile95(allocationSamples)
        let replacementP95 = percentile95(replacementSamples)
        print("PERF-002 allocation_p95_ms=\(allocationP95) replacement_p95_ms=\(replacementP95) samples=1000")
        XCTAssertLessThanOrEqual(allocationP95, 250)
        XCTAssertLessThanOrEqual(replacementP95, 250)
    }

    @MainActor
    func testCapturePathDoesNotEnumerateArchive() async {
        let fileSystem = InMemoryFileSystem()
        let writer = JotWriter(rootURL: URL(fileURLWithPath: "/Jots"), fileSystem: fileSystem) { _ in }
        await writer.receive(
            EditorSnapshot(revision: 1, text: "capture", selection: .start, viewport: .top)
        )
        XCTAssertEqual(fileSystem.recoveryCallCount, 0)
        XCTAssertEqual(fileSystem.writeCount, 1)
    }

    func testLargeDateShardedArchiveHasNoMaterialCapturePenalty() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JOT_RUN_SCALE_TESTS"] == "1",
            "Set JOT_RUN_SCALE_TESTS=1 for the required 100,000-jot scale verification."
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JotScale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalJotFileSystem()
        let allocator = JotPathAllocator()

        let baseline = try captureP95(root: root.appendingPathComponent("baseline"), samples: 250, allocator: allocator, fileSystem: fileSystem)

        for shard in 0..<100 {
            let year = 2000 + shard / 84
            let month = (shard / 7) % 12 + 1
            let day = shard % 28 + 1
            let directory = root
                .appendingPathComponent("archive", isDirectory: true)
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<1_000 {
                let url = directory.appendingPathComponent(String(format: "%04d.md", index))
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
        }

        let scaled = try captureP95(root: root.appendingPathComponent("scaled"), samples: 250, allocator: allocator, fileSystem: fileSystem)
        let ratio = scaled / max(baseline, 0.001)
        print("PERF-004 baseline_p95_ms=\(baseline) scaled_p95_ms=\(scaled) ratio=\(ratio) archive_jots=100000")
        XCTAssertLessThanOrEqual(ratio, 1.10)
    }

    private func captureP95(
        root: URL,
        samples: Int,
        allocator: JotPathAllocator,
        fileSystem: LocalJotFileSystem
    ) throws -> Double {
        var timings: [Double] = []
        for index in 0..<samples {
            let start = ContinuousClock.now
            let allocation = allocator.allocate(root: root, id: ULID.make())
            try fileSystem.writeAtomically(Data("\(index)".utf8), to: allocation.fileURL)
            timings.append(milliseconds(since: start))
        }
        return percentile95(timings)
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private func percentile95(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
    }
}

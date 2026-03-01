import CryptoKit
import Foundation
import XCTest
@testable import DustServe
import DustCore

final class DownloadManagerTests: XCTestCase {

    func testDownloadCompletesFileAtExpectedPath() async throws {
        let modelId = "s2-t1"
        let data = makeData(size: 3 * 1_048_576)
        let descriptor = makeDescriptor(id: modelId, data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let recorder = EventRecorder()
        let stateStore = ModelStateStore()
        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(data: data, chunkSize: 1_048_576),
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: Int64(data.count) * 3),
            baseDirectory: tempDirectory,
            eventEmitter: recorder.record
        )

        await manager.download(descriptor).value

        let finalFile = tempDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
            .appendingPathComponent("\(modelId).bin", isDirectory: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalFile.path))
        XCTAssertEqual(try Data(contentsOf: finalFile), data)
        XCTAssertEqual(stateStore.status(for: descriptor.id), .ready)
    }

    func testSha256VerificationPasses() async {
        let data = makeData(size: 3 * 1_048_576)
        let descriptor = makeDescriptor(id: "s2-t2", data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let recorder = EventRecorder()
        let stateStore = ModelStateStore()
        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(data: data),
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: Int64(data.count) * 3),
            baseDirectory: tempDirectory,
            eventEmitter: recorder.record
        )

        await manager.download(descriptor).value

        XCTAssertEqual(stateStore.status(for: descriptor.id), .ready)
        XCTAssertFalse(recorder.failedErrorCodes().contains("verificationFailed"))
    }

    func testSha256MismatchDeletesPartFile() async {
        let data = makeData(size: 2 * 1_048_576)
        var descriptor = makeDescriptor(id: "s2-t3", data: data)
        descriptor = DustModelDescriptor(
            id: descriptor.id,
            name: descriptor.name,
            format: descriptor.format,
            sizeBytes: descriptor.sizeBytes,
            version: descriptor.version,
            url: descriptor.url,
            sha256: String(repeating: "0", count: 64),
            quantization: descriptor.quantization,
            metadata: descriptor.metadata
        )
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let recorder = EventRecorder()
        let stateStore = ModelStateStore()
        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(data: data),
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: Int64(data.count) * 3),
            baseDirectory: tempDirectory,
            eventEmitter: recorder.record
        )

        await manager.download(descriptor).value

        let partFile = tempDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent("\(descriptor.id).part", isDirectory: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile.path))

        guard case .failed(let error) = stateStore.status(for: descriptor.id) else {
            return XCTFail("Expected failed status")
        }

        guard case .verificationFailed(let detail) = error else {
            return XCTFail("Expected verificationFailed error")
        }
        XCTAssertNotNil(detail)

        XCTAssertEqual(recorder.eventCount(named: "modelFailed"), 1)
        XCTAssertEqual(recorder.failedErrorCodes(), ["verificationFailed"])
    }

    func testInsufficientDiskSpaceRejected() async {
        let data = makeData(size: 1_024)
        let descriptor = makeDescriptor(id: "s2-t4", data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let dataSource = MockDownloadDataSource(data: data)
        let stateStore = ModelStateStore()
        let manager = DownloadManager(
            dataSource: dataSource,
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: 0),
            baseDirectory: tempDirectory,
            eventEmitter: { _, _ in }
        )

        await manager.download(descriptor).value

        XCTAssertEqual(dataSource.downloadCallCount, 0)
        guard case .failed(let error) = stateStore.status(for: descriptor.id) else {
            return XCTFail("Expected failed status")
        }

        guard case .storageFull(let detail) = error else {
            return XCTFail("Expected storageFull error")
        }
        XCTAssertNotNil(detail)
    }

    func testSizeDisclosureBeforeProgress() async {
        let data = makeData(size: 3 * 1_048_576)
        let descriptor = makeDescriptor(id: "s2-t5", data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let recorder = EventRecorder()
        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(data: data, chunkSize: 1_048_576),
            stateStore: ModelStateStore(),
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: Int64(data.count) * 3),
            baseDirectory: tempDirectory,
            eventEmitter: recorder.record
        )

        await manager.download(descriptor).value

        let eventNames = recorder.eventNames()
        guard let sizeIndex = eventNames.firstIndex(of: "sizeDisclosure"),
              let progressIndex = eventNames.firstIndex(of: "modelProgress") else {
            return XCTFail("Expected sizeDisclosure and modelProgress events")
        }

        XCTAssertLessThan(sizeIndex, progressIndex)
    }

    func testProgressMonotonicallyIncreasing() async {
        let data = makeData(size: 5 * 1_048_576)
        let descriptor = makeDescriptor(id: "s2-t6", data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let recorder = EventRecorder()
        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(data: data, chunkSize: 1_048_576),
            stateStore: ModelStateStore(),
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: Int64(data.count) * 3),
            baseDirectory: tempDirectory,
            eventEmitter: recorder.record
        )

        await manager.download(descriptor).value

        let progressValues = recorder.progressValues()
        XCTAssertGreaterThanOrEqual(progressValues.count, 3)

        for index in 1..<progressValues.count {
            XCTAssertGreaterThan(progressValues[index], progressValues[index - 1])
        }
    }

    func testStatusTransitionsCorrectOrder() async {
        let data = Data([0x2A])
        let descriptor = makeDescriptor(id: "s2-t7", data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let transitionRecorder = StatusTransitionRecorder()
        let stateStore = ModelStateStore { modelId, status in
            if modelId == descriptor.id {
                transitionRecorder.record(status: status)
            }
        }

        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(data: data, chunkSize: 1),
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: 1_024),
            baseDirectory: tempDirectory,
            eventEmitter: { _, _ in }
        )

        await manager.download(descriptor).value

        XCTAssertEqual(
            transitionRecorder.labels(),
            ["downloading(0)", "downloading(>0)", "verifying", "ready"]
        )
    }

    func testConcurrentDownloadsIdempotent() async {
        let data = makeData(size: 2 * 1_048_576)
        let descriptor = makeDescriptor(id: "s2-t8", data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let dataSource = MockDownloadDataSource(
            data: data,
            chunkSize: 1_048_576,
            delayPerChunkNanoseconds: 2_000_000
        )
        let recorder = EventRecorder()
        let manager = DownloadManager(
            dataSource: dataSource,
            stateStore: ModelStateStore(),
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: Int64(data.count) * 3),
            baseDirectory: tempDirectory,
            eventEmitter: recorder.record
        )

        async let first: Void = manager.download(descriptor).value
        async let second: Void = manager.download(descriptor).value
        _ = await (first, second)

        XCTAssertEqual(dataSource.downloadCallCount, 1)
        XCTAssertEqual(recorder.eventCount(named: "modelReady"), 1)
    }

    func testCancelDownloadRemovesPartFileAndResetsStatus() async throws {
        let modelId = "s3-t4"
        let data = makeData(size: 3 * 1_048_576)
        let descriptor = makeDescriptor(id: modelId, data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let stateStore = ModelStateStore()
        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(
                data: data,
                chunkSize: 1_048_576,
                delayPerChunkNanoseconds: 20_000_000
            ),
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: Int64(data.count) * 3),
            baseDirectory: tempDirectory,
            eventEmitter: { _, _ in }
        )

        let task = manager.download(descriptor)
        try await Task.sleep(nanoseconds: 25_000_000)
        manager.cancelDownload(modelId: modelId)
        await task.value

        let partFile = tempDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
            .appendingPathComponent("\(modelId).part", isDirectory: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile.path))
        XCTAssertEqual(stateStore.status(for: modelId), .notLoaded)
    }

    func testWifiOnlyBlocksCellularDownload() async {
        let data = makeData(size: 1_024)
        let descriptor = makeDescriptor(id: "s3-t5", data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let dataSource = MockDownloadDataSource(data: data)
        let stateStore = ModelStateStore()
        let manager = DownloadManager(
            dataSource: dataSource,
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: false),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: 10_000),
            baseDirectory: tempDirectory,
            eventEmitter: { _, _ in }
        )

        await manager.download(descriptor).value

        XCTAssertEqual(dataSource.downloadCallCount, 0)
        guard case .failed(let error) = stateStore.status(for: descriptor.id) else {
            return XCTFail("Expected failed status")
        }
        guard case .networkPolicyBlocked = error else {
            return XCTFail("Expected networkPolicyBlocked error")
        }
    }

    func testWifiOnlyAllowsWifiDownload() async {
        let data = makeData(size: 1_024)
        let descriptor = makeDescriptor(id: "s3-t6", data: data)
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let stateStore = ModelStateStore()
        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(data: data, chunkSize: 512),
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: 10_000),
            baseDirectory: tempDirectory,
            eventEmitter: { _, _ in }
        )

        await manager.download(descriptor).value

        XCTAssertEqual(stateStore.status(for: descriptor.id), .ready)
    }

    func testStalePartFileCleanedOnLaunch() throws {
        let modelId = "s3-t7"
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let modelDirectory = tempDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let partFile = modelDirectory.appendingPathComponent("\(modelId).part", isDirectory: false)
        FileManager.default.createFile(atPath: partFile.path, contents: Data([0x01]))

        let stateStore = ModelStateStore()
        stateStore.setStatus(.downloading(progress: 0.5), for: modelId)

        let manager = DownloadManager(
            dataSource: MockDownloadDataSource(data: Data()),
            stateStore: stateStore,
            networkPolicyProvider: MockNetworkPolicyProvider(allowed: true),
            diskSpaceProvider: MockDiskSpaceProvider(bytesAvailable: 10_000),
            baseDirectory: tempDirectory,
            eventEmitter: { _, _ in }
        )

        manager.cleanupStalePartFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile.path))
        XCTAssertEqual(stateStore.status(for: modelId), .notLoaded)
    }

    private func makeDescriptor(id: String, data: Data) -> DustModelDescriptor {
        DustModelDescriptor(
            id: id,
            name: "Test Model \(id)",
            format: .gguf,
            sizeBytes: Int64(data.count),
            version: "1.0.0",
            url: "https://example.com/\(id).bin",
            sha256: sha256(of: data)
        )
    }

    private func makeData(size: Int) -> Data {
        Data((0..<size).map { UInt8($0 % 251) })
    }

    private func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return url
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var progresses: [Float] = []
    private var failedCodes: [String] = []

    func record(name: String, payload: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        names.append(name)

        if name == "modelProgress" {
            if let progress = payload["progress"] as? Float {
                progresses.append(progress)
            } else if let progress = payload["progress"] as? Double {
                progresses.append(Float(progress))
            }
        }

        if name == "modelFailed",
           let error = payload["error"] as? [String: Any],
           let code = error["code"] as? String {
            failedCodes.append(code)
        }
    }

    func eventNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    func progressValues() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return progresses
    }

    func failedErrorCodes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return failedCodes
    }

    func eventCount(named name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return names.filter { $0 == name }.count
    }
}

private final class StatusTransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(status: DustModelStatus) {
        lock.lock()
        defer { lock.unlock() }
        values.append(label(for: status))
    }

    func labels() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    private func label(for status: DustModelStatus) -> String {
        switch status {
        case .notLoaded:
            return "notLoaded"
        case .downloading(let progress):
            return progress == 0 ? "downloading(0)" : "downloading(>0)"
        case .verifying:
            return "verifying"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        case .unloading:
            return "unloading"
        }
    }
}

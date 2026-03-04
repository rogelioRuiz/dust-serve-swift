import CryptoKit
import Foundation
import DustCore

public final class DownloadManager: @unchecked Sendable {
    private static let progressEventIntervalBytes: Int64 = 1_048_576

    private let dataSource: DownloadDataSource
    private let stateStore: ModelStateStore
    private let networkPolicyProvider: NetworkPolicyProvider
    private let diskSpaceProvider: DiskSpaceProvider
    private let baseDirectory: URL
    private let eventEmitter: (String, [String: Any]) -> Void
    private let fileManager: FileManager
    private let lock = NSLock()
    private var activeDownloads: [String: ActiveDownload] = [:]

    public init(
        dataSource: DownloadDataSource,
        stateStore: ModelStateStore,
        networkPolicyProvider: NetworkPolicyProvider,
        diskSpaceProvider: DiskSpaceProvider,
        baseDirectory: URL,
        eventEmitter: @escaping (String, [String: Any]) -> Void,
        fileManager: FileManager = .default
    ) {
        self.dataSource = dataSource
        self.stateStore = stateStore
        self.networkPolicyProvider = networkPolicyProvider
        self.diskSpaceProvider = diskSpaceProvider
        self.baseDirectory = baseDirectory
        self.eventEmitter = eventEmitter
        self.fileManager = fileManager
    }

    @discardableResult
    public func download(_ descriptor: DustModelDescriptor) -> Task<Void, Never> {
        guard let urlString = descriptor.url, let url = URL(string: urlString) else {
            return failImmediately(
                for: descriptor,
                error: .downloadFailed(detail: "Model descriptor is missing a valid download URL")
            )
        }

        guard let expectedHash = descriptor.sha256?.lowercased(), !expectedHash.isEmpty else {
            return failImmediately(
                for: descriptor,
                error: .verificationFailed(detail: "Model descriptor is missing a SHA-256 checksum")
            )
        }

        lock.lock()
        if let existing = activeDownloads[descriptor.id] {
            if !existing.isFinished, let existingTask = existing.task {
                lock.unlock()
                return existingTask
            }
            activeDownloads.removeValue(forKey: descriptor.id)
        }

        let entry = ActiveDownload(url: url)
        let task = Task {
            await Task.yield()
            do {
                try await runDownload(descriptor: descriptor, url: url, expectedHash: expectedHash)
            } catch {
                handleFailure(for: descriptor, error: error)
            }
            finishDownload(for: descriptor.id, entry: entry)
        }
        entry.task = task
        activeDownloads[descriptor.id] = entry
        lock.unlock()

        return task
    }

    public func cancelDownload(modelId: String) {
        lock.lock()
        let activeDownload = activeDownloads[modelId]
        lock.unlock()

        guard let activeDownload else { return }
        activeDownload.task?.cancel()
        dataSource.cancel(url: activeDownload.url)
    }

    private func runDownload(
        descriptor: DustModelDescriptor,
        url: URL,
        expectedHash: String
    ) async throws {
        guard networkPolicyProvider.isDownloadAllowed() else {
            throw DustCoreError.networkPolicyBlocked(
                detail: "Current connection does not satisfy the active network policy"
            )
        }

        let availableBytes = max(diskSpaceProvider.availableBytes(at: baseDirectory), 0)
        let requiredBytes = descriptor.sizeBytes > (Int64.max / 2)
            ? Int64.max
            : max(descriptor.sizeBytes, 0) * 2
        guard availableBytes >= requiredBytes else {
            throw DustCoreError.storageFull(
                detail: "Available bytes: \(availableBytes), required bytes: \(requiredBytes)"
            )
        }

        let modelDirectory = baseDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(descriptor.id, isDirectory: true)
        try fileManager.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let partFileURL = modelDirectory.appendingPathComponent("\(descriptor.id).part", isDirectory: false)
        let finalFileURL = modelDirectory.appendingPathComponent("\(descriptor.id).bin", isDirectory: false)

        if fileManager.fileExists(atPath: partFileURL.path) {
            try fileManager.removeItem(at: partFileURL)
        }

        stateStore.setStatus(.downloading(progress: 0), for: descriptor.id)

        let (preflight, chunks) = try await dataSource.download(from: url)
        let disclosedSize = max(preflight.contentLength ?? descriptor.sizeBytes, 0)
        eventEmitter("sizeDisclosure", [
            "modelId": descriptor.id,
            "sizeBytes": disclosedSize,
        ])

        fileManager.createFile(atPath: partFileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: partFileURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        var totalBytesReceived: Int64 = 0
        var lastProgressEventBytes: Int64 = 0
        let progressDenominator = max(max(disclosedSize, descriptor.sizeBytes), 1)

        for try await chunk in chunks {
            try Task.checkCancellation()

            if !chunk.data.isEmpty {
                hasher.update(data: chunk.data)
                try fileHandle.write(contentsOf: chunk.data)
            }

            totalBytesReceived = chunk.totalBytesReceived
            let progress = min(Float(totalBytesReceived) / Float(progressDenominator), 1)
            stateStore.setStatus(.downloading(progress: progress), for: descriptor.id)

            if shouldEmitProgress(
                currentBytes: totalBytesReceived,
                lastEmittedBytes: lastProgressEventBytes
            ) {
                emitProgress(
                    modelId: descriptor.id,
                    progress: progress,
                    bytesDownloaded: totalBytesReceived,
                    totalBytes: disclosedSize > 0 ? disclosedSize : nil
                )
                lastProgressEventBytes = totalBytesReceived
            }
        }

        if totalBytesReceived > lastProgressEventBytes {
            let progress = min(Float(totalBytesReceived) / Float(progressDenominator), 1)
            emitProgress(
                modelId: descriptor.id,
                progress: progress,
                bytesDownloaded: totalBytesReceived,
                totalBytes: disclosedSize > 0 ? disclosedSize : nil
            )
        }

        try fileHandle.synchronize()
        stateStore.setStatus(.verifying, for: descriptor.id)

        let actualHash = hexDigest(hasher.finalize())
        guard actualHash == expectedHash else {
            throw DustCoreError.verificationFailed(
                detail: "Expected \(expectedHash), received \(actualHash)"
            )
        }

        if fileManager.fileExists(atPath: finalFileURL.path) {
            try fileManager.removeItem(at: finalFileURL)
        }

        try fileManager.moveItem(at: partFileURL, to: finalFileURL)
        stateStore.updateState(for: descriptor.id) { state in
            state.status = .ready
            state.filePath = finalFileURL.path
        }
        eventEmitter("modelReady", [
            "modelId": descriptor.id,
            "path": finalFileURL.path,
        ])
    }

    private func handleFailure(for descriptor: DustModelDescriptor, error: Error) {
        cleanupPartialFile(for: descriptor.id)

        if error is CancellationError {
            stateStore.setStatus(.notLoaded, for: descriptor.id)
            return
        }

        let mlCoreError: DustCoreError
        if let error = error as? DustCoreError {
            mlCoreError = error
        } else {
            mlCoreError = .downloadFailed(detail: error.localizedDescription)
        }

        stateStore.setStatus(.failed(error: mlCoreError), for: descriptor.id)
        eventEmitter("modelFailed", [
            "modelId": descriptor.id,
            "error": mlCoreError.toDict(),
        ])
    }

    public func cleanupStalePartFiles() {
        let modelsDirectory = baseDirectory.appendingPathComponent("models", isDirectory: true)
        guard let modelDirectories = try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for modelDirectory in modelDirectories {
            let modelId = modelDirectory.lastPathComponent
            guard let fileURLs = try? fileManager.contentsOfDirectory(
                at: modelDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let partFiles = fileURLs.filter { $0.pathExtension == "part" }
            guard !partFiles.isEmpty else { continue }

            for partFile in partFiles {
                try? fileManager.removeItem(at: partFile)
            }

            let finalFileURL = modelDirectory.appendingPathComponent("\(modelId).bin", isDirectory: false)
            if !fileManager.fileExists(atPath: finalFileURL.path) {
                stateStore.setStatus(.notLoaded, for: modelId)
            }
        }
    }

    private func failImmediately(
        for descriptor: DustModelDescriptor,
        error: DustCoreError
    ) -> Task<Void, Never> {
        stateStore.setStatus(.failed(error: error), for: descriptor.id)
        eventEmitter("modelFailed", [
            "modelId": descriptor.id,
            "error": error.toDict(),
        ])
        return Task {}
    }

    private func cleanupPartialFile(for modelId: String) {
        let partFileURL = baseDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
            .appendingPathComponent("\(modelId).part", isDirectory: false)

        guard fileManager.fileExists(atPath: partFileURL.path) else { return }
        try? fileManager.removeItem(at: partFileURL)
    }

    private func finishDownload(for modelId: String, entry: ActiveDownload) {
        lock.lock()
        entry.isFinished = true
        if activeDownloads[modelId] === entry {
            activeDownloads.removeValue(forKey: modelId)
        }
        lock.unlock()
    }

    private func shouldEmitProgress(currentBytes: Int64, lastEmittedBytes: Int64) -> Bool {
        currentBytes > lastEmittedBytes
            && (currentBytes - lastEmittedBytes) >= Self.progressEventIntervalBytes
    }

    private func emitProgress(
        modelId: String,
        progress: Float,
        bytesDownloaded: Int64,
        totalBytes: Int64?
    ) {
        var payload: [String: Any] = [
            "modelId": modelId,
            "progress": progress,
            "bytesDownloaded": bytesDownloaded,
        ]
        if let totalBytes {
            payload["totalBytes"] = totalBytes
        }
        eventEmitter("modelProgress", payload)
    }

    private func hexDigest(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class ActiveDownload {
    let url: URL
    var task: Task<Void, Never>?
    var isFinished = false

    init(url: URL) {
        self.url = url
    }
}

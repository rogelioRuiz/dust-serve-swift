import CryptoKit
import Foundation
import DustCore

// MARK: - Manifest types for multi-file model downloads (e.g. MLX)

struct ManifestFileEntry: Codable, Sendable {
    let filename: String
    let url: String
    let sha256: String?
    let sizeBytes: Int64
}

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
    private var pendingReconnections: [String: AsyncThrowingStream<DownloadChunk, Error>] = [:]

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
        let manifest = parseManifest(from: descriptor)

        if manifest == nil {
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

        // Manifest-based multi-file download (e.g. MLX models)
        let manifestEntries = manifest!
        let placeholderURL = URL(string: manifestEntries[0].url)!

        lock.lock()
        if let existing = activeDownloads[descriptor.id] {
            if !existing.isFinished, let existingTask = existing.task {
                lock.unlock()
                return existingTask
            }
            activeDownloads.removeValue(forKey: descriptor.id)
        }

        let entry = ActiveDownload(url: placeholderURL)
        let task = Task {
            await Task.yield()
            do {
                try await runManifestDownload(descriptor: descriptor, manifest: manifestEntries)
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

        let (preflight, chunks): (DownloadPreflightInfo, AsyncThrowingStream<DownloadChunk, Error>)
        if let bgEngine = dataSource as? BackgroundDownloadEngine {
            (preflight, chunks) = try await bgEngine.download(from: url, modelId: descriptor.id)
        } else {
            (preflight, chunks) = try await dataSource.download(from: url)
        }
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
        var receivedFileURL: URL?

        for try await chunk in chunks {
            try Task.checkCancellation()

            if let chunkFileURL = chunk.fileURL {
                receivedFileURL = chunkFileURL
            } else if !chunk.data.isEmpty {
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

        try fileHandle.close()

        if let srcURL = receivedFileURL {
            try? fileManager.removeItem(at: partFileURL)
            try fileManager.moveItem(at: srcURL, to: partFileURL)
        }

        stateStore.setStatus(.verifying, for: descriptor.id)

        let actualHash: String
        if receivedFileURL != nil {
            actualHash = try hashFile(at: partFileURL)
        } else {
            actualHash = hexDigest(hasher.finalize())
        }
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

    private func parseManifest(from descriptor: DustModelDescriptor) -> [ManifestFileEntry]? {
        guard let filesJSON = descriptor.metadata?["files"],
              let data = filesJSON.data(using: .utf8),
              let entries = try? JSONDecoder().decode([ManifestFileEntry].self, from: data),
              !entries.isEmpty else {
            return nil
        }
        return entries
    }

    private func runManifestDownload(
        descriptor: DustModelDescriptor,
        manifest: [ManifestFileEntry]
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

        stateStore.setStatus(.downloading(progress: 0), for: descriptor.id)
        eventEmitter("sizeDisclosure", [
            "modelId": descriptor.id,
            "sizeBytes": descriptor.sizeBytes,
        ])

        var globalBytesDownloaded: Int64 = 0
        let totalSize = max(descriptor.sizeBytes, 1)
        var lastProgressEventBytes: Int64 = 0

        for entry in manifest {
            try Task.checkCancellation()

            guard let url = URL(string: entry.url) else {
                throw DustCoreError.downloadFailed(detail: "Invalid URL for file: \(entry.filename)")
            }

            let finalFileURL = modelDirectory.appendingPathComponent(entry.filename, isDirectory: false)
            let partFileURL = modelDirectory.appendingPathComponent("\(entry.filename).part", isDirectory: false)

            // Skip already-downloaded and verified files (resume support)
            if fileManager.fileExists(atPath: finalFileURL.path) {
                if let expectedHash = entry.sha256?.lowercased(), !expectedHash.isEmpty {
                    if verifyFileHash(at: finalFileURL, expected: expectedHash) {
                        globalBytesDownloaded += entry.sizeBytes
                        let progress = min(Float(globalBytesDownloaded) / Float(totalSize), 1)
                        stateStore.setStatus(.downloading(progress: progress), for: descriptor.id)
                        continue
                    }
                    try fileManager.removeItem(at: finalFileURL)
                } else {
                    // No hash to verify — trust existing file
                    globalBytesDownloaded += entry.sizeBytes
                    let progress = min(Float(globalBytesDownloaded) / Float(totalSize), 1)
                    stateStore.setStatus(.downloading(progress: progress), for: descriptor.id)
                    continue
                }
            }

            if fileManager.fileExists(atPath: partFileURL.path) {
                try fileManager.removeItem(at: partFileURL)
            }

            let (_, chunks) = try await dataSource.download(from: url)

            fileManager.createFile(atPath: partFileURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: partFileURL)
            defer { try? fileHandle.close() }

            var hasher = SHA256()
            var fileBytesReceived: Int64 = 0
            var receivedFileURL: URL?

            for try await chunk in chunks {
                try Task.checkCancellation()

                // File-based chunk: the engine already wrote the data to disk.
                if let chunkFileURL = chunk.fileURL {
                    receivedFileURL = chunkFileURL
                } else if !chunk.data.isEmpty {
                    hasher.update(data: chunk.data)
                    try fileHandle.write(contentsOf: chunk.data)
                }

                fileBytesReceived = chunk.totalBytesReceived
                let overallProgress = min(Float(globalBytesDownloaded + fileBytesReceived) / Float(totalSize), 1)
                stateStore.setStatus(.downloading(progress: overallProgress), for: descriptor.id)

                let currentGlobalBytes = globalBytesDownloaded + fileBytesReceived
                if shouldEmitProgress(currentBytes: currentGlobalBytes, lastEmittedBytes: lastProgressEventBytes) {
                    emitProgress(
                        modelId: descriptor.id,
                        progress: overallProgress,
                        bytesDownloaded: currentGlobalBytes,
                        totalBytes: descriptor.sizeBytes > 0 ? descriptor.sizeBytes : nil
                    )
                    lastProgressEventBytes = currentGlobalBytes
                }
            }

            try fileHandle.close()

            // If the engine delivered a file on disk, move it to partFile
            // (replacing the empty one we created above).
            if let srcURL = receivedFileURL {
                try? fileManager.removeItem(at: partFileURL)
                try fileManager.moveItem(at: srcURL, to: partFileURL)
            } else {
                // Data was written incrementally — just synchronize.
                let fh = try FileHandle(forWritingTo: partFileURL)
                try fh.synchronize()
                try fh.close()
            }

            // Verify this file's SHA-256 (skip if no hash provided)
            if let expectedHash = entry.sha256?.lowercased(), !expectedHash.isEmpty {
                stateStore.setStatus(.verifying, for: descriptor.id)
                if receivedFileURL != nil {
                    // Hash from disk since data wasn't streamed through hasher
                    let actualHash = try hashFile(at: partFileURL)
                    guard actualHash == expectedHash else {
                        throw DustCoreError.verificationFailed(
                            detail: "File \(entry.filename): expected \(expectedHash), received \(actualHash)"
                        )
                    }
                } else {
                    let actualHash = hexDigest(hasher.finalize())
                    guard actualHash == expectedHash else {
                        throw DustCoreError.verificationFailed(
                            detail: "File \(entry.filename): expected \(expectedHash), received \(actualHash)"
                        )
                    }
                }
            }

            if fileManager.fileExists(atPath: finalFileURL.path) {
                try fileManager.removeItem(at: finalFileURL)
            }
            try fileManager.moveItem(at: partFileURL, to: finalFileURL)
            globalBytesDownloaded += fileBytesReceived
        }

        // Emit final progress if needed
        if globalBytesDownloaded > lastProgressEventBytes {
            emitProgress(
                modelId: descriptor.id,
                progress: 1,
                bytesDownloaded: globalBytesDownloaded,
                totalBytes: descriptor.sizeBytes > 0 ? descriptor.sizeBytes : nil
            )
        }

        // All files downloaded — set ready with directory path
        stateStore.updateState(for: descriptor.id) { state in
            state.status = .ready
            state.filePath = modelDirectory.path
        }
        eventEmitter("modelReady", [
            "modelId": descriptor.id,
            "path": modelDirectory.path,
        ])
    }

    private func hashFile(at fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        while true {
            let data = fileHandle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hexDigest(hasher.finalize())
    }

    private func verifyFileHash(at fileURL: URL, expected: String) -> Bool {
        guard let hash = try? hashFile(at: fileURL) else { return false }
        return hash == expected
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

    /// Returns the set of model IDs currently being downloaded.
    public var activeModelIds: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(activeDownloads.keys)
    }

    /// Whether a download is currently active for the given model ID.
    public func isDownloading(modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeDownloads[modelId] != nil
    }

    /// Reconnects orphaned background downloads that survived an app kill.
    /// Call this before `cleanupStalePartFiles()`.
    /// Downloads whose model ID has a descriptor are consumed immediately;
    /// those without one are stashed until `attachReconnectedDownload(for:)` is called.
    public func resumeOrphanedDownloads(
        descriptorProvider: (String) -> DustModelDescriptor?
    ) async {
        guard let bgEngine = dataSource as? BackgroundDownloadEngine else { return }
        let reconnected = await bgEngine.reconnectPendingTasks()

        for download in reconnected {
            if let descriptor = descriptorProvider(download.modelId) {
                attachStream(download.chunks, for: descriptor, url: download.url)
            } else {
                lock.lock()
                pendingReconnections[download.modelId] = download.chunks
                lock.unlock()
            }
        }
    }

    /// Attaches a stashed reconnected download stream for a model that was just registered.
    /// Call this from the plugin's `register()` path after the descriptor is available.
    public func attachReconnectedDownload(for descriptor: DustModelDescriptor, url: URL? = nil) {
        lock.lock()
        guard let stream = pendingReconnections.removeValue(forKey: descriptor.id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        attachStream(stream, for: descriptor, url: url ?? URL(string: descriptor.url ?? "")!)
    }

    /// Whether there is a pending reconnection stream for the given model ID.
    public func hasPendingReconnection(modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingReconnections[modelId] != nil
    }

    private func attachStream(
        _ chunks: AsyncThrowingStream<DownloadChunk, Error>,
        for descriptor: DustModelDescriptor,
        url: URL
    ) {
        let expectedHash = descriptor.sha256?.lowercased() ?? ""

        lock.lock()
        if activeDownloads[descriptor.id] != nil {
            lock.unlock()
            return
        }
        let entry = ActiveDownload(url: url)
        let task = Task {
            await Task.yield()
            do {
                try await consumeReconnectedStream(
                    descriptor: descriptor,
                    chunks: chunks,
                    expectedHash: expectedHash
                )
            } catch {
                handleFailure(for: descriptor, error: error)
            }
            finishDownload(for: descriptor.id, entry: entry)
        }
        entry.task = task
        activeDownloads[descriptor.id] = entry
        lock.unlock()

        stateStore.setStatus(.downloading(progress: 0), for: descriptor.id)
    }

    private func consumeReconnectedStream(
        descriptor: DustModelDescriptor,
        chunks: AsyncThrowingStream<DownloadChunk, Error>,
        expectedHash: String
    ) async throws {
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

        fileManager.createFile(atPath: partFileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: partFileURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        var totalBytesReceived: Int64 = 0
        var lastProgressEventBytes: Int64 = 0
        let progressDenominator = max(descriptor.sizeBytes, 1)
        var receivedFileURL: URL?

        for try await chunk in chunks {
            try Task.checkCancellation()

            if let chunkFileURL = chunk.fileURL {
                receivedFileURL = chunkFileURL
            } else if !chunk.data.isEmpty {
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
                    totalBytes: descriptor.sizeBytes > 0 ? descriptor.sizeBytes : nil
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
                totalBytes: descriptor.sizeBytes > 0 ? descriptor.sizeBytes : nil
            )
        }

        try fileHandle.close()

        if let srcURL = receivedFileURL {
            try? fileManager.removeItem(at: partFileURL)
            try fileManager.moveItem(at: srcURL, to: partFileURL)
        }

        stateStore.setStatus(.verifying, for: descriptor.id)

        let actualHash: String
        if receivedFileURL != nil {
            actualHash = try hashFile(at: partFileURL)
        } else {
            actualHash = hexDigest(hasher.finalize())
        }
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

    public func cleanupStalePartFiles(activeModelIds: Set<String> = []) {
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
            if activeModelIds.contains(modelId) { continue }

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
            let remainingFiles = (try? fileManager.contentsOfDirectory(
                at: modelDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let hasCompletedFiles = fileManager.fileExists(atPath: finalFileURL.path)
                || remainingFiles.contains(where: { $0.pathExtension != "part" })
            if !hasCompletedFiles {
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
        let modelDirectory = baseDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)

        // Clean up single-file .part
        let singlePartFile = modelDirectory.appendingPathComponent("\(modelId).part", isDirectory: false)
        if fileManager.fileExists(atPath: singlePartFile.path) {
            try? fileManager.removeItem(at: singlePartFile)
        }

        // Clean up manifest .part files (e.g. "config.json.part", "model.safetensors.part")
        if let files = try? fileManager.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.pathExtension == "part" {
                try? fileManager.removeItem(at: file)
            }
        }
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

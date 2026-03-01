import Foundation
@testable import DustServe

enum MockDownloadError: Error {
    case injectedFailure
}

final class MockDownloadDataSource: DownloadDataSource, @unchecked Sendable {
    enum FailureMode {
        case none
        case immediate(Error)
        case afterBytes(Int64, Error)
    }

    private let lock = NSLock()
    private(set) var downloadCallCount = 0
    private var cancelledURLs = Set<URL>()

    let data: Data
    let chunkSize: Int
    let preflightContentLength: Int64?
    let failureMode: FailureMode
    let delayPerChunkNanoseconds: UInt64

    init(
        data: Data,
        chunkSize: Int = 1_048_576,
        preflightContentLength: Int64? = nil,
        failureMode: FailureMode = .none,
        delayPerChunkNanoseconds: UInt64 = 0
    ) {
        self.data = data
        self.chunkSize = chunkSize
        self.preflightContentLength = preflightContentLength
        self.failureMode = failureMode
        self.delayPerChunkNanoseconds = delayPerChunkNanoseconds
    }

    func download(from url: URL) async throws -> (
        preflight: DownloadPreflightInfo,
        chunks: AsyncThrowingStream<DownloadChunk, Error>
    ) {
        lock.lock()
        downloadCallCount += 1
        cancelledURLs.remove(url)
        lock.unlock()

        switch failureMode {
        case .immediate(let error):
            throw error
        case .none, .afterBytes:
            break
        }

        let stream = AsyncThrowingStream<DownloadChunk, Error> { continuation in
            let streamTask = Task {
                do {
                    var offset = 0
                    var totalBytesReceived: Int64 = 0

                    while offset < data.count {
                        try Task.checkCancellation()
                        if isCancelled(url: url) {
                            throw CancellationError()
                        }

                        let end = min(offset + chunkSize, data.count)
                        let chunk = data.subdata(in: offset..<end)

                        if delayPerChunkNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: delayPerChunkNanoseconds)
                        }

                        totalBytesReceived += Int64(chunk.count)
                        continuation.yield(
                            DownloadChunk(data: chunk, totalBytesReceived: totalBytesReceived)
                        )

                        if case .afterBytes(let failAfterBytes, let error) = failureMode,
                           totalBytesReceived >= failAfterBytes {
                            throw error
                        }

                        offset = end
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                streamTask.cancel()
            }
        }

        return (
            DownloadPreflightInfo(contentLength: preflightContentLength ?? Int64(data.count)),
            stream
        )
    }

    func cancel(url: URL) {
        lock.lock()
        cancelledURLs.insert(url)
        lock.unlock()
    }

    private func isCancelled(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledURLs.contains(url)
    }
}

struct MockDiskSpaceProvider: DiskSpaceProvider {
    let bytesAvailable: Int64

    init(bytesAvailable: Int64) {
        self.bytesAvailable = bytesAvailable
    }

    func availableBytes(at url: URL) -> Int64 {
        bytesAvailable
    }
}

struct MockNetworkPolicyProvider: NetworkPolicyProvider {
    let allowed: Bool

    init(allowed: Bool) {
        self.allowed = allowed
    }

    func isDownloadAllowed() -> Bool {
        allowed
    }
}

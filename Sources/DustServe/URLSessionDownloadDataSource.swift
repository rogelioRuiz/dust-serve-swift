import Foundation
import DustCore

public final class URLSessionDownloadDataSource: DownloadDataSource, @unchecked Sendable {
    private let session: URLSession
    private let chunkSize: Int
    private let lock = NSLock()
    private var cancelledURLs = Set<URL>()

    public init(session: URLSession = .shared, chunkSize: Int = 1_048_576) {
        self.session = session
        self.chunkSize = chunkSize
    }

    public func download(from url: URL) async throws -> (
        preflight: DownloadPreflightInfo,
        chunks: AsyncThrowingStream<DownloadChunk, Error>
    ) {
        clearCancellation(for: url)

        let request = URLRequest(url: url)
        let (bytes, response) = try await session.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw DustCoreError.downloadFailed(detail: "HTTP \(httpResponse.statusCode)")
        }

        let contentLength = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        let stream = AsyncThrowingStream<DownloadChunk, Error> { continuation in
            let streamTask = Task {
                do {
                    var buffer = Data()
                    var totalBytesReceived: Int64 = 0
                    buffer.reserveCapacity(chunkSize)

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if isCancelled(url: url) {
                            throw CancellationError()
                        }

                        buffer.append(byte)
                        if buffer.count >= chunkSize {
                            totalBytesReceived += Int64(buffer.count)
                            continuation.yield(
                                DownloadChunk(data: buffer, totalBytesReceived: totalBytesReceived)
                            )
                            buffer = Data()
                            buffer.reserveCapacity(chunkSize)
                        }
                    }

                    if !buffer.isEmpty {
                        totalBytesReceived += Int64(buffer.count)
                        continuation.yield(
                            DownloadChunk(data: buffer, totalBytesReceived: totalBytesReceived)
                        )
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

        return (DownloadPreflightInfo(contentLength: contentLength), stream)
    }

    public func cancel(url: URL) {
        lock.lock()
        cancelledURLs.insert(url)
        lock.unlock()
    }

    private func isCancelled(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledURLs.contains(url)
    }

    private func clearCancellation(for url: URL) {
        lock.lock()
        cancelledURLs.remove(url)
        lock.unlock()
    }
}

public struct SystemDiskSpaceProvider: DiskSpaceProvider {
    public init() {}

    public func availableBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: Set([
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]))

        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }

        if let standard = values?.volumeAvailableCapacity {
            return Int64(standard)
        }

        return 0
    }
}

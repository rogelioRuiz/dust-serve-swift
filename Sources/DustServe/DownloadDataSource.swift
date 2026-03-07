import Foundation

public struct DownloadPreflightInfo: Sendable {
    public let contentLength: Int64?

    public init(contentLength: Int64?) {
        self.contentLength = contentLength
    }
}

public struct DownloadChunk: Sendable {
    public let data: Data
    public let totalBytesReceived: Int64
    /// When non-nil the payload lives on disk rather than in ``data``.
    /// Consumers should move (not copy) this file to the final location.
    public let fileURL: URL?

    public init(data: Data, totalBytesReceived: Int64, fileURL: URL? = nil) {
        self.data = data
        self.totalBytesReceived = totalBytesReceived
        self.fileURL = fileURL
    }
}

public protocol DownloadDataSource: Sendable {
    func download(from url: URL) async throws -> (
        preflight: DownloadPreflightInfo,
        chunks: AsyncThrowingStream<DownloadChunk, Error>
    )
    func cancel(url: URL)
}

public protocol DiskSpaceProvider: Sendable {
    func availableBytes(at url: URL) -> Int64
}

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

    public init(data: Data, totalBytesReceived: Int64) {
        self.data = data
        self.totalBytesReceived = totalBytesReceived
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

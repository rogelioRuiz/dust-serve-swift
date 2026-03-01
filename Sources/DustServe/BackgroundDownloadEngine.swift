import CryptoKit
import Foundation

public final class BackgroundDownloadEngine: NSObject, DownloadDataSource, URLSessionDownloadDelegate, @unchecked Sendable {
    private let sessionIdentifier: String
    private let resumeDataDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var statesByTaskIdentifier: [Int: DownloadState] = [:]
    private var taskIdentifiersByURL: [URL: Int] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    public init(
        sessionIdentifier: String = "com.t6x.modelserver.download",
        resumeDataDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.resumeDataDirectory = resumeDataDirectory
        self.fileManager = fileManager
        super.init()

        try? fileManager.createDirectory(
            at: resumeDataDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    public func download(from url: URL) async throws -> (
        preflight: DownloadPreflightInfo,
        chunks: AsyncThrowingStream<DownloadChunk, Error>
    ) {
        try fileManager.createDirectory(
            at: resumeDataDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let stream = AsyncThrowingStream<DownloadChunk, Error> { continuation in
            let task = self.makeDownloadTask(for: url)
            let state = DownloadState(url: url, continuation: continuation)

            self.lock.lock()
            self.statesByTaskIdentifier[task.taskIdentifier] = state
            self.taskIdentifiersByURL[url] = task.taskIdentifier
            self.lock.unlock()

            task.resume()
        }

        return (DownloadPreflightInfo(contentLength: nil), stream)
    }

    public func cancel(url: URL) {
        guard let taskIdentifier = taskIdentifier(for: url) else { return }

        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskIdentifier == taskIdentifier }) as? URLSessionDownloadTask else {
                return
            }

            task.cancel(byProducingResumeData: { resumeData in
                if let resumeData {
                    self.writeResumeData(resumeData, for: url)
                }
            })
        }
    }

    public func handleBackgroundSession(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let state = state(for: downloadTask.taskIdentifier) else { return }
        state.lastTotalBytesReceived = totalBytesWritten
        state.continuation.yield(
            DownloadChunk(data: Data(), totalBytesReceived: totalBytesWritten)
        )
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let state = state(for: downloadTask.taskIdentifier) else { return }

        do {
            let data = try Data(contentsOf: location)
            let totalBytesReceived = max(state.lastTotalBytesReceived, Int64(data.count))
            state.lastTotalBytesReceived = totalBytesReceived
            state.continuation.yield(
                DownloadChunk(data: data, totalBytesReceived: totalBytesReceived)
            )
            state.continuation.finish()
            state.isCompleted = true
            clearResumeData(for: state.url)
        } catch {
            state.continuation.finish(throwing: error)
            state.isCompleted = true
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let state = removeState(for: task.taskIdentifier) else { return }

        if let nsError = error as NSError? {
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                writeResumeData(resumeData, for: state.url)
            }

            if !state.isCompleted {
                state.continuation.finish(throwing: nsError)
            }
            return
        }

        if !state.isCompleted {
            state.continuation.finish()
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completionHandler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        completionHandler?()
    }

    private func makeDownloadTask(for url: URL) -> URLSessionDownloadTask {
        if let resumeData = readResumeData(for: url) {
            return session.downloadTask(withResumeData: resumeData)
        }

        return session.downloadTask(with: URLRequest(url: url))
    }

    private func state(for taskIdentifier: Int) -> DownloadState? {
        lock.lock()
        defer { lock.unlock() }
        return statesByTaskIdentifier[taskIdentifier]
    }

    private func taskIdentifier(for url: URL) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return taskIdentifiersByURL[url]
    }

    private func removeState(for taskIdentifier: Int) -> DownloadState? {
        lock.lock()
        defer { lock.unlock() }

        guard let state = statesByTaskIdentifier.removeValue(forKey: taskIdentifier) else {
            return nil
        }
        taskIdentifiersByURL.removeValue(forKey: state.url)
        return state
    }

    private func resumeDataFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return resumeDataDirectory.appendingPathComponent("\(name).resumedata", isDirectory: false)
    }

    private func readResumeData(for url: URL) -> Data? {
        let fileURL = resumeDataFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    private func writeResumeData(_ data: Data, for url: URL) {
        let fileURL = resumeDataFileURL(for: url)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func clearResumeData(for url: URL) {
        let fileURL = resumeDataFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try? fileManager.removeItem(at: fileURL)
    }
}

private final class DownloadState {
    let url: URL
    let continuation: AsyncThrowingStream<DownloadChunk, Error>.Continuation
    var lastTotalBytesReceived: Int64 = 0
    var isCompleted = false

    init(
        url: URL,
        continuation: AsyncThrowingStream<DownloadChunk, Error>.Continuation
    ) {
        self.url = url
        self.continuation = continuation
    }
}

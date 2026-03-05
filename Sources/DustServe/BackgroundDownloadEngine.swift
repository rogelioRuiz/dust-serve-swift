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

    // MARK: - URL-to-modelId persistence

    private var urlMapFileURL: URL {
        resumeDataDirectory.appendingPathComponent("url-model-map.plist", isDirectory: false)
    }

    private func loadURLToModelIdMap() -> [String: String] {
        guard let data = try? Data(contentsOf: urlMapFileURL),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: String]
        else { return [:] }
        return dict
    }

    private func saveURLToModelIdMap(_ map: [String: String]) {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: map, format: .binary, options: 0
        ) else { return }
        try? data.write(to: urlMapFileURL, options: .atomic)
    }

    private func persistURLMapping(url: URL, modelId: String) {
        var map = loadURLToModelIdMap()
        map[url.absoluteString] = modelId
        saveURLToModelIdMap(map)
    }

    private func removeURLMapping(url: URL) {
        var map = loadURLToModelIdMap()
        map.removeValue(forKey: url.absoluteString)
        saveURLToModelIdMap(map)
    }

    // MARK: - Reconnect pending tasks after app relaunch

    public struct ReconnectedDownload {
        public let url: URL
        public let modelId: String
        public let chunks: AsyncThrowingStream<DownloadChunk, Error>
    }

    /// Reconnects URLSession download tasks that survived an app kill.
    /// Returns stream handles for each active download so the DownloadManager can consume them.
    public func reconnectPendingTasks() async -> [ReconnectedDownload] {
        let tasks = await session.allTasks
        let urlToModelId = loadURLToModelIdMap()
        var reconnected: [ReconnectedDownload] = []
        var reconnectedURLs = Set<String>()

        for task in tasks {
            guard let downloadTask = task as? URLSessionDownloadTask,
                  let url = task.originalRequest?.url ?? task.currentRequest?.url,
                  let modelId = urlToModelId[url.absoluteString],
                  task.state == .running || task.state == .suspended
            else { continue }

            reconnectedURLs.insert(url.absoluteString)
            let stream = AsyncThrowingStream<DownloadChunk, Error> { continuation in
                let state = DownloadState(url: url, continuation: continuation)
                self.lock.lock()
                self.statesByTaskIdentifier[downloadTask.taskIdentifier] = state
                self.taskIdentifiersByURL[url] = downloadTask.taskIdentifier
                self.lock.unlock()
            }

            reconnected.append(ReconnectedDownload(url: url, modelId: modelId, chunks: stream))
        }

        // Clean up stale URL mappings for tasks that no longer exist (e.g. killed on simulator)
        let staleURLs = Set(urlToModelId.keys).subtracting(reconnectedURLs)
        if !staleURLs.isEmpty {
            var updatedMap = urlToModelId
            for url in staleURLs {
                updatedMap.removeValue(forKey: url)
            }
            saveURLToModelIdMap(updatedMap)
        }

        return reconnected
    }

    /// Checks if there is a persisted URL mapping for the given model ID,
    /// indicating a download was in progress when the app was killed.
    public func hasPersistedDownload(forModelId modelId: String) -> Bool {
        let map = loadURLToModelIdMap()
        return map.values.contains(modelId)
    }

    // MARK: - DownloadDataSource

    public func download(from url: URL, modelId: String? = nil) async throws -> (
        preflight: DownloadPreflightInfo,
        chunks: AsyncThrowingStream<DownloadChunk, Error>
    ) {
        try fileManager.createDirectory(
            at: resumeDataDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if let modelId {
            persistURLMapping(url: url, modelId: modelId)
        }

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

    public func download(from url: URL) async throws -> (
        preflight: DownloadPreflightInfo,
        chunks: AsyncThrowingStream<DownloadChunk, Error>
    ) {
        return try await download(from: url, modelId: nil)
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
            removeURLMapping(url: state.url)
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

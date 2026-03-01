import Foundation
import DustCore

final class CloseOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func record(_ id: String) {
        lock.lock()
        ids.append(id)
        lock.unlock()
    }

    func recordedOrder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

actor MockModelSession: DustModelSession {
    nonisolated let priorityValue: DustSessionPriority
    nonisolated let sessionId: String

    private var predictCallCount = 0
    private var predictThreadIsMain: Bool?
    private var closeCallCount = 0
    private let closeOrderRecorder: CloseOrderRecorder?

    init(
        priority: DustSessionPriority = .interactive,
        sessionId: String = "",
        closeOrderRecorder: CloseOrderRecorder? = nil
    ) {
        self.priorityValue = priority
        self.sessionId = sessionId
        self.closeOrderRecorder = closeOrderRecorder
    }

    func predict(inputs: [DustInputTensor]) async throws -> [DustOutputTensor] {
        predictCallCount += 1
        predictThreadIsMain = Thread.isMainThread
        return []
    }

    nonisolated func status() -> DustModelStatus {
        .ready
    }

    nonisolated func priority() -> DustSessionPriority {
        priorityValue
    }

    func close() async throws {
        closeCallCount += 1
        closeOrderRecorder?.record(sessionId)
    }

    func recordedPredictCallCount() -> Int {
        predictCallCount
    }

    func recordedPredictThreadIsMain() -> Bool? {
        predictThreadIsMain
    }

    func recordedCloseCallCount() -> Int {
        closeCallCount
    }
}

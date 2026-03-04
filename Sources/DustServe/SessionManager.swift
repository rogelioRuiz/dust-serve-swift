import Foundation
import DustCore

public enum MemoryPressureLevel {
    case standard
    case critical
}

public final class SessionManager: @unchecked Sendable {

    public let inferenceQueue = DispatchQueue(label: "com.t6x.modelserver.inference")

    private let stateStore: ModelStateStore
    private var factory: any DustModelSessionFactory
    private let lock = NSLock()
    private var cachedSessions: [String: CachedSession] = [:]

    public init(
        stateStore: ModelStateStore,
        factory: any DustModelSessionFactory
    ) {
        self.stateStore = stateStore
        self.factory = factory
    }

    /// Swaps the session factory. Must be called before any sessions are loaded.
    public func setFactory(_ newFactory: any DustModelSessionFactory) {
        lock.lock(); defer { lock.unlock() }
        precondition(cachedSessions.isEmpty, "Cannot swap factory while sessions are active")
        factory = newFactory
    }

    public func loadModel(
        descriptor: DustModelDescriptor,
        priority: DustSessionPriority
    ) async throws -> any DustModelSession {
        if let cached = incrementCachedRefCount(for: descriptor.id) {
            return cached
        }

        guard let state = stateStore.state(for: descriptor.id) else {
            throw DustCoreError.modelNotFound
        }

        guard case .ready = state.status else {
            throw DustCoreError.modelNotReady
        }

        let createdSession = try await factory.makeSession(descriptor: descriptor, priority: priority)

        var installedSession: (any DustModelSession)?
        var discardedSession: (any DustModelSession)?
        var installedRefCount = 0

        lock.lock()
        if var cached = cachedSessions[descriptor.id] {
            cached.refCount += 1
            cached.lastAccessTime = DispatchTime.now().uptimeNanoseconds
            cachedSessions[descriptor.id] = cached
            installedSession = cached.session
            installedRefCount = cached.refCount
            discardedSession = createdSession
        } else {
            let wrappedSession = QueuedModelSession(
                base: createdSession,
                inferenceQueue: inferenceQueue
            )
            cachedSessions[descriptor.id] = CachedSession(
                session: wrappedSession,
                priority: priority,
                refCount: 1,
                lastAccessTime: DispatchTime.now().uptimeNanoseconds
            )
            installedSession = wrappedSession
            installedRefCount = 1
        }
        lock.unlock()

        if let discardedSession {
            try? await discardedSession.close()
        }

        updateRefCount(for: descriptor.id, to: installedRefCount)
        return installedSession ?? createdSession
    }

    public func unloadModel(id: String) async throws {
        var nextRefCount: Int?

        lock.lock()
        if var cached = cachedSessions[id], cached.refCount > 0 {
            cached.refCount -= 1
            cachedSessions[id] = cached
            nextRefCount = cached.refCount
        }
        lock.unlock()

        guard let nextRefCount else {
            throw DustCoreError.modelNotFound
        }

        updateRefCount(for: id, to: nextRefCount)
    }

    public func evict(id: String) async throws {
        let cachedSession: (any DustModelSession)?

        lock.lock()
        cachedSession = cachedSessions.removeValue(forKey: id)?.session
        lock.unlock()

        if cachedSession != nil {
            updateRefCount(for: id, to: 0)
        }

        try await cachedSession?.close()
    }

    public func evictUnderPressure(level: MemoryPressureLevel) async {
        let evicted: [(id: String, session: any DustModelSession)]

        lock.lock()
        let eligible = cachedSessions.filter { (_, cached) in
            guard cached.refCount == 0 else {
                return false
            }

            switch level {
            case .standard:
                return cached.priority == .background
            case .critical:
                return true
            }
        }
        let sorted = eligible.sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
        evicted = sorted.map { ($0.key, $0.value.session) }
        for (id, _) in evicted {
            cachedSessions.removeValue(forKey: id)
        }
        lock.unlock()

        for (id, session) in evicted {
            updateRefCount(for: id, to: 0)
            try? await session.close()
        }
    }

    public func refCount(for id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedSessions[id]?.refCount ?? 0
    }

    public func hasCachedSession(for id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedSessions[id] != nil
    }

    private func incrementCachedRefCount(for id: String) -> (any DustModelSession)? {
        let cachedSession: (any DustModelSession)?
        let refCount: Int

        lock.lock()
        if var cached = cachedSessions[id] {
            cached.refCount += 1
            cached.lastAccessTime = DispatchTime.now().uptimeNanoseconds
            cachedSessions[id] = cached
            cachedSession = cached.session
            refCount = cached.refCount
        } else {
            cachedSession = nil
            refCount = 0
        }
        lock.unlock()

        if cachedSession != nil {
            updateRefCount(for: id, to: refCount)
        }

        return cachedSession
    }

    private func updateRefCount(for id: String, to refCount: Int) {
        _ = stateStore.updateState(for: id) { state in
            state.refCount = refCount
        }
    }
}

private struct CachedSession {
    let session: any DustModelSession
    let priority: DustSessionPriority
    var refCount: Int
    var lastAccessTime: UInt64
}

private final class QueuedModelSession: DustModelSession, @unchecked Sendable {
    private let base: any DustModelSession
    private let inferenceQueue: DispatchQueue

    init(
        base: any DustModelSession,
        inferenceQueue: DispatchQueue
    ) {
        self.base = base
        self.inferenceQueue = inferenceQueue
    }

    func predict(inputs: [DustInputTensor]) async throws -> [DustOutputTensor] {
        try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                let semaphore = DispatchSemaphore(value: 0)
                var result: Result<[DustOutputTensor], Error>?

                Task {
                    do {
                        result = .success(try await self.base.predict(inputs: inputs))
                    } catch {
                        result = .failure(error)
                    }
                    semaphore.signal()
                }

                semaphore.wait()

                if let result {
                    continuation.resume(with: result)
                } else {
                    continuation.resume(
                        throwing: DustCoreError.unknownError(message: "Inference did not complete")
                    )
                }
            }
        }
    }

    func status() -> DustModelStatus {
        base.status()
    }

    func priority() -> DustSessionPriority {
        base.priority()
    }

    func close() async throws {
        try await base.close()
    }
}

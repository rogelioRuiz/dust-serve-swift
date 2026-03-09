import XCTest
@testable import DustServe
import DustCore

private actor MockModelSessionFactory: DustModelSessionFactory {
    private let errorToThrow: DustCoreError?
    private let delayNanoseconds: UInt64
    private let closeOrderRecorder: CloseOrderRecorder?
    private var createCount = 0
    private var sessions: [MockModelSession] = []

    init(
        errorToThrow: DustCoreError? = nil,
        delayNanoseconds: UInt64 = 0,
        closeOrderRecorder: CloseOrderRecorder? = nil
    ) {
        self.errorToThrow = errorToThrow
        self.delayNanoseconds = delayNanoseconds
        self.closeOrderRecorder = closeOrderRecorder
    }

    func makeSession(
        descriptor: DustModelDescriptor,
        priority: DustSessionPriority
    ) async throws -> any DustModelSession {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        if let errorToThrow {
            throw errorToThrow
        }

        createCount += 1
        let session = MockModelSession(
            priority: priority,
            sessionId: descriptor.id,
            closeOrderRecorder: closeOrderRecorder
        )
        sessions.append(session)
        return session
    }

    func createdCount() -> Int {
        createCount
    }

    func firstCreatedSession() -> MockModelSession? {
        sessions.first
    }
}

final class SessionManagerTests: XCTestCase {

    func testLoadModelReturnsSessionForReadyModel() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        let session = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)

        XCTAssertEqual(session.status(), .ready)
        XCTAssertEqual(session.priority(), .interactive)
        let count = await factory.createdCount()
        XCTAssertEqual(count, 1)
    }

    func testLoadModelNonReadyThrowsModelNotReady() async {
        let stateStore = ModelStateStore()
        stateStore.setStatus(.notLoaded, for: "model-a")
        let manager = SessionManager(stateStore: stateStore, factory: MockModelSessionFactory())

        do {
            _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
            XCTFail("Expected modelNotReady")
        } catch let error as DustCoreError {
            XCTAssertEqual(error, .modelNotReady)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoadModelUnknownThrowsModelNotFound() async {
        let manager = SessionManager(stateStore: ModelStateStore(), factory: MockModelSessionFactory())

        do {
            _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
            XCTFail("Expected modelNotFound")
        } catch let error as DustCoreError {
            XCTAssertEqual(error, .modelNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSecondLoadModelReturnsCachedSession() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        let first = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        let second = try await manager.loadModel(descriptor: makeDescriptor(), priority: .background)

        XCTAssertEqual(identity(of: first), identity(of: second))
        let count = await factory.createdCount()
        XCTAssertEqual(count, 1)
    }

    func testRefCountIncrementsOnLoad() async throws {
        let stateStore = makeReadyStateStore()
        let manager = SessionManager(stateStore: stateStore, factory: MockModelSessionFactory())

        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)

        XCTAssertEqual(manager.refCount(for: "model-a"), 3)
        XCTAssertEqual(stateStore.state(for: "model-a")?.refCount, 3)
    }

    func testRefCountDecrementsOnUnload() async throws {
        let stateStore = makeReadyStateStore()
        let manager = SessionManager(stateStore: stateStore, factory: MockModelSessionFactory())

        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        try await manager.unloadModel(id: "model-a")
        try await manager.unloadModel(id: "model-a")

        XCTAssertEqual(manager.refCount(for: "model-a"), 1)
        XCTAssertEqual(stateStore.state(for: "model-a")?.refCount, 1)
    }

    func testRefCountZeroSessionStillCached() async throws {
        let stateStore = makeReadyStateStore()
        let manager = SessionManager(stateStore: stateStore, factory: MockModelSessionFactory())

        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        try await manager.unloadModel(id: "model-a")

        XCTAssertEqual(manager.refCount(for: "model-a"), 0)
        XCTAssertTrue(manager.hasCachedSession(for: "model-a"))
        XCTAssertEqual(stateStore.state(for: "model-a")?.refCount, 0)
    }

    func testReloadAfterEviction() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        let first = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        try await manager.unloadModel(id: "model-a")
        try await manager.evict(id: "model-a")
        let second = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)

        XCTAssertNotEqual(identity(of: first), identity(of: second))
        let count = await factory.createdCount()
        XCTAssertEqual(count, 2)
    }

    func testPredictRunsOnInferenceQueue() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        let session = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        _ = try await session.predict(inputs: [])

        guard let createdSession = await factory.firstCreatedSession() else {
            return XCTFail("Expected created session")
        }

        let predictCount = await createdSession.recordedPredictCallCount()
        let ranOnMain = await createdSession.recordedPredictThreadIsMain()
        XCTAssertEqual(predictCount, 1)
        XCTAssertEqual(ranOnMain, false)
    }

    func testConcurrentLoadModelReturnsSameSession() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory(delayNanoseconds: 20_000_000)
        let manager = SessionManager(stateStore: stateStore, factory: factory)
        let descriptor = makeDescriptor()

        let identities = try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let session = try await manager.loadModel(descriptor: descriptor, priority: .interactive)
                    return identity(of: session)
                }
            }

            var collected: [ObjectIdentifier] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        XCTAssertEqual(Set(identities).count, 1)
        XCTAssertEqual(manager.refCount(for: "model-a"), 20)
        let count = await factory.createdCount()
        XCTAssertEqual(count, 20)
    }

    func testTaskFactoryOverridesFormatFactory() async throws {
        let stateStore = makeReadyStateStore()
        let formatFactory = MockModelSessionFactory()
        let taskFactory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore)

        manager.setFactory(formatFactory, for: DustModelFormat.onnx.rawValue)
        manager.setFactory(taskFactory, for: "embeddings")

        _ = try await manager.loadModel(
            descriptor: makeDescriptor(
                format: .onnx,
                metadata: ["task": "embeddings"]
            ),
            priority: .interactive
        )

        let formatCount = await formatFactory.createdCount()
        let taskCount = await taskFactory.createdCount()
        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(taskCount, 1)
    }

    func testFormatFactoryFallbackUsedWhenTaskFactoryMissing() async throws {
        let stateStore = makeReadyStateStore()
        let formatFactory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore)

        manager.setFactory(formatFactory, for: DustModelFormat.onnx.rawValue)

        _ = try await manager.loadModel(
            descriptor: makeDescriptor(
                format: .onnx,
                metadata: ["task": "embeddings"]
            ),
            priority: .interactive
        )

        let formatCount = await formatFactory.createdCount()
        XCTAssertEqual(formatCount, 1)
    }

    func testBackgroundZeroRefsEvictedOnStandard() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .background)
        try await manager.unloadModel(id: "model-a")

        await manager.evictUnderPressure(level: .standard)

        XCTAssertFalse(manager.hasCachedSession(for: "model-a"))
        guard let createdSession = await factory.firstCreatedSession() else {
            return XCTFail("Expected created session")
        }
        let closeCount = await createdSession.recordedCloseCallCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testBackgroundWithRefsNotEvicted() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .background)

        await manager.evictUnderPressure(level: .standard)

        XCTAssertTrue(manager.hasCachedSession(for: "model-a"))
        guard let createdSession = await factory.firstCreatedSession() else {
            return XCTFail("Expected created session")
        }
        let closeCount = await createdSession.recordedCloseCallCount()
        XCTAssertEqual(closeCount, 0)
    }

    func testInteractiveNotEvictedOnStandard() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        try await manager.unloadModel(id: "model-a")

        await manager.evictUnderPressure(level: .standard)

        XCTAssertTrue(manager.hasCachedSession(for: "model-a"))
        guard let createdSession = await factory.firstCreatedSession() else {
            return XCTFail("Expected created session")
        }
        let closeCount = await createdSession.recordedCloseCallCount()
        XCTAssertEqual(closeCount, 0)
    }

    func testInteractiveEvictedOnCritical() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .interactive)
        try await manager.unloadModel(id: "model-a")

        await manager.evictUnderPressure(level: .critical)

        XCTAssertFalse(manager.hasCachedSession(for: "model-a"))
        guard let createdSession = await factory.firstCreatedSession() else {
            return XCTFail("Expected created session")
        }
        let closeCount = await createdSession.recordedCloseCallCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testBackgroundWithRefsNotEvictedOnCritical() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        _ = try await manager.loadModel(descriptor: makeDescriptor(), priority: .background)

        await manager.evictUnderPressure(level: .critical)

        XCTAssertTrue(manager.hasCachedSession(for: "model-a"))
        guard let createdSession = await factory.firstCreatedSession() else {
            return XCTFail("Expected created session")
        }
        let closeCount = await createdSession.recordedCloseCallCount()
        XCTAssertEqual(closeCount, 0)
    }

    func testReAcquireAfterEvictionReloads() async throws {
        let stateStore = makeReadyStateStore()
        let factory = MockModelSessionFactory()
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        let first = try await manager.loadModel(descriptor: makeDescriptor(), priority: .background)
        try await manager.unloadModel(id: "model-a")
        await manager.evictUnderPressure(level: .standard)
        let second = try await manager.loadModel(descriptor: makeDescriptor(), priority: .background)

        XCTAssertNotEqual(identity(of: first), identity(of: second))
        XCTAssertEqual(stateStore.status(for: "model-a"), .ready)
        let count = await factory.createdCount()
        XCTAssertEqual(count, 2)
    }

    func testLRUEvictionOrder() async throws {
        let recorder = CloseOrderRecorder()
        let stateStore = makeReadyStateStore(ids: ["model-a", "model-b", "model-c"])
        let factory = MockModelSessionFactory(closeOrderRecorder: recorder)
        let manager = SessionManager(stateStore: stateStore, factory: factory)

        _ = try await manager.loadModel(descriptor: makeDescriptor(id: "model-a"), priority: .background)
        try? await Task.sleep(nanoseconds: 1_000_000)
        _ = try await manager.loadModel(descriptor: makeDescriptor(id: "model-b"), priority: .background)
        try? await Task.sleep(nanoseconds: 1_000_000)
        _ = try await manager.loadModel(descriptor: makeDescriptor(id: "model-c"), priority: .background)

        try await manager.unloadModel(id: "model-a")
        try await manager.unloadModel(id: "model-b")
        try await manager.unloadModel(id: "model-c")

        try? await Task.sleep(nanoseconds: 1_000_000)
        _ = try await manager.loadModel(descriptor: makeDescriptor(id: "model-a"), priority: .background)
        try await manager.unloadModel(id: "model-a")

        await manager.evictUnderPressure(level: .standard)

        XCTAssertEqual(recorder.recordedOrder(), ["model-b", "model-c", "model-a"])
    }

    private func makeReadyStateStore(id: String = "model-a") -> ModelStateStore {
        let stateStore = ModelStateStore()
        stateStore.setStatus(.ready, for: id)
        return stateStore
    }

    private func makeReadyStateStore(ids: [String]) -> ModelStateStore {
        let stateStore = ModelStateStore()
        for id in ids {
            stateStore.setStatus(.ready, for: id)
        }
        return stateStore
    }

    private func makeDescriptor(
        id: String = "model-a",
        format: DustModelFormat = .gguf,
        metadata: [String: String]? = nil
    ) -> DustModelDescriptor {
        DustModelDescriptor(
            id: id,
            name: "Model A",
            format: format,
            sizeBytes: 1_024,
            version: "1.0.0",
            metadata: metadata
        )
    }
}

private func identity(of session: any DustModelSession) -> ObjectIdentifier {
    ObjectIdentifier(session as AnyObject)
}

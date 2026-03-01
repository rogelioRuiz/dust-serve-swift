import XCTest
@testable import DustServe
import DustCore

final class ModelServerRegistryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DustCoreRegistry.shared.resetForTesting()
    }

    override func tearDown() {
        DustCoreRegistry.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - S1-T1: Register and retrieve descriptor — all fields match

    func testRegisterAndRetrieveDescriptor() {
        let registry = ModelRegistry()
        let descriptor = DustModelDescriptor(
            id: "qwen3-0.6b",
            name: "Qwen3 0.6B Instruct",
            format: .gguf,
            sizeBytes: 350_000_000,
            version: "1.0.0",
            quantization: "Q4_K_M",
            metadata: ["source": "huggingface", "family": "qwen3"]
        )

        registry.register(descriptor: descriptor)
        let retrieved = registry.descriptor(for: "qwen3-0.6b")

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, "qwen3-0.6b")
        XCTAssertEqual(retrieved?.name, "Qwen3 0.6B Instruct")
        XCTAssertEqual(retrieved?.format, .gguf)
        XCTAssertEqual(retrieved?.sizeBytes, 350_000_000)
        XCTAssertEqual(retrieved?.version, "1.0.0")
        XCTAssertEqual(retrieved?.quantization, "Q4_K_M")
        XCTAssertEqual(retrieved?.metadata?["source"], "huggingface")
        XCTAssertEqual(retrieved?.metadata?["family"], "qwen3")
    }

    // MARK: - S1-T2: Unknown model returns notLoaded — not nil, not error

    func testUnknownModelReturnsNotLoaded() {
        let stateStore = ModelStateStore()
        let status = stateStore.status(for: "ghost")
        XCTAssertEqual(status, .notLoaded)
    }

    // MARK: - S1-T3: listDescriptors returns all registered

    func testListDescriptorsReturnsAll() {
        let registry = ModelRegistry()
        let ids = ["model-a", "model-b", "model-c"]
        for id in ids {
            registry.register(descriptor: DustModelDescriptor(
                id: id, name: id, format: .gguf, sizeBytes: 100, version: "1.0"
            ))
        }

        let all = registry.allDescriptors()
        XCTAssertEqual(all.count, 3)
        let retrievedIds = Set(all.map(\.id))
        XCTAssertEqual(retrievedIds, Set(ids))
    }

    // MARK: - S1-T4: Re-registration overwrites

    func testReRegistrationOverwrites() {
        let registry = ModelRegistry()
        let a = DustModelDescriptor(
            id: "m1", name: "Model A", format: .gguf, sizeBytes: 100, version: "1.0"
        )
        let b = DustModelDescriptor(
            id: "m1", name: "Model B", format: .onnx, sizeBytes: 200, version: "2.0"
        )

        registry.register(descriptor: a)
        registry.register(descriptor: b)

        let retrieved = registry.descriptor(for: "m1")
        XCTAssertEqual(retrieved?.name, "Model B")
        XCTAssertEqual(retrieved?.format, .onnx)
        XCTAssertEqual(retrieved?.sizeBytes, 200)
        XCTAssertEqual(retrieved?.version, "2.0")
    }

    // MARK: - S1-T5: Descriptors and states are independently stored

    func testDescriptorsAndStatesIndependent() {
        let registry = ModelRegistry()
        let stateStore = ModelStateStore()

        let descriptor = DustModelDescriptor(
            id: "m1", name: "Original", format: .gguf, sizeBytes: 500, version: "1.0"
        )
        registry.register(descriptor: descriptor)
        stateStore.setStatus(.notLoaded, for: "m1")

        // Mutate state — descriptor must remain unchanged
        stateStore.setStatus(.downloading(progress: 0.5), for: "m1")

        let retrievedDescriptor = registry.descriptor(for: "m1")
        XCTAssertEqual(retrievedDescriptor?.name, "Original")
        XCTAssertEqual(retrievedDescriptor?.sizeBytes, 500)

        let retrievedStatus = stateStore.status(for: "m1")
        XCTAssertEqual(retrievedStatus, .downloading(progress: 0.5))
    }

    // MARK: - S1-T6: DustCoreRegistry resolves ModelServer after registration

    func testDustCoreRegistryResolvesModelServer() {
        let registry = ModelRegistry()
        let stateStore = ModelStateStore()

        // Create a lightweight ModelServer conformer for testing
        let server = TestModelServer(registry: registry, stateStore: stateStore)
        DustCoreRegistry.shared.register(modelServer: server)

        XCTAssertNoThrow(try DustCoreRegistry.shared.resolveModelServer())
        let resolved = try? DustCoreRegistry.shared.resolveModelServer()
        XCTAssertTrue(resolved === server)
    }

    // MARK: - S1-T8: 50 concurrent tasks — no crash under TSan

    func testConcurrentRegistrationNoCrash() {
        let registry = ModelRegistry()
        let taskCount = 50
        let expectation = XCTestExpectation(description: "All concurrent registrations complete")
        expectation.expectedFulfillmentCount = taskCount

        DispatchQueue.concurrentPerform(iterations: taskCount) { i in
            let descriptor = DustModelDescriptor(
                id: "model-\(i)", name: "Model \(i)", format: .gguf, sizeBytes: Int64(i * 100), version: "1.0"
            )
            registry.register(descriptor: descriptor)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)

        let all = registry.allDescriptors()
        XCTAssertEqual(all.count, taskCount)
    }

    func testConcurrentStateUpdateNoCrash() {
        let stateStore = ModelStateStore()
        let taskCount = 50
        let expectation = XCTestExpectation(description: "All concurrent state updates complete")
        expectation.expectedFulfillmentCount = taskCount

        DispatchQueue.concurrentPerform(iterations: taskCount) { i in
            stateStore.setStatus(.downloading(progress: Float(i) / Float(taskCount)), for: "model-\(i)")
            _ = stateStore.status(for: "model-\(i)")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }
}

// MARK: - Test helpers

/// Lightweight DustModelServer conformer for unit tests that don't need CAPPlugin.
private final class TestModelServer: DustModelServer {
    let registry: ModelRegistry
    let stateStore: ModelStateStore

    init(registry: ModelRegistry, stateStore: ModelStateStore) {
        self.registry = registry
        self.stateStore = stateStore
    }

    func loadModel(descriptor: DustModelDescriptor, priority: DustSessionPriority) async throws -> any DustModelSession {
        throw DustCoreError.formatUnsupported
    }

    func unloadModel(id: String) async throws {
        throw DustCoreError.modelNotFound
    }

    func listModels() async throws -> [DustModelDescriptor] {
        registry.allDescriptors()
    }

    func modelStatus(id: String) async throws -> DustModelStatus {
        stateStore.status(for: id)
    }
}

import Foundation
import DustCore

/// Mutable model state — tracks status throughout the lifecycle.
public struct ModelState: Sendable {
    public var status: DustModelStatus
    public var filePath: String?
    public var refCount: Int

    public init(
        status: DustModelStatus = .notLoaded,
        filePath: String? = nil,
        refCount: Int = 0
    ) {
        self.status = status
        self.filePath = filePath
        self.refCount = refCount
    }
}

/// Thread-safe state store with its own `NSLock`, independent from `ModelRegistry`.
/// State writes happen constantly during download and session events;
/// keeping a separate lock prevents descriptor reads from blocking.
public final class ModelStateStore: @unchecked Sendable {

    private let lock = NSLock()
    private var states: [String: ModelState] = [:]
    private let onStatusChange: (@Sendable (String, DustModelStatus) -> Void)?

    public init(onStatusChange: (@Sendable (String, DustModelStatus) -> Void)? = nil) {
        self.onStatusChange = onStatusChange
    }

    /// Returns the current status for `id`. Returns `.notLoaded` if unknown —
    /// never `nil`, never an error (S1-T2).
    public func status(for id: String) -> DustModelStatus {
        lock.lock()
        defer { lock.unlock() }
        return states[id]?.status ?? .notLoaded
    }

    /// Returns the current state snapshot for `id`, or `nil` if unknown.
    public func state(for id: String) -> ModelState? {
        lock.lock()
        defer { lock.unlock() }
        return states[id]
    }

    /// Atomically updates the state for `id`, creating a default entry if needed.
    @discardableResult
    public func updateState(for id: String, transform: (inout ModelState) -> Void) -> ModelState {
        let previousStatus: DustModelStatus?
        let nextState: ModelState

        lock.lock()
        var state = states[id] ?? ModelState()
        previousStatus = states[id]?.status
        transform(&state)
        states[id] = state
        nextState = state
        lock.unlock()

        if previousStatus != nextState.status {
            onStatusChange?(id, nextState.status)
        }

        return nextState
    }

    /// Sets the status for a given model ID.
    public func setStatus(_ status: DustModelStatus, for id: String) {
        _ = updateState(for: id) { state in
            state.status = status
        }
    }
}

import Foundation
import DustCore

/// Thread-safe, write-once descriptor store.
/// Uses a dedicated `NSLock` — independent from `ModelStateStore`'s lock
/// so that descriptor reads never block during active downloads.
public final class ModelRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var descriptors: [String: DustModelDescriptor] = [:]

    public init() {}

    /// Registers (or overwrites) a descriptor. Write-once semantics per ID;
    /// re-registration with the same ID replaces the previous entry.
    public func register(descriptor: DustModelDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        descriptors[descriptor.id] = descriptor
    }

    /// Returns the descriptor for `id`, or `nil` if not registered.
    public func descriptor(for id: String) -> DustModelDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[id]
    }

    /// Returns all registered descriptors (snapshot copy).
    public func allDescriptors() -> [DustModelDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return Array(descriptors.values)
    }
}

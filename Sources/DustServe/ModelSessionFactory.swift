import Foundation
import DustCore

public protocol ModelSessionFactory: Sendable {
    func makeSession(
        descriptor: DustModelDescriptor,
        priority: DustSessionPriority
    ) async throws -> any DustModelSession
}

public struct StubModelSessionFactory: ModelSessionFactory {
    public init() {}

    public func makeSession(
        descriptor: DustModelDescriptor,
        priority: DustSessionPriority
    ) async throws -> any DustModelSession {
        throw DustCoreError.formatUnsupported
    }
}

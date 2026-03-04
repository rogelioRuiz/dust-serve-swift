import Foundation
import DustCore

// DustModelSessionFactory protocol is defined in DustCore.

public struct StubModelSessionFactory: DustModelSessionFactory {
    public init() {}

    public func makeSession(
        descriptor: DustModelDescriptor,
        priority: DustSessionPriority
    ) async throws -> any DustModelSession {
        throw DustCoreError.formatUnsupported
    }
}

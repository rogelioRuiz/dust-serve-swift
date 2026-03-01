import Foundation
import DustCore

extension DustCoreError {
    /// Returns a dictionary representation of the error suitable for serialization.
    /// This is the Capacitor-free equivalent of `toJSObject()`.
    public func toDict() -> [String: Any] {
        switch self {
        case .modelNotFound:
            return ["code": "modelNotFound"]
        case .modelNotReady:
            return ["code": "modelNotReady"]
        case .modelCorrupted:
            return ["code": "modelCorrupted"]
        case .formatUnsupported:
            return ["code": "formatUnsupported"]
        case .sessionClosed:
            return ["code": "sessionClosed"]
        case .sessionLimitReached:
            return ["code": "sessionLimitReached"]
        case .invalidInput(let detail):
            var obj: [String: Any] = ["code": "invalidInput"]
            if let d = detail { obj["detail"] = d }
            return obj
        case .inferenceFailed(let detail):
            var obj: [String: Any] = ["code": "inferenceFailed"]
            if let d = detail { obj["detail"] = d }
            return obj
        case .memoryExhausted:
            return ["code": "memoryExhausted"]
        case .downloadFailed(let detail):
            var obj: [String: Any] = ["code": "downloadFailed"]
            if let d = detail { obj["detail"] = d }
            return obj
        case .storageFull(let detail):
            var obj: [String: Any] = ["code": "storageFull"]
            if let d = detail { obj["detail"] = d }
            return obj
        case .networkPolicyBlocked(let detail):
            var obj: [String: Any] = ["code": "networkPolicyBlocked"]
            if let d = detail { obj["detail"] = d }
            return obj
        case .verificationFailed(let detail):
            var obj: [String: Any] = ["code": "verificationFailed"]
            if let d = detail { obj["detail"] = d }
            return obj
        case .cancelled:
            return ["code": "cancelled"]
        case .timeout:
            return ["code": "timeout"]
        case .serviceNotRegistered(let name):
            return ["code": "serviceNotRegistered", "serviceName": name]
        case .unknownError(let message):
            var obj: [String: Any] = ["code": "unknownError"]
            if let m = message { obj["message"] = m }
            return obj
        }
    }
}

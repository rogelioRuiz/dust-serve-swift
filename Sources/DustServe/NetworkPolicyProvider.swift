import Foundation
import Network

public protocol NetworkPolicyProvider: Sendable {
    func isDownloadAllowed() -> Bool
}

public final class SystemNetworkPolicyProvider: NetworkPolicyProvider, @unchecked Sendable {
    public static let wifiOnlyDefaultsKey = "com.t6x.modelserver.wifiOnly"

    private let userDefaults: UserDefaults
    private let monitor: NWPathMonitor
    private let lock = NSLock()
    private var usesWiFi = false

    public init(
        userDefaults: UserDefaults = .standard,
        monitor: NWPathMonitor = NWPathMonitor()
    ) {
        self.userDefaults = userDefaults
        self.monitor = monitor

        self.monitor.pathUpdateHandler = { [weak self] path in
            self?.setUsesWiFi(path.usesInterfaceType(.wifi))
        }

        self.setUsesWiFi(monitor.currentPath.usesInterfaceType(.wifi))
        self.monitor.start(queue: DispatchQueue(label: "com.t6x.modelserver.network-policy"))
    }

    deinit {
        monitor.cancel()
    }

    public func isDownloadAllowed() -> Bool {
        guard userDefaults.bool(forKey: Self.wifiOnlyDefaultsKey) else {
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        return usesWiFi
    }

    private func setUsesWiFi(_ value: Bool) {
        lock.lock()
        usesWiFi = value
        lock.unlock()
    }
}

import Foundation
import UserNotifications

/// Posts and updates local notifications to show model download progress.
/// Consumer apps must request notification authorization before progress is shown.
public final class DownloadProgressNotifier: @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    private var lastUpdateTime: [String: Date] = [:]
    private static let minUpdateInterval: TimeInterval = 1.0

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func reportProgress(
        modelId: String,
        modelName: String,
        progress: Float,
        bytesDownloaded: Int64,
        totalBytes: Int64?
    ) {
        lock.lock()
        let now = Date()
        if let last = lastUpdateTime[modelId], now.timeIntervalSince(last) < Self.minUpdateInterval {
            lock.unlock()
            return
        }
        lastUpdateTime[modelId] = now
        lock.unlock()

        let content = UNMutableNotificationContent()
        content.title = "Downloading model"
        let percent = Int(progress * 100)
        if let totalBytes, totalBytes > 0 {
            content.body = "\(percent)% — \(formatBytes(bytesDownloaded)) / \(formatBytes(totalBytes))"
        } else {
            content.body = "\(percent)% — \(formatBytes(bytesDownloaded))"
        }
        content.categoryIdentifier = "dust_download_progress"

        let request = UNNotificationRequest(
            identifier: "dust-download-\(modelId)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    public func reportCompleted(modelId: String, modelName: String) {
        lock.lock()
        lastUpdateTime.removeValue(forKey: modelId)
        lock.unlock()

        center.removeDeliveredNotifications(withIdentifiers: ["dust-download-\(modelId)"])

        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = "\(modelName) is ready to use"
        content.categoryIdentifier = "dust_download_complete"

        let request = UNNotificationRequest(
            identifier: "dust-download-done-\(modelId)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    public func reportFailed(modelId: String, modelName: String, error: String) {
        lock.lock()
        lastUpdateTime.removeValue(forKey: modelId)
        lock.unlock()

        center.removeDeliveredNotifications(withIdentifiers: ["dust-download-\(modelId)"])

        let content = UNMutableNotificationContent()
        content.title = "Download failed"
        content.body = "\(modelName): \(error)"
        content.categoryIdentifier = "dust_download_failed"

        let request = UNNotificationRequest(
            identifier: "dust-download-fail-\(modelId)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        switch bytes {
        case ..<1024:
            return "\(bytes) B"
        case ..<(1024 * 1024):
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        case ..<(1024 * 1024 * 1024):
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        default:
            return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
    }
}

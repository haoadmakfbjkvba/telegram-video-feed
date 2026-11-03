import Foundation

// The "Video" tab (video feed) in the tab bar. On by default; hidden with a long press on the tab and shown
// again from the Settings tab's long-press menu. Stored on the device; TelegramRootController listens for changes.
public enum VideoFeedTab {
    public static let changedNotification = Notification.Name("VideoFeedTabChanged")
    private static let key = "telegram.videofeed.tab"

    public static var isEnabled: Bool {
        return UserDefaults.standard.object(forKey: self.key) as? Bool ?? true
    }

    public static func setEnabled(_ value: Bool) {
        if value == self.isEnabled {
            return
        }
        UserDefaults.standard.set(value, forKey: self.key)
        NotificationCenter.default.post(name: self.changedNotification, object: nil)
    }
}

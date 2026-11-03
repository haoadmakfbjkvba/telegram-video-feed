import Foundation

// Video feed playback: sound and auto-advance to the next video. Stored on the device and changed by the
// sound button in the feed; listeners observe `changedNotification`.
public enum VideoFeedPlayback {
    public static let changedNotification = Notification.Name("VideoFeedPlaybackChanged")
    private static let mutedKey = "telegram.videofeed.muted"
    private static let autoAdvanceKey = "telegram.videofeed.autoadvance"

    // While muted, the feed does not take the audio session and does not interrupt music.
    public static var isMuted: Bool {
        return UserDefaults.standard.bool(forKey: self.mutedKey)
    }

    public static func setMuted(_ value: Bool) {
        if value == self.isMuted {
            return
        }
        UserDefaults.standard.set(value, forKey: self.mutedKey)
        NotificationCenter.default.post(name: self.changedNotification, object: nil)
    }

    // A finished video does not loop: the feed scrolls to the next one on its own.
    public static var autoAdvance: Bool {
        return UserDefaults.standard.bool(forKey: self.autoAdvanceKey)
    }

    public static func setAutoAdvance(_ value: Bool) {
        if value == self.autoAdvance {
            return
        }
        UserDefaults.standard.set(value, forKey: self.autoAdvanceKey)
        NotificationCenter.default.post(name: self.changedNotification, object: nil)
    }
}

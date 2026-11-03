import Foundation
import UIKit
import TelegramCore

// One video in the feed, and the common interface of feed sources (a chat, Following, For You).

struct VideoFeedItem {
    enum Reason: Equatable {
        // The channel is similar to one of your channels (Telegram's channel recommendations).
        case similar(title: String)
        // From Telegram's general channel recommendations.
        case popular
        // One of your channels reposts its videos.
        case repostedIn(title: String)
        // It is mentioned (@username or a t.me link) in a post of one of your channels.
        case mentionedIn(title: String)
        // Found by a hashtag you like.
        case hashtag(tag: String)
    }

    let message: EngineRawMessage
    let file: TelegramMediaFile
    let peer: EnginePeer?
    var isSubscribed: Bool
    let reason: Reason?
    // Caption topics (words and hashtags): what the feed learns your taste from.
    let topics: [String]

    init(message: EngineRawMessage, file: TelegramMediaFile, peer: EnginePeer?, isSubscribed: Bool, reason: Reason?) {
        self.message = message
        self.file = file
        self.peer = peer
        self.isSubscribed = isSubscribed
        self.reason = reason
        self.topics = VideoFeedTaste.topics(text: message.text)
    }

    var key: String {
        return videoFeedKeyString(self.message.id)
    }

    var fileKey: String {
        return videoFeedFileKeyString(self.file.fileId)
    }
}

// The same file in different messages (reposts, duplicates) is one video: "watched" is also tracked per file.
func videoFeedFileKeyString(_ id: EngineMedia.Id) -> String {
    return "f\(id.namespace)_\(id.id)"
}

func videoFeedKeyString(_ id: EngineMessage.Id) -> String {
    return "\(id.peerId.toInt64())_\(id.namespace)_\(id.id)"
}

func videoFeedFile(_ message: EngineRawMessage) -> TelegramMediaFile? {
    // Self-destructing and view-once videos never enter the feed.
    if message.attributes.contains(where: { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }) {
        return nil
    }
    for media in message.media {
        if let file = media as? TelegramMediaFile, (file.isVideo && !file.isAnimated) || file.isInstantVideo {
            return file
        }
    }
    return nil
}

// Chronological order: newest first.
func videoFeedSortKey(_ message: EngineRawMessage) -> (Int32, Int32, Int32) {
    return (message.timestamp, message.id.namespace, message.id.id)
}

protocol VideoFeedSource: AnyObject {
    // Grows downward; everything up to the visible video and the one after it never changes (`replan` rebuilds only past that).
    var items: [VideoFeedItem] { get }
    var isComplete: Bool { get }
    // nil until the feed is ready to show its first video (or an empty state); then the video to start from.
    var initialIndex: Int? { get }
    var updated: (() -> Void)? { get set }
    func start()
    // Scrolled close to the end; `visibleIndex` is the video currently on screen.
    func loadMore(visibleIndex: Int)
    func markSubscribed(peerId: EnginePeer.Id)
    // The taste changed (watched to the end, like, Not Interested): videos after `index` are picked again.
    func replan(keepingThrough index: Int)
    // A channel was hidden: its videos after `index` are removed.
    func removeChannel(peerId: EnginePeer.Id, keepingThrough index: Int)
    // A fresh selection from the start (tapping the Video tab while on the first video).
    func refresh()
}

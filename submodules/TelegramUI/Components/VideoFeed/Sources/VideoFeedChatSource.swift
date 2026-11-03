import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

// The video feed of a single chat. Videos and round videos come from two Telegram searches (the "video" and
// "round video" filters, 100 per page) merged by date, newest first. Only items whose position is final are shown:
// until one search has reached a date, older items of the other wait, so the feed only ever grows downward.
final class VideoFeedChatSource: VideoFeedSource {
    private struct Stream {
        let tags: EngineMessage.Tags
        var state: SearchMessagesState?
        var messages: [EngineRawMessage] = []
        var completed = false
        var isLoading = false
    }

    private static let pageLimit: Int32 = 100
    private static let maxItems = 3000

    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let threadId: Int64?
    private let startMessageId: EngineMessage.Id?
    private var streams: [Stream] = [Stream(tags: .video), Stream(tags: .roundVideo)]
    private let disposables = DisposableSet()
    private var subscribedOverride: Bool?

    private(set) var items: [VideoFeedItem] = []
    private(set) var isComplete = false
    private(set) var initialIndex: Int?
    var updated: (() -> Void)?

    init(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?, startMessageId: EngineMessage.Id?) {
        self.context = context
        self.peerId = peerId
        self.threadId = threadId
        self.startMessageId = startMessageId
    }

    deinit {
        self.disposables.dispose()
    }

    func start() {
        for i in 0 ..< self.streams.count {
            self.load(stream: i)
        }
    }

    func loadMore(visibleIndex: Int) {
        self.loadMore()
    }

    private func loadMore() {
        if let index = self.limitingStream() {
            self.load(stream: index)
        }
    }

    func markSubscribed(peerId: EnginePeer.Id) {
        if peerId == self.peerId {
            self.subscribedOverride = true
            for i in 0 ..< self.items.count {
                self.items[i].isSubscribed = true
            }
        }
    }

    // A chat's feed is chronological, there is nothing to re-rank.
    func replan(keepingThrough index: Int) {
    }

    func removeChannel(peerId: EnginePeer.Id, keepingThrough index: Int) {
    }

    func refresh() {
    }

    private func load(stream index: Int) {
        guard !self.streams[index].isLoading, !self.streams[index].completed else {
            return
        }
        self.streams[index].isLoading = true
        let location: SearchMessagesLocation = .peer(peerId: self.peerId, fromId: nil, tags: self.streams[index].tags, reactions: nil, threadId: self.threadId, minDate: nil, maxDate: nil)
        self.disposables.add((self.context.engine.messages.searchMessages(location: location, query: "", state: self.streams[index].state, limit: VideoFeedChatSource.pageLimit)
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] result, nextState in
            guard let self else {
                return
            }
            var stream = self.streams[index]
            stream.isLoading = false
            stream.state = nextState
            let seen = Set(stream.messages.map { $0.id })
            stream.messages.append(contentsOf: result.messages.filter { !seen.contains($0.id) })
            stream.messages.sort(by: { videoFeedSortKey($0) > videoFeedSortKey($1) })
            if result.completed || result.messages.isEmpty || stream.messages.count >= VideoFeedChatSource.maxItems {
                stream.completed = true
            }
            self.streams[index] = stream
            self.rebuild()
        }))
    }

    // The unfinished search with the newest "last loaded" date: anything older than it is not final yet.
    private func limitingStream() -> Int? {
        var result: (Int, (Int32, Int32, Int32))?
        for (i, stream) in self.streams.enumerated() where !stream.completed {
            guard let last = stream.messages.last else {
                return i
            }
            let key = videoFeedSortKey(last)
            if result == nil || key > result!.1 {
                result = (i, key)
            }
        }
        return result?.0
    }

    private func rebuild() {
        var horizon: (Int32, Int32, Int32)?
        var isWaiting = false
        for stream in self.streams where !stream.completed {
            if let last = stream.messages.last {
                let key = videoFeedSortKey(last)
                if horizon == nil || key > horizon! {
                    horizon = key
                }
            } else {
                isWaiting = true
            }
        }
        var items: [VideoFeedItem] = []
        if !isWaiting {
            var all = self.streams.flatMap { $0.messages }
            all.sort(by: { videoFeedSortKey($0) > videoFeedSortKey($1) })
            for message in all {
                if let horizon, videoFeedSortKey(message) < horizon {
                    break
                }
                if let file = videoFeedFile(message) {
                    let peer = message.peers[message.id.peerId].flatMap(EnginePeer.init)
                    var isSubscribed = true
                    if let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info {
                        if case .member = channel.participationStatus {
                        } else {
                            isSubscribed = false
                        }
                    }
                    items.append(VideoFeedItem(message: message, file: file, peer: peer, isSubscribed: self.subscribedOverride ?? isSubscribed, reason: nil))
                }
            }
        }
        self.items = items
        self.isComplete = self.streams.allSatisfy { $0.completed }

        // First load as far as the message the feed was opened from.
        if self.initialIndex == nil {
            if let startMessageId = self.startMessageId {
                if let index = items.firstIndex(where: { $0.message.id == startMessageId }) {
                    self.initialIndex = index
                } else if self.isComplete {
                    self.initialIndex = 0
                } else {
                    self.loadMore()
                    return
                }
            } else if !items.isEmpty || self.isComplete {
                self.initialIndex = 0
            } else {
                self.loadMore()
                return
            }
        }
        self.updated?()
    }
}

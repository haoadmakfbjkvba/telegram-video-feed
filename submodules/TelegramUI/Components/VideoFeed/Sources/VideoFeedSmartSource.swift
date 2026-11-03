import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

// Following and For You: the video feed across channels.
//
// Your own channels come from the chat list (and the archive) with a weight: pinned and recent rank higher; muted, archived
// and ones with piles of unread rank lower; on top of that the learned taste (VideoFeedTaste): affinity to channels and topics.
// Following: your channels' videos by time, newest first (merged with a boundary, like a chat's feed).
// For You: a mix of your channels and new ones. New channels are discovered five ways and expand as you go:
//  - Telegram's recommendations for your 6 favourite channels and the general ones, then for the next 10;
//  - channels whose videos your channels and already discovered ones repost (as a chain);
//  - channels mentioned (@username, a t.me link) in posts of your channels and liked ones;
//  - public posts with videos for hashtags you like (or frequent in your channels);
//  - recommendations for discovered channels you liked (like, full watch): "like" those.
// Ranking, as on TikTok: a channel and its best video are picked together, by weighted chance.
//  - A channel's weight is affinity: whether it is yours, the learned taste, and how other channels discovered through
//    the same channel are liked (likes and Not Interested spread to "relatives").
//  - A video's weight is freshness (For You only takes the last 90 days, a week old is already three times lower), topics,
//    engagement (reactions, comments and forwards per view), whether the video took off for its channel, and format
//    (short and vertical rank higher).
//  - Variety: a channel never repeats within three videos in a row nor more than twice per dozen, the same topics as the
//    last two videos rank lower; channels not shown yet go first, the share of new channels grows if new ones are liked,
//    and roughly every ninth video is exploration: a new channel regardless of taste. Hidden channels appear nowhere.
//  - Within a session: short-term interest (what was watched in the last minutes) lifts similar videos at once; three skips
//    in a row mean boredom, and exploration and new channels increase; a channel watched a lot today
//    steps back until tomorrow. Discovered channels' reach (typical views) counts: nearly empty ones rank lower.
//
// Speed: the first video shows as soon as 2 channels have loaded (or after 1.2 s, with at least one), similar
// channels are mixed in as they arrive. Loaded data is remembered between openings (Following for 4 minutes, For You
// for 20), so reopening is instant. Only a few videos are picked ahead: after every full watch, like
// or Not Interested, everything past the next video is picked again (`replan`).
final class VideoFeedSmartSource: VideoFeedSource {
    enum Mode {
        case following
        case forYou
    }

    // A channel's video: key, topics and counters are computed once on load, since ranking runs on every scroll.
    private struct Video {
        let message: EngineRawMessage
        let file: TelegramMediaFile
        let key: String
        let fileKey: String
        let topics: [String]
        let sortKey: (Int32, Int32, Int32)
        let views: Int
        // Reactions, comments and forwards (a forward counts double).
        let interactions: Int
        // Views adjusted for age: a video an hour old has few yet.
        let adjustedViews: Double
        // Format: short and vertical rank higher, long and horizontal lower.
        let format: Double

        init(message: EngineRawMessage, file: TelegramMediaFile) {
            self.message = message
            self.file = file
            self.key = videoFeedKeyString(message.id)
            self.fileKey = videoFeedFileKeyString(file.fileId)
            self.topics = VideoFeedTaste.topics(text: message.text)
            self.sortKey = videoFeedSortKey(message)
            var views = 0
            var interactions = 0
            for attribute in message.attributes {
                if let attribute = attribute as? ViewCountMessageAttribute {
                    views = attribute.count
                } else if let attribute = attribute as? ForwardCountMessageAttribute {
                    interactions += attribute.count * 2
                } else if let attribute = attribute as? ReactionsMessageAttribute {
                    interactions += attribute.reactions.reduce(0, { $0 + Int($1.count) })
                } else if let attribute = attribute as? ReplyThreadMessageAttribute {
                    interactions += Int(attribute.count)
                }
            }
            self.views = views
            self.interactions = interactions
            let ageHours = max(0.0, Date().timeIntervalSince1970 - Double(message.timestamp)) / 3600.0
            self.adjustedViews = Double(views) / max(0.2, 1.0 - exp(-ageHours / 18.0))
            var format = 1.0
            if !file.isInstantVideo {
                if let duration = file.duration {
                    if duration <= 75.0 {
                        format *= 1.1
                    } else if duration > 600.0 {
                        format *= 0.6
                    } else if duration > 240.0 {
                        format *= 0.8
                    }
                }
                if let dimensions = file.dimensions {
                    let width = Double(dimensions.width)
                    let height = Double(dimensions.height)
                    if height > width * 1.15 {
                        format *= 1.12
                    } else if width > height * 1.15 {
                        format *= 0.92
                    }
                }
            }
            self.format = format
        }
    }

    private final class Pool {
        let peer: EnginePeer
        var weight: Double
        var isSubscribed: Bool
        let reason: VideoFeedItem.Reason?
        // Which channel it was discovered through (similar, repost, mention): feedback spreads to "relatives" by it.
        let sourcePeerId: EnginePeer.Id?
        var state: SearchMessagesState?
        var videos: [Video] = []
        var isLoading = false
        var hasLoaded = false
        var isExhausted = false
        var oldestLoaded: (Int32, Int32, Int32)?
        // The channel's typical views (age-adjusted median), 0 while it has too few videos.
        var medianViews: Double = 0.0

        init(peer: EnginePeer, weight: Double, isSubscribed: Bool, reason: VideoFeedItem.Reason?, sourcePeerId: EnginePeer.Id? = nil) {
            self.peer = peer
            self.weight = weight
            self.isSubscribed = isSubscribed
            self.reason = reason
            self.sourcePeerId = sourcePeerId
        }

        func copy() -> Pool {
            let pool = Pool(peer: self.peer, weight: self.weight, isSubscribed: self.isSubscribed, reason: self.reason, sourcePeerId: self.sourcePeerId)
            pool.state = self.state
            pool.videos = self.videos
            pool.hasLoaded = self.hasLoaded
            pool.isExhausted = self.isExhausted
            pool.oldestLoaded = self.oldestLoaded
            pool.medianViews = self.medianViews
            return pool
        }

        func add(_ video: Video) {
            if self.videos.contains(where: { $0.message.id == video.message.id }) {
                return
            }
            self.videos.append(video)
        }

        // After loading: newest first, and the channel's typical views.
        func refresh() {
            self.videos.sort(by: { $0.sortKey > $1.sortKey })
            let views = self.videos.filter { $0.views > 0 }.map { $0.adjustedViews }.sorted()
            self.medianViews = views.count >= 3 ? views[views.count / 2] : 0.0
        }
    }

    // For You takes videos no older than this.
    private static let maxAgeDays: Double = 90.0

    private var minTimestamp: Int32 {
        return self.mode == .forYou ? Int32(Date().timeIntervalSince1970 - VideoFeedSmartSource.maxAgeDays * 86400.0) : 0
    }

    // A video's freshness: slightly above one during the first day, then it fades: a week ~0.7, two ~0.4, a month ~0.1.
    private static func freshness(_ video: Video) -> Double {
        let ageDays = max(0.0, Date().timeIntervalSince1970 - Double(video.message.timestamp)) / 86400.0
        if ageDays <= 1.0 {
            return 1.15
        }
        return 1.15 * exp(-(ageDays - 1.0) / 12.0)
    }

    // Engagement: the share of reactions, comments and forwards among views (a typical ~1.5% is one).
    private static func quality(_ video: Video) -> Double {
        guard video.views >= 50 else {
            return 1.0
        }
        let rate = Double(video.interactions) / Double(video.views)
        return max(0.7, min(1.6, pow((rate + 0.002) / 0.017, 0.3)))
    }

    // A discovered channel's reach by typical views: ~2000 is one, nearly empty is lower, large is slightly higher.
    private static func reach(_ pool: Pool) -> Double {
        guard pool.medianViews > 0.0 else {
            return 1.0
        }
        return max(0.75, min(1.25, pow(pool.medianViews / 2000.0, 0.1)))
    }

    // Took off: more views than usual for this channel.
    private static func hit(_ video: Video, in pool: Pool) -> Double {
        guard pool.medianViews > 0.0, video.views >= 50 else {
            return 1.0
        }
        return max(0.75, min(1.5, pow(video.adjustedViews / pool.medianViews, 0.3)))
    }

    // Loaded data between openings of the feed (per account and tab).
    private struct Cached {
        let timestamp: Double
        let pools: [EnginePeer.Id: Pool]
        let subscribedOrder: [EnginePeer.Id]
        let discoveredOrder: [EnginePeer.Id]
        let isDiscoveryDone: Bool
    }
    private static var cache: [String: Cached] = [:]

    static func clearCache() {
        self.cache = [:]
    }

    private let context: AccountContext
    private let mode: Mode
    private let taste: VideoFeedTaste
    private let pageSize: Int32
    private let disposables = DisposableSet()
    private let cacheKey: String

    private var pools: [EnginePeer.Id: Pool] = [:]
    private var subscribedOrder: [EnginePeer.Id] = []
    private var discoveredOrder: [EnginePeer.Id] = []
    private var loadQueue: [EnginePeer.Id] = []
    private var activeLoads = 0
    private var emittedKeys = Set<String>()
    private var emittedFiles = Set<EngineMedia.Id>()
    private var recentChannels: [EnginePeer.Id] = []
    private var isSetUp = false
    private var isDiscoveryDone = false
    private var setUpTimestamp: Double?
    // How many videos the feed wants ready (grows as the user scrolls). Few: after every taste signal
    // everything ahead is picked again, and videos picked far ahead would follow the old taste.
    private var requestedCount = 5
    // How many of your own videos in a row: after two, the next one comes from a discovered channel (if there are any).
    private var subscribedStreak = 0
    private var visibleIndex = 0
    private var notifyPending = false

    // Expanding the set of channels (For You only).
    private var isExpansionStarted = false
    private var recommendedFor = Set<EnginePeer.Id>()
    private var secondDegreeCount = 0
    private var searchedHashtags = Set<String>()
    private var knownNames = Set<String>()
    private var nameQueue: [(name: String, source: String, sourceId: EnginePeer.Id, share: Double)] = []
    private var isResolvingName = false
    private var resolvedNamesCount = 0
    // Running channel searches (liked channels, hashtags): while they run, the feed is not considered empty.
    private var pendingLookups = 0
    // How many times a channel has been in the feed this time: channels not shown yet go first.
    private var shownCount: [EnginePeer.Id: Int] = [:]

    private(set) var items: [VideoFeedItem] = []
    private(set) var isComplete = false
    private(set) var initialIndex: Int?
    var updated: (() -> Void)?

    init(context: AccountContext, mode: Mode) {
        self.context = context
        self.mode = mode
        self.taste = VideoFeedTaste.shared(accountPeerId: context.account.peerId)
        self.pageSize = mode == .following ? 12 : 8
        self.cacheKey = "\(context.account.peerId.toInt64())-\(mode == .following ? "following" : "foryou")"
    }

    deinit {
        self.disposables.dispose()
        if self.isSetUp {
            VideoFeedSmartSource.cache[self.cacheKey] = Cached(timestamp: CFAbsoluteTimeGetCurrent(), pools: self.pools.mapValues { $0.copy() }, subscribedOrder: self.subscribedOrder, discoveredOrder: self.discoveredOrder, isDiscoveryDone: self.isDiscoveryDone)
        }
    }

    // MARK: - Own channels

    func start() {
        // Recently loaded data goes into the feed at once, fresh data follows.
        let maxAge: Double = self.mode == .following ? 4.0 * 60.0 : 20.0 * 60.0
        if let cached = VideoFeedSmartSource.cache[self.cacheKey], CFAbsoluteTimeGetCurrent() - cached.timestamp < maxAge {
            self.pools = cached.pools.mapValues { $0.copy() }
            self.subscribedOrder = cached.subscribedOrder
            self.discoveredOrder = cached.discoveredOrder
            self.isDiscoveryDone = cached.isDiscoveryDone
            self.isSetUp = true
            self.setUpTimestamp = CFAbsoluteTimeGetCurrent()
            self.emit(force: true)
        }
        let signal = combineLatest(
            self.context.engine.messages.chatList(group: .root, count: 500) |> take(1),
            self.context.engine.messages.chatList(group: .archive, count: 300) |> take(1)
        )
        |> deliverOnMainQueue
        self.disposables.add(signal.start(next: { [weak self] root, archive in
            self?.setUp(root: root, archive: archive)
        }))
    }

    private func setUp(root: EngineChatList, archive: EngineChatList) {
        var entries: [(EnginePeer, Double)] = []
        for (list, isArchive) in [(root, false), (archive, true)] {
            for (rank, item) in list.items.reversed().enumerated() {
                guard case let .channel(channel) = item.renderedPeer.peer, case .broadcast = channel.info else {
                    continue
                }
                if case .member = channel.participationStatus {
                } else {
                    continue
                }
                var weight = 1.0 + 0.8 * exp(-Double(rank) / 15.0)
                if case let .chatList(index) = item.index, index.pinningIndex != nil {
                    weight *= 1.6
                }
                if item.isMuted {
                    weight *= 0.55
                }
                let unread = item.readCounters?.count ?? 0
                if unread == 0 {
                    weight *= 1.2
                } else if unread > 40 {
                    weight *= 0.7
                }
                if isArchive {
                    weight *= 0.6
                }
                entries.append((.channel(channel), weight))
            }
        }
        // A channel restored from the cache may have been left since: it is no longer yours.
        let subscribedIds = Set(entries.map { $0.0.id })
        for pool in self.pools.values where pool.isSubscribed && !subscribedIds.contains(pool.peer.id) {
            pool.isSubscribed = false
        }
        for (peer, weight) in entries {
            if let existing = self.pools[peer.id] {
                existing.weight = weight
                existing.isSubscribed = true
            } else {
                self.pools[peer.id] = Pool(peer: peer, weight: weight, isSubscribed: true, reason: nil)
            }
        }
        self.subscribedOrder = entries.map { $0.0.id }.filter { !self.taste.isHidden(peerId: $0) }.sorted(by: { self.effectiveWeight($0) > self.effectiveWeight($1) })
        let wasSetUp = self.isSetUp
        self.isSetUp = true
        if self.setUpTimestamp == nil {
            self.setUpTimestamp = CFAbsoluteTimeGetCurrent()
        }

        // Not loaded yet go first; already loaded ones (from the cache) are re-read from the first page for Following.
        let notLoaded = self.subscribedOrder.filter { self.pools[$0]?.hasLoaded == false }
        switch self.mode {
        case .following:
            self.enqueue(Array(notLoaded.prefix(24)))
            self.isDiscoveryDone = true
        case .forYou:
            self.enqueue(Array(notLoaded.prefix(12)))
            self.addLikedChannels()
            if !self.isDiscoveryDone {
                self.requestRecommendations(for: Array(self.subscribedOrder.prefix(6)), includeGlobal: true)
            }
        }
        if !wasSetUp {
            // Nothing has loaded for a while: show what there is.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: { [weak self] in
                self?.emit(force: false)
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: { [weak self] in
                self?.emit(force: true)
            })
        }
        if self.subscribedOrder.isEmpty && self.mode == .following {
            self.emit(force: true)
        } else {
            self.emit(force: false)
        }
    }

    // Previously liked channels you are not subscribed to: straight into the feed and as a source of similar ones; without
    // them the feed went empty when your channels were hidden or there were none.
    private func addLikedChannels() {
        let ids = self.taste.likedChannelIds(limit: 12).filter { self.pools[$0]?.isSubscribed != true }
        if ids.isEmpty {
            return
        }
        self.pendingLookups += 1
        self.disposables.add((self.context.engine.data.get(EngineDataList(ids.map(TelegramEngine.EngineData.Item.Peer.Peer.init(id:))))
        |> deliverOnMainQueue).start(next: { [weak self] peers in
            guard let self else {
                return
            }
            self.pendingLookups -= 1
            var added: [EnginePeer.Id] = []
            for peer in peers {
                guard let peer, case let .channel(channel) = peer, case .broadcast = channel.info else {
                    continue
                }
                if case .member = channel.participationStatus {
                    continue
                }
                if self.pools[peer.id] == nil {
                    self.addDiscovered(peer: peer, weight: 0.8 + 0.1 * self.taste.score(peerId: peer.id), reason: .popular)
                    added.append(peer.id)
                }
            }
            if added.isEmpty {
                self.emit(force: false)
                return
            }
            self.enqueue(Array(added.prefix(6)))
            self.requestRecommendations(for: Array(added.prefix(3)), includeGlobal: false)
            self.emit(force: false)
        }))
    }

    private func effectiveWeight(_ peerId: EnginePeer.Id) -> Double {
        guard let pool = self.pools[peerId] else {
            return 0.0
        }
        return pool.weight * self.taste.multiplier(peerId: peerId)
    }

    // MARK: - Similar channels

    private func requestRecommendations(for favorites: [EnginePeer.Id], includeGlobal: Bool) {
        let favorites = favorites.filter { !self.recommendedFor.contains($0) }
        for favorite in favorites {
            self.recommendedFor.insert(favorite)
        }
        var signals: [Signal<(EnginePeer.Id?, RecommendedChannels?), NoError>] = []
        for favorite in favorites {
            let value = self.context.engine.peers.recommendedChannels(peerId: favorite)
            |> take(1)
            |> map { channels -> (EnginePeer.Id?, RecommendedChannels?) in
                return (favorite, channels)
            }
            signals.append(videoFeedAfterCompletion(of: self.context.engine.peers.requestRecommendedChannels(peerId: favorite), then: value) |> timeout(6.0, queue: Queue.mainQueue(), alternate: .single((favorite, nil))))
        }
        if includeGlobal {
            let globalValue = self.context.engine.peers.recommendedChannels(peerId: nil)
            |> take(1)
            |> map { channels -> (EnginePeer.Id?, RecommendedChannels?) in
                return (nil, channels)
            }
            signals.append(videoFeedAfterCompletion(of: self.context.engine.peers.requestGlobalRecommendedChannelsIfNeeded(), then: globalValue) |> timeout(6.0, queue: Queue.mainQueue(), alternate: .single((nil, nil))))
        }
        if signals.isEmpty {
            self.isDiscoveryDone = true
            return
        }
        self.disposables.add((combineLatest(signals)
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] results in
            self?.applyRecommendations(results)
        }))
    }

    private func applyRecommendations(_ results: [(EnginePeer.Id?, RecommendedChannels?)]) {
        var scores: [EnginePeer.Id: (score: Double, peer: EnginePeer, bestContribution: Double, reason: VideoFeedItem.Reason, source: EnginePeer.Id?)] = [:]
        let maxFavoriteWeight = max(0.01, self.subscribedOrder.prefix(6).map { self.effectiveWeight($0) }.max() ?? 1.0)
        for (favoriteId, recommendations) in results {
            guard let recommendations else {
                continue
            }
            var favoriteWeight = 0.35
            var reason: VideoFeedItem.Reason = .popular
            if let favoriteId, let favorite = self.pools[favoriteId] {
                favoriteWeight = min(1.2, self.effectiveWeight(favoriteId) / maxFavoriteWeight)
                if case let .channel(channel) = favorite.peer {
                    reason = .similar(title: channel.title)
                }
            }
            for (index, recommended) in recommendations.channels.enumerated() {
                let peerId = recommended.peer.id
                if self.pools[peerId]?.isSubscribed == true || peerId == self.context.account.peerId || self.taste.isHidden(peerId: peerId) {
                    continue
                }
                let contribution = favoriteWeight / (1.0 + Double(index) * 0.15)
                if var current = scores[peerId] {
                    current.score += contribution
                    if contribution > current.bestContribution {
                        current.bestContribution = contribution
                        current.reason = reason
                        current.source = favoriteId
                    }
                    scores[peerId] = current
                } else {
                    scores[peerId] = (contribution, recommended.peer, contribution, reason, favoriteId)
                }
            }
        }
        let sorted = scores.sorted(by: { $0.value.score > $1.value.score })
        for (peerId, value) in sorted.prefix(24) where self.pools[peerId] == nil {
            // Similar channels rank slightly below your own on average: weighted like an own channel of medium affinity.
            self.addDiscovered(peer: value.peer, weight: 0.6 + value.score, reason: value.reason, source: value.source)
        }
        self.isDiscoveryDone = true
        self.enqueueBestDiscovered(limit: 10)
        self.emit(force: false)
    }

    // Channels whose videos your channel reposts: the weight is a share of your channel's weight, growing with every repost.
    private func discoverReposts(in messages: [EngineRawMessage], from pool: Pool) {
        guard case let .channel(sourceChannel) = pool.peer else {
            return
        }
        let maxWeight = max(0.01, self.subscribedOrder.prefix(6).map { self.effectiveWeight($0) }.max() ?? 1.0)
        // Reposts in discovered channels continue the chain, but weaker.
        let share = min(1.2, self.effectiveWeight(pool.peer.id) / maxWeight) * (pool.isSubscribed ? 1.0 : 0.5)
        var added: [EnginePeer.Id] = []
        for message in messages {
            guard let forwardInfo = message.forwardInfo, let channel = (forwardInfo.source ?? forwardInfo.author) as? TelegramChannel, case .broadcast = channel.info else {
                continue
            }
            if case .member = channel.participationStatus {
                continue
            }
            if self.taste.isHidden(peerId: channel.id) {
                continue
            }
            if let existing = self.pools[channel.id] {
                if !existing.isSubscribed {
                    existing.weight += 0.3 * share
                }
                continue
            }
            if channel.id == self.context.account.peerId {
                continue
            }
            self.addDiscovered(peer: .channel(channel), weight: 0.6 + 0.6 * share, reason: .repostedIn(title: sourceChannel.title), source: pool.peer.id)
            added.append(channel.id)
        }
        if !added.isEmpty {
            self.enqueue(Array(added.prefix(4)))
        }
    }

    private func addDiscovered(peer: EnginePeer, weight: Double, reason: VideoFeedItem.Reason, source: EnginePeer.Id? = nil) {
        guard self.pools[peer.id] == nil, !self.taste.isHidden(peerId: peer.id) else {
            return
        }
        self.pools[peer.id] = Pool(peer: peer, weight: weight, isSubscribed: false, reason: reason, sourcePeerId: source)
        self.discoveredOrder.append(peer.id)
        if case let .channel(channel) = peer, let name = channel.addressName?.lowercased() {
            self.knownNames.insert(name)
        }
    }

    // Discovered channels not loaded yet: the heaviest first.
    private func enqueueBestDiscovered(limit: Int) {
        var notLoaded = self.discoveredOrder.filter { self.pools[$0]?.hasLoaded == false && self.pools[$0]?.isLoading == false && !self.taste.isHidden(peerId: $0) }
        notLoaded.sort(by: { self.effectiveWeight($0) > self.effectiveWeight($1) })
        self.enqueue(Array(notLoaded.prefix(limit)))
    }

    // MARK: - Expanding the set of channels

    // Once after the first results: recommendations for the next favourite channels, hashtags, mentions.
    private func expandDiscovery() {
        guard self.mode == .forYou, !self.isExpansionStarted else {
            return
        }
        self.isExpansionStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: { [weak self] in
            guard let self else {
                return
            }
            self.requestRecommendations(for: Array(self.subscribedOrder.dropFirst(6).prefix(10)), includeGlobal: false)
            self.searchFavoriteHashtags(limit: 4)
            self.resolveNextName()
        })
    }

    // Hashtags: liked ones first (by taste), then the most frequent in your channels' videos.
    private func searchFavoriteHashtags(limit: Int) {
        var candidates: [String] = self.taste.favoriteHashtags(limit: 8)
        if candidates.count < limit {
            var counts: [String: Int] = [:]
            for peerId in self.subscribedOrder.prefix(20) {
                guard let pool = self.pools[peerId] else {
                    continue
                }
                for video in pool.videos {
                    for topic in video.topics where topic.hasPrefix("#") {
                        counts[topic, default: 0] += 1
                    }
                }
            }
            candidates.append(contentsOf: counts.filter { $0.value >= 2 }.sorted(by: { $0.value > $1.value }).map { $0.key })
        }
        var started = 0
        for tag in candidates where started < limit && !self.searchedHashtags.contains(tag) {
            started += 1
            self.searchHashtag(tag)
        }
    }

    private func searchHashtag(_ tag: String) {
        self.searchedHashtags.insert(tag)
        self.pendingLookups += 1
        let tagScore = max(0.0, self.taste.topicScore([tag]))
        self.disposables.add((self.context.engine.messages.searchHashtagPosts(hashtag: tag, state: nil, limit: 40)
        |> take(1)
        |> map(Optional.init)
        |> timeout(10.0, queue: Queue.mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else {
                return
            }
            self.pendingLookups -= 1
            guard let (result, _) = value else {
                self.emit(force: false)
                return
            }
            let minTimestamp = self.minTimestamp
            var touched: [Pool] = []
            for message in result.messages {
                guard message.timestamp >= minTimestamp, let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info, let file = videoFeedFile(message) else {
                    continue
                }
                if case .member = channel.participationStatus {
                    continue
                }
                if self.taste.isHidden(peerId: channel.id) {
                    continue
                }
                if self.pools[channel.id] == nil {
                    self.addDiscovered(peer: .channel(channel), weight: 0.55 + 0.3 * min(2.0, tagScore), reason: .hashtag(tag: tag))
                }
                guard let pool = self.pools[channel.id] else {
                    continue
                }
                pool.add(Video(message: message, file: file))
                if !touched.contains(where: { $0 === pool }) {
                    touched.append(pool)
                }
            }
            for pool in touched {
                pool.refresh()
            }
            self.emit(force: false)
        }))
    }

    // Channels mentioned in posts (@username or a t.me/username link): queued and resolved one at a time.
    private func collectMentions(from messages: [EngineRawMessage], source pool: Pool) {
        guard self.mode == .forYou, self.resolvedNamesCount + self.nameQueue.count < 40, case let .channel(sourceChannel) = pool.peer else {
            return
        }
        let maxWeight = max(0.01, self.subscribedOrder.prefix(6).map { self.effectiveWeight($0) }.max() ?? 1.0)
        let share = min(1.2, self.effectiveWeight(pool.peer.id) / maxWeight) * (pool.isSubscribed ? 1.0 : 0.6)
        if let own = sourceChannel.addressName?.lowercased() {
            self.knownNames.insert(own)
        }
        for message in messages {
            for name in VideoFeedSmartSource.mentionedNames(in: message) {
                if self.knownNames.contains(name) || self.nameQueue.contains(where: { $0.name == name }) {
                    continue
                }
                self.knownNames.insert(name)
                self.nameQueue.append((name, sourceChannel.title, pool.peer.id, share))
            }
        }
        if self.isExpansionStarted {
            self.resolveNextName()
        }
    }

    static func mentionedNames(in message: EngineRawMessage) -> [String] {
        var result: [String] = []
        let text = message.text as NSString
        guard let attribute = message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute else {
            return result
        }
        for entity in attribute.entities {
            let range = NSRange(location: entity.range.lowerBound, length: entity.range.count)
            switch entity.type {
            case .Mention:
                if range.location + range.length <= text.length, range.length > 1 {
                    if let name = VideoFeedSmartSource.validName(String(text.substring(with: range).dropFirst())) {
                        result.append(name)
                    }
                }
            case .Url:
                if range.location + range.length <= text.length, let name = VideoFeedSmartSource.telegramName(fromLink: text.substring(with: range)) {
                    result.append(name)
                }
            case let .TextUrl(url):
                if let name = VideoFeedSmartSource.telegramName(fromLink: url) {
                    result.append(name)
                }
            default:
                break
            }
        }
        return result
    }

    private static func telegramName(fromLink link: String) -> String? {
        let lowered = link.lowercased()
        for prefix in ["t.me/", "telegram.me/", "telegram.dog/"] {
            guard let range = lowered.range(of: prefix) else {
                continue
            }
            let rest = lowered[range.upperBound...]
            let name = rest.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
            if ["joinchat", "c", "s", "addstickers", "addemoji", "proxy", "socks", "share", "boost", "addlist", "giftcode", "invoice", "contact", "m", "iv"].contains(String(name)) {
                return nil
            }
            return VideoFeedSmartSource.validName(String(name))
        }
        return nil
    }

    private static func validName(_ name: String) -> String? {
        let name = name.lowercased()
        guard name.count >= 4, name.count <= 32, let first = name.first, first.isLetter, first.isASCII else {
            return nil
        }
        guard name.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }) else {
            return nil
        }
        if name.hasSuffix("bot") {
            return nil
        }
        return name
    }

    private func resolveNextName() {
        guard self.mode == .forYou, !self.isResolvingName, self.resolvedNamesCount < 30, !self.nameQueue.isEmpty else {
            return
        }
        // Mentions from the most liked channels first.
        self.nameQueue.sort(by: { $0.share > $1.share })
        let next = self.nameQueue.removeFirst()
        self.isResolvingName = true
        self.resolvedNamesCount += 1
        self.disposables.add((self.context.engine.peers.resolvePeerByName(name: next.name, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            if case let .result(peer) = result {
                return .single(peer)
            }
            return .complete()
        }
        |> take(1)
        |> timeout(8.0, queue: Queue.mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self else {
                return
            }
            if let peer, case let .channel(channel) = peer, case .broadcast = channel.info, channel.id != self.context.account.peerId {
                var isMember = false
                if case .member = channel.participationStatus {
                    isMember = true
                }
                if !isMember && self.pools[channel.id] == nil {
                    self.addDiscovered(peer: peer, weight: 0.55 + 0.45 * next.share, reason: .mentionedIn(title: next.source), source: next.sourceId)
                    if self.availableCount() < 30 {
                        self.enqueue([channel.id])
                    }
                }
            }
            // The next username a little later: don't hit the server back to back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: { [weak self] in
                guard let self else {
                    return
                }
                self.isResolvingName = false
                self.resolveNextName()
            })
        }))
    }

    // Liked discovered channels: search for similar ones (at most 10 at a time), and for hashtags that
    // started to be liked.
    private func expandFromTaste() {
        guard self.mode == .forYou, self.isExpansionStarted else {
            return
        }
        if self.secondDegreeCount < 10 {
            let liked = self.pools.values.filter { !$0.isSubscribed && !self.recommendedFor.contains($0.peer.id) && self.taste.score(peerId: $0.peer.id) >= 1.5 }
            if let best = liked.max(by: { self.taste.score(peerId: $0.peer.id) < self.taste.score(peerId: $1.peer.id) }) {
                self.secondDegreeCount += 1
                self.requestRecommendations(for: [best.peer.id], includeGlobal: false)
            }
        }
        if self.searchedHashtags.count < 10 {
            for tag in self.taste.favoriteHashtags(limit: 4) where !self.searchedHashtags.contains(tag) {
                self.searchHashtag(tag)
                break
            }
        }
    }

    // MARK: - Loading a channel's videos

    private func enqueue(_ peerIds: [EnginePeer.Id]) {
        for peerId in peerIds where !self.loadQueue.contains(peerId) {
            guard let pool = self.pools[peerId], !pool.isLoading, !pool.isExhausted, !self.taste.isHidden(peerId: peerId) else {
                continue
            }
            self.loadQueue.append(peerId)
        }
        self.pump()
    }

    private func pump() {
        // While there is no feed yet, load wider; later three requests at once are enough.
        let limit = self.initialIndex == nil || self.items.isEmpty ? 6 : 3
        while self.activeLoads < limit, !self.loadQueue.isEmpty {
            let peerId = self.loadQueue.removeFirst()
            guard let pool = self.pools[peerId], !pool.isLoading, !pool.isExhausted else {
                continue
            }
            self.load(pool: pool)
        }
    }

    private func load(pool: Pool) {
        pool.isLoading = true
        self.activeLoads += 1
        // For You asks the server only for recent videos: a channel without videos for a long time comes back empty at once.
        let minDate: Int32? = self.mode == .forYou ? self.minTimestamp : nil
        let location: SearchMessagesLocation = .peer(peerId: pool.peer.id, fromId: nil, tags: .video, reactions: nil, threadId: nil, minDate: minDate, maxDate: nil)
        // A channel that does not answer within 10 seconds is treated as empty so it doesn't hold the feed.
        self.disposables.add((self.context.engine.messages.searchMessages(location: location, query: "", state: pool.state, limit: self.pageSize)
        |> take(1)
        |> map(Optional.init)
        |> timeout(10.0, queue: Queue.mainQueue(), alternate: .single(nil))
        |> deliverOnMainQueue).start(next: { [weak self, weak pool] value in
            guard let self, let pool else {
                return
            }
            self.activeLoads -= 1
            pool.isLoading = false
            pool.hasLoaded = true
            guard let (result, nextState) = value else {
                pool.isExhausted = true
                self.pump()
                self.emit(force: false)
                return
            }
            pool.state = nextState
            for message in result.messages {
                if let file = videoFeedFile(message) {
                    pool.add(Video(message: message, file: file))
                }
                let key = videoFeedSortKey(message)
                if pool.oldestLoaded == nil || key < pool.oldestLoaded! {
                    pool.oldestLoaded = key
                }
            }
            pool.refresh()
            if self.mode == .forYou {
                self.discoverReposts(in: result.messages, from: pool)
                if pool.isSubscribed || self.taste.score(peerId: pool.peer.id) >= 1.0 {
                    self.collectMentions(from: result.messages, source: pool)
                }
            }
            if result.completed || result.messages.isEmpty {
                pool.isExhausted = true
            }
            self.pump()
            self.emit(force: false)
        }))
    }

    // MARK: - Output

    func loadMore(visibleIndex: Int) {
        self.visibleIndex = visibleIndex
        self.requestedCount = max(self.requestedCount, visibleIndex + 5)
        self.emit(force: true)
    }

    func markSubscribed(peerId: EnginePeer.Id) {
        self.pools[peerId]?.isSubscribed = true
        self.taste.recordSubscribed(peerId: peerId)
        for i in 0 ..< self.items.count where self.items[i].message.id.peerId == peerId {
            self.items[i].isSubscribed = true
        }
    }

    func replan(keepingThrough index: Int) {
        // Following is chronological: nothing to rank.
        guard self.mode == .forYou, self.initialIndex != nil else {
            return
        }
        self.visibleIndex = max(self.visibleIndex, index - 1)
        self.requestedCount = max(self.requestedCount, index + 4)
        self.truncate(keepingThrough: index)
        self.emit(force: true)
        self.expandFromTaste()
    }

    func removeChannel(peerId: EnginePeer.Id, keepingThrough index: Int) {
        guard self.initialIndex != nil else {
            return
        }
        switch self.mode {
        case .forYou:
            self.truncate(keepingThrough: index)
        case .following:
            // Chronological: only its videos are removed, the keys stay taken, so they never come back.
            let keep = index + 1
            if self.items.count > keep {
                let tail = self.items[keep...].filter { $0.message.id.peerId != peerId }
                if tail.count != self.items.count - keep {
                    self.items = Array(self.items[..<keep]) + tail
                    self.notifyPending = true
                }
            }
        }
        self.emit(force: true)
    }

    // A fresh selection from the start: what was shown this time is forgotten (watched videos still never repeat), and the
    // heaviest channels are re-read from the first page in case something new came out.
    func refresh() {
        guard self.initialIndex != nil else {
            return
        }
        self.items = []
        self.emittedKeys.removeAll()
        self.emittedFiles.removeAll()
        self.shownCount.removeAll()
        self.recentChannels = []
        self.subscribedStreak = 0
        self.visibleIndex = 0
        self.requestedCount = 5
        self.notifyPending = true
        var best = self.pools.values.filter { $0.hasLoaded && !$0.isLoading && !self.taste.isHidden(peerId: $0.peer.id) }
        best.sort(by: { self.effectiveWeight($0.peer.id) > self.effectiveWeight($1.peer.id) })
        var reload: [EnginePeer.Id] = []
        for pool in best.prefix(8) {
            pool.state = nil
            pool.isExhausted = false
            reload.append(pool.peer.id)
        }
        self.enqueue(reload)
        self.emit(force: true)
    }

    // Removes the videos after `index` and returns them to the pool to be picked again.
    private func truncate(keepingThrough index: Int) {
        let keep = max(0, index + 1)
        guard self.items.count > keep else {
            return
        }
        for item in self.items[keep...] {
            self.emittedKeys.remove(item.key)
            self.emittedFiles.remove(item.file.fileId)
            let peerId = item.message.id.peerId
            if let count = self.shownCount[peerId] {
                self.shownCount[peerId] = count > 1 ? count - 1 : nil
            }
        }
        self.items.removeSubrange(keep...)
        self.recentChannels = self.items.suffix(3).map { $0.message.id.peerId }
        var streak = 0
        for item in self.items.reversed() {
            if item.isSubscribed && streak < 2 {
                streak += 1
            } else {
                break
            }
        }
        self.subscribedStreak = streak
        self.notifyPending = true
    }

    private var loadedPoolCount: Int {
        return self.pools.values.filter { $0.hasLoaded }.count
    }

    private var loadedPoolsWithVideos: Int {
        return self.pools.values.filter { $0.hasLoaded && !$0.videos.isEmpty && !self.taste.isHidden(peerId: $0.peer.id) }.count
    }

    private var hasPendingDiscoveredLoads: Bool {
        return self.pools.values.contains(where: { !$0.isSubscribed && !$0.hasLoaded && !self.taste.isHidden(peerId: $0.peer.id) })
    }

    private var hasPendingLoads: Bool {
        return self.activeLoads > 0 || !self.loadQueue.isEmpty || !self.isSetUp || !self.isDiscoveryDone || self.pendingLookups > 0
    }

    private func emit(force: Bool) {
        let previousCount = self.items.count
        let previousComplete = self.isComplete
        let previousInitial = self.initialIndex
        // First results: two channels with videos, or one if more than a second has passed, or everything has loaded.
        if self.initialIndex == nil {
            let elapsed = self.setUpTimestamp.flatMap { CFAbsoluteTimeGetCurrent() - $0 } ?? 0.0
            let withVideos = self.loadedPoolsWithVideos
            let ready = force || withVideos >= 2 || (withVideos >= 1 && elapsed >= 1.1) || (self.isSetUp && !self.hasPendingLoads)
            if !ready {
                return
            }
        }
        switch self.mode {
        case .following:
            self.emitFollowing()
        case .forYou:
            self.emitForYou(target: self.requestedCount)
        }
        self.isComplete = !self.hasPendingLoads && self.pools.values.allSatisfy { $0.isExhausted || !$0.hasLoaded } && self.availableCount() == 0
        if self.initialIndex == nil && (!self.items.isEmpty || self.isComplete || force) {
            self.initialIndex = 0
        }
        if self.initialIndex != nil && !self.items.isEmpty {
            self.expandDiscovery()
        }
        // Notify the feed only when something changed: otherwise the feed asks for videos again, and so on in a loop.
        let changed = self.notifyPending || self.items.count != previousCount || self.isComplete != previousComplete || self.initialIndex != previousInitial
        if self.initialIndex != nil && changed {
            self.notifyPending = false
            self.updated?()
        }
    }

    private func availableCount() -> Int {
        let minTimestamp = self.minTimestamp
        var count = 0
        for pool in self.pools.values where !self.taste.isHidden(peerId: pool.peer.id) {
            count += pool.videos.filter { $0.message.timestamp >= minTimestamp && !self.emittedKeys.contains($0.key) }.count
        }
        return count
    }

    private func append(_ video: Video, pool: Pool) {
        self.emittedKeys.insert(video.key)
        self.emittedFiles.insert(video.file.fileId)
        self.items.append(VideoFeedItem(message: video.message, file: video.file, peer: pool.peer, isSubscribed: pool.isSubscribed, reason: pool.isSubscribed ? nil : pool.reason))
        self.shownCount[pool.peer.id, default: 0] += 1
        self.recentChannels.append(pool.peer.id)
        if self.recentChannels.count > 3 {
            self.recentChannels.removeFirst()
        }
    }

    // Following: chronological. A channel that may still load something newer than the boundary holds older items back.
    private func emitFollowing() {
        var horizon: (Int32, Int32, Int32)?
        for pool in self.pools.values where pool.isSubscribed && pool.hasLoaded && !pool.isExhausted && !self.taste.isHidden(peerId: pool.peer.id) {
            if let oldest = pool.oldestLoaded, horizon == nil || oldest > horizon! {
                horizon = oldest
            }
        }
        var candidates: [(Video, Pool)] = []
        for pool in self.pools.values where pool.isSubscribed && !self.taste.isHidden(peerId: pool.peer.id) {
            for video in pool.videos where !self.emittedKeys.contains(video.key) && !self.emittedFiles.contains(video.file.fileId) {
                if let horizon, video.sortKey < horizon {
                    continue
                }
                candidates.append((video, pool))
            }
        }
        candidates.sort(by: { $0.0.sortKey > $1.0.sortKey })
        for (video, pool) in candidates where !self.emittedFiles.contains(video.file.fileId) {
            self.append(video, pool: pool)
        }
        // The boundary holds: load more of the channel holding it, and those not loaded yet.
        if let horizon, let limiting = self.pools.values.first(where: { $0.isSubscribed && $0.hasLoaded && !$0.isExhausted && $0.oldestLoaded.map({ $0 == horizon }) == true }) {
            self.enqueue([limiting.peer.id])
        }
        let notLoaded = self.subscribedOrder.filter { self.pools[$0]?.hasLoaded == false }
        if !notLoaded.isEmpty {
            self.enqueue(Array(notLoaded.prefix(6)))
        }
    }

    // For You: own and discovered channels mixed; a channel together with its best video, by weighted chance.
    private func emitForYou(target: Int) {
        var target = target
        // No similar channels yet but loads are still running (they may discover channels through reposts): don't run far
        // ahead with own channels alone, keep only 2 videos ahead of the one on screen.
        if self.availablePools(subscribed: false).isEmpty && (self.hasPendingLoads || self.hasPendingDiscoveredLoads) {
            target = min(target, max(3, self.visibleIndex + 3))
        }
        let lineage = self.lineageFactors()
        var guardCounter = 0
        while self.items.count < target && guardCounter < 200 {
            guardCounter += 1
            let subscribedPools = self.availablePools(subscribed: true)
            let discoveredPools = self.availablePools(subscribed: false)
            var group: [Pool]
            if subscribedPools.isEmpty {
                group = discoveredPools
            } else if discoveredPools.isEmpty {
                group = subscribedPools
            } else if self.subscribedStreak >= 2 {
                group = discoveredPools
            } else {
                group = Double.random(in: 0.0 ..< 1.0) < self.discoveredShare() ? discoveredPools : subscribedPools
            }
            // Exploration: roughly every ninth video comes from a discovered channel not shown yet, regardless of taste,
            // so the feed does not close in on what it already likes. When bored (skipping in a row), nearly every third.
            var explore = false
            if self.items.count >= 3 && Double.random(in: 0.0 ..< 1.0) < (self.taste.isBored ? 0.3 : 0.11) {
                let unexplored = discoveredPools.filter { self.shownCount[$0.peer.id] == nil }
                if !unexplored.isEmpty {
                    group = unexplored
                    explore = true
                }
            }
            let hasNext = self.items.count > self.visibleIndex + 1
            let isWaiting = self.activeLoads > 0 || !self.loadQueue.isEmpty || self.pendingLookups > 0
            var allowSeen = false
            if group.isEmpty {
                // Everything unwatched has been shown: wait while something is loading, otherwise take already watched videos.
                if hasNext && isWaiting {
                    break
                }
                group = self.availablePools(subscribed: nil, allowSeen: true)
                allowSeen = true
                if group.isEmpty {
                    break
                }
            }
            guard let (pool, video) = self.pick(from: group, allowSeen: allowSeen, explore: explore, lineage: lineage) else {
                break
            }
            // The pick fell on a channel among the last two, or the best available is no longer fresh, while other channels are still
            // loading and the next video already exists: wait for them (this happened at the start, with only one channel loaded).
            if hasNext && isWaiting && (self.recentChannels.suffix(2).contains(pool.peer.id) || VideoFeedSmartSource.freshness(video) < 0.1) {
                break
            }
            self.append(video, pool: pool)
            self.subscribedStreak = pool.isSubscribed ? self.subscribedStreak + 1 : 0
        }
        // The pool is running low: load the next pages of favourite channels and new discovered ones (the heaviest).
        if self.availableCount() < 20 {
            var best = self.pools.values.filter { $0.hasLoaded && !$0.isExhausted && !$0.isLoading && !self.taste.isHidden(peerId: $0.peer.id) }
            best.sort(by: { self.effectiveWeight($0.peer.id) > self.effectiveWeight($1.peer.id) })
            self.enqueue(best.prefix(3).map { $0.peer.id })
            let notLoadedOwn = self.subscribedOrder.filter { self.pools[$0]?.hasLoaded == false }
            self.enqueue(Array(notLoadedOwn.prefix(2)))
            self.enqueueBestDiscovered(limit: 4)
        }
    }

    // The share of new channels: 50%, more if the new ones shown are liked, less if they are skipped.
    private func discoveredShare() -> Double {
        var sum = 0.0
        var count = 0.0
        for (peerId, _) in self.shownCount {
            if let pool = self.pools[peerId], !pool.isSubscribed {
                sum += self.taste.score(peerId: peerId)
                count += 1.0
            }
        }
        let boredBonus = self.taste.isBored ? 0.15 : 0.0
        guard count >= 3.0 else {
            return 0.5 + boredBonus
        }
        let average = sum / count
        return max(0.35, min(0.7, 0.5 + average * 0.1)) + boredBonus
    }

    // How channels discovered through a channel are liked: the mean learned affinity to them. A channel whose discoveries
    // are liked brings more, one whose discoveries are skipped or marked Not Interested brings fewer (multiplier 0.6...1.65).
    private func lineageFactors() -> [EnginePeer.Id: Double] {
        var sums: [EnginePeer.Id: (sum: Double, count: Double)] = [:]
        for pool in self.pools.values where !pool.isSubscribed {
            guard let source = pool.sourcePeerId else {
                continue
            }
            let score = self.taste.score(peerId: pool.peer.id)
            if score == 0.0 {
                continue
            }
            var value = sums[source] ?? (0.0, 0.0)
            value.sum += score
            value.count += 1.0
            sums[source] = value
        }
        return sums.mapValues { exp(max(-2.0, min(2.0, $0.sum / $0.count)) / 4.0) }
    }

    private func availablePools(subscribed: Bool?, allowSeen: Bool = false) -> [Pool] {
        return self.pools.values.filter { pool in
            if let subscribed, pool.isSubscribed != subscribed {
                return false
            }
            if self.taste.isHidden(peerId: pool.peer.id) {
                return false
            }
            return self.candidates(in: pool, allowSeen: allowSeen, limit: 1).first != nil
        }
    }

    // A channel's unshown videos (For You: no older than 90 days), newest first.
    private func candidates(in pool: Pool, allowSeen: Bool, limit: Int) -> [Video] {
        let minTimestamp = self.minTimestamp
        var result: [Video] = []
        for video in pool.videos {
            // Videos are sorted newest first: only older ones follow.
            if video.message.timestamp < minTimestamp {
                break
            }
            if self.emittedKeys.contains(video.key) || self.emittedFiles.contains(video.file.fileId) {
                continue
            }
            if !allowSeen && (self.taste.isSeen(video.key) || self.taste.isSeen(video.fileKey)) {
                continue
            }
            result.append(video)
            if result.count >= limit {
                break
            }
        }
        return result
    }

    // Topics of the last two videos: the same topics next rank lower.
    private func recentTopics() -> Set<String> {
        var result = Set<String>()
        for item in self.items.suffix(2) {
            result.formUnion(item.topics)
        }
        return result
    }

    // The channel's best video among its next six and its weight: freshness, topics, engagement, took off, format.
    private func bestVideo(in pool: Pool, allowSeen: Bool, recentTopics: Set<String>) -> (Video, Double)? {
        let options = self.candidates(in: pool, allowSeen: allowSeen, limit: 6)
        var best: (Video, Double)?
        var bestScore = -Double.greatestFiniteMagnitude
        for (index, option) in options.enumerated() {
            var factor = VideoFeedSmartSource.freshness(option) * self.taste.topicMultiplier(option.topics) * VideoFeedSmartSource.quality(option) * VideoFeedSmartSource.hit(option, in: pool) * option.format
            factor *= self.taste.shortTermMultiplier(peerId: pool.peer.id, topics: option.topics)
            let shared = option.topics.filter { recentTopics.contains($0) }
            if shared.count >= 3 {
                factor *= 0.55
            } else if shared.contains(where: { $0.hasPrefix("#") }) {
                factor *= 0.75
            }
            // Order within the channel matters a little too: all else equal, newer wins.
            let score = log(max(1e-9, factor)) - Double(index) * 0.03 + Double.random(in: 0.0 ..< 0.1)
            if score > bestScore {
                bestScore = score
                best = (option, factor)
            }
        }
        return best
    }

    private func pick(from pools: [Pool], allowSeen: Bool, explore: Bool, lineage: [EnginePeer.Id: Double]) -> (Pool, Video)? {
        let recentTopics = self.recentTopics()
        var options: [(pool: Pool, video: Video, weight: Double)] = []
        for pool in pools {
            // Unwatched goes far ahead.
            var seenPenalty = 1.0
            var choice = self.bestVideo(in: pool, allowSeen: false, recentTopics: recentTopics)
            if choice == nil && allowSeen {
                choice = self.bestVideo(in: pool, allowSeen: true, recentTopics: recentTopics)
                seenPenalty = 0.05
            }
            guard let (video, videoFactor) = choice else {
                continue
            }
            var weight: Double
            if explore {
                weight = VideoFeedSmartSource.freshness(video) * video.format
            } else {
                weight = self.effectiveWeight(pool.peer.id) * videoFactor
                if !pool.isSubscribed, let source = pool.sourcePeerId, let factor = lineage[source] {
                    weight *= factor
                }
                if !pool.isSubscribed {
                    weight *= VideoFeedSmartSource.reach(pool)
                }
            }
            // Many of this channel's videos today already: it steps back (an own channel less so).
            let todayViews = Double(self.taste.dayViewCount(peerId: pool.peer.id))
            weight *= exp(-max(0.0, todayViews - 3.0) / (pool.isSubscribed ? 14.0 : 9.0))
            weight *= seenPenalty
            if self.recentChannels.contains(pool.peer.id) {
                weight *= 0.06
            }
            // At most twice in the last 12 videos; channels not shown yet go first.
            let recentCount = self.items.suffix(12).filter { $0.message.id.peerId == pool.peer.id }.count
            if recentCount >= 2 {
                weight *= 0.15
            }
            if self.shownCount[pool.peer.id] == nil {
                weight *= pool.isSubscribed ? 1.2 : 1.6
            }
            options.append((pool, video, max(1e-9, weight)))
        }
        if options.isEmpty {
            return nil
        }
        let total = options.reduce(0.0, { $0 + $1.weight })
        var value = Double.random(in: 0.0 ..< total)
        for option in options {
            value -= option.weight
            if value <= 0.0 {
                return (option.pool, option.video)
            }
        }
        return (options[options.count - 1].pool, options[options.count - 1].video)
    }
}

// Runs a request that only completes (its result lands in the cache), then continues with `next`, which reads it.
private func videoFeedAfterCompletion<T>(of request: Signal<Never, NoError>, then next: Signal<T, NoError>) -> Signal<T, NoError> {
    return Signal { subscriber in
        let disposables = DisposableSet()
        disposables.add(request.start(completed: {
            disposables.add(next.start(next: { value in
                subscriber.putNext(value)
            }, completed: {
                subscriber.putCompletion()
            }))
        }))
        return disposables
    }
}

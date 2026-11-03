import Foundation
import TelegramCore

// The video feed's taste: what the feed learns, stored only on the device (per account).
// Two parts: affinity to a channel and affinity to topics, the words and hashtags of video captions.
// Watched to the end or rewatched: the channel and its topics score higher; skipped within a second: lower; a like:
// much higher; Not Interested: much lower; subscribed from the feed: highest. Hidden channels never enter the feed.
// It also remembers which videos were already shown, so For You does not repeat them.
// On top of the long-term taste there is a short-term interest, like TikTok within a session: what was watched in the
// last minutes weighs more and fades over about 20 minutes (not persisted), and a run of skips in a row means boredom,
// so the feed explores more boldly. A channel watched a lot today steps back for a while.
final class VideoFeedTaste {
    private static var instances: [EnginePeer.Id: VideoFeedTaste] = [:]

    static func shared(accountPeerId: EnginePeer.Id) -> VideoFeedTaste {
        if let current = instances[accountPeerId] {
            return current
        }
        let taste = VideoFeedTaste(accountPeerId: accountPeerId)
        instances[accountPeerId] = taste
        return taste
    }

    private let scoresKey: String
    private let seenKey: String
    private let likedKey: String
    private let hiddenKey: String
    private let topicsKey: String
    private var scores: [String: Double]
    private var seen: [String: Double]
    private var liked: [String: Double]
    private var hidden: [String: Double]
    private var topics: [String: Double]
    private var saveScheduled = false
    // Short-term interest: "c<channel>" and "t<topic>" -> value and when it last changed.
    private var shortTerm: [String: (value: Double, time: Double)] = [:]
    // How many videos in a row were skipped without watching (reset by a full watch or a like).
    private(set) var skipStreak = 0
    // The channel's videos over the last day (from what was seen), recomputed every couple of minutes.
    private var dayViews: (built: Double, counts: [Int64: Int])?

    private init(accountPeerId: EnginePeer.Id) {
        let suffix = "\(accountPeerId.toInt64())"
        self.scoresKey = "telegram.videofeed.scores.\(suffix)"
        self.seenKey = "telegram.videofeed.seen.\(suffix)"
        self.likedKey = "telegram.videofeed.liked.\(suffix)"
        self.hiddenKey = "telegram.videofeed.hidden.\(suffix)"
        self.topicsKey = "telegram.videofeed.topics.\(suffix)"
        let defaults = UserDefaults.standard
        self.scores = defaults.dictionary(forKey: self.scoresKey) as? [String: Double] ?? [:]
        self.seen = defaults.dictionary(forKey: self.seenKey) as? [String: Double] ?? [:]
        self.liked = defaults.dictionary(forKey: self.likedKey) as? [String: Double] ?? [:]
        self.hidden = defaults.dictionary(forKey: self.hiddenKey) as? [String: Double] ?? [:]
        self.topics = defaults.dictionary(forKey: self.topicsKey) as? [String: Double] ?? [:]
    }

    // MARK: - Channels

    // The learned affinity to a channel: 0 means nothing is known, above is liked, below is not.
    func score(peerId: EnginePeer.Id) -> Double {
        return self.scores["\(peerId.toInt64())"] ?? 0.0
    }

    // The channel's weight multiplier from its affinity (from ~0.2 to ~7).
    func multiplier(peerId: EnginePeer.Id) -> Double {
        return exp(self.score(peerId: peerId) / 4.0)
    }

    private func adjust(peerId: EnginePeer.Id, by delta: Double) {
        let key = "\(peerId.toInt64())"
        self.scores[key] = max(-7.0, min(8.0, (self.scores[key] ?? 0.0) + delta))
    }

    // Liked channels (by learned affinity), favourites first. The feed uses them even when
    // you are not subscribed: they are remembered between launches.
    func likedChannelIds(limit: Int) -> [EnginePeer.Id] {
        return self.scores.filter { $0.value >= 1.0 && self.hidden[$0.key] == nil }.sorted(by: { $0.value > $1.value }).prefix(limit).compactMap { Int64($0.key).flatMap(EnginePeer.Id.init) }
    }

    func isHidden(peerId: EnginePeer.Id) -> Bool {
        return self.hidden["\(peerId.toInt64())"] != nil
    }

    var hiddenCount: Int {
        return self.hidden.count
    }

    // MARK: - Topics

    // English and Russian stop words, never topics. Built with Set(_:) from an array: a Set literal with a duplicate
    // traps at launch.
    private static let stopWords = Set<String>([
        "this", "that", "with", "from", "have", "will", "your", "what", "when", "they", "them", "there", "their", "about", "just", "more", "into", "here", "were", "been", "only", "also", "than", "then", "some", "very", "like", "https",
        "это", "этот", "эта", "эти", "того", "тоже", "чтобы", "если", "когда", "потом", "только", "всех", "всем", "весь", "вся", "есть", "были", "было", "была", "будет", "будут", "можно", "нужно", "очень", "ещё", "еще", "уже", "даже", "просто", "которы", "котора", "свой", "своих", "своей", "наши", "наша", "наше", "ваши", "ваша", "вашей", "нашей", "через", "после", "перед", "между", "сегодня", "здесь", "там", "тут", "подписаться", "подпишись", "канал", "канала", "каналу"
    ])

    // A video's topics: whole hashtags and words of 4+ letters, the first 6 letters of long ones (so "kittens" and
    // "kittenish" are one topic). At most 14 topics per video.
    static func topics(text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let lowered = text.lowercased()
        var current = ""
        var isHashtag = false
        func flush() {
            defer {
                current = ""
                isHashtag = false
            }
            if current.count < (isHashtag ? 2 : 4) {
                return
            }
            if !isHashtag && current.allSatisfy({ $0.isNumber }) {
                return
            }
            var token = current
            if !isHashtag {
                if stopWords.contains(token) {
                    return
                }
                if token.count > 6 {
                    token = String(token.prefix(6))
                }
                if stopWords.contains(token) {
                    return
                }
            } else {
                token = "#" + token
            }
            if seen.insert(token).inserted {
                result.append(token)
            }
        }
        for character in lowered {
            if character.isLetter || character.isNumber || (isHashtag && character == "_") {
                current.append(character)
            } else {
                flush()
                if character == "#" {
                    isHashtag = true
                }
            }
            if result.count >= 14 {
                break
            }
        }
        flush()
        return Array(result.prefix(14))
    }

    // How much the video's topics are liked: the mean over known topics, hashtags weigh double. 0 means nothing is known.
    func topicScore(_ tokens: [String]) -> Double {
        var sum = 0.0
        var weight = 0.0
        for token in tokens {
            guard let value = self.topics[token] else {
                continue
            }
            let w = token.hasPrefix("#") ? 2.0 : 1.0
            sum += value * w
            weight += w
        }
        if weight == 0.0 {
            return 0.0
        }
        // Few known topics: be more careful.
        let confidence = min(1.0, weight / 3.0)
        return sum / weight * confidence
    }

    // Clearly liked hashtags: the feed searches for new channels by them.
    func favoriteHashtags(limit: Int) -> [String] {
        return self.topics.filter { $0.key.hasPrefix("#") && $0.value > 0.6 }.sorted(by: { $0.value > $1.value }).prefix(limit).map { $0.key }
    }

    // Multiplier from topics (from ~0.45 to ~2.2).
    func topicMultiplier(_ tokens: [String]) -> Double {
        return exp(max(-0.8, min(0.8, self.topicScore(tokens) / 3.0)))
    }

    private func adjustTopics(_ tokens: [String], by delta: Double) {
        if tokens.isEmpty || delta == 0.0 {
            return
        }
        let share = delta / sqrt(Double(tokens.count))
        for token in tokens {
            self.topics[token] = max(-6.0, min(6.0, (self.topics[token] ?? 0.0) + share))
        }
        // Keep at most 3000 topics: drop the weakest.
        if self.topics.count > 3400 {
            let sorted = self.topics.sorted(by: { abs($0.value) > abs($1.value) })
            self.topics = Dictionary(uniqueKeysWithValues: sorted.prefix(3000).map { ($0.key, $0.value) })
        }
    }

    // MARK: - Short-term interest

    private func shortTermValue(_ key: String, now: Double) -> Double {
        guard let entry = self.shortTerm[key] else {
            return 0.0
        }
        return entry.value * exp(-(now - entry.time) / 1200.0)
    }

    private func bumpShortTerm(peerId: EnginePeer.Id, topics tokens: [String], by delta: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        func bump(_ key: String, _ amount: Double) {
            let value = max(-6.0, min(6.0, self.shortTermValue(key, now: now) + amount))
            self.shortTerm[key] = (value, now)
        }
        bump("c\(peerId.toInt64())", delta)
        if !tokens.isEmpty {
            let share = delta * 0.8 / sqrt(Double(tokens.count))
            for token in tokens {
                bump("t" + token, share)
            }
        }
        // Drop what has faded so the dictionary does not grow.
        if self.shortTerm.count > 800 {
            self.shortTerm = self.shortTerm.filter { abs(self.shortTermValue($0.key, now: now)) > 0.05 }
        }
    }

    // Short-term interest multiplier for a video: channel and topics over the last minutes (from ~0.45 to ~2.2).
    func shortTermMultiplier(peerId: EnginePeer.Id, topics tokens: [String]) -> Double {
        if self.shortTerm.isEmpty {
            return 1.0
        }
        let now = CFAbsoluteTimeGetCurrent()
        var value = self.shortTermValue("c\(peerId.toInt64())", now: now)
        if !tokens.isEmpty {
            var sum = 0.0
            for token in tokens {
                sum += self.shortTermValue("t" + token, now: now)
            }
            value += sum / sqrt(Double(tokens.count))
        }
        return exp(max(-0.8, min(0.8, value / 3.0)))
    }

    // Bored: three videos in a row skipped without watching or marked Not Interested.
    var isBored: Bool {
        return self.skipStreak >= 3
    }

    // How many of the channel's videos were shown over the last day.
    func dayViewCount(peerId: EnginePeer.Id) -> Int {
        let now = Date().timeIntervalSince1970
        if self.dayViews == nil || now - self.dayViews!.built > 120.0 {
            var counts: [Int64: Int] = [:]
            for (key, time) in self.seen where now - time < 86400.0 && !key.hasPrefix("f") {
                // Video key: "<channel>_<namespace>_<id>".
                if let separator = key.firstIndex(of: "_"), let id = Int64(key[..<separator]) {
                    counts[id, default: 0] += 1
                }
            }
            self.dayViews = (now, counts)
        }
        return self.dayViews?.counts[peerId.toInt64()] ?? 0
    }

    // MARK: - Signals

    // Watch time is the main signal, as on TikTok, but adjusted for length: a short video is easy to finish, while 20 seconds
    // of a long one already means interest. Skipped within a second: much lower; within a couple of seconds: lower.
    func recordWatch(peerId: EnginePeer.Id, topics tokens: [String], seconds: Double, duration: Double) {
        let fraction = duration > 0.0 ? seconds / duration : 0.0
        var delta: Double = 0.0
        if seconds < 1.0 && fraction < 0.2 {
            delta = -0.8
        } else if seconds < 2.5 && fraction < 0.25 {
            delta = -0.4
        } else if fraction >= 1.8 {
            delta = 1.6
        } else if fraction >= 0.95 {
            delta = 1.0 + min(0.4, duration / 150.0)
        } else if fraction >= 0.5 {
            delta = 0.5
        } else if seconds >= 20.0 {
            delta = 0.4
        } else if fraction < 0.25 {
            delta = -0.15
        }
        if delta < -0.3 {
            self.skipStreak += 1
        } else if delta > 0.0 {
            self.skipStreak = 0
        }
        if delta != 0.0 {
            self.adjust(peerId: peerId, by: delta)
            self.adjustTopics(tokens, by: delta * 0.6)
            self.bumpShortTerm(peerId: peerId, topics: tokens, by: delta * 1.2)
            self.scheduleSave()
        }
    }

    func isLiked(_ key: String) -> Bool {
        return self.liked[key] != nil
    }

    func setLiked(_ key: String, peerId: EnginePeer.Id, topics tokens: [String], liked: Bool) {
        if liked == self.isLiked(key) {
            return
        }
        if liked {
            self.liked[key] = Date().timeIntervalSince1970
            if self.liked.count > 2200 {
                let sorted = self.liked.sorted(by: { $0.value > $1.value })
                self.liked = Dictionary(uniqueKeysWithValues: sorted.prefix(2000).map { ($0.key, $0.value) })
            }
        } else {
            self.liked.removeValue(forKey: key)
        }
        self.adjust(peerId: peerId, by: liked ? 2.2 : -2.2)
        self.adjustTopics(tokens, by: liked ? 1.6 : -1.6)
        self.bumpShortTerm(peerId: peerId, topics: tokens, by: liked ? 2.5 : -2.5)
        if liked {
            self.skipStreak = 0
        }
        self.scheduleSave()
    }

    func recordNotInterested(peerId: EnginePeer.Id, topics tokens: [String]) {
        self.adjust(peerId: peerId, by: -2.5)
        self.adjustTopics(tokens, by: -1.8)
        self.bumpShortTerm(peerId: peerId, topics: tokens, by: -3.5)
        self.skipStreak += 1
        self.scheduleSave()
    }

    func hideChannel(peerId: EnginePeer.Id) {
        self.hidden["\(peerId.toInt64())"] = Date().timeIntervalSince1970
        self.adjust(peerId: peerId, by: -4.0)
        self.scheduleSave()
    }

    func recordOpened(peerId: EnginePeer.Id) {
        self.adjust(peerId: peerId, by: 0.6)
        self.bumpShortTerm(peerId: peerId, topics: [], by: 1.5)
        self.scheduleSave()
    }

    func recordSubscribed(peerId: EnginePeer.Id) {
        self.adjust(peerId: peerId, by: 3.0)
        self.scheduleSave()
    }

    func unhideAll() {
        self.hidden = [:]
        self.saveNow()
    }

    func reset() {
        self.scores = [:]
        self.liked = [:]
        self.hidden = [:]
        self.topics = [:]
        self.seen = [:]
        self.shortTerm = [:]
        self.skipStreak = 0
        self.dayViews = nil
        self.saveNow()
    }

    // MARK: - Seen

    func isSeen(_ key: String) -> Bool {
        return self.seen[key] != nil
    }

    func markSeen(_ key: String) {
        if self.seen[key] == nil, !key.hasPrefix("f"), let separator = key.firstIndex(of: "_"), let id = Int64(key[..<separator]) {
            self.dayViews?.counts[id, default: 0] += 1
        }
        self.seen[key] = Date().timeIntervalSince1970
        // Remember the last ~4000 videos (two entries each: the message and the file).
        if self.seen.count > 9000 {
            let sorted = self.seen.sorted(by: { $0.value > $1.value })
            self.seen = Dictionary(uniqueKeysWithValues: sorted.prefix(8000).map { ($0.key, $0.value) })
        }
        self.scheduleSave()
    }

    private func scheduleSave() {
        if self.saveScheduled {
            return
        }
        self.saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: { [weak self] in
            guard let self else {
                return
            }
            self.saveScheduled = false
            self.saveNow()
        })
    }

    private func saveNow() {
        let defaults = UserDefaults.standard
        defaults.set(self.scores, forKey: self.scoresKey)
        defaults.set(self.seen, forKey: self.seenKey)
        defaults.set(self.liked, forKey: self.likedKey)
        defaults.set(self.hidden, forKey: self.hiddenKey)
        defaults.set(self.topics, forKey: self.topicsKey)
    }
}

/// Feed settings for a settings screen: hidden channels and resetting what the feed has learned.
public enum VideoFeedPreferences {
    public static func hiddenChannelsCount(accountPeerId: EnginePeer.Id) -> Int {
        return VideoFeedTaste.shared(accountPeerId: accountPeerId).hiddenCount
    }

    public static func unhideAllChannels(accountPeerId: EnginePeer.Id) {
        VideoFeedTaste.shared(accountPeerId: accountPeerId).unhideAll()
        VideoFeedSmartSource.clearCache()
    }

    public static func resetRecommendations(accountPeerId: EnginePeer.Id) {
        VideoFeedTaste.shared(accountPeerId: accountPeerId).reset()
        VideoFeedSmartSource.clearCache()
    }
}

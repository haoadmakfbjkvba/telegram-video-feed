import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ComponentFlow
import TelegramCore
import AccountContext
import TelegramPresentationData
import UniversalMediaPlayer
import GlassBackgroundComponent
import ContextUI

// The video feed: full-screen videos, scrolled vertically, like TikTok.
// Tabs: the chat it was opened from (when opened from a chat), Following (your channels' videos, newest first) and
// For You (your channels and similar ones mixed; the feed learns from what you watch, like and mark Not Interested).
// The interface is glass: Back, the tabs, the info card, the side buttons, pause. Only the current page plays, with
// sound and looped; tap pauses, double tap likes, hold plays at 2x. Scrolling past the end of a chat's feed continues
// into For You. Can live as a tab in the tab bar (`isTab`): no Back then, the icon is a stack of videos.
public final class VideoFeedScreen: ViewController {
    private enum Tab: Equatable {
        case chat
        case following
        case forYou
    }

    private let context: AccountContext
    private let presentationData: PresentationData
    private let isTab: Bool
    private let chatPeerId: EnginePeer.Id?
    private let chatThreadId: Int64?
    private let chatStartMessageId: EngineMessage.Id?
    private var chatTitle: String?
    private let tabs: [Tab]
    private var selectedTab: Tab
    private var sources: [Tab: VideoFeedSource] = [:]
    private var positions: [Tab: Int] = [:]
    private let taste: VideoFeedTaste
    private let disposables = DisposableSet()
    private var joiningPeerIds = Set<EnginePeer.Id>()
    private var justSubscribedPeerIds = Set<EnginePeer.Id>()
    private var isReplanScheduled = false

    private var feedNode: VideoFeedNode {
        return self.displayNode as! VideoFeedNode
    }

    /// A chat's feed (with Following and For You next to it).
    public init(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?, startMessageId: EngineMessage.Id?) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.isTab = false
        self.chatPeerId = peerId
        self.chatThreadId = threadId
        self.chatStartMessageId = startMessageId
        self.tabs = [.chat, .following, .forYou]
        self.selectedTab = .chat
        self.taste = VideoFeedTaste.shared(accountPeerId: context.account.peerId)
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .White
    }

    /// The general feed: Following and For You, opens on For You. `isTab` is the tab bar tab.
    public init(context: AccountContext, isTab: Bool = false) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.isTab = isTab
        self.chatPeerId = nil
        self.chatThreadId = nil
        self.chatStartMessageId = nil
        self.tabs = [.following, .forYou]
        self.selectedTab = .forYou
        self.taste = VideoFeedTaste.shared(accountPeerId: context.account.peerId)
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .White
        if isTab {
            let title = self.presentationData.strings.VideoFeed_Tab
            self.title = title
            self.tabBarItem.title = title
            let icon = videoFeedTabIcon()
            self.tabBarItem.image = icon
            self.tabBarItem.selectedImage = icon
            self.tabBarItemContextActionType = .always
            // Tapping the selected tab: back to the first video, and on the first one a fresh selection (like TikTok).
            self.scrollToTop = { [weak self] in
                guard let self, self.isNodeLoaded else {
                    return
                }
                if self.feedNode.currentPosition == 0 && self.feedNode.hasContent {
                    self.refreshCurrentFeed()
                } else {
                    self.feedNode.scrollTo(index: 0, animated: true)
                }
            }
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.disposables.dispose()
    }

    override public func loadDisplayNode() {
        self.displayNode = VideoFeedNode(context: self.context, presentationData: self.presentationData, showsBack: !self.isTab)
        let node = self.feedNode
        node.close = { [weak self] in
            self?.close()
        }
        node.tabSelected = { [weak self] index in
            guard let self, index < self.tabs.count else {
                return
            }
            self.select(tab: self.tabs[index])
        }
        node.nearEnd = { [weak self] in
            guard let self else {
                return
            }
            self.sources[self.selectedTab]?.loadMore(visibleIndex: self.feedNode.currentPosition)
        }
        node.reachedEnd = { [weak self] in
            guard let self, self.selectedTab == .chat else {
                return
            }
            self.select(tab: .forYou)
        }
        node.openInChat = { [weak self] item in
            self?.taste.recordOpened(peerId: item.message.id.peerId)
            self?.openChat(item: item, atMessage: true)
        }
        node.openChannel = { [weak self] item in
            self?.taste.recordOpened(peerId: item.message.id.peerId)
            self?.openChat(item: item, atMessage: false)
        }
        node.subscribe = { [weak self] item in
            self?.subscribe(item: item)
        }
        node.didWatch = { [weak self] item, seconds in
            guard let self else {
                return
            }
            let duration = item.file.duration ?? 0.0
            self.taste.recordWatch(peerId: item.message.id.peerId, topics: item.topics, seconds: seconds, duration: duration)
            if seconds >= 1.0 {
                self.taste.markSeen(item.key)
                self.taste.markSeen(item.fileKey)
            }
            self.scheduleReplan()
        }
        node.isLiked = { [weak self] item in
            return self?.taste.isLiked(item.key) ?? false
        }
        node.likeChanged = { [weak self] item, liked in
            guard let self else {
                return
            }
            self.taste.setLiked(item.key, peerId: item.message.id.peerId, topics: item.topics, liked: liked)
            self.scheduleReplan()
        }
        node.notInterested = { [weak self] item in
            guard let self else {
                return
            }
            self.taste.recordNotInterested(peerId: item.message.id.peerId, topics: item.topics)
            self.taste.markSeen(item.key)
            self.taste.markSeen(item.fileKey)
            HapticFeedback().impact(.light)
            self.feedNode.showToast(self.presentationData.strings.VideoFeed_NotInterestedToast)
            let position = self.feedNode.currentPosition
            self.sources[self.selectedTab]?.replan(keepingThrough: position)
            self.feedNode.dismissCurrent()
        }
        node.morePressed = { [weak self] item, sourceView in
            self?.openMoreMenu(item: item, sourceView: sourceView)
        }
        node.soundToggled = {
            VideoFeedPlayback.setMuted(!VideoFeedPlayback.isMuted)
        }
        node.actionFor = { [weak self] item in
            guard let self else {
                return .openInChat
            }
            if self.justSubscribedPeerIds.contains(item.message.id.peerId) {
                return .subscribed
            }
            if self.joiningPeerIds.contains(item.message.id.peerId) {
                return .joining
            }
            if !item.isSubscribed, case let .channel(channel) = item.peer, case .broadcast = channel.info {
                return .subscribe
            }
            return .openInChat
        }
        self.displayNodeDidLoad()

        if let chatPeerId = self.chatPeerId {
            let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: chatPeerId))
            |> deliverOnMainQueue).start(next: { [weak self] peer in
                guard let self, let peer else {
                    return
                }
                self.chatTitle = peer.compactDisplayTitle
                self.updateTabs(transition: .immediate)
            })
        }
        self.updateTabs(transition: .immediate)
        self.select(tab: self.selectedTab, force: true)
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.feedNode.update(layout: layout, transition: transition)
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.feedNode.setVisible(false)
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.feedNode.setVisible(true)
    }

    private func title(for tab: Tab) -> String {
        let strings = self.presentationData.strings
        switch tab {
        case .chat:
            return self.chatTitle ?? " "
        case .following:
            return strings.VideoFeed_Following
        case .forYou:
            return strings.VideoFeed_ForYou
        }
    }

    private func updateTabs(transition: ComponentTransition) {
        let index = self.tabs.firstIndex(of: self.selectedTab) ?? 0
        self.feedNode.updateTabs(titles: self.tabs.map { self.title(for: $0) }, selectedIndex: index, transition: transition)
    }

    private func source(for tab: Tab) -> VideoFeedSource {
        if let current = self.sources[tab] {
            return current
        }
        let source: VideoFeedSource
        switch tab {
        case .chat:
            source = VideoFeedChatSource(context: self.context, peerId: self.chatPeerId ?? self.context.account.peerId, threadId: self.chatThreadId, startMessageId: self.chatStartMessageId)
        case .following:
            source = VideoFeedSmartSource(context: self.context, mode: .following)
        case .forYou:
            source = VideoFeedSmartSource(context: self.context, mode: .forYou)
        }
        source.updated = { [weak self, weak source] in
            // During a tab switch the switch itself sets the feed, with everything the source has loaded by then.
            guard let self, let source, self.sources[self.selectedTab] === source, !self.feedNode.isSwitchingContent else {
                return
            }
            self.applySource(source, reset: false)
        }
        self.sources[tab] = source
        source.start()
        return source
    }

    private func select(tab: Tab, force: Bool = false) {
        if tab == self.selectedTab && !force {
            return
        }
        // Mid-switch the screen still shows the previous tab; its position is already saved.
        if self.isNodeLoaded, self.sources[self.selectedTab] != nil, !self.feedNode.isSwitchingContent {
            self.positions[self.selectedTab] = self.feedNode.currentPosition
        }
        let previousIndex = self.tabs.firstIndex(of: self.selectedTab) ?? 0
        self.selectedTab = tab
        self.updateTabs(transition: force ? .immediate : .spring(duration: 0.4))
        let source = self.source(for: tab)
        if force {
            self.applySource(source, reset: true)
        } else {
            let forward = (self.tabs.firstIndex(of: tab) ?? 0) > previousIndex
            self.feedNode.switchContent(forward: forward, apply: { [weak self] in
                guard let self else {
                    return
                }
                self.applySource(self.source(for: self.selectedTab), reset: true)
            })
        }
    }

    private func applySource(_ source: VideoFeedSource, reset: Bool) {
        let emptyText: String
        switch self.selectedTab {
        case .chat:
            emptyText = self.presentationData.strings.VideoFeed_EmptyChat
        case .following:
            emptyText = self.presentationData.strings.VideoFeed_EmptyFollowing
        case .forYou:
            emptyText = self.presentationData.strings.VideoFeed_EmptyForYou
        }
        guard let initialIndex = source.initialIndex else {
            self.feedNode.setItems([], isComplete: false, isReady: false, scrollTo: reset ? 0 : nil, emptyText: emptyText, canContinue: false)
            return
        }
        var scrollTo: Int?
        if reset {
            scrollTo = self.positions[self.selectedTab] ?? initialIndex
        } else if !self.feedNode.hasContent {
            scrollTo = initialIndex
        }
        self.feedNode.setItems(source.items, isComplete: source.isComplete, isReady: true, scrollTo: scrollTo, emptyText: emptyText, canContinue: self.selectedTab == .chat)
    }

    // The taste changed: For You picks everything after the next video again. On the next pass: the signal
    // comes from scrolling and from the feed's layout.
    private func scheduleReplan() {
        if self.isReplanScheduled {
            return
        }
        self.isReplanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isReplanScheduled = false
            guard self.isNodeLoaded, self.selectedTab == .forYou else {
                return
            }
            self.sources[.forYou]?.replan(keepingThrough: self.feedNode.currentPosition + 1)
        }
    }

    // More: Telegram's menu from the circle: don't show this channel, share, show in chat. Dark, like the feed itself.
    private func openMoreMenu(item: VideoFeedItem, sourceView: UIView) {
        let strings = self.presentationData.strings
        var items: [ContextMenuItem] = []
        if self.selectedTab != .chat, case let .channel(channel) = item.peer, case .broadcast = channel.info {
            items.append(.action(ContextMenuActionItem(text: strings.VideoFeed_HideChannel, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Peer Info/HideIcon"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    self?.hideChannel(item: item)
                })
            })))
        }
        // Content protected from forwarding is neither saved nor forwarded, as in Telegram itself.
        let isProtected = item.message.isCopyProtected()
        if case .channel = item.peer, !isProtected {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuShare, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    self?.share(item: item)
                })
            })))
        }
        if !isProtected {
            items.append(.action(ContextMenuActionItem(text: strings.VideoFeed_SaveToSaved, icon: { theme in
                return videoFeedMenuIcon("bookmark", color: theme.contextMenu.primaryColor)
            }, action: { [weak self] c, _ in
                c?.dismiss(completion: {
                    self?.saveToSavedMessages(item: item)
                })
            })))
        }
        items.append(.action(ContextMenuActionItem(text: strings.SharedMedia_ViewInChat, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/GoToMessage"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] c, _ in
            c?.dismiss(completion: {
                guard let self else {
                    return
                }
                self.taste.recordOpened(peerId: item.message.id.peerId)
                self.openChat(item: item, atMessage: true)
            })
        })))
        let presentationData = self.presentationData.withUpdated(theme: defaultDarkColorPresentationTheme)
        let controller = makeContextController(presentationData: presentationData, source: .reference(VideoFeedViewContextReferenceContentSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: nil)
        // While the menu is open, auto-advance does not scroll.
        self.feedNode.setInteractionHold(true)
        controller.dismissed = { [weak self] in
            self?.feedNode.setInteractionHold(false)
        }
        self.presentInGlobalOverlay(controller)
    }

    // Save to Saved Messages by forwarding, like Forward in a chat; confirmed with the feed's toast.
    private func saveToSavedMessages(item: VideoFeedItem) {
        let _ = enqueueMessages(account: self.context.account, peerId: self.context.account.peerId, messages: [.forward(source: item.message.id, threadId: nil, grouping: .auto, attributes: [], correlationId: nil)]).startStandalone()
        HapticFeedback().success()
        self.feedNode.showToast(self.presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One.replacingOccurrences(of: "**", with: ""))
    }

    // A fresh selection on the same tab: what was picked and shown is reset, the channels' latest videos are reloaded,
    // and what was already watched is not repeated.
    private func refreshCurrentFeed() {
        guard self.selectedTab != .chat, let source = self.sources[self.selectedTab] else {
            return
        }
        HapticFeedback().impact(.medium)
        let tab = self.selectedTab
        self.feedNode.refreshContent(apply: { [weak self] in
            guard let self, self.selectedTab == tab else {
                return
            }
            source.refresh()
            self.positions[tab] = nil
            self.applySource(source, reset: true)
            self.feedNode.showToast(self.presentationData.strings.VideoFeed_Refreshed)
        })
    }

    // Telegram's Share sheet: to your chats or as a link.
    private func share(item: VideoFeedItem) {
        let presentationData = self.presentationData.withUpdated(theme: defaultDarkColorPresentationTheme)
        self.feedNode.setInteractionHold(true)
        let controller = self.context.sharedContext.makeShareScreen(context: self.context, params: ShareControllerParams(subject: .messages([item.message]), externalShare: true, updatedPresentationData: (presentationData, .single(presentationData)), dismissed: { [weak self] _ in
            self?.feedNode.setInteractionHold(false)
        }))
        self.present(controller, in: .window(.root))
    }

    private func hideChannel(item: VideoFeedItem) {
        let peerId = item.message.id.peerId
        self.taste.hideChannel(peerId: peerId)
        HapticFeedback().impact(.light)
        self.feedNode.showToast(self.presentationData.strings.VideoFeed_ChannelHidden)
        let position = self.feedNode.currentPosition
        for (tab, source) in self.sources where tab != .chat {
            source.removeChannel(peerId: peerId, keepingThrough: tab == self.selectedTab ? position : (self.positions[tab] ?? 0))
        }
        self.feedNode.dismissCurrent()
    }

    override public func tabBarItemContextAction(sourceView: ContextExtractedContentContainingView, gesture: ContextGesture) {
        guard self.isTab else {
            return
        }
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.VideoFeed_HideTab, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Peer Info/HideIcon"), color: theme.contextMenu.primaryColor)
        }, action: { c, _ in
            c?.dismiss(completion: {
                VideoFeedTab.setEnabled(false)
            })
        })))
        let controller = makeContextController(presentationData: self.presentationData, source: .reference(VideoFeedTabContextReferenceContentSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: gesture)
        self.context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
    }

    private func close() {
        if self.isTab {
            return
        }
        if let navigationController = self.navigationController as? NavigationController {
            navigationController.filterController(self, animated: true)
        } else {
            self.dismiss()
        }
    }

    private func openChat(item: VideoFeedItem, atMessage: Bool) {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        let context = self.context
        let messageId = item.message.id
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: messageId.peerId))
        |> deliverOnMainQueue).start(next: { peer in
            guard let peer else {
                return
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), subject: atMessage ? .message(id: .id(messageId), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false) : nil))
        })
    }

    private func subscribe(item: VideoFeedItem) {
        let peerId = item.message.id.peerId
        if self.joiningPeerIds.contains(peerId) {
            return
        }
        self.joiningPeerIds.insert(peerId)
        HapticFeedback().impact(.light)
        self.feedNode.refreshCard()
        self.disposables.add((self.context.engine.peers.joinChannel(peerId: peerId, hash: nil)
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else {
                return
            }
            if case .webView = result {
                // The channel asks to confirm joining on its own page: open the channel.
                self.joiningPeerIds.remove(peerId)
                self.feedNode.refreshCard()
                self.openChat(item: item, atMessage: false)
            }
        }, error: { [weak self] _ in
            guard let self else {
                return
            }
            self.joiningPeerIds.remove(peerId)
            HapticFeedback().error()
            self.feedNode.refreshCard()
        }, completed: { [weak self] in
            guard let self else {
                return
            }
            self.joiningPeerIds.remove(peerId)
            for source in self.sources.values {
                source.markSubscribed(peerId: peerId)
            }
            self.justSubscribedPeerIds.insert(peerId)
            HapticFeedback().success()
            if let source = self.sources[self.selectedTab] {
                self.applySource(source, reset: false)
            }
            // "Subscribed" stays for a couple of seconds, then the regular button returns.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: { [weak self] in
                guard let self else {
                    return
                }
                self.justSubscribedPeerIds.remove(peerId)
                self.feedNode.refreshCard()
            })
        }))
    }
}

// A menu item icon from a system symbol, in a 24 pt frame like Telegram's menu icons.
private func videoFeedMenuIcon(_ name: String, color: UIColor) -> UIImage? {
    guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .regular)) else {
        return nil
    }
    let size = CGSize(width: 24.0, height: 24.0)
    let format = UIGraphicsImageRendererFormat.preferred()
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        let symbolSize = symbol.size
        symbol.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(x: floor((size.width - symbolSize.width) / 2.0), y: floor((size.height - symbolSize.height) / 2.0), width: symbolSize.width, height: symbolSize.height))
    }
}

// The tab icon: a stack of videos, the same size as Telegram's tab icons.
private func videoFeedTabIcon() -> UIImage? {
    let size = CGSize(width: 30.0, height: 30.0)
    guard let symbol = UIImage(systemName: "play.square.stack.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 23.0, weight: .medium)) else {
        return nil
    }
    let format = UIGraphicsImageRendererFormat.preferred()
    format.opaque = false
    let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        let symbolSize = symbol.size
        symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(x: floor((size.width - symbolSize.width) / 2.0), y: floor((size.height - symbolSize.height) / 2.0), width: symbolSize.width, height: symbolSize.height))
    }
    return image.withRenderingMode(.alwaysTemplate)
}

private final class VideoFeedViewContextReferenceContentSource: ContextReferenceContentSource {
    let keepInPlace: Bool = true
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: UIScreen.main.bounds, actionsPosition: .top)
    }
}

private final class VideoFeedTabContextReferenceContentSource: ContextReferenceContentSource {
    let keepInPlace: Bool = true
    private let sourceView: ContextExtractedContentContainingView

    init(sourceView: ContextExtractedContentContainingView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView.contentView, contentAreaInScreenSpace: UIScreen.main.bounds, actionsPosition: .top)
    }
}

private final class VideoFeedNode: ASDisplayNode, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let showsBack: Bool

    private let scrollView = UIScrollView()
    private var pages: [Int: VideoFeedPageNode] = [:]
    private var pageKeys: [Int: String] = [:]
    private var items: [VideoFeedItem] = []
    private var isComplete = false
    private var isReady = false
    private var canContinue = false
    private var currentIndex = 0
    private var activeIndex: Int?
    private var isFeedVisible = true
    private var isInWindow = false
    private var isAppActive = true
    private var appObservers: [NSObjectProtocol] = []
    private var validLayout: ContainerViewLayout?

    // Screen layers: the videos (with pause, loading, empty state) in `contentView`; the card and side buttons in `overlayHost`,
    // inside it `overlayContainer`. A tab switch moves both upper layers, scrolling moves only `overlayContainer`
    // (each has its own fade, so the animations don't interfere).
    private let contentView = VideoFeedPassthroughView()
    private let overlayHost = VideoFeedPassthroughView()
    private let overlayContainer = VideoFeedPassthroughView()
    private var contentSwitchGeneration = 0
    private(set) var isSwitchingContent = false
    private let topBar = VideoFeedTopBar()
    private let dimView = UIView()
    private let card = VideoFeedInfoCard()
    private let sideActions = VideoFeedSideActions()
    private let speedGlass = GlassBackgroundView()
    private let speedLabel = UILabel()
    private let pauseGlass = GlassBackgroundView()
    private let pauseGlyph = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let emptyGlass = GlassBackgroundView()
    private let emptyLabel = UILabel()
    private let continueGlass = GlassBackgroundView()
    private let continueLabel = UILabel()
    private let toastGlass = GlassBackgroundView()
    private let toastLabel = UILabel()
    private var toastHideWork: DispatchWorkItem?
    // Scrubbing: the time above the card while the bar is dragged.
    private let timeGlass = GlassBackgroundView()
    private let timeLabel = UILabel()
    private var isScrubbing = false
    private var lastScrubSeek: Double = 0.0
    // The current video's latest status: its duration for scrubbing and its end time for auto-advance.
    private var lastStatus: MediaPlayerStatus?
    private var autoAdvanceWork: DispatchWorkItem?
    // A menu or sheet is open above the feed: the feed does not scroll by itself.
    private var interactionHolds = 0
    private var isMuted = VideoFeedPlayback.isMuted
    private var tabPan: UIPanGestureRecognizer?

    private let statusDisposable = MetaDisposable()
    private var prefetchDisposables: [String: Disposable] = [:]
    private var isPausedByUser = false
    private var activeSince: Double?
    private var pausedSince: Double?
    private var pausedTotal: Double = 0.0
    private var tabTitles: [String] = []
    private var selectedTabIndex = 0

    var close: (() -> Void)?
    var tabSelected: ((Int) -> Void)?
    var nearEnd: (() -> Void)?
    var reachedEnd: (() -> Void)?
    var openInChat: ((VideoFeedItem) -> Void)?
    var openChannel: ((VideoFeedItem) -> Void)?
    var subscribe: ((VideoFeedItem) -> Void)?
    var didWatch: ((VideoFeedItem, Double) -> Void)?
    var actionFor: ((VideoFeedItem) -> VideoFeedInfoCard.Action)?
    var isLiked: ((VideoFeedItem) -> Bool)?
    var likeChanged: ((VideoFeedItem, Bool) -> Void)?
    var notInterested: ((VideoFeedItem) -> Void)?
    var morePressed: ((VideoFeedItem, UIView) -> Void)?
    var soundToggled: (() -> Void)?

    var currentPosition: Int {
        return self.currentIndex
    }

    var hasContent: Bool {
        return !self.items.isEmpty
    }

    init(context: AccountContext, presentationData: PresentationData, showsBack: Bool) {
        self.context = context
        self.presentationData = presentationData
        self.showsBack = showsBack
        super.init()
        self.backgroundColor = .black
    }

    deinit {
        self.statusDisposable.dispose()
        for (_, disposable) in self.prefetchDisposables {
            disposable.dispose()
        }
        for observer in self.appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func didLoad() {
        super.didLoad()

        // The app went to the background (or Control Center opened): the video pauses, and resumes on return.
        self.appObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.isAppActive = false
            self?.updateActivePage()
        }))
        self.appObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.isAppActive = true
            self?.updateActivePage()
        }))
        // Sound and auto-advance can change from outside the feed too.
        self.appObservers.append(NotificationCenter.default.addObserver(forName: VideoFeedPlayback.changedNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.playbackSettingsChanged()
        }))

        self.scrollView.isPagingEnabled = true
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.alwaysBounceVertical = true
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.scrollView.scrollsToTop = false
        self.scrollView.delegate = self
        self.view.addSubview(self.contentView)
        self.contentView.addSubview(self.scrollView)

        // Double tap likes; a single tap (pause) waits to see whether a second one follows.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(self.doubleTapGesture(_:)))
        doubleTap.numberOfTapsRequired = 2
        self.scrollView.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        tap.require(toFail: doubleTap)
        self.scrollView.addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressGesture(_:)))
        longPress.minimumPressDuration = 0.35
        self.scrollView.addGestureRecognizer(longPress)
        // A horizontal swipe switches to the neighbouring tab (like Following / For You on TikTok); vertical scrolling is untouched.
        let tabPan = UIPanGestureRecognizer(target: self, action: #selector(self.tabPanGesture(_:)))
        tabPan.delegate = self
        self.scrollView.addGestureRecognizer(tabPan)
        self.tabPan = tabPan
        // A right swipe with a tab on the left is the tab, not Back.
        self.scrollView.disablesInteractiveTransitionGestureRecognizerNow = { [weak self] in
            guard let self else {
                return false
            }
            return self.selectedTabIndex > 0
        }

        // Dimming under the expanded caption; a tap collapses it.
        self.dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        self.dimView.alpha = 0.0
        self.dimView.isUserInteractionEnabled = false
        self.dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapped)))
        self.view.addSubview(self.dimView)
        self.view.addSubview(self.overlayHost)
        self.overlayHost.addSubview(self.overlayContainer)

        self.pauseGlyph.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30.0, weight: .regular))
        self.pauseGlyph.tintColor = .white
        self.pauseGlyph.contentMode = .center
        self.pauseGlass.contentView.addSubview(self.pauseGlyph)
        self.pauseGlass.isUserInteractionEnabled = false
        self.pauseGlass.alpha = 0.0
        self.contentView.addSubview(self.pauseGlass)

        self.speedLabel.text = "2×"
        self.speedLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        self.speedLabel.textColor = .white
        self.speedLabel.textAlignment = .center
        self.speedGlass.contentView.addSubview(self.speedLabel)
        self.speedGlass.isUserInteractionEnabled = false
        self.speedGlass.alpha = 0.0

        self.card.isHidden = true
        self.card.openChannel = { [weak self] in
            guard let self, let item = self.currentItem else {
                return
            }
            self.openChannel?(item)
        }
        self.card.actionPressed = { [weak self] action in
            guard let self, let item = self.currentItem else {
                return
            }
            switch action {
            case .subscribe:
                self.subscribe?(item)
            case .joining:
                break
            case .subscribed, .openInChat:
                self.openInChat?(item)
            }
        }
        self.card.scrubBegan = { [weak self] in
            self?.scrubBegan()
        }
        self.card.scrubMoved = { [weak self] fraction in
            self?.scrubMoved(fraction: fraction)
        }
        self.card.scrubEnded = { [weak self] fraction in
            self?.scrubEnded(fraction: fraction)
        }
        self.card.expandedChanged = { [weak self] expanded in
            guard let self else {
                return
            }
            self.dimView.isUserInteractionEnabled = expanded
            UIView.animate(withDuration: 0.25, animations: {
                self.dimView.alpha = expanded ? 1.0 : 0.0
                self.sideActions.alpha = expanded ? 0.0 : 1.0
            })
            self.layoutOverlays(transition: .spring(duration: 0.45))
            if expanded {
                self.cancelAutoAdvance()
            } else {
                self.scheduleAutoAdvance()
            }
        }
        self.overlayContainer.addSubview(self.card)

        let strings = self.presentationData.strings
        self.sideActions.isHidden = true
        self.sideActions.setAccessibilityLabels(like: strings.VideoFeed_Like, dislike: strings.VideoFeed_NotInterested, more: strings.VideoFeed_ShowMore)
        self.sideActions.likePressed = { [weak self] in
            guard let self, let item = self.currentItem else {
                return
            }
            let liked = !(self.isLiked?(item) ?? false)
            if liked {
                HapticFeedback().impact(.light)
            }
            self.likeChanged?(item, liked)
            self.sideActions.setLiked(liked, animated: true)
        }
        self.sideActions.dislikePressed = { [weak self] in
            guard let self, let item = self.currentItem else {
                return
            }
            self.notInterested?(item)
        }
        self.sideActions.morePressed = { [weak self] sourceView in
            guard let self, let item = self.currentItem else {
                return
            }
            self.morePressed?(item, sourceView)
        }
        self.overlayContainer.addSubview(self.sideActions)

        self.view.addSubview(self.speedGlass)

        self.topBar.backPressed = { [weak self] in
            self?.close?()
        }
        self.topBar.soundPressed = { [weak self] in
            HapticFeedback().impact(.light)
            self?.soundToggled?()
        }
        self.topBar.setMuted(self.isMuted, accessibilityLabel: self.isMuted ? strings.Conversation_Unmute : strings.Conversation_Mute)
        self.topBar.tabSelected = { [weak self] index in
            self?.tabSelected?(index)
        }
        self.view.addSubview(self.topBar)

        self.activityIndicator.color = .white
        self.activityIndicator.startAnimating()
        self.contentView.addSubview(self.activityIndicator)

        self.emptyLabel.font = UIFont.systemFont(ofSize: 16.0, weight: .medium)
        self.emptyLabel.textColor = UIColor(white: 1.0, alpha: 0.85)
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.numberOfLines = 0
        self.emptyGlass.contentView.addSubview(self.emptyLabel)
        self.emptyGlass.alpha = 0.0
        self.emptyGlass.isUserInteractionEnabled = false
        self.contentView.addSubview(self.emptyGlass)

        self.continueLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
        self.continueLabel.textColor = .white
        self.continueLabel.textAlignment = .center
        self.continueLabel.text = self.presentationData.strings.VideoFeed_ContinueHint
        self.continueGlass.contentView.addSubview(self.continueLabel)
        self.continueGlass.isUserInteractionEnabled = false
        self.continueGlass.alpha = 0.0
        self.overlayContainer.addSubview(self.continueGlass)

        self.toastLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
        self.toastLabel.textColor = .white
        self.toastLabel.textAlignment = .center
        self.toastGlass.contentView.addSubview(self.toastLabel)
        self.toastGlass.isUserInteractionEnabled = false
        self.toastGlass.alpha = 0.0
        self.view.addSubview(self.toastGlass)

        self.timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 17.0, weight: .semibold)
        self.timeLabel.textColor = .white
        self.timeLabel.textAlignment = .center
        self.timeGlass.contentView.addSubview(self.timeLabel)
        self.timeGlass.isUserInteractionEnabled = false
        self.timeGlass.alpha = 0.0
        self.view.addSubview(self.timeGlass)
    }

    // As a tab bar tab, the feed leaves the window without viewDidDisappear: pause when it leaves the hierarchy.
    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        self.isInWindow = true
        self.updateActivePage()
    }

    override func didExitHierarchy() {
        super.didExitHierarchy()
        self.isInWindow = false
        self.updateActivePage()
    }

    private var currentItem: VideoFeedItem? {
        return self.currentIndex < self.items.count ? self.items[self.currentIndex] : nil
    }

    func updateTabs(titles: [String], selectedIndex: Int, transition: ComponentTransition) {
        self.tabTitles = titles
        self.selectedTabIndex = selectedIndex
        if let layout = self.validLayout {
            self.topBar.update(width: layout.size.width, sideInset: 16.0 + max(layout.safeInsets.left, layout.safeInsets.right), tabs: titles, selectedIndex: selectedIndex, showsBack: self.showsBack, transition: transition)
        }
    }

    func setItems(_ items: [VideoFeedItem], isComplete: Bool, isReady: Bool, scrollTo: Int?, emptyText: String, canContinue: Bool) {
        let reset = scrollTo != nil
        if reset {
            // A new feed (another tab): pages and watch tracking start over.
            self.finishWatching()
            for (_, page) in self.pages {
                page.removeFromSupernode()
            }
            self.pages.removeAll()
            self.pageKeys.removeAll()
            self.activeIndex = nil
            self.card.setExpanded(false)
        }
        let hadItems = !self.items.isEmpty
        self.items = items
        self.isComplete = isComplete
        self.isReady = isReady
        self.canContinue = canContinue
        // Videos after the current one were picked again: pages with the old videos are removed.
        for (index, page) in self.pages where index >= items.count || self.pageKeys[index] != items[index].key {
            page.removeFromSupernode()
            self.pages.removeValue(forKey: index)
            self.pageKeys.removeValue(forKey: index)
        }
        self.activityIndicator.isHidden = isReady && (!items.isEmpty || isComplete)
        // Empty state: its text changes only while it is being shown (otherwise the fading placeholder flashed the text of another
        // tab); when videos arrive the placeholder leaves at once, the feed itself covers it.
        let showsEmpty = isReady && items.isEmpty && isComplete
        if showsEmpty {
            self.emptyLabel.text = emptyText
            if self.emptyGlass.alpha == 0.0 {
                self.emptyGlass.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
                UIView.animate(withDuration: 0.4, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, options: [.beginFromCurrentState], animations: {
                    self.emptyGlass.alpha = 1.0
                    self.emptyGlass.transform = .identity
                }, completion: nil)
            }
        } else if self.emptyGlass.alpha > 0.0 {
            self.emptyGlass.layer.removeAllAnimations()
            if items.isEmpty {
                UIView.animate(withDuration: 0.2, delay: 0.0, options: [.beginFromCurrentState], animations: {
                    self.emptyGlass.alpha = 0.0
                }, completion: nil)
            } else {
                self.emptyGlass.alpha = 0.0
            }
        }
        if let scrollTo {
            self.currentIndex = max(0, min(scrollTo, max(0, items.count - 1)))
        } else if self.currentIndex >= items.count && !items.isEmpty {
            self.currentIndex = items.count - 1
        }
        if let layout = self.validLayout {
            self.layoutScroll(size: layout.size, resetOffset: reset)
            self.layoutOverlays(transition: .immediate)
        }
        // More videos arrived: auto-advance may have been waiting for the next one.
        if self.autoAdvanceWork == nil {
            self.scheduleAutoAdvance()
        }
        // The first videos after loading fade in, the card rises slightly into place (during a tab switch the switch itself
        // handles the appearance).
        if !hadItems && !items.isEmpty && !self.isSwitchingContent {
            self.scrollView.alpha = 0.0
            self.overlayContainer.alpha = 0.0
            self.overlayContainer.transform = CGAffineTransform(translationX: 0.0, y: 18.0)
            UIView.animate(withDuration: 0.45, delay: 0.0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.0, options: [.allowUserInteraction], animations: {
                self.scrollView.alpha = 1.0
                self.overlayContainer.alpha = 1.0
                self.overlayContainer.transform = .identity
            }, completion: nil)
        }
    }

    // Tab switch: the old videos slide and fade towards the new tab, the new ones arrive from the other side.
    // `apply` sets the new feed once the old one is no longer visible. A new call during a switch cancels the previous `apply`.
    func switchContent(forward: Bool, apply: @escaping () -> Void) {
        self.contentSwitchGeneration += 1
        let generation = self.contentSwitchGeneration
        self.isSwitchingContent = true
        // After a horizontal swipe the feed has already followed the finger: it continues from there.
        let dragged = abs(self.contentView.transform.tx)
        let shift: CGFloat = (forward ? -1.0 : 1.0) * max(32.0, dragged + 24.0)
        let layers: [UIView] = [self.contentView, self.overlayHost]
        UIView.animate(withDuration: 0.14, delay: 0.0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
            for view in layers {
                view.alpha = 0.0
                view.transform = CGAffineTransform(translationX: shift, y: 0.0)
            }
        }, completion: { [weak self] _ in
            guard let self, generation == self.contentSwitchGeneration else {
                return
            }
            apply()
            self.isSwitchingContent = false
            let enterShift: CGFloat = forward ? 32.0 : -32.0
            for view in layers {
                view.transform = CGAffineTransform(translationX: enterShift, y: 0.0)
            }
            UIView.animate(withDuration: 0.45, delay: 0.0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                for view in layers {
                    view.alpha = 1.0
                    view.transform = .identity
                }
            }, completion: nil)
        })
    }

    func setVisible(_ isVisible: Bool) {
        self.isFeedVisible = isVisible
        self.updateActivePage()
    }

    func refreshCard() {
        self.layoutOverlays(transition: .spring(duration: 0.4))
    }

    // MARK: - Sound and auto-advance

    private func playbackSettingsChanged() {
        let muted = VideoFeedPlayback.isMuted
        if muted != self.isMuted {
            self.isMuted = muted
            for (_, page) in self.pages {
                page.setSoundEnabled(!muted)
            }
            let strings = self.presentationData.strings
            self.topBar.setMuted(muted, accessibilityLabel: muted ? strings.Conversation_Unmute : strings.Conversation_Mute)
        }
        if VideoFeedPlayback.autoAdvance {
            self.scheduleAutoAdvance()
        } else {
            self.cancelAutoAdvance()
        }
    }

    // A menu or sheet above the feed: while it is open, the feed does not scroll by itself.
    func setInteractionHold(_ hold: Bool) {
        self.interactionHolds = max(0, self.interactionHolds + (hold ? 1 : -1))
        if self.interactionHolds == 0 {
            self.scheduleAutoAdvance()
        } else {
            self.cancelAutoAdvance()
        }
    }

    private func cancelAutoAdvance() {
        self.autoAdvanceWork?.cancel()
        self.autoAdvanceWork = nil
    }

    // Near the end of the video (from the player status, adjusted for speed) the feed scrolls to the next one slightly early,
    // so the start of the loop does not flash.
    private func scheduleAutoAdvance() {
        self.cancelAutoAdvance()
        guard VideoFeedPlayback.autoAdvance, self.activeIndex != nil, self.currentIndex + 1 < self.items.count, let status = self.lastStatus, status.duration > 1.0, status.baseRate > 0.0 else {
            return
        }
        guard case .playing = status.status else {
            return
        }
        let timestamp = status.timestamp + max(0.0, CACurrentMediaTime() - status.generationTimestamp) * status.baseRate
        let remaining = (status.duration - timestamp) / status.baseRate
        let work = DispatchWorkItem { [weak self] in
            self?.performAutoAdvance()
        }
        self.autoAdvanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, remaining - 0.15), execute: work)
    }

    private func performAutoAdvance() {
        self.autoAdvanceWork = nil
        guard VideoFeedPlayback.autoAdvance, !self.isScrubbing, !self.isPausedByUser, !self.card.isExpanded, self.interactionHolds == 0, !self.scrollView.isTracking, !self.scrollView.isDecelerating, !self.isSwitchingContent, self.activeIndex == self.currentIndex, self.currentIndex + 1 < self.items.count else {
            return
        }
        self.scrollTo(index: self.currentIndex + 1, animated: true)
    }

    // MARK: - Scrubbing

    private var currentDuration: Double? {
        if let duration = self.lastStatus?.duration, duration > 0.0 {
            return duration
        }
        if let duration = self.currentItem?.file.duration, duration > 0.0 {
            return duration
        }
        return nil
    }

    private static func timeString(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func scrubBegan() {
        guard let active = self.activeIndex, let page = self.pages[active] else {
            return
        }
        self.isScrubbing = true
        self.cancelAutoAdvance()
        page.setPaused(true)
        HapticFeedback().impact(.light)
        self.timeGlass.transform = CGAffineTransform(translationX: 0.0, y: 8.0).scaledBy(x: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.35, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, options: [.beginFromCurrentState], animations: {
            self.timeGlass.alpha = 1.0
            self.timeGlass.transform = .identity
            self.sideActions.alpha = 0.0
        }, completion: nil)
    }

    private func scrubMoved(fraction: CGFloat) {
        guard self.isScrubbing, let duration = self.currentDuration, let active = self.activeIndex, let page = self.pages[active] else {
            return
        }
        let time = Double(fraction) * duration
        self.timeLabel.text = "\(VideoFeedNode.timeString(time)) / \(VideoFeedNode.timeString(duration))"
        self.layoutTimeGlass()
        // Seek under the finger at most every 80 ms, otherwise the player can't keep up and stutters.
        let now = CACurrentMediaTime()
        if now - self.lastScrubSeek > 0.08 {
            self.lastScrubSeek = now
            page.seek(time)
        }
    }

    private func scrubEnded(fraction: CGFloat) {
        guard self.isScrubbing else {
            return
        }
        self.isScrubbing = false
        if let duration = self.currentDuration, let active = self.activeIndex, let page = self.pages[active] {
            page.seek(min(Double(fraction) * duration, max(0.0, duration - 0.3)))
            if !self.isPausedByUser {
                page.setPaused(false)
            }
        }
        UIView.animate(withDuration: 0.25, delay: 0.0, options: [.beginFromCurrentState], animations: {
            self.timeGlass.alpha = 0.0
            self.timeGlass.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            self.sideActions.alpha = self.card.isExpanded ? 0.0 : 1.0
        }, completion: nil)
    }

    private func layoutTimeGlass() {
        let text = self.timeLabel.text ?? ""
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: self.timeLabel.font!]).width)
        let size = CGSize(width: textWidth + 36.0, height: 40.0)
        let frame = CGRect(x: floor((self.view.bounds.width - size.width) * 0.5), y: self.card.frame.minY - 14.0 - size.height, width: size.width, height: size.height)
        self.timeGlass.bounds = CGRect(origin: CGPoint(), size: size)
        self.timeGlass.center = CGPoint(x: frame.midX, y: frame.midY)
        self.timeGlass.update(size: size, cornerRadius: size.height * 0.5, isDark: true, tintColor: .init(kind: .panel), transition: .immediate)
        self.timeLabel.frame = CGRect(origin: CGPoint(), size: size)
    }

    // MARK: - Horizontal swipe between tabs

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === self.tabPan, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        if self.card.isExpanded || self.isScrubbing || self.tabTitles.count < 2 {
            return false
        }
        let velocity = pan.velocity(in: self.view)
        guard abs(velocity.x) > abs(velocity.y) * 1.3 else {
            return false
        }
        // Only towards an existing tab: on the outermost one, swiping outward is left to the system (Back).
        let target = self.selectedTabIndex + (velocity.x < 0.0 ? 1 : -1)
        return target >= 0 && target < self.tabTitles.count
    }

    @objc private func tabPanGesture(_ recognizer: UIPanGestureRecognizer) {
        let width = max(1.0, self.view.bounds.width)
        let translation = recognizer.translation(in: self.view).x
        let layers: [UIView] = [self.contentView, self.overlayHost]
        switch recognizer.state {
        case .changed:
            // The feed follows the finger at half speed and fades towards the edge.
            let offset = translation * 0.5
            let alpha = 1.0 - min(0.6, abs(translation) / width)
            for view in layers {
                view.transform = CGAffineTransform(translationX: offset, y: 0.0)
                view.alpha = alpha
            }
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: self.view).x
            let direction = translation < 0.0 ? 1 : -1
            let target = self.selectedTabIndex + direction
            let passed = abs(translation) > width * 0.22 || abs(velocity) > 600.0
            let sameDirection = (velocity == 0.0) || ((velocity < 0.0) == (translation < 0.0))
            if recognizer.state == .ended && passed && sameDirection && target >= 0 && target < self.tabTitles.count {
                HapticFeedback().impact(.light)
                self.tabSelected?(target)
            } else {
                UIView.animate(withDuration: 0.45, delay: 0.0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                    for view in layers {
                        view.transform = .identity
                        view.alpha = 1.0
                    }
                }, completion: nil)
            }
        default:
            break
        }
    }

    // Refresh (tapping the Video tab on the first video): the feed fades with a slight recede, `apply`
    // sets the fresh selection, and it fades in in place.
    func refreshContent(apply: @escaping () -> Void) {
        self.contentSwitchGeneration += 1
        let generation = self.contentSwitchGeneration
        self.isSwitchingContent = true
        self.cancelAutoAdvance()
        let layers: [UIView] = [self.contentView, self.overlayHost]
        UIView.animate(withDuration: 0.18, delay: 0.0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
            for view in layers {
                view.alpha = 0.0
                view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            }
        }, completion: { [weak self] _ in
            guard let self, generation == self.contentSwitchGeneration else {
                return
            }
            apply()
            self.isSwitchingContent = false
            UIView.animate(withDuration: 0.5, delay: 0.0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                for view in layers {
                    view.alpha = 1.0
                    view.transform = .identity
                }
            }, completion: nil)
        })
    }

    func scrollTo(index: Int, animated: Bool) {
        guard let layout = self.validLayout, !self.items.isEmpty else {
            return
        }
        let target = max(0, min(index, self.items.count - 1))
        self.card.setExpanded(false)
        let offset = CGPoint(x: 0.0, y: layout.size.height * CGFloat(target))
        if animated && abs(target - self.currentIndex) > 2 {
            // Far away (tapping the Video tab): scrolling through every video takes long and each one on the way would
            // start a player, so the feed briefly fades out and fades in already in place.
            let layers: [UIView] = [self.contentView, self.overlayHost]
            UIView.animate(withDuration: 0.15, delay: 0.0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
                for view in layers {
                    view.alpha = 0.0
                }
            }, completion: { [weak self] _ in
                guard let self else {
                    return
                }
                self.scrollView.setContentOffset(offset, animated: false)
                UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                    for view in layers {
                        view.alpha = 1.0
                    }
                }, completion: nil)
            })
        } else {
            self.scrollView.setContentOffset(offset, animated: animated)
        }
    }

    // Not Interested and Don't Show This Channel: the video recedes and fades while the feed scrolls to the next one.
    func dismissCurrent() {
        let next = self.currentIndex + 1
        guard next < self.items.count else {
            return
        }
        self.pages[self.currentIndex]?.playDismiss()
        self.scrollTo(index: next, animated: true)
    }

    func showToast(_ text: String) {
        self.toastLabel.text = text
        self.toastHideWork?.cancel()
        if let layout = self.validLayout {
            self.layoutToast(layout: layout)
        }
        if self.toastGlass.alpha < 0.5 {
            self.toastGlass.transform = CGAffineTransform(translationX: 0.0, y: -12.0).scaledBy(x: 0.92, y: 0.92)
        }
        UIView.animate(withDuration: 0.45, delay: 0.0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.0, options: [.beginFromCurrentState], animations: {
            self.toastGlass.alpha = 1.0
            self.toastGlass.transform = .identity
        }, completion: nil)
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            UIView.animate(withDuration: 0.3, delay: 0.0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
                self.toastGlass.alpha = 0.0
                self.toastGlass.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            }, completion: nil)
        }
        self.toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func layoutToast(layout: ContainerViewLayout) {
        let size = layout.size
        let topInset = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
        let text = self.toastLabel.text ?? ""
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: self.toastLabel.font!]).width)
        let width = min(size.width - 32.0, textWidth + 36.0)
        let frame = CGRect(x: floor((size.width - width) / 2.0), y: topInset + 4.0 + VideoFeedTopBar.height + 14.0, width: width, height: 36.0)
        self.toastGlass.bounds = CGRect(origin: CGPoint(), size: frame.size)
        self.toastGlass.center = CGPoint(x: frame.midX, y: frame.midY)
        self.toastGlass.update(size: frame.size, cornerRadius: 18.0, isDark: true, tintColor: .init(kind: .panel), transition: .immediate)
        self.toastLabel.frame = CGRect(origin: CGPoint(), size: frame.size).insetBy(dx: 12.0, dy: 0.0)
    }

    func update(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let sizeChanged = self.validLayout?.size != layout.size
        self.validLayout = layout
        self.updateTabs(titles: self.tabTitles, selectedIndex: self.selectedTabIndex, transition: .immediate)
        self.layoutOverlays(transition: .immediate)
        self.layoutScroll(size: layout.size, resetOffset: sizeChanged)
    }

    private func layoutOverlays(transition: ComponentTransition) {
        guard let layout = self.validLayout else {
            return
        }
        let size = layout.size
        let safe = layout.safeInsets
        let topInset = max(layout.statusBarHeight ?? 0.0, safe.top)
        let bottomInset = max(safe.bottom, layout.intrinsicInsets.bottom)
        let sideInset: CGFloat = 12.0 + max(safe.left, safe.right)

        self.topBar.frame = CGRect(x: 0.0, y: topInset + 4.0, width: size.width, height: VideoFeedTopBar.height)
        self.dimView.frame = CGRect(origin: CGPoint(), size: size)
        // Full-screen layers; they may be offset (tab switch, scrolling), so frames go through bounds and center.
        for view in [self.contentView, self.overlayHost, self.overlayContainer] {
            view.bounds = CGRect(origin: CGPoint(), size: size)
            view.center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        }
        if self.toastGlass.alpha > 0.0 {
            self.layoutToast(layout: layout)
        }

        let speedFrame = CGRect(x: floor((size.width - 64.0) / 2.0), y: topInset + VideoFeedTopBar.height + 16.0, width: 64.0, height: 34.0)
        self.speedGlass.frame = speedFrame
        self.speedGlass.update(size: speedFrame.size, cornerRadius: 17.0, isDark: true, tintColor: .init(kind: .panel), transition: .immediate)
        self.speedLabel.frame = CGRect(origin: CGPoint(), size: speedFrame.size)

        let pauseFrame = CGRect(x: floor((size.width - 76.0) / 2.0), y: floor((size.height - 76.0) / 2.0), width: 76.0, height: 76.0)
        self.pauseGlass.frame = pauseFrame
        self.pauseGlass.update(size: pauseFrame.size, cornerRadius: 38.0, isDark: true, tintColor: .init(kind: .panel), transition: .immediate)
        // play.fill looks shifted to the left: move it by a couple of points, like the system player.
        self.pauseGlyph.frame = CGRect(origin: CGPoint(), size: pauseFrame.size).offsetBy(dx: 3.0, dy: 0.0)
        self.activityIndicator.center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)

        let emptyWidth = min(size.width - 64.0, 320.0)
        let emptyTextSize = self.emptyLabel.sizeThatFits(CGSize(width: emptyWidth - 40.0, height: 200.0))
        let emptyFrame = CGRect(x: floor((size.width - emptyWidth) / 2.0), y: floor((size.height - emptyTextSize.height - 36.0) / 2.0), width: emptyWidth, height: ceil(emptyTextSize.height) + 36.0)
        self.emptyGlass.frame = emptyFrame
        self.emptyGlass.update(size: emptyFrame.size, cornerRadius: 22.0, isDark: true, tintColor: .init(kind: .panel), transition: .immediate)
        self.emptyLabel.frame = CGRect(origin: CGPoint(), size: emptyFrame.size).insetBy(dx: 20.0, dy: 18.0)

        if let item = self.currentItem {
            self.card.isHidden = false
            self.sideActions.isHidden = false
            let width = size.width - sideInset * 2.0
            let action = self.actionFor?(item) ?? .openInChat
            // The expanded caption takes at most 42% of the screen and never goes under the tabs at the top.
            let topLimit = topInset + 4.0 + VideoFeedTopBar.height + 16.0
            let maxCaption = max(60.0, min(floor(size.height * 0.42), size.height - bottomInset - 8.0 - topLimit - 120.0))
            let cardHeight = self.card.update(context: self.context, presentationData: self.presentationData, item: item, action: action, width: width, maxCaptionHeight: maxCaption, transition: transition)
            let cardFrame = CGRect(x: sideInset, y: size.height - bottomInset - 8.0 - cardHeight, width: width, height: cardHeight)
            transition.setFrame(view: self.card, frame: cardFrame)

            let actionsSize = self.sideActions.preferredSize
            transition.setFrame(view: self.sideActions, frame: CGRect(x: size.width - sideInset - actionsSize.width, y: cardFrame.minY - 14.0 - actionsSize.height, width: actionsSize.width, height: actionsSize.height))
            self.sideActions.setLiked(self.isLiked?(item) ?? false, animated: false)

            let continueText = self.continueLabel.text ?? ""
            let continueWidth = ceil((continueText as NSString).size(withAttributes: [.font: self.continueLabel.font!]).width) + 32.0
            let continueFrame = CGRect(x: floor((size.width - continueWidth) / 2.0), y: cardFrame.minY - 12.0 - 34.0, width: continueWidth, height: 34.0)
            self.continueGlass.frame = continueFrame
            self.continueGlass.update(size: continueFrame.size, cornerRadius: 17.0, isDark: true, tintColor: .init(kind: .panel), transition: .immediate)
            self.continueLabel.frame = CGRect(origin: CGPoint(), size: continueFrame.size)
        } else {
            self.card.isHidden = true
            self.sideActions.isHidden = true
        }
        // End of a chat's feed: a hint that For You comes next.
        let showContinue = self.canContinue && self.isComplete && !self.items.isEmpty && self.currentIndex == self.items.count - 1
        UIView.animate(withDuration: 0.25, animations: {
            self.continueGlass.alpha = showContinue ? 1.0 : 0.0
        })
    }

    private func layoutScroll(size: CGSize, resetOffset: Bool) {
        self.scrollView.frame = CGRect(origin: CGPoint(), size: size)
        let contentSize = CGSize(width: size.width, height: size.height * CGFloat(max(self.items.count, 1)))
        if self.scrollView.contentSize != contentSize {
            self.scrollView.contentSize = contentSize
        }
        if resetOffset {
            self.scrollView.contentOffset = CGPoint(x: 0.0, y: size.height * CGFloat(self.currentIndex))
        }
        for (index, page) in self.pages {
            page.frame = CGRect(x: 0.0, y: size.height * CGFloat(index), width: size.width, height: size.height)
            page.updateLayout(size: size)
        }
        self.updatePages()
    }

    private func updatePages() {
        guard let layout = self.validLayout, !self.items.isEmpty else {
            for (_, page) in self.pages {
                page.removeFromSupernode()
            }
            self.pages.removeAll()
            self.pageKeys.removeAll()
            self.updateActivePage()
            return
        }
        let size = layout.size
        let visible = Set(max(0, self.currentIndex - 1) ... min(self.items.count - 1, self.currentIndex + 1))
        for (index, page) in self.pages where !visible.contains(index) {
            page.removeFromSupernode()
            self.pages.removeValue(forKey: index)
            self.pageKeys.removeValue(forKey: index)
        }
        for index in visible where self.pages[index] == nil {
            let item = self.items[index]
            let page = VideoFeedPageNode(context: self.context, message: item.message, file: item.file, soundEnabled: !self.isMuted)
            page.frame = CGRect(x: 0.0, y: size.height * CGFloat(index), width: size.width, height: size.height)
            page.updateLayout(size: size)
            self.scrollView.addSubview(page.view)
            self.pages[index] = page
            self.pageKeys[index] = item.key
        }
        self.updateActivePage()
        if self.currentIndex >= self.items.count - 4 && !self.isComplete {
            self.requestMore()
        }
    }

    // The beginning of the next two videos is preloaded: swipe, and the video is already playing.
    private func updatePrefetch() {
        var wanted: [String: VideoFeedItem] = [:]
        if self.isFeedVisible && self.isInWindow && self.isAppActive && !self.items.isEmpty {
            for index in (self.currentIndex + 1) ... (self.currentIndex + 2) where index < self.items.count {
                wanted[self.items[index].key] = self.items[index]
            }
        }
        for (key, disposable) in self.prefetchDisposables where wanted[key] == nil {
            disposable.dispose()
            self.prefetchDisposables.removeValue(forKey: key)
        }
        for (key, item) in wanted where self.prefetchDisposables[key] == nil {
            let size = item.file.size ?? 0
            let limit: Int64
            if isMediaStreamable(message: EngineMessage(item.message), media: item.file) {
                limit = size > 0 ? min(size, 2_500_000) : 2_500_000
            } else if size > 0 && size <= 12_000_000 {
                limit = size
            } else {
                continue
            }
            let reference = FileMediaReference.message(message: MessageReference(item.message), media: item.file).resourceReference(item.file.resource)
            self.prefetchDisposables[key] = self.context.engine.resources.fetch(reference: reference, userLocation: .peer(item.message.id.peerId), userContentType: item.file.isInstantVideo ? .audioVideoMessage : .video, range: (0 ..< limit, .default)).start()
        }
    }

    // Requests for more videos come not from layout but on the next pass, at most one at a time: the source answers
    // by updating the feed, and a direct call would recurse.
    private var isMoreRequested = false
    private func requestMore() {
        if self.isMoreRequested {
            return
        }
        self.isMoreRequested = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isMoreRequested = false
            self.nearEnd?()
        }
    }

    // How long the current video was watched (excluding pauses): For You learns from it.
    private func finishWatching() {
        guard let start = self.activeSince, let index = self.activeIndex, index < self.items.count else {
            self.activeSince = nil
            return
        }
        let now = CACurrentMediaTime()
        var paused = self.pausedTotal
        if let pausedSince = self.pausedSince {
            paused += now - pausedSince
        }
        let seconds = max(0.0, now - start - paused)
        self.activeSince = nil
        self.pausedSince = nil
        self.pausedTotal = 0.0
        self.didWatch?(self.items[index], seconds)
    }

    private func updateActivePage() {
        let active: Int? = self.isFeedVisible && self.isInWindow && self.isAppActive && !self.items.isEmpty ? self.currentIndex : nil
        if self.activeIndex != active {
            self.finishWatching()
            self.cancelAutoAdvance()
            self.lastStatus = nil
            self.activeIndex = active
            self.isPausedByUser = false
            self.pauseGlass.alpha = 0.0
            self.card.setProgress(nil)
            self.card.setExpanded(false)
            if active != nil {
                self.activeSince = CACurrentMediaTime()
            }
            self.layoutOverlays(transition: .immediate)
        }
        for (index, page) in self.pages {
            page.setActive(index == active)
        }
        if let active, let page = self.pages[active] {
            self.statusDisposable.set((page.videoNode.status
            |> deliverOnMainQueue).start(next: { [weak self] status in
                guard let self else {
                    return
                }
                self.lastStatus = status
                self.card.setProgress(status)
                self.scheduleAutoAdvance()
            }))
        } else {
            self.statusDisposable.set(nil)
            self.lastStatus = nil
            self.cancelAutoAdvance()
        }
        self.updatePrefetch()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let height = scrollView.bounds.height
        guard height > 0.0, !self.items.isEmpty else {
            return
        }
        let index = max(0, min(self.items.count - 1, Int(round(scrollView.contentOffset.y / height))))
        if index != self.currentIndex {
            self.currentIndex = index
            self.updatePages()
        }
        self.updateOverlayScrollEffect()
    }

    // The card and buttons follow scrolling: they move slightly after the video and fade, gone by mid-swipe;
    // the content changes at that moment, and the new ones arrive from the other side (instead of jumping in place).
    private func updateOverlayScrollEffect() {
        let height = self.scrollView.bounds.height
        guard height > 0.0 else {
            return
        }
        let offset = self.scrollView.contentOffset.y
        let delta = offset - round(offset / height) * height
        let progress = min(1.0, abs(delta) / (height * 0.3))
        let alpha = 1.0 - progress
        if self.overlayContainer.layer.animation(forKey: "opacity") == nil {
            self.overlayContainer.alpha = alpha
        }
        self.overlayContainer.transform = CGAffineTransform(translationX: 0.0, y: -delta * 0.18)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        self.resetDismissedPages()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.resetDismissedPages()
    }

    private func resetDismissedPages() {
        for (index, page) in self.pages where index != self.currentIndex {
            page.resetDismiss()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // Pulled past the last video of a chat's feed: For You continues.
        let maxOffset = max(0.0, scrollView.contentSize.height - scrollView.bounds.height)
        if self.canContinue && self.isComplete && scrollView.contentOffset.y > maxOffset + 70.0 {
            HapticFeedback().impact(.medium)
            self.reachedEnd?()
        }
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if self.card.isExpanded {
            self.card.setExpanded(false)
            return
        }
        guard let active = self.activeIndex, let page = self.pages[active] else {
            return
        }
        self.isPausedByUser = !self.isPausedByUser
        page.setPaused(self.isPausedByUser)
        if self.isPausedByUser {
            self.pausedSince = CACurrentMediaTime()
        } else if let pausedSince = self.pausedSince {
            self.pausedTotal += CACurrentMediaTime() - pausedSince
            self.pausedSince = nil
        }
        if self.isPausedByUser {
            self.pauseGlass.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
            self.cancelAutoAdvance()
        }
        UIView.animate(withDuration: 0.35, delay: 0.0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.0, options: [.beginFromCurrentState], animations: {
            self.pauseGlass.alpha = self.isPausedByUser ? 1.0 : 0.0
            self.pauseGlass.transform = self.isPausedByUser ? .identity : CGAffineTransform(scaleX: 0.7, y: 0.7)
        }, completion: nil)
    }

    // Double tap likes (only sets, never removes) and shows a heart at the tap point.
    @objc private func doubleTapGesture(_ recognizer: UITapGestureRecognizer) {
        guard let item = self.currentItem, !self.card.isExpanded else {
            return
        }
        self.showHeart(at: recognizer.location(in: self.view))
        if !(self.isLiked?(item) ?? false) {
            HapticFeedback().impact(.light)
            self.likeChanged?(item, true)
            self.sideActions.setLiked(true, animated: true)
        } else {
            self.sideActions.bounceLike()
        }
    }

    private func showHeart(at point: CGPoint) {
        let heart = UIImageView(image: UIImage(systemName: "heart.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 86.0, weight: .regular))?.withRenderingMode(.alwaysTemplate))
        heart.tintColor = UIColor.systemRed
        heart.sizeToFit()
        heart.center = point
        heart.isUserInteractionEnabled = false
        let tilt = CGFloat.random(in: -0.25 ... 0.25)
        heart.transform = CGAffineTransform(rotationAngle: tilt).scaledBy(x: 0.4, y: 0.4)
        heart.alpha = 0.0
        self.view.insertSubview(heart, belowSubview: self.dimView)
        UIView.animate(withDuration: 0.4, delay: 0.0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.0, options: [], animations: {
            heart.alpha = 1.0
            heart.transform = CGAffineTransform(rotationAngle: tilt)
        }, completion: { _ in
            UIView.animate(withDuration: 0.35, delay: 0.25, options: [.curveEaseIn], animations: {
                heart.alpha = 0.0
                heart.transform = CGAffineTransform(translationX: 0.0, y: -60.0).rotated(by: tilt).scaledBy(x: 1.3, y: 1.3)
            }, completion: { _ in
                heart.removeFromSuperview()
            })
        })
    }

    @objc private func dimTapped() {
        self.card.setExpanded(false)
    }

    @objc private func longPressGesture(_ recognizer: UILongPressGestureRecognizer) {
        guard let active = self.activeIndex, let page = self.pages[active] else {
            return
        }
        switch recognizer.state {
        case .began:
            page.videoNode.setBaseRate(2.0)
            HapticFeedback().impact(.light)
            self.speedGlass.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            UIView.animate(withDuration: 0.4, delay: 0.0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.0, options: [.beginFromCurrentState], animations: {
                self.speedGlass.alpha = 1.0
                self.speedGlass.transform = .identity
            }, completion: nil)
        case .ended, .cancelled, .failed:
            page.videoNode.setBaseRate(1.0)
            UIView.animate(withDuration: 0.2, delay: 0.0, options: [.beginFromCurrentState], animations: {
                self.speedGlass.alpha = 0.0
                self.speedGlass.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            }, completion: nil)
        default:
            break
        }
    }
}

// A full-screen layer that does not catch touches itself: the feed scrolls under it.
final class VideoFeedPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let result = super.hitTest(point, with: event), result !== self else {
            return nil
        }
        return result
    }
}

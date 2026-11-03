import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramCore
import AccountContext
import TelegramPresentationData
import GlassBackgroundComponent
import AvatarNode
import TextFormat
import MultilineTextWithEntitiesComponent
import UniversalMediaPlayer

// The glass info card at the bottom of the video feed. The channel's avatar and name (tap opens the channel),
// below them the reason it is shown ("Like ..." for discovered channels) and the date; on the right Subscribe (for a
// channel you are not in) or Show in Chat. The caption keeps premium emoji and formatting; a long one is collapsed to
// two lines, "more" expands it (scrollable if it does not fit), "Show less" collapses it. At the bottom, a progress bar.
// The collapsed caption is the full text clipped to the height of two lines: a line limit on text with quotes
// and paragraphs did not work, and a long post covered the whole screen.
// The edge fade is a mask on a static container around the scroll view: a mask on the scroll view itself moved with
// the text, and the bottom of the caption went blank while scrolling.
final class VideoFeedInfoCard: UIView, UIScrollViewDelegate {
    enum Action {
        case subscribe
        // A join request was sent: the blue button shows a spinner.
        case joining
        case subscribed
        case openInChat
    }

    private let glass = GlassBackgroundView()
    private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 15.0))
    private let headerButton = HighlightTrackingButton()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let actionGlass = GlassBackgroundView()
    private let actionButton = HighlightTrackingButton()
    private let actionLabel = UILabel()
    private let actionActivity = UIActivityIndicatorView(style: .medium)
    private let captionClipView = UIView()
    private let captionScrollView = UIScrollView()
    private let caption = ComponentView<Empty>()
    private let measureCaption = ComponentView<Empty>()
    // Mask: a solid middle and two gradients at the edges; its frames animate together with the card. The anchor point of
    // every layer is the centre (the default): a frame animation moves the centre, and with a corner anchor the mask
    // slid by half its size during expansion, so only a piece of text at the bottom right was visible.
    private let captionMask = CALayer()
    private let captionMaskBody = CALayer()
    private let captionMaskTop = CAGradientLayer()
    private let captionMaskBottom = CAGradientLayer()
    private var twoLinesHeight: (CGFloat, CGFloat)?
    private let moreButton = HighlightTrackingButton()
    private let moreLabel = UILabel()
    private let progressTrack = UIView()
    private let progressBar = UIView()
    // Scrubbing: tap and drag on the bar (the hit area extends above and below it); the bar thickens while dragging.
    private let scrubArea = UIView()
    private var progressLine = CGRect()
    private var progressThickness: CGFloat = 2.0
    private(set) var isScrubbing = false
    var scrubBegan: (() -> Void)?
    var scrubMoved: ((CGFloat) -> Void)?
    var scrubEnded: ((CGFloat) -> Void)?

    private var currentKey: String?
    private var currentCaption: NSAttributedString?
    private(set) var isExpanded = false
    private var isTruncated = false
    private var currentAction: Action?

    var openChannel: (() -> Void)?
    var actionPressed: ((Action) -> Void)?
    var expandedChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.glass)

        self.headerButton.addTarget(self, action: #selector(self.headerAction), for: .touchUpInside)
        self.headerButton.internalHighligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            self.headerButton.alpha = highlighted ? 0.6 : 1.0
        }
        self.avatarNode.isUserInteractionEnabled = false
        self.headerButton.addSubview(self.avatarNode.view)
        self.titleLabel.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
        self.titleLabel.textColor = .white
        self.titleLabel.isUserInteractionEnabled = false
        self.headerButton.addSubview(self.titleLabel)
        self.subtitleLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.subtitleLabel.textColor = UIColor(white: 1.0, alpha: 0.65)
        self.subtitleLabel.isUserInteractionEnabled = false
        self.headerButton.addSubview(self.subtitleLabel)
        self.glass.contentView.addSubview(self.headerButton)

        self.actionLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
        self.actionLabel.textColor = .white
        self.actionLabel.textAlignment = .center
        self.actionLabel.isUserInteractionEnabled = false
        self.actionButton.addSubview(self.actionLabel)
        self.actionActivity.color = .white
        self.actionActivity.hidesWhenStopped = true
        self.actionActivity.isUserInteractionEnabled = false
        self.actionButton.addSubview(self.actionActivity)
        self.actionButton.addTarget(self, action: #selector(self.actionTapped), for: .touchUpInside)
        self.actionButton.internalHighligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            VideoFeedTopBar.press(view: self.actionGlass, highlighted: highlighted)
        }
        self.actionGlass.contentView.addSubview(self.actionButton)
        self.glass.contentView.addSubview(self.actionGlass)

        self.captionScrollView.showsVerticalScrollIndicator = false
        self.captionScrollView.alwaysBounceVertical = false
        self.captionScrollView.isScrollEnabled = false
        self.captionScrollView.clipsToBounds = true
        self.captionScrollView.contentInsetAdjustmentBehavior = .never
        self.captionScrollView.delegate = self
        let captionTap = UITapGestureRecognizer(target: self, action: #selector(self.captionTapped))
        self.captionScrollView.addGestureRecognizer(captionTap)
        self.captionMaskBody.backgroundColor = UIColor.black.cgColor
        self.captionMaskTop.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        self.captionMaskBottom.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        for layer in [self.captionMaskBody, self.captionMaskTop, self.captionMaskBottom] {
            self.captionMask.addSublayer(layer)
        }
        self.captionClipView.clipsToBounds = true
        self.captionClipView.layer.mask = self.captionMask
        self.captionClipView.addSubview(self.captionScrollView)
        self.glass.contentView.addSubview(self.captionClipView)

        self.moreLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .semibold)
        self.moreLabel.textColor = UIColor(white: 1.0, alpha: 0.85)
        self.moreLabel.isUserInteractionEnabled = false
        self.moreButton.addSubview(self.moreLabel)
        self.moreButton.addTarget(self, action: #selector(self.captionTapped), for: .touchUpInside)
        self.glass.contentView.addSubview(self.moreButton)

        self.progressTrack.backgroundColor = UIColor(white: 1.0, alpha: 0.2)
        self.progressTrack.isUserInteractionEnabled = false
        self.progressTrack.clipsToBounds = true
        self.progressBar.backgroundColor = .white
        self.progressTrack.addSubview(self.progressBar)
        self.glass.contentView.addSubview(self.progressTrack)

        // A tap seeks the video to that point, a drag follows the finger.
        let scrub = UILongPressGestureRecognizer(target: self, action: #selector(self.scrubGesture(_:)))
        scrub.minimumPressDuration = 0.0
        scrub.allowableMovement = .greatestFiniteMagnitude
        self.scrubArea.addGestureRecognizer(scrub)
        self.glass.contentView.addSubview(self.scrubArea)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func headerAction() {
        self.openChannel?()
    }

    @objc private func actionTapped() {
        if let action = self.currentAction {
            self.actionPressed?(action)
        }
    }

    @objc private func captionTapped() {
        guard self.isTruncated else {
            return
        }
        self.setExpanded(!self.isExpanded)
    }

    func setExpanded(_ value: Bool) {
        if self.isExpanded != value {
            self.isExpanded = value
            self.expandedChanged?(value)
        }
    }

    private static func captionString(message: EngineRawMessage) -> NSAttributedString {
        var entities: [MessageTextEntity] = []
        for attribute in message.attributes {
            if let attribute = attribute as? TextEntitiesMessageAttribute {
                entities = attribute.entities
                break
            }
        }
        let size: CGFloat = 15.0
        return stringWithAppliedEntities(message.text, entities: entities, baseColor: .white, linkColor: UIColor(white: 1.0, alpha: 0.85), baseFont: Font.regular(size), linkFont: Font.medium(size), boldFont: Font.semibold(size), italicFont: Font.italic(size), boldItalicFont: Font.semiboldItalic(size), fixedFont: Font.monospace(size - 1.0), blockQuoteFont: Font.regular(size), underlineLinks: false, message: message)
    }

    /// Lays the card out for a video and returns its height.
    func update(context: AccountContext, presentationData: PresentationData, item: VideoFeedItem, action: Action, width: CGFloat, maxCaptionHeight: CGFloat, transition: ComponentTransition) -> CGFloat {
        let strings = presentationData.strings
        let inner: CGFloat = 14.0
        let key = item.key
        let isSameItem = self.currentKey == key
        if self.currentKey != key {
            self.currentKey = key
            self.isExpanded = false
            self.captionScrollView.contentOffset = CGPoint()
            self.currentCaption = VideoFeedInfoCard.captionString(message: item.message)
            if let peer = item.peer {
                self.avatarNode.setPeer(context: context, theme: presentationData.theme, peer: peer, synchronousLoad: false, displayDimensions: CGSize(width: 38.0, height: 38.0))
            }
        }

        // Header: the channel (or the author in a chat), below it the reason it is shown and the date.
        var title = item.peer?.displayTitle(strings: strings, displayOrder: presentationData.nameDisplayOrder) ?? ""
        if case let .channel(channel) = item.peer, case .broadcast = channel.info {
        } else if let author = item.message.author {
            title = EnginePeer(author).displayTitle(strings: strings, displayOrder: presentationData.nameDisplayOrder)
        }
        self.titleLabel.text = title
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: strings.baseLanguageCode)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var subtitle = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(item.message.timestamp)))
        if !item.isSubscribed, let reason = item.reason {
            switch reason {
            case let .similar(title):
                subtitle = strings.VideoFeed_SimilarTo(title).string + " · " + subtitle
            case .popular:
                subtitle = strings.VideoFeed_Recommended + " · " + subtitle
            case let .repostedIn(title):
                subtitle = strings.VideoFeed_RepostedIn(title).string + " · " + subtitle
            case let .mentionedIn(title):
                subtitle = strings.VideoFeed_MentionedIn(title).string + " · " + subtitle
            case let .hashtag(tag):
                subtitle = strings.VideoFeed_ByHashtag(tag).string + " · " + subtitle
            }
        }
        self.subtitleLabel.text = subtitle

        // The button on the right. When it changes for the same video (loading, Subscribed) it moves with a spring and the
        // title cross-fades, even if the card itself is laid out without animation.
        let actionChanged = isSameItem && self.currentAction != nil && self.currentAction != action
        self.currentAction = action
        let actionTransition: ComponentTransition = actionChanged ? .spring(duration: 0.4) : transition
        let actionTitle: String
        let actionTint: GlassBackgroundView.TintColor
        switch action {
        case .subscribe, .joining:
            actionTitle = strings.VideoFeed_Subscribe
            actionTint = .init(kind: .custom(style: .default, color: presentationData.theme.list.itemCheckColors.fillColor))
        case .subscribed:
            actionTitle = "✓ " + strings.VideoFeed_Subscribed
            actionTint = .init(kind: .panel)
        case .openInChat:
            actionTitle = strings.SharedMedia_ViewInChat
            actionTint = .init(kind: .panel)
        }
        if actionChanged && self.actionLabel.text != actionTitle {
            UIView.transition(with: self.actionLabel, duration: 0.22, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: {
                self.actionLabel.text = actionTitle
            }, completion: nil)
        } else {
            self.actionLabel.text = actionTitle
        }
        let isJoining = action == .joining
        self.actionButton.isEnabled = !isJoining
        if isJoining {
            self.actionActivity.startAnimating()
        } else {
            self.actionActivity.stopAnimating()
        }
        actionTransition.setAlpha(view: self.actionLabel, alpha: isJoining ? 0.0 : 1.0)
        let actionTextWidth = ceil((actionTitle as NSString).size(withAttributes: [.font: self.actionLabel.font!]).width)
        let actionSize = CGSize(width: actionTextWidth + 28.0, height: 34.0)

        var y: CGFloat = inner
        let headerHeight: CGFloat = 40.0
        let actionFrame = CGRect(x: width - inner - actionSize.width, y: y + floor((headerHeight - actionSize.height) * 0.5), width: actionSize.width, height: actionSize.height)
        actionTransition.setFrame(view: self.actionGlass, frame: actionFrame)
        self.actionGlass.update(size: actionSize, cornerRadius: actionSize.height * 0.5, isDark: true, tintColor: actionTint, transition: actionTransition)
        actionTransition.setFrame(view: self.actionButton, frame: CGRect(origin: CGPoint(), size: actionSize))
        actionTransition.setFrame(view: self.actionLabel, frame: CGRect(origin: CGPoint(), size: actionSize))
        self.actionActivity.center = CGPoint(x: actionSize.width * 0.5, y: actionSize.height * 0.5)

        let headerFrame = CGRect(x: inner, y: y, width: actionFrame.minX - inner - 10.0, height: headerHeight)
        self.headerButton.frame = headerFrame
        self.avatarNode.frame = CGRect(x: 0.0, y: 1.0, width: 38.0, height: 38.0)
        self.titleLabel.frame = CGRect(x: 48.0, y: 1.0, width: headerFrame.width - 48.0, height: 20.0)
        self.subtitleLabel.frame = CGRect(x: 48.0, y: 22.0, width: headerFrame.width - 48.0, height: 17.0)
        y += headerHeight

        // Caption.
        let captionWidth = width - inner * 2.0
        var captionHeight: CGFloat = 0.0
        if let captionString = self.currentCaption, captionString.length > 0 {
            let fullSize = self.caption.update(transition: .immediate, component: AnyComponent(MultilineTextWithEntitiesComponent(context: context, animationCache: context.animationCache, animationRenderer: context.animationRenderer, placeholderColor: UIColor(white: 1.0, alpha: 0.2), text: .plain(captionString), maximumNumberOfLines: 0, lineSpacing: 0.1)), environment: {}, containerSize: CGSize(width: captionWidth, height: 100000.0))
            let collapsedHeight = self.collapsedCaptionHeight(context: context, width: captionWidth)
            self.isTruncated = fullSize.height > collapsedHeight + 4.0
            if !self.isTruncated {
                self.isExpanded = false
            }
            if let captionView = self.caption.view {
                if captionView.superview == nil {
                    self.captionScrollView.addSubview(captionView)
                }
                captionView.frame = CGRect(origin: CGPoint(), size: fullSize)
            }
            if self.isExpanded {
                captionHeight = min(fullSize.height, maxCaptionHeight)
            } else {
                // Exactly two lines: the third never peeks out.
                captionHeight = self.isTruncated ? min(fullSize.height, collapsedHeight + 2.0) : fullSize.height
                self.captionScrollView.contentOffset = CGPoint()
            }
            let canScroll = self.isExpanded && fullSize.height > captionHeight + 0.5
            self.captionScrollView.contentSize = fullSize
            self.captionScrollView.isScrollEnabled = canScroll
            if !canScroll {
                self.captionScrollView.contentOffset = CGPoint()
            } else {
                let maxOffset = fullSize.height - captionHeight
                if self.captionScrollView.contentOffset.y > maxOffset {
                    self.captionScrollView.contentOffset = CGPoint(x: 0.0, y: maxOffset)
                }
            }
            y += 8.0
            let captionFrame = CGRect(x: inner, y: y, width: captionWidth, height: captionHeight)
            transition.setFrame(view: self.captionClipView, frame: captionFrame)
            transition.setFrame(view: self.captionScrollView, frame: CGRect(origin: CGPoint(), size: captionFrame.size))
            self.captionClipView.isHidden = false
            self.updateCaptionFade(transition: transition)
            y += captionHeight
        } else {
            self.isTruncated = false
            self.isExpanded = false
            self.captionClipView.isHidden = true
        }

        if self.isTruncated {
            let moreText = self.isExpanded ? strings.VideoFeed_ShowLess : strings.VideoFeed_ShowMore
            if !transition.animation.isImmediate && self.moreLabel.text != nil && self.moreLabel.text != moreText {
                UIView.transition(with: self.moreLabel, duration: 0.2, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: {
                    self.moreLabel.text = moreText
                }, completion: nil)
            } else {
                self.moreLabel.text = moreText
            }
            self.moreLabel.sizeToFit()
            let moreSize = CGSize(width: self.moreLabel.bounds.width + 8.0, height: 24.0)
            transition.setFrame(view: self.moreButton, frame: CGRect(x: inner - 4.0, y: y + 2.0, width: moreSize.width, height: moreSize.height))
            self.moreLabel.frame = CGRect(x: 4.0, y: 0.0, width: moreSize.width - 8.0, height: moreSize.height)
            self.moreButton.isHidden = false
            y += 2.0 + moreSize.height
        } else {
            self.moreButton.isHidden = true
        }

        y += 12.0
        self.progressLine = CGRect(x: inner, y: y, width: width - inner * 2.0, height: 2.0)
        self.layoutProgress(transition: transition)
        self.scrubArea.frame = CGRect(x: self.progressLine.minX - 8.0, y: self.progressLine.minY - 10.0, width: self.progressLine.width + 16.0, height: 26.0)
        y += 2.0 + inner

        let size = CGSize(width: width, height: y)
        transition.setFrame(view: self.glass, frame: CGRect(origin: CGPoint(), size: size))
        self.glass.update(size: size, cornerRadius: 24.0, isDark: true, tintColor: .init(kind: .panel), transition: transition)
        return y
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === self.captionScrollView {
            self.updateCaptionFade(transition: .immediate)
        }
    }

    // The caption's edges fade while there is text beyond them: the bottom when collapsed; when expanded and scrollable,
    // the top once scrolled and the bottom until the end is reached.
    private func updateCaptionFade(transition: ComponentTransition) {
        let size = self.captionScrollView.frame.size
        var topFade: CGFloat = 0.0
        var bottomFade: CGFloat = 0.0
        if self.isExpanded {
            if self.captionScrollView.isScrollEnabled {
                let offset = self.captionScrollView.contentOffset.y
                let maxOffset = max(0.0, self.captionScrollView.contentSize.height - size.height)
                topFade = max(0.0, min(18.0, offset))
                bottomFade = max(0.0, min(22.0, maxOffset - offset))
            }
        } else if self.isTruncated {
            bottomFade = 6.0
        }
        topFade = min(topFade, floor(size.height * 0.3))
        bottomFade = min(bottomFade, floor(size.height * 0.3))
        let bodyFrame = CGRect(x: 0.0, y: topFade, width: size.width, height: max(0.0, size.height - topFade - bottomFade))
        let topFrame = CGRect(x: 0.0, y: 0.0, width: size.width, height: topFade)
        let bottomFrame = CGRect(x: 0.0, y: bodyFrame.maxY, width: size.width, height: bottomFade)
        if transition.animation.isImmediate {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.captionMask.frame = CGRect(origin: CGPoint(), size: size)
            self.captionMaskBody.frame = bodyFrame
            self.captionMaskTop.frame = topFrame
            self.captionMaskBottom.frame = bottomFrame
            CATransaction.commit()
        } else {
            transition.setFrame(layer: self.captionMask, frame: CGRect(origin: CGPoint(), size: size))
            transition.setFrame(layer: self.captionMaskBody, frame: bodyFrame)
            transition.setFrame(layer: self.captionMaskTop, frame: topFrame)
            transition.setFrame(layer: self.captionMaskBottom, frame: bottomFrame)
        }
    }

    // The collapsed caption's height reaches the bottom of the second line with text, measured on the real lines: a line
    // with emoji or a quote is taller than the sample and was clipped by it. Empty lines are skipped, but if the second line
    // with text is far down, clip at the second line.
    private func collapsedCaptionHeight(context: AccountContext, width: CGFloat) -> CGFloat {
        let sample = self.sampleTwoLinesHeight(context: context, width: width)
        guard let view = self.caption.view as? MultilineTextWithEntitiesComponent.View, let layout = view.textNode.cachedLayout, let string = layout.attributedString, string.length > 0, let rects = layout.rangeRects(in: NSRange(location: 0, length: string.length))?.rects, !rects.isEmpty else {
            return sample
        }
        let lines = rects.sorted(by: { $0.minY < $1.minY })
        let textLines = lines.filter { $0.width > 2.0 }
        if textLines.count >= 2, textLines[1].maxY <= sample * 2.3 {
            return ceil(view.textNode.frame.minY + textLines[1].maxY)
        }
        if lines.count >= 2 {
            return ceil(view.textNode.frame.minY + lines[1].maxY)
        }
        return sample
    }

    // The height of two sample lines in this font (measured once per width).
    private func sampleTwoLinesHeight(context: AccountContext, width: CGFloat) -> CGFloat {
        if let (cachedWidth, height) = self.twoLinesHeight, cachedWidth == width {
            return height
        }
        let sample = NSAttributedString(string: "Ag\nAg", font: Font.regular(15.0), textColor: .white)
        let size = self.measureCaption.update(transition: .immediate, component: AnyComponent(MultilineTextWithEntitiesComponent(context: context, animationCache: context.animationCache, animationRenderer: context.animationRenderer, placeholderColor: .clear, text: .plain(sample), maximumNumberOfLines: 0, lineSpacing: 0.1)), environment: {}, containerSize: CGSize(width: width, height: 1000.0))
        let height = ceil(size.height)
        self.twoLinesHeight = (width, height)
        return height
    }

    // The bar is centred on its line; thickness changes with a spring (scrubbing), the progress width is left alone: it
    // has its own linear animation.
    private func layoutProgress(transition: ComponentTransition) {
        let thickness = self.progressThickness
        let frame = CGRect(x: self.progressLine.minX, y: self.progressLine.midY - thickness * 0.5, width: self.progressLine.width, height: thickness)
        transition.setFrame(view: self.progressTrack, frame: frame)
        transition.setCornerRadius(layer: self.progressTrack.layer, cornerRadius: thickness * 0.5)
        if self.progressBar.frame.height != thickness {
            var barFrame = self.progressBar.frame
            barFrame.origin.y = 0.0
            barFrame.size.height = thickness
            transition.setFrame(view: self.progressBar, frame: barFrame)
        }
    }

    private func setProgressFraction(_ fraction: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.progressBar.frame = CGRect(x: 0.0, y: 0.0, width: self.progressLine.width * fraction, height: self.progressThickness)
        CATransaction.commit()
    }

    @objc private func scrubGesture(_ recognizer: UILongPressGestureRecognizer) {
        let width = max(1.0, self.progressLine.width)
        let fraction = max(0.0, min(1.0, recognizer.location(in: self.progressTrack).x / width))
        switch recognizer.state {
        case .began:
            self.isScrubbing = true
            self.progressBar.layer.removeAllAnimations()
            self.progressThickness = 6.0
            self.setProgressFraction(fraction)
            self.layoutProgress(transition: .spring(duration: 0.3))
            self.scrubBegan?()
            self.scrubMoved?(fraction)
        case .changed:
            self.setProgressFraction(fraction)
            self.scrubMoved?(fraction)
        case .ended, .cancelled, .failed:
            self.progressThickness = 2.0
            self.layoutProgress(transition: .spring(duration: 0.3))
            self.scrubEnded?(fraction)
            self.isScrubbing = false
        default:
            break
        }
    }

    // Progress: set from the status, then runs by itself with a linear animation to the end of the video. While dragging,
    // the bar stays at the finger and the status does not move it.
    func setProgress(_ status: MediaPlayerStatus?) {
        if self.isScrubbing {
            return
        }
        let width = self.progressLine.width
        let thickness = self.progressThickness
        self.progressBar.layer.removeAllAnimations()
        guard let status, status.duration > 0.0 else {
            self.progressBar.frame = CGRect(x: 0.0, y: 0.0, width: 0.0, height: thickness)
            return
        }
        var timestamp = status.timestamp
        if case .playing = status.status {
            timestamp += max(0.0, CACurrentMediaTime() - status.generationTimestamp) * status.baseRate
        }
        let progress = max(0.0, min(1.0, timestamp / status.duration))
        self.progressBar.frame = CGRect(x: 0.0, y: 0.0, width: width * progress, height: thickness)
        if case .playing = status.status, status.baseRate > 0.0 {
            let remaining = (status.duration - timestamp) / status.baseRate
            if remaining > 0.0 {
                UIView.animate(withDuration: remaining, delay: 0.0, options: [.curveLinear], animations: {
                    self.progressBar.frame = CGRect(x: 0.0, y: 0.0, width: width, height: thickness)
                })
            }
        }
    }
}

import Foundation
import UIKit
import Display
import ComponentFlow
import GlassBackgroundComponent

// The video's buttons on the right above the info card, glass circles: Like (a heart, red when liked),
// Not Interested and More (Telegram's context menu from the circle: don't show this channel, share). Like and
// Not Interested stay on the device and only teach the feed.
// UIKit's system menu on More lifted a square snapshot of the button and stuttered over the glass, hence Telegram's menu.
final class VideoFeedSideActions: UIView {
    private final class RoundButton {
        let glass = GlassBackgroundView()
        let button = HighlightTrackingButton()
        let icon = UIImageView()

        init(symbol: String) {
            self.icon.image = VideoFeedSideActions.symbol(symbol)
            self.icon.tintColor = .white
            self.icon.contentMode = .center
            self.icon.isUserInteractionEnabled = false
            self.glass.contentView.addSubview(self.button)
            // The icon sits above the glass, not inside it: iOS 26 softens glass content, and a red heart came out pink.
            self.glass.addSubview(self.icon)
            self.button.internalHighligthedChanged = { [weak glass = self.glass] highlighted in
                if let glass {
                    VideoFeedTopBar.press(view: glass, highlighted: highlighted)
                }
            }
        }
    }

    static let buttonSize: CGFloat = 46.0
    static let spacing: CGFloat = 12.0

    private let like = RoundButton(symbol: "heart.fill")
    private let dislike = RoundButton(symbol: "hand.thumbsdown")
    private let more = RoundButton(symbol: "ellipsis")
    private var isLiked = false
    private var dislikeGeneration = 0

    var likePressed: (() -> Void)?
    var dislikePressed: (() -> Void)?
    // The menu opens from this circle.
    var morePressed: ((UIView) -> Void)?

    static func symbol(_ name: String) -> UIImage? {
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.0, weight: .medium))?.withRenderingMode(.alwaysTemplate)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for item in [self.like, self.dislike, self.more] {
            self.addSubview(item.glass)
        }
        self.like.button.addTarget(self, action: #selector(self.likeAction), for: .touchUpInside)
        self.dislike.button.addTarget(self, action: #selector(self.dislikeAction), for: .touchUpInside)
        self.more.button.addTarget(self, action: #selector(self.moreAction), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var preferredSize: CGSize {
        let size = VideoFeedSideActions.buttonSize
        return CGSize(width: size, height: size * 3.0 + VideoFeedSideActions.spacing * 2.0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = VideoFeedSideActions.buttonSize
        for (index, item) in [self.like, self.dislike, self.more].enumerated() {
            let frame = CGRect(x: 0.0, y: CGFloat(index) * (size + VideoFeedSideActions.spacing), width: size, height: size)
            item.glass.frame = frame
            item.glass.update(size: frame.size, cornerRadius: size * 0.5, isDark: true, tintColor: .init(kind: .panel), transition: .immediate)
            item.button.frame = CGRect(origin: CGPoint(), size: frame.size)
            item.icon.frame = CGRect(origin: CGPoint(), size: frame.size)
        }
    }

    // Like: the heart turns red with a dissolve and bounces (the symbol's system bounce, like Favorite in Photos);
    // removing the like turns it white and it sinks down.
    func setLiked(_ value: Bool, animated: Bool) {
        let changed = self.isLiked != value
        self.isLiked = value
        self.like.button.accessibilityValue = value ? "1" : "0"
        let color: UIColor = value ? UIColor.systemRed : .white
        if changed && animated {
            UIView.transition(with: self.like.icon, duration: 0.2, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: {
                self.like.icon.tintColor = color
            }, completion: nil)
            VideoFeedSideActions.bounce(self.like.icon, up: value)
        } else {
            self.like.icon.tintColor = color
        }
    }

    // A double tap on an already liked video just bounces the heart again.
    func bounceLike() {
        VideoFeedSideActions.bounce(self.like.icon, up: true)
    }

    // Not Interested: the symbol briefly fills and sinks, then returns to its outline.
    func playDislike() {
        self.dislikeGeneration += 1
        let generation = self.dislikeGeneration
        let icon = self.dislike.icon
        VideoFeedSideActions.setSymbol(icon, VideoFeedSideActions.symbol("hand.thumbsdown.fill"))
        VideoFeedSideActions.bounce(icon, up: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: { [weak self] in
            guard let self, self.dislikeGeneration == generation else {
                return
            }
            VideoFeedSideActions.setSymbol(icon, VideoFeedSideActions.symbol("hand.thumbsdown"))
        })
    }

    private static func bounce(_ icon: UIImageView, up: Bool) {
        if #available(iOS 17.0, *) {
            icon.addSymbolEffect(up ? .bounce.up : .bounce.down, options: .nonRepeating)
        } else {
            icon.transform = CGAffineTransform(scaleX: up ? 0.6 : 1.2, y: up ? 0.6 : 1.2)
            UIView.animate(withDuration: 0.45, delay: 0.0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.0, options: [.beginFromCurrentState], animations: {
                icon.transform = .identity
            }, completion: nil)
        }
    }

    private static func setSymbol(_ icon: UIImageView, _ image: UIImage?) {
        guard let image else {
            return
        }
        if #available(iOS 17.0, *) {
            icon.setSymbolImage(image, contentTransition: .replace.downUp)
        } else {
            icon.image = image
        }
    }

    func setAccessibilityLabels(like: String, dislike: String, more: String) {
        self.like.button.accessibilityLabel = like
        self.dislike.button.accessibilityLabel = dislike
        self.more.button.accessibilityLabel = more
    }

    @objc private func likeAction() {
        self.likePressed?()
    }

    @objc private func dislikeAction() {
        self.playDislike()
        self.dislikePressed?()
    }

    @objc private func moreAction() {
        self.morePressed?(self.more.glass)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let result = super.hitTest(point, with: event), result !== self else {
            return nil
        }
        return result
    }
}

import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import UniversalMediaPlayer
import TelegramUniversalVideoContent
import TinyThumbnail

// Only the current page has a player: a player with sound takes the audio session while it is still loading, and a
// neighbouring page used to pause the current one. Neighbours show a blurred thumbnail from the file itself until reached.
final class VideoFeedPageNode: ASDisplayNode {
    let videoNode: UniversalVideoNode
    private let containerNode = ASDisplayNode()
    private let roundMask = CAShapeLayer()
    private let thumbnailView = UIImageView()
    private let dimensions: CGSize
    private let isRound: Bool
    private var isActive = false
    private var isPaused = false
    // The requested sound state (the feed's sound button changes it on the fly).
    private var soundEnabled: Bool

    init(context: AccountContext, message: EngineRawMessage, file: TelegramMediaFile, soundEnabled: Bool) {
        self.soundEnabled = soundEnabled
        self.isRound = file.isInstantVideo
        self.dimensions = file.dimensions?.cgSize ?? CGSize(width: 720.0, height: 1280.0)
        // Its own content id: with the message's id, the feed would take the player away from the bubble in the chat (and vice versa).
        let content = NativeVideoContent(id: .contextResult(Int64(message.stableId), "video-feed"), userLocation: .peer(message.id.peerId), fileReference: .message(message: MessageReference(message), media: file), streamVideo: isMediaStreamable(message: EngineMessage(message), media: file) ? .conservative : .none, loopVideo: true, enableSound: soundEnabled, placeholderColor: .black, captureProtected: message.isCopyProtected(), storeAfterDownload: nil)
        self.videoNode = UniversalVideoNode(context: context, decoration: VideoFeedDecoration(), content: content, priority: .gallery)
        super.init()
        if let data = file.immediateThumbnailData.flatMap(decodeTinyThumbnail(data:)) {
            self.thumbnailView.image = UIImage(data: data)
        }
        self.thumbnailView.contentMode = .scaleAspectFill
        self.thumbnailView.clipsToBounds = true
        self.addSubnode(self.containerNode)
        self.containerNode.view.addSubview(self.thumbnailView)
        self.videoNode.isUserInteractionEnabled = false
        self.videoNode.ownsContentNodeUpdated = { [weak self] owns in
            if owns, let self, self.isActive {
                self.startPlayback()
            }
        }
        self.containerNode.addSubnode(self.videoNode)
        if self.isRound {
            self.containerNode.layer.mask = self.roundMask
        }
    }

    func updateLayout(size: CGSize) {
        // The frame is set without the dismiss offset (`playDismiss`), which is then restored.
        let transform = self.containerNode.view.transform
        self.containerNode.view.transform = .identity
        defer {
            self.containerNode.view.transform = transform
        }
        if self.isRound {
            // A round video gets an exact circular mask with the video slightly larger: some round videos are not perfectly
            // square and would show black bars at the sides.
            let diameter = min(size.width, size.height) - 40.0
            let frame = CGRect(x: floor((size.width - diameter) / 2.0), y: floor((size.height - diameter) / 2.0) - 40.0, width: diameter, height: diameter)
            self.containerNode.frame = frame
            self.roundMask.frame = CGRect(origin: CGPoint(), size: frame.size)
            self.roundMask.path = UIBezierPath(ovalIn: CGRect(origin: CGPoint(), size: frame.size)).cgPath
            let bleed = ceil(diameter * 0.04)
            let videoFrame = CGRect(origin: CGPoint(), size: frame.size).insetBy(dx: -bleed, dy: -bleed)
            self.thumbnailView.frame = videoFrame
            self.videoNode.frame = videoFrame
            self.videoNode.updateLayout(size: videoFrame.size, transition: .immediate)
        } else {
            let fitted = self.dimensions.aspectFitted(size)
            let frame = CGRect(x: floor((size.width - fitted.width) / 2.0), y: floor((size.height - fitted.height) / 2.0), width: fitted.width, height: fitted.height)
            self.containerNode.frame = frame
            self.thumbnailView.frame = CGRect(origin: CGPoint(), size: frame.size)
            self.videoNode.frame = CGRect(origin: CGPoint(), size: frame.size)
            self.videoNode.updateLayout(size: frame.size, transition: .immediate)
        }
    }

    // Not Interested: the video recedes and fades while the feed scrolls on.
    func playDismiss() {
        UIView.animate(withDuration: 0.38, delay: 0.0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
            self.containerNode.view.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            self.containerNode.view.alpha = 0.3
        }, completion: nil)
    }

    func resetDismiss() {
        if self.containerNode.view.transform.isIdentity && self.containerNode.view.alpha == 1.0 {
            return
        }
        self.containerNode.view.layer.removeAllAnimations()
        self.containerNode.view.transform = .identity
        self.containerNode.view.alpha = 1.0
    }

    func setActive(_ isActive: Bool) {
        if self.isActive == isActive {
            return
        }
        if isActive {
            self.resetDismiss()
        }
        self.isActive = isActive
        self.isPaused = false
        if isActive {
            self.videoNode.canAttachContent = true
            if self.videoNode.ownsContentNode {
                self.startPlayback()
            }
        } else {
            self.videoNode.pause()
            self.videoNode.setBaseRate(1.0)
            self.videoNode.canAttachContent = false
        }
    }

    func setPaused(_ isPaused: Bool) {
        self.isPaused = isPaused
        if isPaused {
            self.videoNode.pause()
        } else {
            self.startPlayback()
        }
    }

    // While muted the player does not hold the audio session (music keeps playing); unmuting continues from the same position.
    func setSoundEnabled(_ value: Bool) {
        if self.soundEnabled == value {
            return
        }
        self.soundEnabled = value
        if self.isActive && !self.isPaused && self.videoNode.ownsContentNode {
            self.videoNode.setSoundEnabled(value)
        }
    }

    func seek(_ timestamp: Double) {
        self.videoNode.seek(timestamp)
    }

    // Looping is `loopVideo`. Sound is set every time: the player may still have the old state (toggled while it was
    // paused or off screen); setting the same state again does nothing.
    private func startPlayback() {
        if self.isPaused {
            return
        }
        self.videoNode.play()
        self.videoNode.setSoundEnabled(self.soundEnabled)
    }
}

final class VideoFeedDecoration: UniversalVideoDecoration {
    let backgroundNode: ASDisplayNode? = nil
    let contentContainerNode = ASDisplayNode()
    let foregroundNode: ASDisplayNode? = nil
    private var contentNode: (ASDisplayNode & UniversalVideoContentNode)?
    private var validLayout: (CGSize, CGSize)?

    func updateContentNode(_ contentNode: (UniversalVideoContentNode & ASDisplayNode)?) {
        if self.contentNode === contentNode {
            return
        }
        if let previous = self.contentNode, previous.supernode === self.contentContainerNode {
            previous.removeFromSupernode()
        }
        self.contentNode = contentNode
        if let contentNode {
            self.contentContainerNode.addSubnode(contentNode)
            if let (size, actualSize) = self.validLayout {
                contentNode.frame = CGRect(origin: CGPoint(), size: size)
                contentNode.updateLayout(size: size, actualSize: actualSize, transition: .immediate)
            }
        }
    }

    func updateContentNodeSnapshot(_ snapshot: UIView?) {
    }

    func updateLayout(size: CGSize, actualSize: CGSize, transition: ContainedViewLayoutTransition) {
        self.validLayout = (size, actualSize)
        transition.updateFrame(node: self.contentContainerNode, frame: CGRect(origin: CGPoint(), size: size))
        if let contentNode = self.contentNode {
            transition.updateFrame(node: contentNode, frame: CGRect(origin: CGPoint(), size: size))
            contentNode.updateLayout(size: size, actualSize: actualSize, transition: transition)
        }
    }

    func setStatus(_ status: Signal<MediaPlayerStatus?, NoError>) {
    }

    func tap() {
    }
}

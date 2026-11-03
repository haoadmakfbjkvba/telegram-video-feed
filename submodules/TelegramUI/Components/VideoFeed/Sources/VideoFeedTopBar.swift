import Foundation
import UIKit
import Display
import ComponentFlow
import GlassBackgroundComponent

// The top of the video feed: a round glass Back button (the arrow of Telegram's navigation), a glass tab switcher
// in the centre (the selected tab is a light pill that moves with a spring) and a round sound button on the right:
// a speaker with waves or crossed out, switched with the system symbol replacement.
final class VideoFeedTopBar: UIView {
    private let backGlass = GlassBackgroundView()
    private let backButton = HighlightTrackingButton()
    private let backIconView = UIImageView()
    private let soundGlass = GlassBackgroundView()
    private let soundButton = HighlightTrackingButton()
    private let soundIconView = UIImageView()
    private var isMuted: Bool?
    private let tabsGlass = GlassBackgroundView()
    private let selectionView = UIView()
    private var tabButtons: [HighlightTrackingButton] = []
    private var tabLabels: [UILabel] = []
    private var currentTabs: [String] = []
    private var selectedIndex = 0

    var backPressed: (() -> Void)?
    var soundPressed: (() -> Void)?
    var tabSelected: ((Int) -> Void)?

    static let height: CGFloat = 44.0

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.addSubview(self.backGlass)
        self.backIconView.image = navigationBarBackArrowImage(color: .white)
        self.backIconView.contentMode = .center
        self.backIconView.isUserInteractionEnabled = false
        self.backButton.addSubview(self.backIconView)
        self.backButton.addTarget(self, action: #selector(self.backAction), for: .touchUpInside)
        self.backButton.internalHighligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            VideoFeedTopBar.press(view: self.backGlass, highlighted: highlighted)
        }
        self.backGlass.contentView.addSubview(self.backButton)

        self.addSubview(self.soundGlass)
        self.soundIconView.tintColor = .white
        self.soundIconView.contentMode = .center
        self.soundIconView.isUserInteractionEnabled = false
        self.soundButton.addTarget(self, action: #selector(self.soundAction), for: .touchUpInside)
        self.soundButton.internalHighligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            VideoFeedTopBar.press(view: self.soundGlass, highlighted: highlighted)
        }
        self.soundGlass.contentView.addSubview(self.soundButton)
        self.soundGlass.addSubview(self.soundIconView)

        self.addSubview(self.tabsGlass)
        self.selectionView.backgroundColor = UIColor(white: 1.0, alpha: 0.2)
        self.selectionView.isUserInteractionEnabled = false
        self.tabsGlass.contentView.addSubview(self.selectionView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let result = super.hitTest(point, with: event), result !== self else {
            return nil
        }
        return result
    }

    static func press(view: UIView, highlighted: Bool) {
        if highlighted {
            ComponentTransition(animation: .curve(duration: 0.15, curve: .easeInOut)).setScale(view: view, scale: 0.92)
        } else {
            ComponentTransition(animation: .curve(duration: 0.4, curve: .spring)).setScale(view: view, scale: 1.0)
        }
    }

    @objc private func backAction() {
        self.backPressed?()
    }

    @objc private func soundAction() {
        self.soundPressed?()
    }

    private static func soundIcon(muted: Bool) -> UIImage? {
        return UIImage(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16.0, weight: .semibold))?.withRenderingMode(.alwaysTemplate)
    }

    func setMuted(_ muted: Bool, accessibilityLabel: String) {
        let previous = self.isMuted
        self.isMuted = muted
        self.soundButton.accessibilityLabel = accessibilityLabel
        guard previous != muted, let image = VideoFeedTopBar.soundIcon(muted: muted) else {
            return
        }
        if previous != nil, #available(iOS 17.0, *) {
            self.soundIconView.setSymbolImage(image, contentTransition: .replace.downUp)
        } else {
            self.soundIconView.image = image
        }
    }

    @objc private func tabAction(_ sender: UIButton) {
        if let index = self.tabButtons.firstIndex(where: { $0 === sender }) {
            self.tabSelected?(index)
        }
    }

    // `showsBack` is false for the feed in the tab bar: there is nowhere to go back to, the tabs are centred.
    func update(width: CGFloat, sideInset: CGFloat, tabs: [String], selectedIndex: Int, showsBack: Bool = true, transition: ComponentTransition) {
        let backSize: CGFloat = 44.0
        // Glass on iOS 26 renders in its own view: hide it through `isVisible`, not `isHidden`.
        self.backGlass.alpha = showsBack ? 1.0 : 0.0
        self.backGlass.isUserInteractionEnabled = showsBack
        let backFrame = CGRect(x: sideInset, y: 0.0, width: backSize, height: backSize)
        transition.setFrame(view: self.backGlass, frame: backFrame)
        self.backGlass.update(size: backFrame.size, cornerRadius: backSize * 0.5, isDark: true, tintColor: .init(kind: .panel), isVisible: showsBack, transition: transition)
        self.backButton.frame = CGRect(origin: CGPoint(), size: backFrame.size)
        // The arrow looks right of its frame's centre: shift it by a point, like Telegram's round Back button.
        self.backIconView.frame = CGRect(origin: CGPoint(), size: backFrame.size).offsetBy(dx: -1.0, dy: 0.0)

        if tabs != self.currentTabs {
            self.currentTabs = tabs
            for button in self.tabButtons {
                button.removeFromSuperview()
            }
            self.tabButtons = []
            self.tabLabels = []
            for title in tabs {
                let button = HighlightTrackingButton()
                let label = UILabel()
                label.text = title
                label.textAlignment = .center
                label.lineBreakMode = .byTruncatingTail
                label.isUserInteractionEnabled = false
                button.addSubview(label)
                button.addTarget(self, action: #selector(self.tabAction(_:)), for: .touchUpInside)
                self.tabsGlass.contentView.addSubview(button)
                self.tabButtons.append(button)
                self.tabLabels.append(label)
            }
        }

        let previousSelected = self.selectedIndex
        self.selectedIndex = selectedIndex
        let padding: CGFloat = 4.0
        let tabHeight: CGFloat = backSize - padding * 2.0
        // Tab widths follow their text. Centred on screen when they fit; otherwise from Back to the right edge.
        // If they still don't fit, the padding shrinks first, then the long title (the chat's name) is truncated.
        let soundFrame = CGRect(x: width - sideInset - backSize, y: 0.0, width: backSize, height: backSize)
        transition.setFrame(view: self.soundGlass, frame: soundFrame)
        self.soundGlass.update(size: soundFrame.size, cornerRadius: backSize * 0.5, isDark: true, tintColor: .init(kind: .panel), transition: transition)
        self.soundButton.frame = CGRect(origin: CGPoint(), size: soundFrame.size)
        self.soundIconView.frame = CGRect(origin: CGPoint(), size: soundFrame.size)

        // The tabs never go under Back on the left or the sound button on the right (Back's space is reserved even
        // without it, so the tabs stay exactly centred).
        let leftLimit = sideInset + backSize + 10.0
        let rightLimit = width - sideInset - backSize - 10.0
        let maxTabsWidth = rightLimit - leftLimit
        let font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        var textWidths: [CGFloat] = []
        for (index, label) in self.tabLabels.enumerated() {
            label.font = UIFont.systemFont(ofSize: 15.0, weight: index == selectedIndex ? .semibold : .medium)
            label.textColor = index == selectedIndex ? .white : UIColor(white: 1.0, alpha: 0.72)
            textWidths.append(ceil(((label.text ?? "") as NSString).size(withAttributes: [.font: font]).width))
        }
        var tabPadding: CGFloat = 28.0
        func totalWidth(_ widths: [CGFloat]) -> CGFloat {
            return widths.reduce(0.0, +) + padding * 2.0
        }
        var widths = textWidths.map { $0 + tabPadding }
        if totalWidth(widths) > maxTabsWidth {
            tabPadding = 20.0
            widths = textWidths.map { $0 + tabPadding }
        }
        if totalWidth(widths) > maxTabsWidth, let longest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[longest] = max(60.0, widths[longest] - (totalWidth(widths) - maxTabsWidth))
        }
        let total = min(totalWidth(widths), maxTabsWidth)
        let tabsX = min(max(floor((width - total) * 0.5), leftLimit), rightLimit - total)
        let tabsFrame = CGRect(x: tabsX, y: 0.0, width: total, height: backSize)
        transition.setFrame(view: self.tabsGlass, frame: tabsFrame)
        self.tabsGlass.update(size: tabsFrame.size, cornerRadius: backSize * 0.5, isDark: true, tintColor: .init(kind: .panel), transition: transition)
        self.tabsGlass.isHidden = tabs.count < 2

        var x = padding
        var selectionFrame = CGRect()
        for (index, button) in self.tabButtons.enumerated() {
            let frame = CGRect(x: x, y: padding, width: widths[index], height: tabHeight)
            button.frame = frame
            self.tabLabels[index].frame = CGRect(origin: CGPoint(), size: frame.size).insetBy(dx: (tabPadding - 8.0) * 0.5, dy: 0.0)
            if index == selectedIndex {
                selectionFrame = frame
            }
            x += widths[index]
        }
        self.selectionView.layer.cornerRadius = tabHeight * 0.5
        if previousSelected != selectedIndex && !transition.animation.isImmediate {
            ComponentTransition(animation: .curve(duration: 0.45, curve: .spring)).setFrame(view: self.selectionView, frame: selectionFrame)
        } else {
            transition.setFrame(view: self.selectionView, frame: selectionFrame)
        }
    }
}

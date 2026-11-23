import AppKit
import os
import QuartzCore

/// What one of the three screens in the transition shows.
enum CardContent {
    /// No space on that side.
    case none
    /// A space we have no image for.
    case placeholder
    case snapshot(Snapshot)
}

/// One screen in the transition.
private final class Card {
    /// Moves and scales.
    let container = CALayer()
    /// The screen, clipped to the corner shape of the display.
    private let content = CALayer()
    private let image = CALayer()
    private let patch = CALayer()
    private let dim = CALayer()

    var isPresent = false
    private var patchFrame = CGRect.zero

    init() {
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // A side of the hexagon that is turned away must not show from behind.
        container.isDoubleSided = false
        container.allowsEdgeAntialiasing = true
        // For the Stack transition. The shadow is drawn from a path, so its cost does not depend on the image.
        container.shadowColor = CGColor(gray: 0, alpha: 1)
        container.shadowOffset = .zero
        container.shadowRadius = Config.stackShadowRadius
        container.shadowOpacity = 0

        content.masksToBounds = true
        content.cornerCurve = .continuous
        content.backgroundColor = CGColor(gray: 0.11, alpha: 1)

        image.contentsGravity = .resize
        image.minificationFilter = .trilinear
        patch.contentsGravity = .resize
        patch.minificationFilter = .trilinear
        dim.backgroundColor = CGColor(gray: 0, alpha: 1)

        content.addSublayer(image)
        content.addSublayer(patch)
        content.addSublayer(dim)
        container.addSublayer(content)
    }

    func layout(size: CGSize, cornerRadius: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        container.bounds = bounds
        content.frame = bounds
        content.cornerRadius = cornerRadius
        container.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        image.frame = bounds
        dim.frame = bounds
        layoutPatch()
    }

    func set(_ content: CardContent) {
        switch content {
        case .none:
            isPresent = false
            image.contents = nil
            patch.contents = nil
        case .placeholder:
            isPresent = true
            image.contents = nil
            patch.contents = nil
        case .snapshot(let snapshot):
            isPresent = true
            image.contents = snapshot.image
            patch.contents = snapshot.patch
            patchFrame = snapshot.patchFrame
            layoutPatch()
        }
    }

    func setDim(_ amount: CGFloat) {
        dim.opacity = Float(amount)
    }

    func setShadow(_ amount: CGFloat) {
        container.shadowOpacity = Float(amount)
    }

    private func layoutPatch() {
        // `patchFrame` counts from the top of the screen, the layer from the bottom.
        patch.frame = CGRect(
            x: patchFrame.minX, y: container.bounds.height - patchFrame.maxY,
            width: patchFrame.width, height: patchFrame.height
        )
    }

}

/// A borderless window above everything that draws the current space and the spaces around it.
/// Each one is the whole screen, with the corner shape of the display.
final class Overlay {
    private var panel: NSPanel
    private let root = CALayer()
    /// The number of spaces on each side of the current one that can show. One is enough for a swipe.
    /// Two are for a fast second step in the same direction, which starts before the first has arrived.
    static let reach = 2

    private let cards = (0..<(reach * 2 + 1)).map { _ in Card() }
    private var size = CGSize.zero
    private var cardRadius: CGFloat = -1

    private(set) var isVisible = false

    /// Where the loader goes on the cover, in screen coordinates, and its colour.
    struct Loader {
        let frame: CGRect
        let color: CGColor
    }

    private var loaderLayer: CALayer?
    /// Notification banners that were on screen. They do not move with the screens. See `NotificationImage`.
    private let notificationsLayer = CALayer()

    /// The transition to draw. Set it before `setCards`.
    var style = TransitionStyle.lightweight

    /// True: each screen has the corner shape of the display. False: square corners. Set it before `attach(to:)`.
    var roundsCorners = true

    /// False: the window is above everything, and the images it shows have the Dock and the menu bar in them.
    /// True: the window is just below the Dock. The real Dock, menu bar and island show on top of it
    /// and do not move, so the images must not have them.
    var isBelowDock = false {
        didSet {
            guard isBelowDock != oldValue else { return }
            panel.level = Self.level(belowDock: isBelowDock)
            if isBelowDock, isInOwnSpace {
                // Our space is above the Dock: the window goes back to the desktops.
                replacePanel()
            }
        }
    }

    /// True when the window is in a space of its own, above the spaces of the user: see
    /// `Spaces.moveToOwnSpace`. Only above everything, so not when it is below the Dock, and only on the main
    /// display, the one this was measured on. Elsewhere it is on all desktops, as a window can be.
    private(set) var isInOwnSpace = false
    private var wantsOwnSpace = false

    private static func level(belowDock: Bool) -> NSWindow.Level {
        belowDock
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
            : NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    }

    init() {
        panel = Self.makePanel()

        let view = NSView()
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view

        for card in cards {
            root.addSublayer(card.container)
        }
        notificationsLayer.contentsGravity = .resize
        notificationsLayer.zPosition = 5_000
        notificationsLayer.isHidden = true
        root.addSublayer(notificationsLayer)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level(belowDock: false)
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Stay in place on every space while the Dock switches below.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    /// The desktops the window was last found to be on all of, and when. See `ensureOnAllDesktops`.
    private var checkedDesktops: [UInt64]?
    private var checkedAt: CFTimeInterval = 0

    /// The window must be on every desktop: the Dock switches below it, and a window that is on one
    /// desktop only disappears at that moment. macOS takes a window out of "all desktops" when a desktop
    /// is removed. A new window is on all of them again, so this replaces the window when one is missing.
    /// Returns true when it replaced the window.
    ///
    /// The check is a call to the window server, which can take several milliseconds. It is skipped when
    /// the same desktops were checked less than `maxAge` seconds ago: a desktop that is added or removed
    /// changes the list, and so asks for a new check.
    @discardableResult
    func ensureOnAllDesktops(_ desktopIDs: [UInt64], maxAge: CFTimeInterval = .infinity) -> Bool {
        // In a space of its own the window is on no desktop, and shows on all of them.
        guard !isInOwnSpace else { return false }
        if desktopIDs == checkedDesktops, CACurrentMediaTime() - checkedAt < maxAge {
            return false
        }
        let current = Spaces.spaces(ofWindow: panel.windowNumber)
        // Empty means the window was never on screen, and then there is nothing to repair.
        guard !current.isEmpty else { return false }
        checkedDesktops = desktopIDs
        checkedAt = CACurrentMediaTime()
        guard !Set(current).isSuperset(of: desktopIDs) else { return false }
        replacePanel()
        return true
    }

    /// A new window in place of this one, with the same content. A new window is on all desktops.
    private func replacePanel() {
        let old = panel
        let fresh = Self.makePanel()
        let view = old.contentView
        old.contentView = NSView()
        fresh.contentView = view
        fresh.setFrame(old.frame, display: false)
        fresh.level = old.level
        fresh.alphaValue = old.alphaValue
        panel = fresh
        isInOwnSpace = false
        checkedDesktops = nil
        if isVisible {
            CATransaction.flush()
            fresh.orderFrontRegardless()
        }
        old.orderOut(nil)
        old.close()
    }

    /// For a capture of everything below the overlay.
    var windowNumber: Int { panel.windowNumber }

    var alpha: CGFloat {
        get { panel.alphaValue }
        set { panel.alphaValue = newValue }
    }

    /// When the window was last shown, on the clock of `CACurrentMediaTime`.
    private(set) var presentedAt: CFTimeInterval = 0

    /// True when the window can fade out. False when it must be removed in one step.
    ///
    /// When a window has covered the whole display for a little more than a second, macOS no longer draws
    /// what is below it. A fade then goes to black, and the desktop comes back only when the window is gone.
    /// Measured: clean after 1.0 s, black after 1.3 s. Window opacity, window level and a window alpha just
    /// below 1 make no difference. Removing the window in one step is always clean.
    var canFadeOut: Bool {
        CACurrentMediaTime() - presentedAt < Config.fadeSafeTime
    }

    /// `content` gives the screen at a number of steps from the current space: 0 is the current space,
    /// -1 the space to its left, +1 the space to its right.
    func setCards(_ content: (_ offset: Int) -> CardContent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, card) in cards.enumerated() {
            card.set(content(index - Self.reach))
        }
        CATransaction.commit()
    }

    /// Draws the transition. `progress` 0 shows the current space, +1 the next space, -1 the previous space.
    /// In every style the picture at 0 is the current space at full size, so the hand-off to the live desktop is exact.
    func render(progress: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .hexagon: renderHexagon(progress)
        case .stack: renderStack(progress)
        case .magnetic: renderMagnetic(progress)
        case .lightweight, .system, .instant: renderLightweight(progress)
        }
        CATransaction.commit()
    }

    /// The screens slide, a little smaller, with a constant gap.
    private func renderLightweight(_ progress: CGFloat) {
        let scale = TransitionMath.scale(progress: progress)
        // The gap is constant. At rest the next screen is one gap past the edge of the display.
        let spacing = size.width * scale + Config.gap

        root.sublayerTransform = CATransform3DIdentity
        for (index, card) in cards.enumerated() {
            let offset = CGFloat(index - Self.reach) - progress
            let layer = card.container
            layer.isHidden = !card.isPresent || abs(offset) > 1.05
            layer.opacity = 1
            layer.zPosition = 0
            layer.position = CGPoint(x: size.width / 2 + offset * spacing, y: size.height / 2)
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            card.setDim(TransitionMath.dim(offCentre: abs(offset)))
            card.setShadow(0)
        }
    }

    /// The screens slide in a row. Each one is full size only in the middle of the display: the one that
    /// leaves shrinks as it goes, and the one that arrives grows into place.
    private func renderMagnetic(_ progress: CGFloat) {
        let gap = Config.gap / max(size.width, 1)

        root.sublayerTransform = CATransform3DIdentity
        for (index, card) in cards.enumerated() {
            let offset = CGFloat(index - Self.reach) - progress
            let layer = card.container
            // One full step away, a screen is already off the display.
            layer.isHidden = !card.isPresent || abs(offset) > 1.02
            layer.opacity = 1
            layer.zPosition = 0
            layer.position = CGPoint(
                x: size.width / 2 + TransitionMath.magneticPosition(offset: offset, gap: gap) * size.width,
                y: size.height / 2
            )
            let scale = TransitionMath.magneticScale(offset: offset)
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            card.setDim(TransitionMath.dim(offCentre: abs(offset)))
            card.setShadow(0)
        }
    }

    /// The screens are a pile of cards. The next one slides in from the right onto the pile, and the top
    /// one slides off to the right. A screen on the pile does not move: it only gets a little smaller and
    /// darker as another screen covers it.
    private func renderStack(_ progress: CGFloat) {
        root.sublayerTransform = CATransform3DIdentity
        // The cards are in the layer tree in the order of the spaces, so a later space is always on top
        // of an earlier one. That is the order of the pile.
        for (index, card) in cards.enumerated() {
            let offset = CGFloat(index - Self.reach) - progress
            let layer = card.container
            // More than one step off the display, or with a full card on top of the card on top of it.
            layer.isHidden = !card.isPresent || offset > 1.02 || offset < -1
            layer.opacity = 1
            layer.zPosition = 0
            layer.position = CGPoint(
                x: size.width / 2 + TransitionMath.stackSlide(offset: offset) * size.width, y: size.height / 2
            )
            let scale = TransitionMath.stackScale(offset: offset)
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            card.setDim(TransitionMath.stackDim(offset: offset))
            card.setShadow(TransitionMath.stackShadow(offset: offset))
        }
    }

    /// The screens are the sides of a six-sided prism that turns on an upright axis behind the display.
    private func renderHexagon(_ progress: CGFloat) {
        let width = size.width
        let apothem = TransitionMath.hexApothem * width
        let pushback = TransitionMath.hexPushback(progress: progress) * width

        // The eye is in front of the centre of the display. The perspective is part of the transform of
        // each side, which is at the centre: as a transform of the root layer it would use the anchor
        // point of that layer, and AppKit puts the anchor of a view's layer in a corner.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (Config.hexPerspective * width)
        root.sublayerTransform = CATransform3DIdentity

        for (index, card) in cards.enumerated() {
            let offset = CGFloat(index - Self.reach) - progress
            let layer = card.container
            layer.isHidden = !card.isPresent || abs(offset) > 1.4
            layer.opacity = 1
            layer.zPosition = 0
            layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
            // Out to the side of the prism, around the axis, then back to where the axis is.
            var transform = CATransform3DMakeTranslation(0, 0, apothem)
            transform = CATransform3DConcat(transform, CATransform3DMakeRotation(offset * TransitionMath.hexFaceAngle, 0, 1, 0))
            transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(0, 0, -apothem - pushback))
            layer.transform = CATransform3DConcat(transform, perspective)
            card.setDim(TransitionMath.hexDim(offset: offset))
            card.setShadow(0)
        }
    }

    /// Sizes the window and the layers for a screen. Does not show the window.
    /// Each transition calls it, and most of the time nothing changed: then it does nothing.
    func attach(to screen: NSScreen) {
        wantsOwnSpace = !isBelowDock && screen.displayID == CGMainDisplayID() && !Self.ownSpaceTurnedOff
        if isInOwnSpace, !wantsOwnSpace {
            replacePanel()
        }
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        let radius = roundsCorners ? Self.cornerRadius(of: screen) : 0
        guard screen.frame.size != size || radius != cardRadius else { return }
        size = screen.frame.size
        cardRadius = radius

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        for card in cards {
            card.layout(size: size, cornerRadius: radius)
        }
        CATransaction.commit()
    }

    /// Call after `attach(to:)`, `setCards` and `render`, so the first visible frame is already correct.
    func present() {
        CATransaction.flush()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        presentedAt = CACurrentMediaTime()
        isVisible = true
        if wantsOwnSpace, !isInOwnSpace, !ownSpaceFailed {
            // Once for each window: it stays in that space. The window server takes the move after the
            // window comes on screen, in order, but only reports either a moment later: see `checkOwnSpace`.
            if Spaces.moveToOwnSpace(windowNumber: panel.windowNumber) {
                isInOwnSpace = true
                let moved = panel
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.checkOwnSpace(moved)
                }
            } else {
                ownSpaceFailed = true
                Self.log.error("no space of its own for the overlay window, it stays on all desktops")
            }
        }
    }

    /// The move to a space of our own failed: not tried again for this run of the app.
    private var ownSpaceFailed = false
    /// To compare with and without the space of our own: `defaults write com.cnrad.interspace
    /// debugNoOwnSpace -bool true`, read at launch.
    private static let ownSpaceTurnedOff = UserDefaults.standard.bool(forKey: "debugNoOwnSpace")
    private static let log = Logger(subsystem: "com.cnrad.interspace", category: "overlay")

    /// After a move to a space of our own: the window must be on screen, and on no desktop. If it is not,
    /// a new window takes its place, on all desktops as before.
    private func checkOwnSpace(_ moved: NSPanel) {
        // Hidden again, or replaced: the next window that is shown is checked.
        guard moved === panel, isInOwnSpace else { return }
        guard isVisible else {
            isInOwnSpace = false
            return
        }
        let onDesktops = Spaces.spaces(ofWindow: panel.windowNumber)
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]]
        let onScreen = (info?.first?[kCGWindowIsOnscreen as String] as? Bool) == true
        if onDesktops.isEmpty, onScreen {
            Self.log.info("the overlay window is in a space of its own")
            return
        }
        Self.log.error("the overlay window did not move to a space of its own (on screen \(onScreen), on \(onDesktops.count) desktops), it stays on all desktops")
        ownSpaceFailed = true
        replacePanel()
    }

    /// Draws a loader above the screens, or removes it with `nil`. Call after `attach(to:)`.
    /// It is for the cover of the visit of all spaces only: `hide()` removes it.
    func showLoader(_ loader: Loader?) {
        loaderLayer?.removeFromSuperlayer()
        loaderLayer = nil
        guard let loader, panel.frame.contains(loader.frame) else { return }
        let layer = MenuBarIcon.loaderLayer(color: loader.color)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: loader.frame.midX - panel.frame.minX, y: loader.frame.midY - panel.frame.minY)
        layer.zPosition = 10_000
        root.addSublayer(layer)
        CATransaction.commit()
        loaderLayer = layer
    }

    /// Draws notification banners above the screens, where they were on the display, or removes them with
    /// `nil`. Call after `attach(to:)`. `hide()` removes them.
    func showNotifications(_ notifications: NotificationImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let notifications {
            // `frame` counts from the top of the screen, the layer from the bottom.
            notificationsLayer.frame = CGRect(
                x: notifications.frame.minX, y: size.height - notifications.frame.maxY,
                width: notifications.frame.width, height: notifications.frame.height
            )
            notificationsLayer.contents = notifications.image
            notificationsLayer.isHidden = false
        } else {
            notificationsLayer.contents = nil
            notificationsLayer.isHidden = true
        }
        CATransaction.commit()
    }

    func hide() {
        panel.orderOut(nil)
        showLoader(nil)
        showNotifications(nil)
        // The alpha stays as it is. `present()` sets it, so a hidden window can never show at full alpha.
        isVisible = false
        // Release the screen-size images.
        setCards { _ in .none }
    }

    /// The radius of the physical display corners, in points. macOS reports it through a private property.
    private static func cornerRadius(of screen: NSScreen) -> CGFloat {
        let selector = NSSelectorFromString("_cornerRadius")
        if screen.responds(to: selector),
           let radius = (screen.value(forKey: "_cornerRadius") as? NSNumber)?.doubleValue,
           radius > 0 {
            return CGFloat(radius)
        }
        return Config.fallbackCornerRadius
    }
}

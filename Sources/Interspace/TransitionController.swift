import AppKit
import QuartzCore
import CDockSwipe
import os

private let log = Logger(subsystem: "com.cnrad.interspace", category: "spaces")

/// Connects the gesture to the overlay and to the real space switch.
///
/// `progress` is measured from the space the Dock will show when everything settles:
/// 0 is that space, +1 the space to its right, -1 the space to its left.
/// When a swipe commits, the real switch is posted at once below the overlay,
/// the base moves to the new space, and the spring always runs to 0.
///
/// A press of the keyboard shortcut is a swipe that commits at once. A press during a transition moves
/// the base again and keeps the position and the speed of the picture, so the picture turns around from
/// where it is. The Dock gets one switch at a time: see `pumpDock`.
///
/// Everything that moves is drawn on the frames of the display link, from the start of a drag to the end
/// of the transition. In that time the main thread makes no call to the window server that can keep it
/// waiting: the Dock is watched from a thread of its own (`DockWatcher`).
final class TransitionController {
    private enum Phase {
        case idle
        /// Fingers control `progress`.
        case dragging
        /// The spring runs to 0.
        case settling
        /// At rest on a snapshot, waiting for the live desktop below to be ready.
        case holding
        /// Fade from the snapshot to the live desktop.
        case revealing
        /// Visiting every space behind a frozen image of the screen, to capture it.
        case touring
    }

    /// Set to false to make every gesture callback do nothing.
    var isEnabled = false {
        didSet {
            if !isEnabled, oldValue { abort() }
        }
    }

    private let overlay = Overlay()
    private let snapshotter = Snapshotter()
    private let recognizer = SwipeRecognizer()
    private let dockWatcher = DockWatcher()

    private var phase = Phase.idle {
        didSet {
            if phase != oldValue, phase != .idle {
                stats.enter(String(describing: phase), at: CACurrentMediaTime())
            }
        }
    }
    private var layout: SpaceLayout?
    private var baseIndex = 0
    /// The space the Dock was last sent to. Not `baseIndex` while a switch still waits for the Dock.
    private var dockIndex = 0
    /// When the last switch was posted in this transition. 0: none yet.
    private var dockPostTime: CFTimeInterval = 0
    /// The Dock was seen on `dockIndex` after the last switch. False while that switch is on its way.
    private var dockLanded = true
    /// The release that waits for the snapshot is a press of the keyboard shortcut.
    private var keyPending = false
    /// Where the picture is, in every phase. During a drag the fingers move it, on each frame of the display.
    private var progress: CGFloat = 0
    private var velocity: CGFloat = 0
    private var dragOrigin: CGFloat = 0
    /// The finger positions of the drag in progress, in trackpad widths. See `TouchResampler`.
    private var fingers = TouchResampler()
    /// A picture that comes on screen after the fingers have moved starts where the live desktop is, and
    /// catches up with them. `offset` is how far it was from them then, in spaces. It goes to 0.
    private var catchUp: (start: CFTimeInterval, offset: CGFloat)?
    /// When three or more fingers came down that may start the next swipe. See `holdsForFingers`.
    private var fingersDownSince: CFTimeInterval?

    /// How long before a frame of the display the fingers are read for it: a little more than half the time
    /// between two reports of the trackpad, so a frame almost always falls between two reports.
    private static let resampleLatency: CFTimeInterval = 0.005
    /// How fast a picture that came on screen late catches up with the fingers, in seconds. See `catchUp`.
    private static let catchUpTime: CGFloat = 0.03
    /// The longest time the overlay waits for fingers that came down to start a swipe. See `holdsForFingers`.
    private static let fingersHoldTime: CFTimeInterval = 0.6
    /// A switch the Dock has not made in this time is given up, and the picture goes to where the Dock is.
    /// The Dock usually shows the new space 15 to 70 ms after the switch; under load it can be much slower.
    private static let dockLandingTimeout: CFTimeInterval = 1.0
    /// The overlay at rest looks at the live desktop after this time even when the Dock was not seen on
    /// the new space, so it can never stay up. With the time to come to rest, later than `dockLandingTimeout`.
    private static let forceLiveCheckTime: CFTimeInterval = 1.0

    // Snapshot of the current space for the gesture in progress.
    private var captureToken = 0
    private var captureStarted: CFTimeInterval = 0
    private var captureFinished = false
    private var captureFailed = false
    /// A release that arrived before the snapshot.
    private var pendingRelease: (target: Int, velocity: CGFloat)?
    /// Counts the waits for a late snapshot (`switchWithoutOverlayIfLate`): only the newest one may act.
    private var lateSwitchToken = 0

    /// The image of the current space has no Dock in it, so the overlay goes below the real Dock.
    /// It comes from the capture and not from the setting: the capture can fail to leave the Dock out.
    private var overlayIsBelowDock = false
    /// Notification banners that were on screen at the capture for this transition. The overlay draws them
    /// where they were, above the moving screens. See `NotificationImage`.
    private var notifications: NotificationImage?

    /// Full images, for the spaces near the current one. A space is in `cache` or in `packed`, not in both.
    private var cache: [UInt64: Snapshot] = [:]
    /// Compressed images, for the spaces that are too far away to show. See `Config.fullImageRadius`.
    private var packed: [UInt64: PackedSnapshot] = [:]
    /// Every space in `cache` or `packed`, oldest first.
    private var cacheOrder: [UInt64] = []
    private var packing: Set<UInt64> = []
    private var unpacking: Set<UInt64> = []
    private static let packQueue = DispatchQueue(label: "com.cnrad.interspace.pack", qos: .utility, autoreleaseFrequency: .workItem)
    private static let unpackQueue = DispatchQueue(label: "com.cnrad.interspace.unpack", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private var wallpapers: [CGDirectDisplayID: Snapshot] = [:]
    private var wallpapersInProgress: Set<CGDirectDisplayID> = []
    /// Displays whose desktop picture could not be made. Not tried again until the displays change.
    private var wallpapersFailed: Set<CGDirectDisplayID> = []
    /// Counts the changes of the displays, so a picture made for the displays before a change is not kept.
    private var wallpaperGeneration = 0
    private var knownSpaces: [String: [UInt64]] = [:]

    /// The visit of all spaces freezes the screen below a picture of it. A loader on that picture, where
    /// the menu bar icon is, shows that the app is at work. The real icon cannot do this: it is below the cover.
    ///
    /// `hideMenuBarIcon` is called before the picture for the cover is taken. It hides the icon, so the
    /// picture has an empty place for the loader, and returns that place. `nil`: no loader on this screen.
    var hideMenuBarIcon: ((NSScreen) -> Overlay.Loader?)?
    /// Called when the cover is on screen and hides the menu bar, and when a visit stops for any reason.
    var showMenuBarIcon: (() -> Void)?
    /// How long the menu bar needs to draw without the icon before the picture is taken.
    private static let iconHideTime = 0.08

    private var link: CADisplayLink?
    /// The moment the last frame of the display link was drawn for. 0: no frame yet.
    private var lastFrameTarget: CFTimeInterval = 0
    private var phaseStart: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var watchdog: Timer?

    /// The Dock reports intermediate state for a moment after a synthetic swipe, so our own
    /// count is the truth during that time. A swipe past the last space can wedge the Dock.
    private var lastSwitch: (displayUUID: String, spaceIDs: [UInt64], index: Int, time: CFTimeInterval)?
    private var didSwitch = false

    // The wait for a stable live desktop before the fade.
    private var stabilityToken = 0
    private var stabilityStarted = false
    /// The live desktop below shows the new space and has stopped changing.
    private var liveReady = false
    /// The overlay is removed in one step at the end, with no fade. See `Overlay.canFadeOut`.
    private var revealIsCut = false
    private var lastSample: [UInt8]?
    private var refreshToken = 0


    /// Space indexes still to visit, in order. The last one is the space the visit started on.
    /// A swipe in the Instant transition is in progress, and it has already switched (or cannot).
    private var instantSwipeActive = false
    private var instantSwipeFired = false
    /// The space the Instant swipe started on, the direction of its first movement (+1 or -1),
    /// and the number of spaces it has gone since, with a sign.
    private var instantOrigin = 0
    private var instantDirection = 0
    private var instantSteps = 0
    /// Keeps the Dock going to the space the swipe asked for, one step at a time, also after the fingers lift.
    private var instantPump: Timer?

    /// For the log line at the end of each showing of the overlay.
    private var stats = TransitionStats()

    private var tourRoute: [Int] = []
    private var tourToken = 0
    /// The kind of image this visit makes: with the Dock in it, or without.
    private var tourIncludesDock = true
    /// A small copy of the desktop the visit started on. The cover goes away only when the live desktop
    /// looks like this again.
    private var tourOriginSample: [UInt8]?

    init() {
        recognizer.onArm = { [weak self] in self?.arm() }
        recognizer.onDisarm = { [weak self] in self?.disarm() }
        recognizer.onBegin = { [weak self] time in self?.begin(at: time) }
        recognizer.onChange = { [weak self] dx, time in self?.change(dx, at: time) }
        recognizer.onEnd = { [weak self] velocity, cancelled in self?.end(velocity: velocity, cancelled: cancelled) }
    }

    func handle(_ frame: TouchFrame) {
        guard isEnabled, phase != .touring else { return }
        recognizer.handle(frame)
    }

    func prewarm() {
        snapshotter.refreshDisplays { [weak self] in
            // The first capture after launch is slower than the ones after it. Take it now and throw it
            // away, so the first swipe does not pay for it. A swipe that starts during it shares its result.
            guard let self, self.phase == .idle, let screen = NSScreen.main else { return }
            self.snapshotter.capture(screen: screen, includeDock: AppSettings.shared.dockMovesWithSpace) { _ in }
        }
        prepareWallpapers()
    }

    func displaysChanged() {
        wallpapers.removeAll()
        wallpapersInProgress.removeAll()
        wallpapersFailed.removeAll()
        wallpaperGeneration += 1
        if phase == .idle {
            forgetAllImages()
        }
        snapshotter.refreshDisplays()
        prepareWallpapers()
    }

    /// Makes the desktop picture of each display now, off the main thread. A swipe to a space with no
    /// image shows that picture, and making it in the swipe stops the main thread for more than 0.1 s.
    private func prepareWallpapers() {
        let generation = wallpaperGeneration
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            guard wallpapers[displayID] == nil, !wallpapersInProgress.contains(displayID),
                  !wallpapersFailed.contains(displayID)
            else { continue }
            wallpapersInProgress.insert(displayID)
            snapshotter.wallpaper(for: screen) { [weak self] snapshot in
                // The displays changed during the work.
                guard let self, generation == self.wallpaperGeneration else { return }
                self.wallpapersInProgress.remove(displayID)
                guard let snapshot else {
                    self.wallpapersFailed.insert(displayID)
                    return
                }
                guard self.wallpapers[displayID] == nil else { return }
                self.wallpapers[displayID] = snapshot
                // A transition on screen that waits for it, with a plain card in its place, gets it now.
                if self.overlay.isVisible, self.phase != .touring, self.layout?.displayID == displayID {
                    CATransaction.begin()
                    self.assignCards()
                    self.overlay.render(progress: self.progress)
                    CATransaction.commit()
                }
            }
        }
    }

    // MARK: - Gesture

    private var isInstant: Bool {
        AppSettings.shared.transition == .instant
    }

    private func arm() {
        fingersDownSince = CACurrentMediaTime()
        // Instant draws nothing, so it needs no image.
        guard Config.captureOnTouchDown, !isInstant, phase == .idle, !overlay.isVisible else { return }
        prepare()
    }

    /// The fingers lifted, or became a gesture of another kind, before a swipe started.
    private func disarm() {
        fingersDownSince = nil
    }

    /// True while fingers that came down at the end of a transition can still start the next swipe. The
    /// overlay then waits at rest for them, and does not go away: their swipe catches it, and needs no new
    /// snapshot. A new snapshot comes only after the fingers have moved, or after they have lifted, for a
    /// quick flick, and the swipe then has no animation for its first part, or none at all.
    private var holdsForFingers: Bool {
        guard let since = fingersDownSince else { return false }
        return CACurrentMediaTime() - since < Self.fingersHoldTime
    }

    private func begin(at time: CFTimeInterval) {
        fingersDownSince = nil
        if isInstant, phase == .idle, !overlay.isVisible {
            if instantPump == nil {
                // Only the list of spaces is needed, to know if there is a space in that direction.
                layout = currentLayout()
                setBase(layout?.currentIndex ?? 0)
            }
            // If the Dock is still on its way from the swipe before, this one goes on from where that one ends.
            instantOrigin = baseIndex
            instantDirection = 0
            instantSteps = 0
            instantSwipeActive = layout != nil
            instantSwipeFired = false
            return
        }

        let now = CACurrentMediaTime()
        lastFrameTime = now
        startWatchdog()
        fingers.reset(at: time, value: 0)

        if overlay.isVisible {
            // Catch the transition in flight and continue from where it is.
            log.notice("begin: caught the overlay in phase \(String(describing: self.phase), privacy: .public) at progress \(self.progress)")
            stats.catches += 1
            stabilityToken += 1
            stabilityStarted = false
            liveReady = false
            overlay.alpha = 1
            pendingRelease = nil
            keyPending = false
            catchUp = nil
            dragOrigin = progress
            velocity = 0
            phase = .dragging
            startLink()
            return
        }

        if phase == .dragging, let release = pendingRelease {
            // The swipe before this one ended before its snapshot came, and the snapshot is still on its way.
            // That swipe is not lost: this one goes on from the space it was going to.
            log.notice("begin: the swipe before still waits for its snapshot, target \(release.target)")
            pendingRelease = nil
            keyPending = false
            // Its switch with no transition, if the snapshot is late, is for its own release, not this one's.
            lateSwitchToken += 1
            dragOrigin = CGFloat(release.target)
            velocity = 0
            // A press of a key does not start the display link: this drag needs it.
            startLink()
            return
        }

        if layout == nil || now - captureStarted > Config.snapshotMaxAge {
            prepare()
        }
        guard layout != nil else {
            // No space information: leave the gesture alone.
            log.notice("begin: no space information, the swipe does nothing")
            stopWatchdog()
            recognizer.reset()
            return
        }

        progress = 0
        velocity = 0
        dragOrigin = 0
        catchUp = nil
        didSwitch = false
        pendingRelease = nil
        keyPending = false
        stats = TransitionStats(start: now)
        phase = .dragging
        startDockWatcher()
        startLink()
        if captureFinished, !captureFailed {
            present()
        }
    }

    // MARK: - Keyboard

    /// A press of the shortcut for the space to the left (-1) or to the right (+1).
    func keyboardStep(_ direction: Int) {
        guard isEnabled, direction != 0 else { return }

        if isInstant {
            guard phase == .idle, !overlay.isVisible, !instantSwipeActive, instantPump == nil,
                  let layout = currentLayout()
            else { return }
            self.layout = layout
            setBase(layout.currentIndex)
            _ = postSwitch(direction)
            self.layout = nil
            return
        }

        switch phase {
        case .touring:
            return

        case .dragging:
            // Fingers have the transition. Only a press that still waits for its snapshot takes one more.
            guard keyPending, let release = pendingRelease, let layout,
                  layout.spaceIDs.indices.contains(baseIndex + release.target + direction)
            else { return }
            pendingRelease = (release.target + direction, 0)

        case .idle:
            guard !overlay.isVisible else { return }
            if layout == nil || CACurrentMediaTime() - captureStarted > Config.snapshotMaxAge {
                prepare()
            }
            guard let layout, layout.spaceIDs.indices.contains(baseIndex + direction) else {
                // No space in that direction, or no space information.
                captureToken += 1
                reset()
                return
            }
            log.notice("key: start, direction \(direction)")
            progress = 0
            velocity = 0
            dragOrigin = 0
            catchUp = nil
            didSwitch = false
            stats = TransitionStats(start: CACurrentMediaTime())
            phase = .dragging
            keyPending = true
            pendingRelease = (direction, 0)
            startDockWatcher()
            if captureFinished {
                captureDidFinish()
            } else {
                switchWithoutOverlayIfLate()
            }

        case .settling, .holding, .revealing:
            guard let layout, layout.spaceIDs.indices.contains(baseIndex + direction) else { return }
            // Catch the transition in flight. The picture stays where it is and keeps its speed:
            // only the place where it comes to rest changes.
            log.notice("key: direction \(direction) in phase \(String(describing: self.phase), privacy: .public) at progress \(self.progress) velocity \(self.velocity)")
            overlay.alpha = 1
            commit(target: direction, velocity: velocity)
        }
    }

    /// A release can come before the snapshot. When the snapshot takes too long, switch with no transition.
    private func switchWithoutOverlayIfLate() {
        let token = captureToken
        lateSwitchToken += 1
        let lateToken = lateSwitchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.captureToken == token, self.lateSwitchToken == lateToken,
                  let release = self.pendingRelease
            else { return }
            self.pendingRelease = nil
            self.captureToken += 1
            self.switchWithoutOverlay(release.target)
        }
    }

    /// A report of the trackpad during a drag. The picture moves on the next frame of the display, from
    /// the reports around that frame: see `renderDrag`.
    private func change(_ dx: CGFloat, at time: CFTimeInterval) {
        if instantSwipeActive {
            instantChange(Self.progress(forFingerTravel: dx))
            return
        }
        guard phase == .dragging, pendingRelease == nil else { return }
        lastFrameTime = CACurrentMediaTime()
        fingers.add(at: time, value: dx)
        stats.touch(at: time)
    }

    private func end(velocity fingerVelocity: CGFloat, cancelled: Bool) {
        fingersDownSince = nil
        if instantSwipeActive {
            instantSwipeActive = false
            finishInstantIfDone()
            return
        }
        guard phase == .dragging, pendingRelease == nil else { return }
        stopWatchdog()
        stats.released = CACurrentMediaTime()
        stats.endTouches()

        let releaseVelocity = Self.progress(forFingerTravel: fingerVelocity)
        // Where the fingers left the trackpad. The picture can be a frame behind them: it stays where it is,
        // and the spring takes it from there.
        var raw = dragOrigin + Self.progress(forFingerTravel: fingers.latest)
        if overlay.isVisible {
            // Whole spaces crossed since the last frame: the base moves there first, as on a frame.
            let crossed = Int(raw.rounded(.towardZero))
            if crossed != 0 {
                let before = baseIndex
                retarget(by: crossed)
                let moved = CGFloat(baseIndex - before)
                dragOrigin -= moved
                raw -= moved
            }
        }
        // With nothing on screen yet, a swipe that went on from the swipe before it (see `begin`) can be
        // more than one space: the whole spaces are part of the target.
        let whole = overlay.isVisible ? 0 : Int(raw.rounded(.towardZero))
        let target = cancelled
            ? 0 : whole + self.target(for: raw - CGFloat(whole), velocity: releaseVelocity, from: baseIndex + whole)
        log.notice("end: progress \(raw) velocity \(releaseVelocity) target \(target) overlay \(self.overlay.isVisible) captureFinished \(self.captureFinished) captureFailed \(self.captureFailed)")

        if overlay.isVisible {
            commit(target: target, velocity: releaseVelocity)
        } else if target == 0 {
            // Nothing was shown and nothing changes.
            reset()
        } else if captureFinished {
            // The snapshot failed. Switch with no transition instead of doing nothing.
            switchWithoutOverlay(target)
        } else {
            // A very fast flick can end before the snapshot arrives. Run the animation when it does.
            pendingRelease = (target, releaseVelocity)
            switchWithoutOverlayIfLate()
        }
    }

    // MARK: - Instant

    /// How far the fingers must come back past a step before that step is undone, in spaces.
    /// Without it, fingers that rest on the line between two steps would switch back and forth.
    private static let instantBackMargin: CGFloat = 0.15

    /// `travel` is how far the fingers have moved since the swipe started, in spaces, with the swipe
    /// sensitivity in it. The first movement switches one space at once. After that, each further whole
    /// space of travel switches one more, as a scroll does, and travel back undoes them.
    /// At normal sensitivity a full trackpad width is under one space, so one swipe is one space.
    private func instantChange(_ travel: CGFloat) {
        guard let layout else { return }
        if !instantSwipeFired {
            guard travel != 0 else { return }
            instantSwipeFired = true
            instantDirection = travel > 0 ? 1 : -1
        }
        // In the direction of the first movement. The first step is there at no travel at all.
        let forward = travel * CGFloat(instantDirection) + 1
        var steps = instantSteps * instantDirection
        while forward >= CGFloat(steps + 1) { steps += 1 }
        while forward < CGFloat(steps) - Self.instantBackMargin { steps -= 1 }

        let wanted = min(max(instantOrigin + steps * instantDirection, 0), layout.spaceIDs.count - 1)
        // At the first or the last space the count stops too, so the way back starts at once.
        instantSteps = wanted - instantOrigin
        guard wanted != baseIndex else { return }
        baseIndex = wanted
        pumpDock()
        if instantPump == nil, dockIndex != baseIndex {
            // The Dock takes one step at a time. This sends the next one when the step before is done.
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pumpDock()
                self.finishInstantIfDone()
            }
            RunLoop.main.add(timer, forMode: .common)
            instantPump = timer
        }
    }

    /// Ends the Instant swipe when the fingers are up and the Dock is where the swipe asked.
    private func finishInstantIfDone() {
        guard !instantSwipeActive, dockIndex == baseIndex || layout == nil else { return }
        instantPump?.invalidate()
        instantPump = nil
        if phase == .idle, !overlay.isVisible {
            layout = nil
        }
    }

    /// The space to come to rest on, from where the picture is and how fast it goes, from `base`
    /// (`baseIndex` when not given).
    private func target(for progress: CGFloat, velocity: CGFloat, from base: Int? = nil) -> Int {
        let base = base ?? baseIndex
        let count = layout?.spaceIDs.count ?? 0
        let hasNext = base + 1 < count
        let hasPrevious = count > 0 && base > 0
        var target = 0
        if progress > Config.commitThreshold, hasNext {
            target = 1
        } else if progress < -Config.commitThreshold, hasPrevious {
            target = -1
        }

        if velocity > Config.flickVelocity {
            if target == -1 {
                target = 0
            } else if progress > Config.flickMinProgress, hasNext {
                target = 1
            }
        } else if velocity < -Config.flickVelocity {
            if target == 1 {
                target = 0
            } else if progress < -Config.flickMinProgress, hasPrevious {
                target = -1
            }
        }
        return target
    }

    private func commit(target: Int, velocity releaseVelocity: CGFloat) {
        // A press of the shortcut during a snap starts the next one here.
        if target != 0 {
            retarget(by: target)
        }
        // The spring goes on from where the picture is now.
        catchUp = nil
        velocity = min(max(releaseVelocity, -TransitionMath.maxReleaseVelocity), TransitionMath.maxReleaseVelocity)
        stabilityToken += 1
        stabilityStarted = false
        liveReady = false
        phase = .settling
        startLink()
    }

    private func switchWithoutOverlay(_ target: Int) {
        log.notice("switch with no overlay, target \(target)")
        if target != 0 {
            _ = postSwitch(target.signum())
        }
        reset()
    }

    /// Sets the space the transition is measured from, when the Dock is at rest on that space.
    private func setBase(_ index: Int) {
        baseIndex = index
        dockIndex = index
        dockPostTime = 0
        dockLanded = true
    }

    private var limit: CGFloat { CGFloat(Overlay.reach) }

    /// Moves the place where the transition comes to rest by a number of spaces. The picture does not move.
    private func retarget(by requested: Int) {
        guard let layout else { return }
        let destination = min(max(baseIndex + requested, 0), layout.spaceIDs.count - 1)
        let steps = destination - baseIndex
        guard steps != 0 else { return }
        baseIndex = destination
        unpackNearImages()
        // There is a picture for `limit` spaces to each side. More than that is rare, and the picture jumps.
        progress = min(max(progress - CGFloat(steps), -limit), limit)
        didSwitch = true
        pumpDock()
        // The screens get new images and new positions. Both must reach the display in the
        // same frame: new images in the old positions show the wrong desktop for one frame.
        CATransaction.begin()
        assignCards()
        overlay.render(progress: progress)
        CATransaction.commit()
    }

    /// Sends the Dock one space closer to `baseIndex`, when it has finished the step before.
    ///
    /// The picture is free of the Dock: it turns around at once. The Dock is not: a swipe that is posted
    /// while the Dock is busy with another one can be lost. So the Dock gets one at a time, below the overlay.
    ///
    /// It also watches every switch until the Dock shows its space. A switch the Dock did not make is given
    /// up after `dockLandingTimeout`, and the picture goes to where the Dock is: the overlay must never go
    /// away over a desktop that is not the one it shows, and the next swipe must start from the right space.
    private func pumpDock() {
        // Nothing on its way, and nothing to send.
        guard layout != nil, !(dockLanded && dockIndex == baseIndex) else { return }
        let landed = dockPostTime == 0 || dockIsOn(dockIndex) == true
        if landed, !dockLanded {
            dockLanded = true
            if stats.dockLanded == 0 { stats.dockLanded = CACurrentMediaTime() }
            stats.dock("landed", at: CACurrentMediaTime())
        }
        guard landed else {
            guard CACurrentMediaTime() - dockPostTime > Self.dockLandingTimeout else { return }
            log.error("the Dock did not switch to index \(self.dockIndex) in \(Int(Self.dockLandingTimeout * 1000)) ms, following it")
            // Our count of the switches is wrong now. The next swipe reads where the Dock is.
            lastSwitch = nil
            followDock(readDock: true)
            return
        }
        guard dockIndex != baseIndex else { return }
        // Behind the overlay the switch waits until the picture has almost come to rest: see
        // `Config.switchDistance`. A swipe that catches the picture before then and goes back needs no switch.
        if overlay.isVisible, phase == .dragging || abs(progress) >= Config.switchDistance {
            return
        }
        if !postSwitch(baseIndex > dockIndex ? 1 : -1) {
            followDock(readDock: false)
        }
    }

    /// The Dock cannot go where the picture goes. Makes the picture go where the Dock is.
    private func followDock(readDock: Bool) {
        guard let layout else { return }
        var actual = dockIndex
        if readDock, let live = Spaces.state(displayID: layout.displayID), live.spaceIDs == layout.spaceIDs,
           let index = live.spaceIDs.firstIndex(of: live.currentID) {
            actual = index
        }
        let moved = baseIndex - actual
        setBase(actual)
        guard moved != 0 else { return }
        unpackNearImages()
        // During a drag, the caller moves `dragOrigin` with the base: see `tick` and `renderDrag`.
        progress = min(max(progress + CGFloat(moved), -limit), limit)
        if overlay.isVisible {
            CATransaction.begin()
            assignCards()
            overlay.render(progress: progress)
            CATransaction.commit()
        }
        if phase == .holding || phase == .revealing {
            // The picture is not at rest now.
            stabilityToken += 1
            stabilityStarted = false
            liveReady = false
            overlay.alpha = 1
            phase = .settling
        }
    }

    /// Makes the Dock switch one space now, from the space it was last sent to, with no animation of its own.
    private func postSwitch(_ target: Int) -> Bool {
        guard let layout, layout.spaceIDs.indices.contains(dockIndex + target) else { return false }
        // A swipe past the last space can wedge the Dock. If a desktop was added or removed since this
        // gesture read the list, our index is not safe: do not switch.
        guard let liveIDs = liveSpaceIDs(), liveIDs == layout.spaceIDs else {
            log.notice("the list of spaces changed during a gesture, no switch")
            return false
        }
        if overlay.ensureOnAllDesktops(layout.desktopIDs) {
            log.notice("replaced the overlay window at the switch: it was not on every desktop")
        }
        guard ds_post_switch(target > 0 ? DSDirectionRight : DSDirectionLeft) else { return false }
        dockIndex += target
        dockPostTime = CACurrentMediaTime()
        dockLanded = false
        if stats.firstPost == 0 { stats.firstPost = dockPostTime }
        stats.dock("post", at: dockPostTime)
        lastSwitch = (layout.displayUUID, layout.spaceIDs, dockIndex, dockPostTime)
        return true
    }

    /// The list of spaces as it is now: from the watcher when it read it a moment ago, or read here.
    private func liveSpaceIDs() -> [UInt64]? {
        guard let layout else { return nil }
        if let reading = dockWatcher.latest, CACurrentMediaTime() - reading.started < 0.1 {
            return reading.state.spaceIDs
        }
        return Spaces.state(displayID: layout.displayID)?.spaceIDs
    }

    /// Watches the Dock from a thread of its own until `reset`, for `pumpDock` and the live check.
    private func startDockWatcher() {
        guard let layout else { return }
        dockWatcher.start(displayID: layout.displayID)
    }

    // MARK: - Snapshot

    /// Reads the space list and starts the snapshot of the current space.
    private func prepare() {
        refreshToken += 1
        captureToken += 1
        captureFinished = false
        captureFailed = false
        notifications = nil
        layout = currentLayout()
        guard let layout else { return }
        setBase(layout.currentIndex)
        unpackNearImages()
        // The window must be on every desktop before it is shown. The check is a call to the window server,
        // so it is made here, before anything moves; `present` and `postSwitch` then find it done.
        if overlay.ensureOnAllDesktops(layout.desktopIDs, maxAge: 10) {
            log.notice("replaced the overlay window before a swipe: it was not on every desktop")
        }
        captureStarted = CACurrentMediaTime()

        let token = captureToken
        let spaceID = layout.spaceIDs[baseIndex]
        snapshotter.capture(screen: layout.screen, includeDock: AppSettings.shared.dockMovesWithSpace) { [weak self] snapshot in
            guard let self, token == self.captureToken else { return }
            if let snapshot {
                self.overlayIsBelowDock = !snapshot.includesDock
                self.store(snapshot, for: spaceID)
            }
            self.notifications = snapshot?.notifications
            self.captureFinished = true
            self.captureFailed = snapshot == nil
            self.captureDidFinish()
        }
    }

    private func captureDidFinish() {
        guard phase == .dragging, !overlay.isVisible else { return }
        if !captureFailed {
            present()
        }
        guard let release = pendingRelease else { return }
        pendingRelease = nil
        if overlay.isVisible {
            commit(target: release.target, velocity: release.velocity)
        } else {
            switchWithoutOverlay(release.target)
        }
    }

    private func currentLayout() -> SpaceLayout? {
        guard let screen = NSScreen.underCursor, var layout = Spaces.layout(for: screen) else { return nil }
        if let lastSwitch,
           lastSwitch.displayUUID == layout.displayUUID,
           lastSwitch.spaceIDs == layout.spaceIDs,
           CACurrentMediaTime() - lastSwitch.time < 1.0,
           layout.spaceIDs.indices.contains(lastSwitch.index) {
            layout.currentIndex = lastSwitch.index
        }
        forgetRemovedSpaces(layout)
        return layout
    }

    /// Drops the images of spaces that are gone, so a removed desktop does not keep its memory.
    private func forgetRemovedSpaces(_ layout: SpaceLayout) {
        defer { knownSpaces[layout.displayUUID] = layout.spaceIDs }
        guard let before = knownSpaces[layout.displayUUID], before != layout.spaceIDs else { return }
        let removed = Set(before).subtracting(layout.spaceIDs)
        for spaceID in removed {
            cache[spaceID] = nil
            packed[spaceID] = nil
        }
        cacheOrder.removeAll { removed.contains($0) }
        log.notice("spaces changed: \(before.count) to \(layout.spaceIDs.count), \(removed.count) removed")
    }

    private func store(_ snapshot: Snapshot, for spaceID: UInt64) {
        var snapshot = snapshot
        // They were on screen at the capture, and are not part of the space.
        snapshot.notifications = nil
        cache[spaceID] = snapshot
        // The new image replaces the old one in each form.
        packed[spaceID] = nil
        cacheOrder.removeAll { $0 == spaceID }
        cacheOrder.append(spaceID)
        while cacheOrder.count > Config.snapshotCacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache[oldest] = nil
            packed[oldest] = nil
        }
    }

    private func forgetAllImages() {
        cache.removeAll()
        packed.removeAll()
        cacheOrder.removeAll()
    }

    /// The kind of image we have of a space: with the Dock in it, or without. Nil when we have none.
    private func imageIncludesDock(_ spaceID: UInt64) -> Bool? {
        cache[spaceID]?.includesDock ?? packed[spaceID]?.includesDock
    }

    // MARK: - Memory

    /// Compresses the images of the spaces that are far from the current one, a moment after a transition,
    /// when nothing moves. A new swipe cancels it.
    private func packFarImages(_ token: Int) {
        guard cache.count > 2 * Config.fullImageRadius + 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, token == self.refreshToken, self.phase == .idle, !self.overlay.isVisible else { return }
            for screen in NSScreen.screens {
                guard let layout = Spaces.layout(for: screen) else { continue }
                for (index, spaceID) in layout.spaceIDs.enumerated()
                where abs(index - layout.currentIndex) > Config.fullImageRadius {
                    guard let snapshot = self.cache[spaceID], !self.packing.contains(spaceID) else { continue }
                    self.packing.insert(spaceID)
                    Self.packQueue.async { [weak self] in
                        let stored = PackedSnapshot(snapshot)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.packing.remove(spaceID)
                            // Not when the space has a newer image now, and not in a transition: the
                            // space can be near by now, and a card can need the image in this frame.
                            guard let stored, self.phase == .idle, self.cache[spaceID]?.image === snapshot.image else { return }
                            self.cache[spaceID] = nil
                            self.packed[spaceID] = stored
                            log.info("packed the image of space \(spaceID): \(stored.fullByteCount / 1_000_000) MB to \(stored.byteCount / 1_000_000) MB")
                        }
                    }
                }
            }
        }
    }

    /// Makes full images again for the spaces that are near the base now, off the main thread.
    /// It runs one step before such a space can show, so the image is there when a card needs it.
    private func unpackNearImages() {
        guard let layout, !packed.isEmpty else { return }
        for (index, spaceID) in layout.spaceIDs.enumerated() where abs(index - baseIndex) <= Config.fullImageRadius {
            guard let stored = packed[spaceID], !unpacking.contains(spaceID) else { continue }
            unpacking.insert(spaceID)
            Self.unpackQueue.async { [weak self] in
                let snapshot = stored.unpacked()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.unpacking.remove(spaceID)
                    // The space has a newer image now, or `content(at:)` could not wait for this one.
                    guard let current = self.packed[spaceID], current.isSame(as: stored) else { return }
                    self.packed[spaceID] = nil
                    if let snapshot {
                        self.cache[spaceID] = snapshot
                    } else {
                        self.cacheOrder.removeAll { $0 == spaceID }
                    }
                }
            }
        }
    }

    private func content(at index: Int) -> CardContent {
        guard let layout, layout.spaceIDs.indices.contains(index) else { return .none }
        let spaceID = layout.spaceIDs[index]
        if let snapshot = cache[spaceID] {
            return .snapshot(snapshot)
        }
        if let stored = packed[spaceID] {
            // `unpackNearImages` has not finished this one. A card needs it now, so the main thread makes it.
            let started = CACurrentMediaTime()
            packed[spaceID] = nil
            if let snapshot = stored.unpacked() {
                cache[spaceID] = snapshot
                log.notice("unpacked an image in the transition: \(Int((CACurrentMediaTime() - started) * 1000)) ms on the main thread")
                return .snapshot(snapshot)
            }
            cacheOrder.removeAll { $0 == spaceID }
        }
        if let wallpaper = wallpapers[layout.displayID] {
            return .snapshot(wallpaper)
        }
        // Not made yet, or it could not be made. Made here, it would stop the main thread for more than 0.1 s
        // in the middle of the transition: it is made on a thread of its own, and the card gets it when it is
        // ready (`prepareWallpapers`). Until then the card is plain.
        prepareWallpapers()
        return .placeholder
    }

    // MARK: - Overlay

    private func present() {
        guard let layout else { return }
        if overlay.ensureOnAllDesktops(layout.desktopIDs) {
            log.notice("replaced the overlay window before it was shown: it was not on every desktop")
        }
        overlay.isBelowDock = overlayIsBelowDock
        overlay.style = AppSettings.shared.transition
        overlay.roundsCorners = AppSettings.shared.roundedCorners
        var fingersAt: CGFloat = 0
        if phase == .dragging, pendingRelease == nil {
            // The fingers moved while the snapshot was taken. The picture comes on screen where the live
            // desktop is, so nothing jumps, and catches up with them in a few frames.
            let now = CACurrentMediaTime()
            fingersAt = dragPosition(dragOrigin + Self.progress(forFingerTravel: fingers.value(at: now - Self.resampleLatency)))
            progress = 0
            catchUp = (now, -fingersAt)
        }
        CATransaction.begin()
        overlay.attach(to: layout.screen)
        assignCards()
        overlay.showNotifications(notifications)
        overlay.render(progress: progress)
        CATransaction.commit()
        overlay.present()
        stats.presented = CACurrentMediaTime()
        stats.presentedProgress = fingersAt
    }

    private func assignCards() {
        overlay.setCards { offset in self.content(at: self.baseIndex + offset) }
    }

    /// `base` and `origin` are `baseIndex` and `dragOrigin` when not given.
    private func constrain(_ raw: CGFloat, base: Int? = nil, origin: CGFloat? = nil) -> CGFloat {
        let base = base ?? baseIndex
        let count = layout?.spaceIDs.count ?? 0
        if raw > 0, base + 1 >= count { return Self.rubberBand(raw) }
        if raw < 0, base <= 0 { return -Self.rubberBand(-raw) }
        // One space, or as far as the picture already was when the fingers caught it.
        let limit = max(1, abs(origin ?? dragOrigin))
        return min(max(raw, -limit), limit)
    }

    private static func rubberBand(_ distance: CGFloat) -> CGFloat {
        let limit = Config.edgeRubberBand
        return (1 - 1 / (distance * 0.55 / limit + 1)) * limit
    }

    /// Content follows the fingers: with natural scrolling, fingers that move left bring in the space on the right.
    private static func progress(forFingerTravel dx: CGFloat) -> CGFloat {
        let natural = (UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
        return (natural ? -dx : dx) * Config.travelPerTrackpadWidth * CGFloat(AppSettings.shared.sensitivity)
    }

    // MARK: - Animation

    /// Runs from the start of a drag (or of a press of a key) to the end of the transition.
    private func startLink() {
        guard link == nil, let screen = layout?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        // Every frame the display can show: 120 a second on a ProMotion display.
        let fastest = Float(max(screen.maximumFramesPerSecond, 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fastest), maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrameTarget = 0
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let workStart = CACurrentMediaTime()
        let tickPhase = phase
        stats.tick(at: link.timestamp, frame: link.duration)
        // The frame that ends the transition removes the overlay, and no frame of it follows: not counted.
        defer {
            if phase != .idle {
                stats.work(CACurrentMediaTime() - workStart, phase: String(describing: tickPhase))
            }
        }
        // Each frame shows the picture as it is at the moment the frame is on screen.
        let frameTime = link.targetTimestamp
        let delta = lastFrameTarget == 0 ? link.duration : min(max(frameTime - lastFrameTarget, 0), 1.0 / 30)
        lastFrameTarget = frameTime
        // The Dock is looked after once this frame is drawn: a switch keeps the window server busy.
        defer {
            if phase != .idle, phase != .touring {
                let before = baseIndex
                pumpDock()
                if phase == .dragging {
                    // The Dock did not go where the drag sent it, and the base went back to it. The fingers
                    // keep the picture where it is: they now count from that space.
                    dragOrigin -= CGFloat(baseIndex - before)
                }
            }
        }

        switch phase {
        case .dragging:
            if overlay.isVisible, pendingRelease == nil {
                renderDrag(at: link.timestamp)
            }

        case .settling:
            stepSpring(CGFloat(delta))
            overlay.render(progress: progress)
            startLiveCheckIfNeeded()
            if abs(progress) < Config.revealStartDistance {
                // Close enough: the last points of travel finish below the fade.
                if liveReady, !holdsForFingers {
                    startReveal()
                } else if isSettled {
                    progress = 0
                    velocity = 0
                    overlay.render(progress: 0)
                    phase = .holding
                    phaseStart = CACurrentMediaTime()
                }
            }

        case .holding:
            startLiveCheckIfNeeded(force: CACurrentMediaTime() - phaseStart > Self.forceLiveCheckTime)
            if liveReady, !holdsForFingers {
                startReveal()
            }

        case .revealing:
            if !isSettled {
                stepSpring(CGFloat(delta))
                overlay.render(progress: isSettled ? 0 : progress)
            }
            if revealIsCut {
                // No fade to hide the last points of travel: wait until the picture is exactly in place.
                if isSettled {
                    reset()
                }
            } else {
                let alpha = 1 - CGFloat(frameTime - phaseStart) / Config.revealDuration
                if alpha <= 0 {
                    reset()
                } else {
                    overlay.alpha = alpha
                }
            }

        case .idle, .touring:
            break
        }
    }

    /// Draws the drag on a frame of the display, with the fingers where they were `resampleLatency` before
    /// it. Reports of the trackpad and frames of the display come on two clocks, so a picture that moves on
    /// each report moves unevenly; this one moves on each frame.
    private func renderDrag(at time: CFTimeInterval) {
        let raw = dragOrigin + Self.progress(forFingerTravel: fingers.value(at: time - Self.resampleLatency))
        progress = dragPosition(raw) + catchUpOffset(at: time)

        // With a high sensitivity one drag can pass several spaces. Each time the fingers have crossed a
        // whole space, that space becomes the one the transition is measured from, and the Dock is sent
        // there below the overlay. The drag then goes on to the next space, or back again.
        let crossed = Int(raw.rounded(.towardZero))
        if crossed != 0 {
            let before = baseIndex
            // The picture stays where it is: only the space it is measured from moves.
            retarget(by: crossed)
            dragOrigin -= CGFloat(baseIndex - before)
        }
        overlay.render(progress: progress)
    }

    /// Where a drag puts the picture for fingers at `raw`, in spaces from the base as it is now: the place
    /// `renderDrag` draws, with the whole spaces it crosses, before any catch-up.
    private func dragPosition(_ raw: CGFloat) -> CGFloat {
        guard let layout else { return constrain(raw) }
        let crossed = Int(raw.rounded(.towardZero))
        let steps = min(max(baseIndex + crossed, 0), layout.spaceIDs.count - 1) - baseIndex
        guard steps != 0 else { return constrain(raw) }
        let moved = CGFloat(steps)
        return constrain(raw - moved, base: baseIndex + steps, origin: dragOrigin - moved) + moved
    }

    /// How far the picture still is from the fingers, after it came on screen late. See `catchUp`.
    /// Critically damped: it starts with the speed of the fingers, so the picture never jumps.
    private func catchUpOffset(at time: CFTimeInterval) -> CGFloat {
        guard let catchUp else { return 0 }
        let t = CGFloat(time - catchUp.start) / Self.catchUpTime
        guard t > 0 else { return catchUp.offset }
        guard t < 12 else {
            self.catchUp = nil
            return 0
        }
        return catchUp.offset * (1 + t) * exp(-t)
    }

    private var isSettled: Bool {
        TransitionMath.isSettled(progress: progress, velocity: velocity)
    }

    /// Starts to look at the live desktop below the overlay near the end of the snap.
    /// It starts only when the Dock shows the new space: before that, the old space would look "ready".
    private func startLiveCheckIfNeeded(force: Bool = false) {
        guard !liveReady, !stabilityStarted else { return }
        guard didSwitch else {
            // Nothing changed below, the live desktop is what the snapshot shows.
            liveReady = true
            return
        }
        // The Dock still has a switch to do.
        guard dockIndex == baseIndex else { return }
        guard force || (abs(progress) < Config.liveCheckStartDistance && dockHasLanded) else { return }
        stabilityStarted = true
        lastSample = nil
        stabilityToken += 1
        sampleLiveDesktop(stabilityToken, deadline: CACurrentMediaTime() + Config.revealMaxWait)
    }

    private func startReveal() {
        stabilityToken += 1
        stabilityStarted = false
        lastSample = nil
        revealIsCut = !overlay.canFadeOut
        phase = .revealing
        phaseStart = CACurrentMediaTime()
        stats.revealed = phaseStart
        stats.revealIsCut = revealIsCut
    }

    /// Looks at the desktop below the overlay until two looks in a row are the same.
    private func sampleLiveDesktop(_ token: Int, deadline: CFTimeInterval) {
        guard let layout else {
            liveReady = true
            return
        }
        snapshotter.sampleBelow(windowNumber: overlay.windowNumber, screen: layout.screen) { [weak self] sample in
            // A new swipe that catches the overlay ends this check.
            guard let self, token == self.stabilityToken, self.phase == .settling || self.phase == .holding else { return }
            guard let sample else {
                self.liveReady = true
                return
            }
            if let origin = self.tourOriginSample {
                // After a visit of all spaces: not "has it stopped changing" but "is it the desktop we
                // started on". A desktop that was visited can look still and be the wrong one.
                if Snapshotter.samplesMatch(origin, sample, sameDesktop: true) {
                    self.liveReady = true
                    return
                }
            } else if let previous = self.lastSample, Snapshotter.samplesMatch(previous, sample) {
                self.liveReady = true
                return
            }
            if CACurrentMediaTime() > deadline {
                log.info("live desktop still changing, fading anyway")
                self.liveReady = true
            } else {
                self.lastSample = sample
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    guard let self, token == self.stabilityToken else { return }
                    self.sampleLiveDesktop(token, deadline: deadline)
                }
            }
        }
    }

    private func stepSpring(_ delta: CGFloat) {
        TransitionMath.stepSpring(
            progress: &progress, velocity: &velocity, delta: delta, speed: CGFloat(AppSettings.shared.speed),
            limit: limit
        )
    }

    private var dockHasLanded: Bool {
        dockIsOn(baseIndex) == true
    }

    /// True when the Dock shows the space at `index`, false when it shows another one, and nil when that is
    /// not known yet: the watcher has no reading made after the last switch. Also true when it cannot be
    /// known at all, so nothing waits for it.
    ///
    /// During a transition the reading comes from `dockWatcher`, and costs the main thread nothing. Without
    /// it (Instant, the visit of all spaces) the space list is read here.
    private func dockIsOn(_ index: Int) -> Bool? {
        guard let layout, layout.spaceIDs.indices.contains(index) else { return true }
        let current: UInt64
        if dockWatcher.isRunning {
            // A reading that started before the last switch was posted cannot show that switch.
            guard let reading = dockWatcher.latest, reading.started > dockPostTime else { return nil }
            current = reading.state.currentID
        } else {
            guard let live = Spaces.state(displayID: layout.displayID) else { return true }
            current = live.currentID
        }
        return current == layout.spaceIDs[index]
    }

    // MARK: - Capture of every space

    /// macOS draws only the active space, so a space can be captured only while it is active.
    /// This shows a frozen image of the screen, switches through the spaces we have no image of below it,
    /// captures each one, and comes back. It takes about a second.
    /// `again` also replaces the images we already have.
    func captureAllSpaces(again: Bool = false) {
        guard isEnabled, AppSettings.shared.transition.isDrawn, phase == .idle, !overlay.isVisible,
              let layout = currentLayout(), layout.spaceIDs.count > 1
        else { return }

        if again {
            forgetAllImages()
        }
        let origin = layout.currentIndex
        let includeDock = AppSettings.shared.dockMovesWithSpace
        // An image of the other kind (with the Dock, or without it) is as good as no image.
        let unknown = layout.spaceIDs.indices.filter {
            $0 != origin && imageIncludesDock(layout.spaceIDs[$0]) != includeDock
        }
        guard let lowest = unknown.min(), let highest = unknown.max() else { return }

        // Go to the nearer end first, then to the other end, then back.
        let low = min(lowest, origin)
        let high = max(highest, origin)
        let stops = origin - low <= high - origin ? [low, high, origin] : [high, low, origin]
        var route: [Int] = []
        var position = origin
        for stop in stops {
            while position != stop {
                position += stop > position ? 1 : -1
                route.append(position)
            }
        }

        log.notice("visit start: \(layout.spaceIDs.count) spaces, on index \(origin), route \(route, privacy: .public)")
        recognizer.reset()
        fingersDownSince = nil
        captureToken += 1
        tourToken += 1
        let token = tourToken
        self.layout = layout
        setBase(origin)
        tourRoute = route
        progress = 0
        velocity = 0
        phase = .touring

        // The overlay covers the screen, so nothing may leave it there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3 + 0.8 * Double(route.count)) { [weak self] in
            guard let self, self.isTouring(token) else { return }
            self.reset()
        }

        tourIncludesDock = includeDock
        tourOriginSample = nil

        /// Shows the cover, then starts the visit.
        func begin(cover: Snapshot, loader: Overlay.Loader? = nil) {
            presentCover(cover)
            overlay.showLoader(loader)
            if loader != nil {
                // The icon comes back below the cover. Not at once: the cover must be on screen first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.showMenuBarIcon?()
                }
            }
            // The captures below need to know the overlay window, which is on screen only now.
            snapshotter.refreshDisplays { [weak self] in
                guard let self, self.isTouring(token) else { return }
                // What the desktop below the cover looks like before the first switch.
                self.snapshotter.sampleBelow(windowNumber: self.overlay.windowNumber, screen: layout.screen) { [weak self] sample in
                    guard let self, self.isTouring(token) else { return }
                    self.tourOriginSample = sample
                    self.visitNextSpace(token)
                }
            }
        }

        snapshotter.capture(screen: layout.screen, includeDock: includeDock) { [weak self] snapshot in
            guard let self, self.isTouring(token) else { return }
            guard let snapshot else {
                self.reset()
                return
            }
            self.store(snapshot, for: layout.spaceIDs[origin])
            // The image above is for the transitions, so it has the icon in it. The cover gets its own.
            let loader = self.hideMenuBarIcon?(layout.screen)
            if snapshot.includesDock, loader == nil {
                begin(cover: snapshot)
                return
            }
            // One more image, of the whole screen, for one of two reasons. The image for the transition has no
            // Dock and no menu bar, and the cover must have them, because it is above everything. Or the cover
            // gets a loader, and the image must not have the icon where the loader goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + (loader == nil ? 0 : Self.iconHideTime)) { [weak self] in
                guard let self, self.isTouring(token) else { return }
                self.snapshotter.capture(screen: layout.screen, includeDock: true) { [weak self] full in
                    guard let self, self.isTouring(token) else { return }
                    guard let full else {
                        self.reset()
                        return
                    }
                    begin(cover: full, loader: loader)
                }
            }
        }
    }

    /// Shows a frozen image of the whole screen above everything, the Dock and the menu bar too.
    ///
    /// The Dock draws a space switch in its own layer, below the real Dock and above normal windows.
    /// An overlay just below the Dock can be under that layer for one frame, and the space that is being
    /// visited then shows through. Above everything, in a space of its own, nothing can be on top of the
    /// cover; see `Spaces.moveToOwnSpace` for a switch to or from a full-screen app.
    private func presentCover(_ cover: Snapshot) {
        guard let layout else { return }
        overlay.ensureOnAllDesktops(layout.desktopIDs)
        overlay.isBelowDock = false
        overlay.style = .lightweight
        overlay.roundsCorners = AppSettings.shared.roundedCorners
        CATransaction.begin()
        overlay.attach(to: layout.screen)
        overlay.setCards { offset in offset == 0 ? .snapshot(cover) : .none }
        overlay.showNotifications(cover.notifications)
        overlay.render(progress: 0)
        CATransaction.commit()
        overlay.present()
    }

    private func isTouring(_ token: Int) -> Bool {
        phase == .touring && token == tourToken
    }

    private func visitNextSpace(_ token: Int) {
        guard let layout, !tourRoute.isEmpty else {
            finishTour()
            return
        }
        let index = tourRoute.removeFirst()
        guard postSwitch(index > baseIndex ? 1 : -1) else {
            finishTour()
            return
        }
        // `postSwitch` moved `dockIndex` to the same space.
        baseIndex = index
        let spaceID = layout.spaceIDs[index]
        let includesDock = tourIncludesDock
        let needsCapture = imageIncludesDock(spaceID) != includesDock

        // Never post the next swipe before the Dock has finished this one.
        waitForDock(token, deadline: CACurrentMediaTime() + 1.0) { [weak self] in
            guard let self else { return }
            guard needsCapture else {
                // Only on the way to another space. The Dock has finished this switch, and that is all
                // the next one needs: a swipe posts its next switch on the same condition (`pumpDock`).
                self.visitNextSpace(token)
                return
            }
            // The space gets time to draw itself before the capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.visitSettleTime) { [weak self] in
                guard let self, self.isTouring(token) else { return }
                let finish: (Snapshot?) -> Void = { [weak self] snapshot in
                    guard let self, self.isTouring(token) else { return }
                    log.notice("visit: index \(index) captured \(snapshot != nil), with the Dock \(includesDock)")
                    if let snapshot {
                        self.store(snapshot, for: spaceID)
                    }
                    self.visitNextSpace(token)
                }
                if includesDock {
                    // Everything below the cover.
                    self.snapshotter.captureBelow(windowNumber: self.overlay.windowNumber, screen: layout.screen, completion: finish)
                } else {
                    // Everything below the Dock. The cover is above the Dock, so it is not in the image.
                    self.snapshotter.captureBelowDock(screen: layout.screen, completion: finish)
                }
            }
        }
    }

    private func waitForDock(_ token: Int, deadline: CFTimeInterval, then: @escaping () -> Void) {
        guard isTouring(token) else { return }
        if dockHasLanded {
            then()
        } else if CACurrentMediaTime() > deadline {
            // The Dock did not follow. Stop here and show where it really is.
            log.error("visit: the Dock did not reach index \(self.baseIndex)")
            finishTour()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                self?.waitForDock(token, deadline: deadline, then: then)
            }
        }
    }

    private func finishTour() {
        tourRoute.removeAll()
        tourToken += 1
        guard let layout, overlay.isVisible else {
            reset()
            return
        }
        // Show the space the Dock is on, also when the visit stopped early.
        if let live = Spaces.layout(for: layout.screen), live.spaceIDs == layout.spaceIDs {
            setBase(live.currentIndex)
        } else {
            setBase(baseIndex)
        }
        log.notice("visit end: on index \(self.baseIndex), \(self.cacheOrder.count) spaces captured")
        // The cover stays as it is, a picture of the desktop the visit started on.
        didSwitch = true
        stabilityStarted = false
        liveReady = false
        phase = .holding
        phaseStart = CACurrentMediaTime()
        startDockWatcher()
        startLink()
    }

    // MARK: - Reset

    private func reset() {
        if overlay.isVisible, phase != .revealing {
            log.notice("reset with the overlay visible in phase \(String(describing: self.phase), privacy: .public)")
        }
        stopLink()
        stopWatchdog()
        dockWatcher.stop()
        let switched = didSwitch && overlay.isVisible
        if overlay.isVisible {
            if phase != .touring {
                log.notice("transition: \(self.stats.summary(end: CACurrentMediaTime()), privacy: .public)")
            }
            overlay.hide()
        }
        stabilityToken += 1
        stabilityStarted = false
        liveReady = false
        lastSample = nil
        refreshToken += 1
        if switched, Config.refreshAfterSwitch, isEnabled {
            refreshCurrentSpace(refreshToken)
        }
        packFarImages(refreshToken)
        phase = .idle
        layout = nil
        progress = 0
        velocity = 0
        catchUp = nil
        didSwitch = false
        pendingRelease = nil
        keyPending = false
        dockPostTime = 0
        dockLanded = true
        captureFinished = false
        captureFailed = false
        tourRoute.removeAll()
        tourToken += 1
        // Only the end of a visit of all spaces uses this. A swipe must not wait for that desktop.
        tourOriginSample = nil
        showMenuBarIcon?()
        // Fingers that came down while this transition ended can start the next swipe at any moment.
        // Its snapshot starts now, not only when they move.
        if holdsForFingers, Config.captureOnTouchDown, isEnabled, !isInstant {
            prepare()
        }
    }

    /// Captures the space we just arrived on, now that the overlay is gone and the desktop is at rest.
    /// A new swipe cancels it, because a swipe takes its own capture.
    private func refreshCurrentSpace(_ token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, token == self.refreshToken, self.phase == .idle, !self.overlay.isVisible,
                  let layout = self.currentLayout()
            else { return }
            let spaceID = layout.spaceIDs[layout.currentIndex]
            self.snapshotter.capture(screen: layout.screen, includeDock: AppSettings.shared.dockMovesWithSpace) { [weak self] snapshot in
                guard let self, let snapshot, token == self.refreshToken, !self.overlay.isVisible,
                      // The image is of this space only if the space did not change during the capture.
                      let after = Spaces.layout(for: layout.screen),
                      after.spaceIDs.indices.contains(after.currentIndex),
                      after.spaceIDs[after.currentIndex] == spaceID
                else { return }
                self.store(snapshot, for: spaceID)
                log.info("refreshed the image of space \(spaceID)")
            }
        }
    }

    /// Stops everything now, for example when the app is disabled in the middle of a swipe.
    private func abort() {
        instantSwipeActive = false
        instantPump?.invalidate()
        instantPump = nil
        captureToken += 1
        fingersDownSince = nil
        recognizer.reset()
        reset()
    }

    // The overlay covers the whole screen, so a drag must never stay open if the trackpad stops reporting.
    private func startWatchdog() {
        stopWatchdog()
        var staleChecks = 0
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.phase == .dragging, self.pendingRelease == nil else { return }
            guard CACurrentMediaTime() - self.lastFrameTime > 1.0 else {
                staleChecks = 0
                return
            }
            // Two checks in a row. If the main thread was busy, touch frames wait in its queue, and this
            // timer can run before them: one more turn lets them arrive, so a busy moment does not end the drag.
            staleChecks += 1
            if staleChecks >= 2 {
                log.notice("the trackpad stopped reporting during a drag, ending it")
                self.recognizer.reset()
                self.end(velocity: 0, cancelled: false)
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }
}

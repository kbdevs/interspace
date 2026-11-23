import AppKit
import ScreenCaptureKit

/// A full-screen image of one space.
struct Snapshot {
    /// The screen as it looks, window shadows included.
    let image: CGImage
    /// The area around the camera with the island removed. It goes on top of `image`.
    var patch: CGImage?
    /// Where `patch` goes, in points from the top left of the screen.
    var patchFrame = CGRect.zero
    /// False when the image stops below the Dock: it has no Dock, no menu bar and no island.
    /// The overlay must then be below the Dock too, so the real ones show on top of it.
    var includesDock = true
    /// The notification banners that were on screen, which are not in `image`. For the transition that
    /// starts now only: an image that is kept for later does not keep them. See `NotificationImage`.
    var notifications: NotificationImage?
}

/// Notification banners, alerts or the Notification Center panel, cut out of the screen as it looked.
///
/// They stay where they are when the space changes, so they must not be in the image of a space: an image
/// kept for later would show a banner that is long gone. The overlay is above them, so it draws them above
/// the moving screens itself, and they do not go away during the transition.
struct NotificationImage {
    /// With transparency, and only what the banners add to the screen: their shadows have no desktop in them.
    let image: CGImage
    /// Where the image goes, in points from the top left of the screen.
    let frame: CGRect
}

/// A snapshot that uses less memory: the same pixels, compressed with no loss. Use from any thread.
///
/// A full-screen image is about 34 MB on a 3600 x 2364 display. The app keeps one for each space, and it
/// draws only the spaces near the current one. The others wait in this form.
struct PackedSnapshot {
    private let data: NSData
    private let width: Int
    private let height: Int
    private let bitsPerComponent: Int
    private let bitsPerPixel: Int
    private let bytesPerRow: Int
    private let colorSpace: CGColorSpace
    private let bitmapInfo: CGBitmapInfo
    private let shouldInterpolate: Bool
    private let intent: CGColorRenderingIntent
    private let patch: CGImage?
    private let patchFrame: CGRect
    let includesDock: Bool

    /// Bytes in memory, and bytes of the image this was made from.
    var byteCount: Int { data.length }
    var fullByteCount: Int { bytesPerRow * height }

    /// Nil when the pixels cannot be read, or when the result is not much smaller.
    init?(_ snapshot: Snapshot) {
        let image = snapshot.image
        guard let colorSpace = image.colorSpace,
              let pixels = image.dataProvider?.data as NSData?,
              pixels.length >= image.bytesPerRow * image.height,
              let compressed = try? pixels.compressed(using: .lz4),
              compressed.length * 4 < pixels.length * 3
        else { return nil }
        data = compressed
        width = image.width
        height = image.height
        bitsPerComponent = image.bitsPerComponent
        bitsPerPixel = image.bitsPerPixel
        bytesPerRow = image.bytesPerRow
        self.colorSpace = colorSpace
        bitmapInfo = image.bitmapInfo
        shouldInterpolate = image.shouldInterpolate
        intent = image.renderingIntent
        patch = snapshot.patch
        patchFrame = snapshot.patchFrame
        includesDock = snapshot.includesDock
    }

    /// The snapshot this was made from, with the same pixels. About 15 ms for a full-screen image.
    func unpacked() -> Snapshot? {
        guard let pixels = try? data.decompressed(using: .lz4),
              pixels.length >= bytesPerRow * height,
              let provider = CGDataProvider(data: pixels),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                  bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                  decode: nil, shouldInterpolate: shouldInterpolate, intent: intent
              )
        else { return nil }
        return Snapshot(image: image, patch: patch, patchFrame: patchFrame, includesDock: includesDock)
    }

    /// True when both are the same stored data, not only equal data.
    func isSame(as other: PackedSnapshot) -> Bool {
        data === other.data
    }
}

/// Captures displays with ScreenCaptureKit. Use from the main thread.
///
/// Two captures run at the same time, because no single one gives the right image:
/// - a capture of the screen rectangle has window shadows, but also the island around the camera;
/// - a capture with a window filter can leave the island out, but has no window shadows.
/// The first is the image. A small piece of the second covers the island.
///
/// When Notification Center shows something, the image is made from a list of windows instead, without
/// its window: see `captureWithoutNotifications`.
final class Snapshotter {
    /// The system process that draws the island, in a full-screen window above the menu bar.
    /// The island does not move with a space, so it must not be in the image of one.
    private static let islandOwnerBundleID = "com.apple.MenuBarAgent"
    private static let menuBarWindowLayer = 24
    /// The system process that draws notification banners, alerts and the Notification Center panel, in a
    /// window that covers the screen, above the Dock and below the menu bar (layer 21 on macOS 27). Its
    /// widgets on the desktop, if any, are below the windows. See `NotificationImage`.
    private static let notificationCenterBundleID = "com.apple.notificationcenterui"

    private var displays: [CGDirectDisplayID: SCDisplay] = [:]
    /// System processes, by bundle identifier. See `processID(of:)`.
    private var processes: [String: NSRunningApplication] = [:]
    private var islandWindows: [SCWindow] = []
    /// Windows of this app that are on screen (the overlay).
    private var ownWindows: [SCWindow] = []
    private var waiters: [CGDirectDisplayID: [(Snapshot?) -> Void]] = [:]
    /// The capture that runs for each display. A result with a different number is from a capture that
    /// was given up, and it is ignored.
    private var running: [CGDirectDisplayID: Int] = [:]
    /// When the capture that runs for each display started.
    private var runningSince: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var lastCaptureNumber = 0
    /// A capture takes much less than 0.1 s. The capture service can stop answering, and then the
    /// callers must not wait with no end.
    private static let captureTimeout: Double = 2
    /// A capture that runs longer than this is not shared with a new caller, who would wait on it with the
    /// gesture in progress: a new capture starts, and every caller gets its result. Measured: 30 to 140 ms.
    private static let staleCapture: Double = 0.3

    /// Loads the display and window lists. It is slow, so do it before the first swipe.
    func refreshDisplays(_ completion: (() -> Void)? = nil) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                if let self, let content {
                    self.displays = content.displays.reduce(into: [:]) { $0[$1.displayID] = $1 }
                    self.islandWindows = content.windows.filter {
                        $0.owningApplication?.bundleIdentifier == Self.islandOwnerBundleID
                            && $0.windowLayer > Self.menuBarWindowLayer
                    }
                    let pid = ProcessInfo.processInfo.processIdentifier
                    self.ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
                }
                completion?()
            }
        }
    }

    /// Captures one display. Calls made while a capture of the same display runs share its result.
    ///
    /// With `includeDock` false the image has only what is below the Dock. If that is not possible,
    /// the result is the full screen: look at `includesDock` of the snapshot.
    func capture(screen: NSScreen, includeDock: Bool = true, completion: @escaping (Snapshot?) -> Void) {
        let displayID = screen.displayID
        if waiters[displayID] != nil {
            waiters[displayID]?.append(completion)
            guard CACurrentMediaTime() - (runningSince[displayID] ?? 0) > Self.staleCapture else { return }
            // The capture that runs is late. Its result, if it comes, is ignored: see `finish`.
        } else {
            waiters[displayID] = [completion]
        }
        lastCaptureNumber += 1
        let number = lastCaptureNumber
        running[displayID] = number
        runningSince[displayID] = CACurrentMediaTime()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeout) { [weak self] in
            guard let self, self.running[displayID] == number else { return }
            // The display and window lists can be the cause, so the next capture loads them again.
            self.displays[displayID] = nil
            self.finish(displayID, nil, number)
        }

        if includeDock {
            captureScreen(screen, number)
        } else {
            captureBelowDock(screen: screen) { [weak self] snapshot in
                guard let self, self.running[displayID] == number else { return }
                if let snapshot {
                    self.finish(displayID, snapshot, number)
                } else {
                    self.captureScreen(screen, number)
                }
            }
        }
    }

    /// The full screen, as it looks.
    private func captureScreen(_ screen: NSScreen, _ number: Int) {
        let displayID = screen.displayID
        let scale = screen.backingScaleFactor
        let islandFrame = Self.islandFrame(on: screen)
        if let display = displays[displayID] {
            run(display: display, scale: scale, islandFrame: islandFrame, number: number)
        } else {
            refreshDisplays { [weak self] in
                guard let self else { return }
                if let display = self.displays[displayID] {
                    self.run(display: display, scale: scale, islandFrame: islandFrame, number: number)
                } else {
                    self.finish(displayID, nil, number)
                }
            }
        }
    }

    private func run(display: SCDisplay, scale: CGFloat, islandFrame: CGRect?, number: Int) {
        let displayID = display.displayID
        let group = DispatchGroup()
        var screenImage: CGImage?
        var filteredImage: CGImage?

        // At the same time as the captures below. Most of the time it only reads the window list. When it
        // finds a banner, its image is the one: the others have the banner in them, and are not waited for.
        if let notificationCenter = processID(of: Self.notificationCenterBundleID) {
            let bounds = CGDisplayBounds(displayID)
            let islandOwner = processID(of: Self.islandOwnerBundleID)
            group.enter()
            Self.captureQueue.async { [weak self] in
                let result = Self.captureWithoutNotifications(bounds: bounds, notificationCenter: notificationCenter, islandOwner: islandOwner)
                DispatchQueue.main.async {
                    if let result {
                        var snapshot = Snapshot(image: result.image)
                        snapshot.notifications = result.notifications
                        self?.finish(displayID, snapshot, number)
                    }
                    group.leave()
                }
            }
        }

        var needsFiltered = true
        if #available(macOS 15.2, *) {
            needsFiltered = islandFrame != nil && !islandWindows.isEmpty
            group.enter()
            SCScreenshotManager.captureImage(in: display.frame) { image, _ in
                DispatchQueue.main.async {
                    screenImage = image
                    group.leave()
                }
            }
        }

        if needsFiltered {
            let filter = SCContentFilter(display: display, excludingWindows: islandWindows)
            let configuration = filteredConfiguration(for: display, scale: scale)
            group.enter()
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                DispatchQueue.main.async {
                    filteredImage = image
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            // Done already, without a notification banner.
            guard let self, self.running[displayID] == number else { return }
            guard let image = screenImage ?? filteredImage else {
                // The display and window lists can be stale after a display change.
                self.displays[displayID] = nil
                self.finish(displayID, nil, number)
                return
            }
            var snapshot = Snapshot(image: image)
            if screenImage != nil, let filteredImage, let islandFrame {
                Self.addPatch(to: &snapshot, from: filteredImage, islandFrame: islandFrame, scale: scale)
            }
            self.finish(displayID, snapshot, number)
        }
    }

    private func filteredConfiguration(for display: SCDisplay, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((CGFloat(display.width) * scale).rounded())
        configuration.height = Int((CGFloat(display.height) * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // Wide gamut, so the snapshot matches the live desktop on a P3 panel.
        configuration.colorSpaceName = CGColorSpace.displayP3
        return configuration
    }

    private static func addPatch(to snapshot: inout Snapshot, from filtered: CGImage, islandFrame: CGRect, scale: CGFloat) {
        let pixels = CGRect(
            x: islandFrame.minX * scale, y: islandFrame.minY * scale,
            width: islandFrame.width * scale, height: islandFrame.height * scale
        ).integral
        guard let crop = filtered.cropping(to: pixels) else { return }
        // A cropped image keeps the whole image it was cut from in memory: one more full screen for each
        // snapshot. The copy has only its own pixels.
        snapshot.patch = Self.copy(of: crop) ?? crop
        snapshot.patchFrame = CGRect(
            x: pixels.minX / scale, y: pixels.minY / scale,
            width: pixels.width / scale, height: pixels.height / scale
        )
    }

    /// The same pixels in memory of their own.
    private static func copy(of image: CGImage) -> CGImage? {
        guard let colorSpace = image.colorSpace, colorSpace.model == .rgb, image.bitsPerComponent == 8,
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: - Capture below the overlay

    private typealias WindowListImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage`. It is not in the current SDK, but it is the one capture that can take
    /// "everything below this window" with window shadows.
    private static let windowListImage: WindowListImageFn? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(pointer, to: WindowListImageFn.self)
    }()

    // MARK: - Capture below the Dock

    private static let captureQueue = DispatchQueue(label: "com.cnrad.interspace.capture", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private static let dockBundleID = "com.apple.dock"
    private static let dockWindowLayer = Int(CGWindowLevelForKey(.dockWindow))

    /// Everything below the Dock window, window shadows included. The menu bar and the island are above
    /// the Dock, so they are not in the image either. Nil when the Dock has no window on screen.
    func captureBelowDock(screen: NSScreen, completion: @escaping (Snapshot?) -> Void) {
        let bounds = CGDisplayBounds(screen.displayID)
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first?.processIdentifier
        Self.captureQueue.async {
            let onScreenBelowWindow: UInt32 = 1 << 2
            var snapshot: Snapshot?
            if let dockPID, let window = Self.dockWindow(ownedBy: dockPID, on: bounds),
               let image = Self.windowListImage?(bounds, onScreenBelowWindow, window, 0)?.takeRetainedValue() {
                snapshot = Snapshot(image: image, includesDock: false)
            }
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    /// The window the Dock draws itself in. The order of windows is the same on all displays, so a Dock
    /// window on a different display is also a correct limit for this one.
    private static func dockWindow(ownedBy pid: pid_t, on bounds: CGRect) -> UInt32? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var onDisplay: UInt32?
        var anywhere: UInt32?
        // The list goes from front to back. The last match is the lowest, so no Dock window is below it.
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == dockWindowLayer,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            anywhere = number
            if let frame = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
               frame.intersects(bounds) {
                onDisplay = number
            }
        }
        return onDisplay ?? anywhere
    }

    private static let sampleQueue = DispatchQueue(label: "com.cnrad.interspace.sample", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private static let sampleWidth = 96
    private static let sampleHeight = 60

    /// A very small grey copy of the screen below one of our windows, to tell if the screen still changes.
    /// It runs off the main thread, so the gesture stays responsive. A notification banner is not in it:
    /// one that slides in is not a change of the desktop, and must not keep the overlay up.
    func sampleBelow(windowNumber: Int, screen: NSScreen, completion: @escaping ([UInt8]?) -> Void) {
        let bounds = CGDisplayBounds(screen.displayID)
        let notificationCenter = processID(of: Self.notificationCenterBundleID)
        Self.sampleQueue.async {
            var sample: [UInt8]?
            if windowNumber > 0,
               let image = Self.imageBelow(window: CGWindowID(windowNumber), bounds: bounds, options: Self.nominalResolution,
                                           notificationCenter: notificationCenter) {
                var pixels = [UInt8](repeating: 0, count: Self.sampleWidth * Self.sampleHeight)
                let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                    guard let context = CGContext(
                        data: buffer.baseAddress, width: Self.sampleWidth, height: Self.sampleHeight,
                        bitsPerComponent: 8, bytesPerRow: Self.sampleWidth, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue
                    ) else { return false }
                    context.interpolationQuality = .medium
                    context.draw(image, in: CGRect(x: 0, y: 0, width: Self.sampleWidth, height: Self.sampleHeight))
                    return true
                }
                if drawn {
                    sample = pixels
                }
            }
            DispatchQueue.main.async {
                completion(sample)
            }
        }
    }

    /// True when two samples show the same screen. A text cursor that blinks does not count as a change.
    ///
    /// `sameDesktop` asks a different question: are the two samples of the same desktop, with some time
    /// between them? Small changes (a clock, text that is being written) are then allowed. Two different
    /// desktops differ in most of the picture, so this test is safe to make much less strict.
    static func samplesMatch(_ a: [UInt8], _ b: [UInt8], sameDesktop: Bool = false) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var total = 0
        var changed = 0
        for index in a.indices {
            let difference = abs(Int(a[index]) - Int(b[index]))
            total += difference
            if difference > 16 { changed += 1 }
        }
        if sameDesktop {
            return Double(total) / Double(a.count) < 6 && changed * 12 < a.count
        }
        return Double(total) / Double(a.count) < 0.6 && changed * 400 < a.count
    }

    /// Captures a screen as it is below one of our windows, while that window covers it, without
    /// notification banners. Call `refreshDisplays` after the window is on screen and before this, so the
    /// window is known. `includesDock` says if that window is above the Dock. If it is not, the image has
    /// no island to cover.
    func captureBelow(windowNumber: Int, screen: NSScreen, includesDock: Bool = true, completion: @escaping (Snapshot?) -> Void) {
        let displayID = screen.displayID
        let scale = screen.backingScaleFactor
        guard windowNumber > 0,
              let image = Self.imageBelow(window: CGWindowID(windowNumber), bounds: CGDisplayBounds(displayID), options: 0,
                                          notificationCenter: processID(of: Self.notificationCenterBundleID))
        else {
            completion(nil)
            return
        }

        var snapshot = Snapshot(image: image, includesDock: includesDock)
        guard includesDock, let islandFrame = Self.islandFrame(on: screen), !islandWindows.isEmpty, !ownWindows.isEmpty,
              let display = displays[displayID]
        else {
            completion(snapshot)
            return
        }

        let filter = SCContentFilter(display: display, excludingWindows: islandWindows + ownWindows)
        let configuration = filteredConfiguration(for: display, scale: scale)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { filtered, _ in
            DispatchQueue.main.async {
                if let filtered {
                    Self.addPatch(to: &snapshot, from: filtered, islandFrame: islandFrame, scale: scale)
                }
                completion(snapshot)
            }
        }
    }

    private func finish(_ displayID: CGDirectDisplayID, _ snapshot: Snapshot?, _ number: Int) {
        guard running[displayID] == number else { return }
        running[displayID] = nil
        runningSince[displayID] = nil
        let callbacks = waiters.removeValue(forKey: displayID) ?? []
        for callback in callbacks {
            callback(snapshot)
        }
    }

    // MARK: - Without notification banners

    /// The process with a bundle identifier, looked up again only when it has quit.
    private func processID(of bundleID: String) -> pid_t? {
        if let known = processes[bundleID], !known.isTerminated {
            return known.processIdentifier
        }
        let found = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        processes[bundleID] = found
        return found?.processIdentifier
    }

    private typealias WindowArrayImageFn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImageFromArray`, also not in the current SDK: the windows given, composited as on
    /// screen, window shadows included. It is how a window can be left out of an image of the screen.
    private static let windowArrayImage: WindowArrayImageFn? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        return unsafeBitCast(pointer, to: WindowArrayImageFn.self)
    }()

    /// One pixel for each point.
    private static let nominalResolution: UInt32 = 1 << 4

    /// A window on screen, from the window list.
    private struct ListedWindow {
        let number: CGWindowID
        let owner: pid_t
        let layer: Int
        let frame: CGRect
    }

    /// The windows on screen, front to back: all of them, or those below `window`.
    private static func windowsOnScreen(below window: CGWindowID? = nil) -> [ListedWindow] {
        let list: CFArray?
        if let window {
            list = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow], window)
        } else {
            list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        }
        return (list as? [[String: Any]] ?? []).compactMap { window in
            guard let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { return nil }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let frame = (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            return ListedWindow(number: number, owner: owner, layer: layer, frame: frame ?? .null)
        }
    }

    /// A window of Notification Center that is above the desktop: banners, alerts, its panel.
    private static func isNotification(_ window: ListedWindow, notificationCenter: pid_t?) -> Bool {
        window.owner == notificationCenter && window.layer > 0
    }

    /// The windows given, from front to back, in the part of the screen given.
    private static func image(of windows: [ListedWindow], bounds: CGRect, options: UInt32 = 0) -> CGImage? {
        guard let windowArrayImage, !windows.isEmpty else { return nil }
        // The call takes the window numbers themselves, not CFNumbers.
        var values = windows.map { UnsafeRawPointer(bitPattern: UInt($0.number)) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil) else { return nil }
        return windowArrayImage(bounds, array, options)?.takeRetainedValue()
    }

    /// Everything on screen below one of our windows, without notification banners. Calls the window server.
    private static func imageBelow(window: CGWindowID, bounds: CGRect, options: UInt32, notificationCenter: pid_t?) -> CGImage? {
        if notificationCenter != nil {
            let below = windowsOnScreen(below: window)
            if below.contains(where: { isNotification($0, notificationCenter: notificationCenter) }) {
                return image(of: below.filter { !isNotification($0, notificationCenter: notificationCenter) }, bounds: bounds, options: options)
            }
        }
        let onScreenBelowWindow: UInt32 = 1 << 2
        return windowListImage?(bounds, onScreenBelowWindow, window, options)?.takeRetainedValue()
    }

    /// What `captureWithoutNotifications` makes.
    private struct CleanCapture {
        let image: CGImage
        let notifications: NotificationImage?
    }

    /// When Notification Center shows something on the display: the screen without it, and what it shows,
    /// cut out of the screen as it looks. Nil when it shows nothing there, and when a capture fails: the
    /// screen capture is then used. The island is left out too, as the patch does for the screen capture.
    /// Calls the window server, so not on the main thread: about 70 ms with a banner, under 1 ms without.
    private static func captureWithoutNotifications(bounds: CGRect, notificationCenter: pid_t, islandOwner: pid_t?) -> CleanCapture? {
        let windows = windowsOnScreen().filter {
            $0.frame.intersects(bounds) && !($0.owner == islandOwner && $0.layer > menuBarWindowLayer)
        }
        let notifications = windows.filter { isNotification($0, notificationCenter: notificationCenter) }
        guard !notifications.isEmpty,
              let clean = image(of: windows.filter { !isNotification($0, notificationCenter: notificationCenter) }, bounds: bounds)
        else { return nil }
        return CleanCapture(image: clean, notifications: cutOut(notifications, from: windows, clean: clean, bounds: bounds))
    }

    /// What the windows of Notification Center add to the screen. Three captures: those windows alone,
    /// before and after, tell where they show something and how much of what is below still shows; the
    /// screen as it looks, in between, gives the pixels. Nil when the windows show nothing, or when that
    /// moved between the captures: a banner that slides in or out would be cut at the wrong place, and is
    /// better left out until the transition is over.
    private static func cutOut(_ notifications: [ListedWindow], from windows: [ListedWindow], clean: CGImage, bounds: CGRect) -> NotificationImage? {
        guard let before = image(of: notifications, bounds: bounds, options: nominalResolution),
              let box = visibleBox(of: before),
              let shown = image(of: windows, bounds: bounds),
              let after = image(of: notifications, bounds: bounds, options: nominalResolution),
              visibleBox(of: after) == box,
              shown.width == clean.width, shown.height == clean.height,
              before.width > 0, bounds.width > 0
        else { return nil }
        // `box` is in the pixels of the nominal image, about one per point. The other images have the pixels
        // of the display.
        let points = CGFloat(before.width) / bounds.width
        let scale = CGFloat(shown.width) / bounds.width
        let frame = CGRect(x: box.minX / points, y: box.minY / points, width: box.width / points, height: box.height / points)
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: shown.width, height: shown.height))
        guard !pixels.isEmpty,
              let image = separate(shown: shown, clean: clean, coverage: before, coverageBox: box, pixels: pixels)
        else { return nil }
        return NotificationImage(
            image: image,
            frame: CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
        )
    }

    /// The smallest box around the pixels that are not fully transparent, in pixels from the top left.
    private static func visibleBox(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              // Only the alpha of each pixel. The colour space is not used.
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
              ),
              let data = context.data
        else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let alpha = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        // The first row in memory is the top of the image.
        for y in 0..<height {
            let row = alpha + y * width
            for x in 0..<width where row[x] != 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The banners alone, in `pixels` of the screen. On screen a pixel is the banner plus the part of the
    /// desktop that still shows through it: `shown = banner + clean × (1 − coverage)`. So the banner is
    /// `shown − clean × (1 − coverage)`, with `coverage` as its alpha. Its shadow then darkens whatever
    /// screen is below it, with nothing of this desktop in it.
    private static func separate(shown: CGImage, clean: CGImage, coverage: CGImage, coverageBox: CGRect, pixels: CGRect) -> CGImage? {
        let width = Int(pixels.width)
        let height = Int(pixels.height)
        let colorSpace = shown.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.displayP3)
        func bitmap() -> CGContext? {
            guard let colorSpace else { return nil }
            return CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        guard let shownPart = shown.cropping(to: pixels), let cleanPart = clean.cropping(to: pixels),
              let coveragePart = coverage.cropping(to: coverageBox),
              let result = bitmap(), let below = bitmap(), let cover = bitmap(),
              let out = result.data?.assumingMemoryBound(to: UInt8.self),
              let under = below.data?.assumingMemoryBound(to: UInt8.self),
              let alpha = cover.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        for context in [result, below, cover] {
            context.setBlendMode(.copy)
        }
        result.interpolationQuality = .none
        result.draw(shownPart, in: rect)
        below.interpolationQuality = .none
        below.draw(cleanPart, in: rect)
        // From points to pixels.
        cover.interpolationQuality = .high
        cover.draw(coveragePart, in: rect)

        // Premultiplied, so no colour value can be above the alpha.
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let a = Int(alpha[index + 3])
            let through = 255 - a
            for channel in 0..<3 {
                let value = Int(out[index + channel]) - (Int(under[index + channel]) * through + 127) / 255
                out[index + channel] = UInt8(min(max(value, 0), a))
            }
            out[index + 3] = UInt8(a)
        }
        return result.makeImage()
    }

    /// The area that can hold the island, in points from the top left of the screen. Nil when the screen has no camera housing.
    private static func islandFrame(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }
        let minX = left.maxX - screen.frame.minX
        let maxX = right.minX - screen.frame.minX
        let width = maxX - minX
        guard width > 0 else { return nil }
        // One housing width more on each side, in case the island is wider than the housing.
        return CGRect(x: minX - width, y: 0, width: width * 3, height: screen.safeAreaInsets.top)
            .intersection(CGRect(origin: .zero, size: screen.frame.size))
    }

    /// What a desktop picture is made from. Read on the main thread, used on any thread.
    private struct WallpaperRequest {
        let url: URL
        let width: Int
        let height: Int
    }

    private static let wallpaperQueue = DispatchQueue(label: "com.cnrad.interspace.wallpaper", qos: .userInitiated, autoreleaseFrequency: .workItem)

    private static func wallpaperRequest(for screen: NSScreen) -> WallpaperRequest? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let scale = screen.backingScaleFactor
        let width = Int((screen.frame.width * scale).rounded())
        let height = Int((screen.frame.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        return WallpaperRequest(url: url, width: width, height: height)
    }

    /// The desktop picture, for a space we have not seen yet.
    ///
    /// It takes more than 0.1 s for a large picture, so this is only for when the picture was not made
    /// ahead of time: see the version with a completion.
    func wallpaper(for screen: NSScreen) -> Snapshot? {
        Self.wallpaperRequest(for: screen).flatMap(Self.renderWallpaper)
    }

    /// The same picture, made off the main thread. `completion` is called on the main thread.
    func wallpaper(for screen: NSScreen, completion: @escaping (Snapshot?) -> Void) {
        guard let request = Self.wallpaperRequest(for: screen) else {
            completion(nil)
            return
        }
        Self.wallpaperQueue.async {
            let snapshot = Self.renderWallpaper(request)
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    private static func renderWallpaper(_ request: WallpaperRequest) -> Snapshot? {
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = request.width
        let height = request.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let bitmap = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        // Aspect fill.
        let fill = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * fill, height: CGFloat(image.height) * fill)
        let rect = CGRect(
            x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
            width: size.width, height: size.height
        )
        bitmap.interpolationQuality = .high
        bitmap.draw(image, in: rect)
        return bitmap.makeImage().map { Snapshot(image: $0) }
    }
}

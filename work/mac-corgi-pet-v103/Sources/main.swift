import AppKit

private enum RemoteUpdate {
    static let manifestURL = URL(string: "https://github.com/moxian1993/xiaoxiao-pet/releases/latest/download/update.json")!
}

private struct UpdateManifest: Decodable {
    let schemaVersion: Int
    let version: String
    let build: Int
    let releaseNotes: String?
    let releases: [UpdateRelease]?
    let platforms: [String: UpdatePackage]

    func notes(after build: Int) -> [String] {
        let collected = (releases ?? [])
            .filter { $0.build > build && $0.build <= self.build }
            .sorted { $0.build < $1.build }
            .flatMap(\.notes)
        if !collected.isEmpty { return collected }

        guard let releaseNotes else { return [] }
        let note = releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? [] : [note]
    }
}

private struct UpdateRelease: Decodable {
    let build: Int
    let notes: [String]
}

private struct UpdatePackage: Decodable {
    let archive: String
    let sha256: String
    let url: String?
}

private enum SpriteLayout {
    static let cellWidth: CGFloat = 192
    static let cellHeight: CGFloat = 208
    static let columns = 8
}

// This is the only place that needs to follow the physical row order in spritesheet.png.
// Add, remove, or reorder cases here; animation playback uses semantic names instead of row numbers.
private enum SpriteRow: Int {
    case runningRight
    case dance
    case jump
    case boredom
    case sleepEntrySecond
    case sleepIdle
    case petting
    case gazeFirstHalf
    case gazeSecondHalf
    case companionEntry
    case companionIdle
    case companionExit
    case lifting
    case puttingDown
}

private enum IdleAction: String {
    case companion
    case sleep
    case gaze
    case automatic
}

private enum StrollMode {
    case running
    case jumping
}

private enum PetAction {
    case companion
    case sleep
    case gaze
    case dance
    case boredom
    case petting
    case running
    case jumping
}

private final class SpriteAnimator: NSObject {
    private let atlas: NSImage
    private weak var imageView: NSImageView?
    private var cache: [Int: NSImage] = [:]
    private var visibleBoundsCache: [Int: NSRect] = [:]
    private var timer: Timer?
    private var row: SpriteRow = .companionExit
    private var frames: [Int] = [0]
    private var framePosition = 0
    private var completedLoops = 0
    private var requestedLoops: Int?
    private var completion: (() -> Void)?
    private var facesLeft = false
    private(set) var currentVisibleBounds: NSRect?

    init(atlas: NSImage, imageView: NSImageView) {
        self.atlas = atlas
        self.imageView = imageView
        super.init()
    }

    deinit {
        timer?.invalidate()
    }

    func play(
        row: SpriteRow,
        frames: [Int],
        interval: TimeInterval,
        loops: Int? = nil,
        completion: (() -> Void)? = nil
    ) {
        timer?.invalidate()
        self.row = row
        self.frames = frames
        framePosition = 0
        completedLoops = 0
        requestedLoops = loops
        self.completion = completion
        showCurrentFrame()

        guard frames.count > 1 else { return }
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(advanceFrame), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setFacingLeft(_ facesLeft: Bool) {
        guard self.facesLeft != facesLeft else { return }
        self.facesLeft = facesLeft
        showCurrentFrame()
    }

    func pointInWindow(forSpritePoint spritePoint: NSPoint) -> NSPoint? {
        guard let imageView else { return nil }
        let sourceSize = NSSize(width: SpriteLayout.cellWidth, height: SpriteLayout.cellHeight)
        let scale = min(imageView.bounds.width / sourceSize.width, imageView.bounds.height / sourceSize.height)
        let drawnOrigin = NSPoint(
            x: (imageView.bounds.width - sourceSize.width * scale) / 2,
            y: (imageView.bounds.height - sourceSize.height * scale) / 2
        )
        let pointInImageView = NSPoint(
            x: drawnOrigin.x + spritePoint.x * scale,
            y: drawnOrigin.y + spritePoint.y * scale
        )
        return imageView.convert(pointInImageView, to: nil)
    }

    @objc private func advanceFrame() {
        framePosition += 1
        if framePosition >= frames.count {
            framePosition = 0
            completedLoops += 1
            if let requestedLoops, completedLoops >= requestedLoops {
                timer?.invalidate()
                timer = nil
                let finished = completion
                completion = nil
                finished?()
                return
            }
        }
        showCurrentFrame()
    }

    private func showCurrentFrame() {
        guard frames.indices.contains(framePosition) else { return }
        let column = frames[framePosition]
        let key = frameCacheKey(row: row, column: column)
        imageView?.image = imageForFrame(row: row, column: column)
        currentVisibleBounds = visibleBoundsCache[key]
    }

    private func imageForFrame(row: SpriteRow, column: Int) -> NSImage? {
        let rowIndex = row.rawValue
        let key = frameCacheKey(row: row, column: column)
        if let cached = cache[key] { return cached }

        let sourceY = atlas.size.height - CGFloat(rowIndex + 1) * SpriteLayout.cellHeight
        let sourceRect = NSRect(
            x: CGFloat(column) * SpriteLayout.cellWidth,
            y: sourceY,
            width: SpriteLayout.cellWidth,
            height: SpriteLayout.cellHeight
        )
        guard sourceRect.minX >= 0, sourceRect.minY >= 0,
              sourceRect.maxX <= atlas.size.width, sourceRect.maxY <= atlas.size.height else {
            return nil
        }

        let frame = NSImage(size: NSSize(width: SpriteLayout.cellWidth, height: SpriteLayout.cellHeight))
        frame.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        if facesLeft {
            let transform = NSAffineTransform()
            transform.translateX(by: SpriteLayout.cellWidth, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
        }
        atlas.draw(
            in: NSRect(x: 0, y: 0, width: SpriteLayout.cellWidth, height: SpriteLayout.cellHeight),
            from: sourceRect,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        frame.unlockFocus()
        cache[key] = frame
        visibleBoundsCache[key] = alphaBounds(for: frame)
        return frame
    }

    private func frameCacheKey(row: SpriteRow, column: Int) -> Int {
        row.rawValue * SpriteLayout.columns + column + (facesLeft ? 1000 : 0)
    }

    private func alphaBounds(for image: NSImage) -> NSRect? {
        let width = Int(SpriteLayout.cellWidth)
        let height = Int(SpriteLayout.cellHeight)
        var proposedRect = NSRect(x: 0, y: 0, width: width, height: height)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { rawBuffer -> NSRect? in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return nil
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var minimumX = width
            var maximumX = -1
            var minimumY = height
            var maximumY = -1
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 12 {
                    minimumX = min(minimumX, x)
                    maximumX = max(maximumX, x)
                    minimumY = min(minimumY, y)
                    maximumY = max(maximumY, y)
                }
            }
            guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
            return NSRect(
                x: minimumX,
                y: height - maximumY - 1,
                width: maximumX - minimumX + 1,
                height: maximumY - minimumY + 1
            )
        }
    }
}

private final class PetView: NSView {
    weak var spriteImageView: NSImageView?
    var visibleSpriteBoundsProvider: (() -> NSRect?)?
    var menuProvider: (() -> NSMenu)?
    var onPositionChanged: ((NSPoint) -> Void)?
    var onInteraction: (() -> Void)?
    var onDragStarted: ((Bool, NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDragDirectionChanged: ((Bool) -> Void)?
    var onClicked: (() -> Void)?

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var lastDragMouseX: CGFloat = 0
    private var isDraggingPet = false
    private var dragStartedInTopArea = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onInteraction?()
        dragStartMouse = NSEvent.mouseLocation
        lastDragMouseX = dragStartMouse.x
        dragStartOrigin = window.frame.origin
        isDraggingPet = false
        let localPoint = convert(event.locationInWindow, from: nil)
        dragStartedInTopArea = isPointInVisibleSpriteTop(localPoint)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        if !isDraggingPet {
            isDraggingPet = true
            onDragStarted?(dragStartedInTopArea, current)
            dragStartOrigin = window.frame.origin
            if dragStartedInTopArea {
                dragStartMouse = current
                lastDragMouseX = current.x
            }
        }
        let horizontalDelta = current.x - lastDragMouseX
        if abs(horizontalDelta) >= 0.5 {
            onDragDirectionChanged?(horizontalDelta < 0)
        }
        lastDragMouseX = current.x
        let origin = NSPoint(
            x: dragStartOrigin.x + current.x - dragStartMouse.x,
            y: dragStartOrigin.y + current.y - dragStartMouse.y
        )
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        if let origin = window?.frame.origin {
            onPositionChanged?(origin)
        }
        if isDraggingPet {
            isDraggingPet = false
            onDragEnded?()
        } else {
            onClicked?()
        }
        onInteraction?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    private func isPointInVisibleSpriteTop(_ point: NSPoint) -> Bool {
        guard let imageView = spriteImageView,
              let sourceBounds = visibleSpriteBoundsProvider?() else {
            return point.y >= bounds.height * 0.65
        }

        let sourceSize = NSSize(width: SpriteLayout.cellWidth, height: SpriteLayout.cellHeight)
        let scale = min(imageView.bounds.width / sourceSize.width, imageView.bounds.height / sourceSize.height)
        let drawnSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawnOrigin = NSPoint(
            x: (imageView.bounds.width - drawnSize.width) / 2,
            y: (imageView.bounds.height - drawnSize.height) / 2
        )
        let visibleBounds = NSRect(
            x: drawnOrigin.x + sourceBounds.minX * scale,
            y: drawnOrigin.y + sourceBounds.minY * scale,
            width: sourceBounds.width * scale,
            height: sourceBounds.height * scale
        )
        let pointInImageView = imageView.convert(point, from: self)
        let topThreshold = visibleBounds.minY + visibleBounds.height * 0.65
        return visibleBounds.contains(pointInImageView) && pointInImageView.y >= topThreshold
    }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class UpdateDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Int64, Int64) -> Void
    private var receivedData = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?

    init(progressHandler: @escaping @Sendable (Int64, Int64) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(from url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        progressHandler(0, response.expectedContentLength)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        progressHandler(Int64(receivedData.count), response?.expectedContentLength ?? -1)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            continuation = nil
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (receivedData, response))
        } else {
            continuation?.resume(throwing: NSError(
                domain: "com.local.corgi-xiaoxiao.update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "下载更新包失败，请稍后重试。"]
            ))
        }
    }
}

@MainActor
private final class UpdateProgressPanel {
    private let panel: NSPanel
    private let statusLabel: NSTextField
    private let progressIndicator: NSProgressIndicator

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 112),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "正在更新"
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 112))
        statusLabel = NSTextField(labelWithString: "正在下载更新…")
        statusLabel.frame = NSRect(x: 24, y: 66, width: 272, height: 20)

        progressIndicator = NSProgressIndicator(frame: NSRect(x: 24, y: 34, width: 272, height: 18))
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0

        contentView.addSubview(statusLabel)
        contentView.addSubview(progressIndicator)
        panel.contentView = contentView
    }

    func show() {
        panel.center()
        panel.orderFrontRegardless()
    }

    func update(received: Int64, total: Int64) {
        guard total > 0 else {
            statusLabel.stringValue = "正在下载更新…"
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            return
        }
        if progressIndicator.isIndeterminate {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
        }
        let progress = min(max(Double(received) / Double(total), 0), 1)
        progressIndicator.doubleValue = progress
        statusLabel.stringValue = "正在下载更新… \(Int((progress * 100).rounded()))%"
    }

    func showPreparingInstallation() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 1
        statusLabel.stringValue = "正在准备安装…"
    }

    func close() {
        panel.orderOut(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let baseWindowSize = NSSize(width: 230, height: 250)
    private let inactivityInterval: TimeInterval = 30
    private var panel: PetPanel!
    private var animator: SpriteAnimator!
    private var alwaysOnTop = true
    private var petScale = min(max(UserDefaults.standard.double(forKey: "PetScaleV2"), 0.4), 0.8)
    private var idleAction = IdleAction(rawValue: UserDefaults.standard.string(forKey: "IdleAction") ?? "") ?? .companion
    private var appliedIdleAction = IdleAction(rawValue: UserDefaults.standard.string(forKey: "IdleAction") ?? "") ?? .companion
    private var automaticIdleIntervalMinutes: Int = {
        let saved = UserDefaults.standard.integer(forKey: "AutomaticIdleIntervalMinutes")
        return saved > 0 ? min(max(saved, 1), 60) : 20
    }()
    private var inactivityTimer: Timer?
    private var idleSelectionTimer: Timer?
    private var automaticIdleTimer: Timer?
    private var automaticIdleIndex = 0
    private var isSleeping = false
    private var isCompanionActive = false
    private var isGazeActive = false
    private var companionMicroTimer: Timer?
    private var gazeUpdateTimer: Timer?
    private var gazeFrameIndex: Int?
    private var walkingTimer: Timer?
    private var walkingEndTimer: Timer?
    private var walkingVelocity = NSPoint(x: 28, y: 0)
    private var walkingTarget = NSPoint.zero
    private var nextWalkingTurn: TimeInterval = 0
    private var walkingSaveTicks = 0
    private var strollMode: StrollMode = .running
    private var temporaryActionScale: CGFloat = 1
    private var isDragActionActive = false
    private var currentAction: PetAction = .companion
    private var actionBeforeDrag: PetAction?
    private var isPreparingUpdate = false

    private var windowSize: NSSize {
        NSSize(
            width: baseWindowSize.width * petScale * temporaryActionScale,
            height: baseWindowSize.height * petScale * temporaryActionScale
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.object(forKey: "PetScaleV2") == nil {
            petScale = 0.6
        }

        guard let atlasURL = Bundle.main.url(forResource: "spritesheet", withExtension: "png"),
              let atlas = NSImage(contentsOf: atlasURL) else {
            showFatalError("无法读取桌宠精灵图。")
            return
        }

        let contentRect = NSRect(origin: restoredOrigin(), size: windowSize)
        panel = PetPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false

        let petView = PetView(frame: NSRect(origin: .zero, size: windowSize))
        petView.wantsLayer = true
        petView.layer?.backgroundColor = NSColor.clear.cgColor
        petView.menuProvider = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        petView.onPositionChanged = { origin in
            UserDefaults.standard.set(Double(origin.x), forKey: "PetWindowX")
            UserDefaults.standard.set(Double(origin.y), forKey: "PetWindowY")
        }
        petView.onInteraction = { [weak self] in self?.notePointerActivity() }
        petView.onDragStarted = { [weak self] shouldLift, mouseLocation in
            self?.handleDragStarted(shouldLift: shouldLift, mouseLocation: mouseLocation)
        }
        petView.onDragEnded = { [weak self] in self?.handleDragEnded() }
        petView.onDragDirectionChanged = { [weak self] facesLeft in
            guard let self, !self.isSleeping, !self.isCompanionActive, !self.isGazeActive,
                  !self.isDragActionActive else { return }
            self.animator.setFacingLeft(facesLeft)
        }
        petView.onClicked = { [weak self] in self?.handlePetClick() }

        let imageView = NSImageView(frame: petView.bounds.insetBy(dx: 4, dy: 4))
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        imageView.isEnabled = true
        petView.spriteImageView = imageView
        petView.addSubview(imageView)
        panel.contentView = petView

        animator = SpriteAnimator(atlas: atlas, imageView: imageView)
        petView.visibleSpriteBoundsProvider = { [weak self] in
            self?.animator.currentVisibleBounds
        }
        panel.orderFrontRegardless()
        startCompanion()
        applySavedIdleActionAfterLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "柯基小小")
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "柯基小小", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("陪伴", #selector(playCompanion)))
        menu.addItem(item("睡觉", #selector(playSleep)))
        menu.addItem(item("注视", #selector(playGaze)))
        menu.addItem(item("散步", #selector(playWalk)))
        menu.addItem(item("扭屁股", #selector(playDance)))
        menu.addItem(item("无聊", #selector(playBoredom)))
        menu.addItem(optimizationMenuItem())
        menu.addItem(.separator())
        menu.addItem(scaleMenuItem())
        menu.addItem(idleActionMenuItem())
        menu.addItem(.separator())

        let topItem = item("始终置顶", #selector(toggleAlwaysOnTop(_:)))
        topItem.state = alwaysOnTop ? .on : .off
        menu.addItem(topItem)
        menu.addItem(.separator())
        menu.addItem(item("更新", #selector(checkRemoteUpdate)))
        menu.addItem(.separator())
        menu.addItem(item("退出柯基小小", #selector(quitApp)))
        return menu
    }

    private func optimizationMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "待优化", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "待优化")
        submenu.addItem(item("摸摸", #selector(playPetting)))
        parent.submenu = submenu
        return parent
    }

    private func scaleMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 48))
        let label = NSTextField(labelWithString: "大小")
        label.frame = NSRect(x: 16, y: 16, width: 68, height: 18)

        let slider = NSSlider(value: Double(petScale), minValue: 0.4, maxValue: 0.8, target: self, action: #selector(scaleChanged(_:)))
        slider.frame = NSRect(x: 88, y: 10, width: 144, height: 28)
        slider.isContinuous = true
        slider.toolTip = "拖动调整柯基大小"

        container.addSubview(label)
        container.addSubview(slider)
        menuItem.view = container
        return menuItem
    }

    private func idleActionMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "静置动作", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "静置动作")

        let companionItem = item("陪伴", #selector(selectCompanionIdle(_:)))
        companionItem.state = idleAction == .companion ? .on : .off
        submenu.addItem(companionItem)

        let sleepItem = item("睡觉", #selector(selectSleepIdle(_:)))
        sleepItem.state = idleAction == .sleep ? .on : .off
        submenu.addItem(sleepItem)

        let gazeItem = item("注视", #selector(selectGazeIdle(_:)))
        gazeItem.state = idleAction == .gaze ? .on : .off
        submenu.addItem(gazeItem)

        let automaticItem = item("自动轮替", #selector(selectAutomaticIdle(_:)))
        automaticItem.state = idleAction == .automatic ? .on : .off
        submenu.addItem(automaticItem)
        submenu.addItem(.separator())
        submenu.addItem(automaticIntervalMenuItem())

        parent.submenu = submenu
        return parent
    }

    private func automaticIntervalMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 52))
        let label = NSTextField(labelWithString: "轮替时间：\(automaticIdleIntervalMinutes)分钟")
        label.frame = NSRect(x: 14, y: 29, width: 242, height: 18)
        label.tag = 9101

        let slider = NSSlider(
            value: Double(automaticIdleIntervalMinutes),
            minValue: 1,
            maxValue: 60,
            target: self,
            action: #selector(automaticIntervalChanged(_:))
        )
        slider.frame = NSRect(x: 14, y: 3, width: 242, height: 25)
        slider.isContinuous = true
        slider.numberOfTickMarks = 13
        slider.allowsTickMarkValuesOnly = false
        slider.toolTip = "拖动设置自动轮替时间"

        container.addSubview(label)
        container.addSubview(slider)
        menuItem.view = container
        return menuItem
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func playDance() {
        registerInteraction()
        currentAction = .dance
        setTemporaryActionScale(1.3)
        animator.setFacingLeft(false)
        animator.play(row: .dance, frames: Array(0..<8), interval: 0.125, loops: 2) { [weak self] in
            guard let self else { return }
            self.animator.setFacingLeft(true)
            self.animator.play(row: .dance, frames: Array(0..<8), interval: 0.125, loops: 2) { [weak self] in
                guard let self else { return }
                self.animator.setFacingLeft(false)
                self.animator.play(row: .dance, frames: Array(0..<8), interval: 0.125, loops: 2) { [weak self] in
                    guard let self else { return }
                    self.animator.setFacingLeft(true)
                    self.animator.play(row: .dance, frames: Array(0..<8), interval: 0.125, loops: 2) { [weak self] in
                        guard let self else { return }
                        self.animator.setFacingLeft(false)
                        self.setTemporaryActionScale(1)
                        self.finishInteraction()
                    }
                }
            }
        }
    }

    @objc private func playBoredom() {
        registerInteraction()
        currentAction = .boredom
        let framesBeforePause = [3, 4, 0, 1, 2, 5, 6]
        let framesAfterPause = [7, 6, 5, 2, 1, 0, 4, 3]
        let interval = 0.13 / 0.8
        animator.setFacingLeft(false)
        animator.play(row: .boredom, frames: framesBeforePause, interval: interval, loops: 1) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.animator.play(row: .boredom, frames: framesAfterPause, interval: interval, loops: 1) { [weak self] in
                    self?.finishInteraction()
                }
            }
        }
    }

    @objc private func playPetting() {
        registerInteraction()
        currentAction = .petting
        animator.play(row: .petting, frames: Array(0..<6), interval: 0.2, loops: 2) { [weak self] in
            self?.finishInteraction()
        }
    }

    @objc private func playGaze() {
        startGazeTracking()
        if appliedIdleAction == .automatic {
            scheduleAutomaticIdleRotation()
        }
    }

    private func startGazeTracking() {
        guard !isGazeActive else { return }
        stopWalking(savePosition: false)
        stopGazeTracking()
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        deactivateCompanion()
        isSleeping = false
        isGazeActive = true
        currentAction = .gaze
        animator.setFacingLeft(false)
        gazeFrameIndex = nil
        updateGazeFrame()

        let updateTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateGazeFrame()
        }
        RunLoop.main.add(updateTimer, forMode: .common)
        gazeUpdateTimer = updateTimer
    }

    private func updateGazeFrame() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let deltaX = mouse.x - panel.frame.midX
        let deltaY = mouse.y - panel.frame.midY
        var degrees = atan2(deltaX, deltaY) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let frameIndex = Int((degrees / 22.5).rounded()) % 16
        guard gazeFrameIndex != frameIndex else { return }
        gazeFrameIndex = frameIndex
        if frameIndex < 8 {
            animator.play(row: .gazeFirstHalf, frames: [frameIndex], interval: 1.0)
        } else {
            animator.play(row: .gazeSecondHalf, frames: [frameIndex - 8], interval: 1.0)
        }
    }

    private func stopGazeTracking() {
        gazeUpdateTimer?.invalidate()
        gazeUpdateTimer = nil
        gazeFrameIndex = nil
        isGazeActive = false
    }

    private func handlePetClick() {
        if isSleeping {
            startCompanion()
            if appliedIdleAction == .automatic {
                automaticIdleIndex = 0
                scheduleAutomaticIdleRotation()
            }
            return
        }

        if isCompanionActive || isGazeActive {
            playRandomInteraction()
        }
    }

    private func playRandomInteraction() {
        switch Int.random(in: 0..<3) {
        case 0: playDance()
        case 1: playPetting()
        default: playWalk()
        }
    }

    private func handleDragStarted(shouldLift: Bool, mouseLocation: NSPoint) {
        guard shouldLift else { return }
        actionBeforeDrag = currentAction
        registerInteraction()
        setTemporaryActionScale(1.5)
        isDragActionActive = true
        animator.setFacingLeft(false)
        animator.play(row: .lifting, frames: Array(0..<8), interval: 0.09, loops: 1) { [weak self] in
            guard let self, self.isDragActionActive else { return }
            self.animator.play(row: .lifting, frames: Array(4..<8), interval: 0.16)
        }
        alignLiftTopCenter(to: mouseLocation)
    }

    private func alignLiftTopCenter(to mouseLocation: NSPoint) {
        guard let panel else { return }
        let liftingHotspot = NSPoint(x: SpriteLayout.cellWidth / 2, y: SpriteLayout.cellHeight - 2)
        let anchor = animator.pointInWindow(forSpritePoint: liftingHotspot)
            ?? NSPoint(x: panel.frame.width / 2, y: panel.frame.height)
        panel.setFrameOrigin(NSPoint(
            x: mouseLocation.x - anchor.x,
            y: mouseLocation.y - anchor.y
        ))
    }

    private func handleDragEnded() {
        guard isDragActionActive else { return }
        isDragActionActive = false
        animator.setFacingLeft(false)
        animator.play(row: .puttingDown, frames: Array(0..<8), interval: 0.09, loops: 1) { [weak self] in
            guard let self else { return }
            self.setTemporaryActionScale(1)
            self.restoreActionBeforeDrag()
        }
    }

    private func restoreActionBeforeDrag() {
        guard let action = actionBeforeDrag else {
            applyCurrentIdleActionNow()
            return
        }
        actionBeforeDrag = nil
        switch action {
        case .companion:
            startCompanion()
            if appliedIdleAction == .automatic { scheduleAutomaticIdleRotation() }
        case .sleep:
            startSleeping()
            if appliedIdleAction == .automatic { scheduleAutomaticIdleRotation() }
        case .gaze:
            startGazeTracking()
            if appliedIdleAction == .automatic { scheduleAutomaticIdleRotation() }
        case .dance:
            playDance()
        case .boredom:
            playBoredom()
        case .petting:
            playPetting()
        case .running:
            startWalking(mode: .running)
        case .jumping:
            startWalking(mode: .jumping)
        }
    }

    @objc private func playCompanion() {
        guard !isCompanionActive else { return }
        startCompanion()
        if appliedIdleAction == .automatic {
            scheduleAutomaticIdleRotation()
        }
    }

    private func startCompanion() {
        guard !isCompanionActive else {
            scheduleSleepTransitionIfNeeded()
            return
        }
        stopWalking(savePosition: false)
        stopGazeTracking()
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        companionMicroTimer?.invalidate()
        companionMicroTimer = nil
        isSleeping = false
        isCompanionActive = true
        currentAction = .companion
        scheduleSleepTransitionIfNeeded()
        animator.play(
            row: .companionEntry,
            frames: Array(0..<6),
            interval: 0.16,
            loops: 1
        ) { [weak self] in
            self?.startCompanionIdle()
        }
    }

    private func startCompanionIdle() {
        guard isCompanionActive else { return }
        showCompanionIdleFrame()
        scheduleCompanionMicroAction()
    }

    private func showCompanionIdleFrame() {
        guard isCompanionActive else { return }
        animator.play(row: .companionIdle, frames: [0], interval: 1.0)
    }

    private func scheduleCompanionMicroAction() {
        companionMicroTimer?.invalidate()
        guard isCompanionActive else { return }
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.playCompanionMicroAction()
        }
        RunLoop.main.add(timer, forMode: .common)
        companionMicroTimer = timer
    }

    private func playCompanionMicroAction() {
        guard isCompanionActive else { return }
        scheduleCompanionMicroAction()
        let row: SpriteRow
        let frames: [Int]
        let interval: TimeInterval
        switch Int.random(in: 0..<5) {
        case 0:
            row = .companionIdle
            frames = [0, 1, 2]
            interval = 0.14
        case 1:
            row = .companionIdle
            frames = [2, 3, 4]
            interval = 0.14
        case 2:
            row = .companionIdle
            frames = [4, 5, 4]
            interval = 0.14
        case 3:
            row = .companionIdle
            frames = [4, 6, 4]
            interval = 0.14
        default:
            row = .companionIdle
            frames = [0, 7, 0]
            interval = 0.14
        }
        animator.play(
            row: row,
            frames: frames,
            interval: interval,
            loops: 1
        ) { [weak self] in
            self?.showCompanionIdleFrame()
        }
    }

    private func deactivateCompanion() {
        isCompanionActive = false
        companionMicroTimer?.invalidate()
        companionMicroTimer = nil
    }

    @objc private func playSleep() {
        guard !isSleeping else { return }
        startSleeping()
        if appliedIdleAction == .automatic {
            scheduleAutomaticIdleRotation()
        }
    }

    private func startSleeping() {
        guard !isSleeping else { return }
        stopWalking(savePosition: false)
        stopGazeTracking()
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        deactivateCompanion()
        isSleeping = true
        currentAction = .sleep
        animator.play(row: .sleepEntrySecond, frames: Array(0..<8), interval: 0.14, loops: 1) { [weak self] in
            self?.animator.play(row: .sleepIdle, frames: [0, 1], interval: 0.14, loops: 1) { [weak self] in
                self?.animator.play(row: .sleepIdle, frames: [1, 2, 3, 4], interval: 0.52)
            }
        }
    }

    @objc private func playWalk() {
        registerInteraction()
        startWalking()
    }

    private func startRunning(loops: Int?) {
        animator.play(row: .runningRight, frames: Array(0..<8), interval: 0.11, loops: loops) { [weak self] in
            self?.finishInteraction()
        }
    }

    private func startWalking(mode: StrollMode? = nil) {
        stopWalking(savePosition: false)
        strollMode = mode ?? (Bool.random() ? .running : .jumping)
        currentAction = strollMode == .running ? .running : .jumping
        let speed: CGFloat = strollMode == .running ? 28 : 52
        walkingVelocity = NSPoint(x: Bool.random() ? speed : -speed, y: 0)
        walkingSaveTicks = 0
        setTemporaryActionScale(strollMode == .running ? 1.3 : 1)
        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            chooseWalkingTarget(in: visible)
        }
        animator.setFacingLeft(walkingVelocity.x < 0)
        if strollMode == .running {
            startRunning(loops: nil)
        } else {
            animator.play(row: .jump, frames: Array(0..<5), interval: 0.14)
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.advanceWalking()
        }
        RunLoop.main.add(timer, forMode: .common)
        walkingTimer = timer

        let endTimer = Timer(timeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.stopWalking()
            self.finishInteraction()
        }
        RunLoop.main.add(endTimer, forMode: .common)
        walkingEndTimer = endTimer
    }

    private func advanceWalking() {
        guard let panel, let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        var origin = panel.frame.origin
        let minimumX = visible.minX
        let maximumX = max(minimumX, visible.maxX - panel.frame.width)
        let minimumY = visible.minY
        let maximumY = max(minimumY, visible.maxY - panel.frame.height)
        let now = Date.timeIntervalSinceReferenceDate
        let distanceToTarget = hypot(walkingTarget.x - origin.x, walkingTarget.y - origin.y)

        if now >= nextWalkingTurn || distanceToTarget < 36 {
            chooseWalkingTarget(in: visible)
        }

        let targetDX = walkingTarget.x - origin.x
        let targetDY = walkingTarget.y - origin.y
        let targetDistance = max(hypot(targetDX, targetDY), 1)
        let speed: CGFloat = strollMode == .running ? 28 : 52
        let desiredX = targetDX / targetDistance * speed
        let desiredY = targetDY / targetDistance * speed
        let steering: CGFloat = 0.14
        walkingVelocity.x += (desiredX - walkingVelocity.x) * steering
        walkingVelocity.y += (desiredY - walkingVelocity.y) * steering

        let currentSpeed = max(hypot(walkingVelocity.x, walkingVelocity.y), 1)
        walkingVelocity.x = walkingVelocity.x / currentSpeed * speed
        walkingVelocity.y = walkingVelocity.y / currentSpeed * speed
        origin.x += walkingVelocity.x / 30.0
        origin.y += walkingVelocity.y / 30.0

        let clampedX = min(max(origin.x, minimumX), maximumX)
        let clampedY = min(max(origin.y, minimumY), maximumY)
        if clampedX != origin.x || clampedY != origin.y {
            origin.x = clampedX
            origin.y = clampedY
            chooseWalkingTarget(in: visible)
        }

        if abs(walkingVelocity.x) > 1 {
            animator.setFacingLeft(walkingVelocity.x < 0)
        }
        panel.setFrameOrigin(origin)
        walkingSaveTicks += 1
        if walkingSaveTicks >= 30 {
            walkingSaveTicks = 0
            savePosition(origin)
        }
    }

    private func chooseWalkingTarget(in visible: NSRect) {
        let maximumX = max(visible.minX, visible.maxX - panel.frame.width)
        let maximumY = max(visible.minY, visible.maxY - panel.frame.height)
        let origin = panel.frame.origin
        let currentAngle = atan2(walkingVelocity.y, walkingVelocity.x)
        let turnMagnitude = CGFloat.random(in: (.pi / 3)...(.pi * 5 / 6))
        let turnDirection: CGFloat = Bool.random() ? 1 : -1
        let newAngle = currentAngle + turnMagnitude * turnDirection
        let minimumDistance: CGFloat = strollMode == .running ? 100 : 180
        let distanceLimit: CGFloat = strollMode == .running ? 360 : 560
        let maximumDistance = max(minimumDistance, min(distanceLimit, min(visible.width, visible.height) * 0.75))
        let distance = CGFloat.random(in: minimumDistance...maximumDistance)
        let candidateX = origin.x + cos(newAngle) * distance
        let candidateY = origin.y + sin(newAngle) * distance
        walkingTarget = NSPoint(
            x: min(max(candidateX, visible.minX), maximumX),
            y: min(max(candidateY, visible.minY), maximumY)
        )
        nextWalkingTurn = Date.timeIntervalSinceReferenceDate + Double.random(
            in: strollMode == .running ? 0.8...3.0 : 1.5...4.0
        )
    }

    private func stopWalking(savePosition shouldSave: Bool = true) {
        let wasWalking = walkingTimer != nil || walkingEndTimer != nil
        walkingTimer?.invalidate()
        walkingTimer = nil
        walkingEndTimer?.invalidate()
        walkingEndTimer = nil
        setTemporaryActionScale(1)
        if wasWalking, shouldSave, let origin = panel?.frame.origin {
            savePosition(origin)
        }
    }

    private func setTemporaryActionScale(_ scale: CGFloat) {
        guard temporaryActionScale != scale, let panel else { return }
        let oldFrame = panel.frame
        temporaryActionScale = scale
        let newSize = windowSize
        var origin = NSPoint(x: oldFrame.midX - newSize.width / 2, y: oldFrame.minY)
        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - newSize.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - newSize.height)
        }
        panel.setFrame(NSRect(origin: origin, size: newSize), display: true)
    }

    @objc private func scaleChanged(_ sender: NSSlider) {
        registerSettingsInteraction()
        petScale = CGFloat(sender.doubleValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "PetScaleV2")

        let oldFrame = panel.frame
        let newSize = windowSize
        var origin = NSPoint(x: oldFrame.midX - newSize.width / 2, y: oldFrame.minY)
        if let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - newSize.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - newSize.height)
        }
        panel.setFrame(NSRect(origin: origin, size: newSize), display: true)
        savePosition(origin)
    }

    @objc private func selectCompanionIdle(_ sender: NSMenuItem) {
        selectIdleAction(.companion)
    }

    @objc private func selectSleepIdle(_ sender: NSMenuItem) {
        selectIdleAction(.sleep)
    }

    @objc private func selectGazeIdle(_ sender: NSMenuItem) {
        selectIdleAction(.gaze)
    }

    @objc private func selectAutomaticIdle(_ sender: NSMenuItem) {
        selectIdleAction(.automatic)
    }

    @objc private func automaticIntervalChanged(_ sender: NSSlider) {
        let minutes = min(max(Int(sender.doubleValue.rounded()), 1), 60)
        sender.doubleValue = Double(minutes)
        automaticIdleIntervalMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "AutomaticIdleIntervalMinutes")
        if let label = sender.superview?.viewWithTag(9101) as? NSTextField {
            label.stringValue = "轮替时间：\(minutes)分钟"
        }
        if appliedIdleAction == .automatic {
            scheduleAutomaticIdleRotation()
        }
    }

    private func selectIdleAction(_ action: IdleAction) {
        idleAction = action
        UserDefaults.standard.set(action.rawValue, forKey: "IdleAction")
        idleSelectionTimer?.invalidate()
        idleSelectionTimer = nil
        automaticIdleTimer?.invalidate()
        automaticIdleTimer = nil
        inactivityTimer?.invalidate()
        inactivityTimer = nil

        if isCurrentIdleAction(action) {
            appliedIdleAction = action
            if action == .automatic {
                scheduleAutomaticIdleRotation()
            }
            return
        }

        let timer = Timer(timeInterval: inactivityInterval, repeats: false) { [weak self] _ in
            guard let self, self.idleAction == action else { return }
            self.appliedIdleAction = action
            if self.isDragActionActive || self.walkingTimer != nil {
                return
            }
            self.applyIdleAction(action)
        }
        RunLoop.main.add(timer, forMode: .common)
        idleSelectionTimer = timer
    }

    private func isCurrentIdleAction(_ action: IdleAction) -> Bool {
        switch action {
        case .companion:
            return isCompanionActive
        case .sleep:
            return isSleeping
        case .gaze:
            return isGazeActive
        case .automatic:
            return appliedIdleAction == .automatic && (isCompanionActive || isSleeping || isGazeActive)
        }
    }

    private func applyIdleAction(_ action: IdleAction) {
        switch action {
        case .companion:
            startCompanion()
        case .sleep:
            startSleeping()
        case .gaze:
            startGazeTracking()
        case .automatic:
            automaticIdleIndex = 0
            startCompanion()
            scheduleAutomaticIdleRotation()
        }
    }

    private func applyCurrentIdleActionNow() {
        applyIdleAction(appliedIdleAction)
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        registerSettingsInteraction()
        alwaysOnTop.toggle()
        panel.level = alwaysOnTop ? .floating : .normal
        sender.state = alwaysOnTop ? .on : .off
    }

    @objc private func quitApp() {
        stopWalking()
        stopGazeTracking()
        inactivityTimer?.invalidate()
        idleSelectionTimer?.invalidate()
        automaticIdleTimer?.invalidate()
        companionMicroTimer?.invalidate()
        NSApp.terminate(nil)
    }

    @objc private func checkRemoteUpdate() {
        guard !isPreparingUpdate else { return }
        isPreparingUpdate = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPreparingUpdate = false }

            do {
                try await self.prepareRemoteUpdate()
            } catch {
                self.showUpdateMessage(title: "无法更新", message: error.localizedDescription, style: .critical)
            }
        }
    }

    @MainActor
    private func prepareRemoteUpdate() async throws {
        let (manifestData, manifestResponse) = try await URLSession.shared.data(from: RemoteUpdate.manifestURL)
        try validateRemoteResponse(manifestResponse, action: "获取更新信息")

        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else {
            throw updateError("不支持此更新清单格式。")
        }
        guard let package = manifest.platforms["macos"] else {
            throw updateError("更新清单中没有 macOS 安装包。")
        }

        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let currentBuildNumber = Int(currentBuild) ?? 0
        guard manifest.build > currentBuildNumber else {
            showUpdateMessage(
                title: "已经是最新版本",
                message: "当前已是最新版本。"
            )
            return
        }

        guard package.archive == URL(fileURLWithPath: package.archive).lastPathComponent,
              !package.archive.contains("/"), !package.archive.contains(":") else {
            throw updateError("更新包文件名不安全。")
        }
        guard let remoteArchiveAddress = package.url,
              let remoteArchiveURL = URL(string: remoteArchiveAddress, relativeTo: RemoteUpdate.manifestURL)?.absoluteURL,
              remoteArchiveURL.scheme?.lowercased() == "https" else {
            throw updateError("更新清单中的下载地址无效。")
        }

        let updateNotes = manifest.notes(after: currentBuildNumber)
        let alert = NSAlert()
        alert.messageText = "可以更新"
        if manifest.build == currentBuildNumber + 1, !updateNotes.isEmpty {
            let content = updateNotes.enumerated()
                .map { "\($0.offset + 1)、\($0.element)" }
                .joined(separator: "\n")
            alert.informativeText = "更新内容：\n\(content)\n\n下载完成后会自动安装。"
        } else {
            alert.informativeText = "检测到可用更新。\n\n下载完成后会自动安装。"
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let progressPanel = UpdateProgressPanel()
        progressPanel.show()
        defer { progressPanel.close() }

        let downloader = UpdateDownloader { received, total in
            Task { @MainActor in
                progressPanel.update(received: received, total: total)
            }
        }
        let (downloadData, downloadResponse) = try await downloader.download(from: remoteArchiveURL)
        try validateRemoteResponse(downloadResponse, action: "下载更新包")

        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorgiPetUpdate-\(UUID().uuidString).zip", isDirectory: false)
        try downloadData.write(to: downloadURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        let actualHash = try sha256(of: downloadURL)
        guard actualHash.caseInsensitiveCompare(package.sha256) == .orderedSame else {
            throw updateError("更新包校验失败，文件可能不完整。")
        }

        let updateDirectory = try updateDirectory()
        let archiveURL = updateDirectory.appendingPathComponent(package.archive, isDirectory: false)
        let stagingURL = updateDirectory.appendingPathComponent(".\(UUID().uuidString).download", isDirectory: false)
        try FileManager.default.copyItem(at: downloadURL, to: stagingURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: archiveURL)

        progressPanel.showPreparingInstallation()
        let successMessage: String
        if updateNotes.isEmpty {
            successMessage = "更新已完成。"
        } else {
            let content = updateNotes.map { "• \($0)" }.joined(separator: "\n")
            successMessage = "更新内容：\n\(content)"
        }

        try launchUpdateInstaller(
            archiveURL: archiveURL,
            expectedHash: actualHash,
            targetBuild: manifest.build,
            updateDirectory: updateDirectory,
            successMessage: successMessage
        )
        quitApp()
    }

    private func validateRemoteResponse(_ response: URLResponse, action: String) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw updateError("\(action)失败，请稍后重试。")
        }
    }

    private func updateDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("柯基小小", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sha256(of fileURL: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", fileURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let hash = text.split(whereSeparator: { $0.isWhitespace }).first,
              hash.count == 64 else {
            throw updateError("无法校验更新包。")
        }
        return String(hash)
    }

    private func launchUpdateInstaller(
        archiveURL: URL,
        expectedHash: String,
        targetBuild: Int,
        updateDirectory: URL,
        successMessage: String
    ) throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let helperSource = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
            throw updateError("应用内缺少更新助手。")
        }

        let targetURL = Bundle.main.bundleURL.standardizedFileURL
        let targetParent = targetURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: targetParent.path) else {
            throw updateError("当前应用所在目录不可写。请先把“柯基小小.app”移动到“应用程序”或其他可写目录后再更新。")
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorgiPetUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let helperURL = workDirectory.appendingPathComponent("install-update.sh", isDirectory: false)
        try FileManager.default.copyItem(at: helperSource, to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let supportDirectory = updateDirectory.deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            helperURL.path,
            archiveURL.path,
            expectedHash,
            targetURL.path,
            bundleIdentifier,
            String(targetBuild),
            supportDirectory.path,
            workDirectory.path,
            String(ProcessInfo.processInfo.processIdentifier),
            successMessage
        ]
        try process.run()
    }

    private func updateError(_ message: String) -> NSError {
        NSError(domain: "com.local.corgi-xiaoxiao.update", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func showUpdateMessage(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private func registerInteraction() {
        stopWalking(savePosition: false)
        stopGazeTracking()
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        automaticIdleTimer?.invalidate()
        automaticIdleTimer = nil
        deactivateCompanion()
        isSleeping = false
    }

    private func notePointerActivity() {
    }

    private func registerSettingsInteraction() {
    }

    private func scheduleSleepTransitionIfNeeded() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        guard isCompanionActive, appliedIdleAction == .sleep else { return }
        let timer = Timer(timeInterval: inactivityInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.isCompanionActive, self.appliedIdleAction == .sleep else { return }
            self.startSleeping()
        }
        RunLoop.main.add(timer, forMode: .common)
        inactivityTimer = timer
    }

    private func applySavedIdleActionAfterLaunch() {
        switch appliedIdleAction {
        case .companion:
            break
        case .sleep:
            scheduleSleepTransitionIfNeeded()
        case .gaze:
            startGazeTracking()
        case .automatic:
            automaticIdleIndex = 0
            scheduleAutomaticIdleRotation()
        }
    }

    private func finishInteraction() {
        switch appliedIdleAction {
        case .companion, .sleep:
            startCompanion()
        case .gaze:
            startGazeTracking()
        case .automatic:
            automaticIdleIndex = 0
            startCompanion()
            scheduleAutomaticIdleRotation()
        }
    }

    private func scheduleAutomaticIdleRotation() {
        automaticIdleTimer?.invalidate()
        automaticIdleTimer = nil
        guard appliedIdleAction == .automatic else { return }
        let interval = TimeInterval(automaticIdleIntervalMinutes * 60)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.advanceAutomaticIdleAction()
        }
        RunLoop.main.add(timer, forMode: .common)
        automaticIdleTimer = timer
    }

    private func advanceAutomaticIdleAction() {
        guard appliedIdleAction == .automatic else { return }
        automaticIdleIndex = (automaticIdleIndex + 1) % 3
        switch automaticIdleIndex {
        case 0:
            startCompanion()
        case 1:
            startGazeTracking()
        default:
            startSleeping()
        }
        scheduleAutomaticIdleRotation()
    }

    private func savePosition(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: "PetWindowX")
        UserDefaults.standard.set(Double(origin.y), forKey: "PetWindowY")
    }

    private func restoredOrigin() -> NSPoint {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "PetWindowX") != nil,
              defaults.object(forKey: "PetWindowY") != nil else {
            return defaultOrigin()
        }
        let saved = NSPoint(x: defaults.double(forKey: "PetWindowX"), y: defaults.double(forKey: "PetWindowY"))
        guard let screen = NSScreen.main else { return saved }
        let visible = screen.visibleFrame
        return NSPoint(
            x: min(max(saved.x, visible.minX), visible.maxX - windowSize.width),
            y: min(max(saved.y, visible.minY), visible.maxY - windowSize.height)
        )
    }

    private func defaultOrigin() -> NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return NSPoint(x: 80, y: 80) }
        return NSPoint(x: visible.maxX - windowSize.width - 28, y: visible.minY + 36)
    }

    private func showFatalError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "柯基小小启动失败"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()

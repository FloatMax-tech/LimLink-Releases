import AppKit
import Combine
import Observation

/// 把同一份快照画到 Dock 和菜单栏。菜单栏用 `NSStatusItem` 重画图标：
/// Mac 方案 3.7 把 `MenuBarExtra` 标签能不能放会变的图标标成待验证，并写了不行就改用 `NSStatusItem`。
@MainActor
final class ProgressSurfaces: ObservableObject {
    private var dock: DockTileController?
    private var menuBar: MenuBarProgressController?
    private var reducer = DockTileReducer()
    private var pending: BatchProgressSnapshot?
    private weak var model: MacTransferModel?
    private var expiryTask: Task<Void, Never>?
    private var scheduledExpiry: Date?

    deinit { expiryTask?.cancel() }

    func observe(_ model: MacTransferModel) {
        guard self.model !== model else { return }
        self.model = model
        observeProgress()
    }

    private func observeProgress() {
        guard let model else { return }
        let snapshot = withObservationTracking { model.progressSnapshot } onChange: { [weak self] in
            Task { @MainActor in self?.observeProgress() }
        }
        render(snapshot)
    }

    func attach(dock: DockTileController, menuBar: MenuBarProgressController) {
        self.dock = dock
        self.menuBar = menuBar
        if let pending {
            render(pending)
        }
    }

    func render(_ snapshot: BatchProgressSnapshot, now: Date = Date()) {
        pending = snapshot
        let visual = reducer.present(sessions: [snapshot], now: now)
        let value = DialAccessibility.value(for: snapshot)
        dock?.apply(visual, accessibilityValue: value)
        menuBar?.apply(visual, accessibilityValue: value, status: DialCaption.detail(snapshot))
        scheduleExpiry(at: reducer.nextUpdateDate)
    }

    private func scheduleExpiry(at date: Date?) {
        guard date != scheduledExpiry else { return }
        expiryTask?.cancel()
        expiryTask = nil
        scheduledExpiry = date
        guard let date else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, date.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled, let snapshot = self.pending else { return }
            self.scheduledExpiry = nil
            self.expiryTask = nil
            self.render(snapshot)
        }
    }
}

final class DockTileController {
    private let tile = DockProgressView(frame: .zero)
    private var throttle = DisplayThrottle()
    private var lastVisual: DockTileVisual?

    func apply(_ visual: DockTileVisual, accessibilityValue: String, now: Date = Date()) {
        if visual == lastVisual {
            guard throttle.shouldDisplay(visual: visual, now: now) else { return }
        } else {
            _ = throttle.shouldDisplay(visual: visual, now: now)
        }
        lastVisual = visual
        switch visual {
        case .systemIcon:
            NSApp.dockTile.contentView = nil
        case .ring, .checkmark:
            let size = NSApp.dockTile.size
            tile.frame = NSRect(origin: .zero, size: size)
            tile.visual = visual
            tile.accessibilityText = accessibilityValue
            NSApp.dockTile.contentView = tile
        }
        NSApp.dockTile.display()
    }
}

final class DockProgressView: NSView {
    var visual: DockTileVisual = .systemIcon {
        didSet { needsDisplay = true }
    }
    var accessibilityText: String = ""

    // NSAccessibility is an informal protocol. Swift imports these as methods.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityLabel() -> String? {
        "LimLink"
    }

    override func accessibilityValue() -> Any? {
        accessibilityText
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let symbolRect = bounds.insetBy(dx: bounds.width * 0.28, dy: bounds.height * 0.30)
        if let symbol = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil) {
            symbol.isTemplate = true
            symbol.draw(in: symbolRect)
        }

        let ringRect = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
        RingImage.draw(visual: visual, in: ringRect, lineWidth: max(2, bounds.width * 0.06), template: false)

        if case .checkmark = visual {
            let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            mark?.draw(in: bounds.insetBy(dx: bounds.width * 0.32, dy: bounds.height * 0.32))
        }
    }
}

/// Menu bar item: a progress ring while transferring; clicking opens a popover that can answer
/// receive requests. It stays after the main window closes.
final class MenuBarProgressController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var throttle = DisplayThrottle()
    private var lastVisual: DockTileVisual?
    /// Builds the popover content once the app's models exist.
    var makeContent: (() -> NSViewController)?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image(for: .systemIcon)
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("LimLink")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        statusItem = item
    }

    /// Shows the popover, for example when a receive request arrives while no window is open.
    func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        if popover.contentViewController == nil { popover.contentViewController = makeContent?() }
        guard popover.contentViewController != nil else { return }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func apply(_ visual: DockTileVisual, accessibilityValue: String, status: String, now: Date = Date()) {
        install()
        if visual == lastVisual {
            guard throttle.shouldDisplay(visual: visual, now: now) else { return }
        } else {
            _ = throttle.shouldDisplay(visual: visual, now: now)
        }
        lastVisual = visual
        let image = MenuBarIcon.image(for: visual)
        if case .ring(_, .paused) = visual {
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }
        statusItem?.button?.image = image
        statusItem?.button?.setAccessibilityValue(accessibilityValue)
        statusItem?.button?.toolTip = status
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }
}

enum MenuBarIcon {
    static func image(for visual: DockTileVisual) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            if case .systemIcon = visual {
                // The brand ring: outer 78, inner 54 on a 108 canvas.
                let unit = rect.width / 108
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 21 * unit, dy: 21 * unit))
                ring.appendOval(in: rect.insetBy(dx: 33 * unit, dy: 33 * unit))
                ring.windingRule = .evenOdd
                NSColor.black.setFill()
                ring.fill()
                return true
            }
            let paused: Bool
            if case .ring(_, .paused) = visual {
                paused = true
            } else {
                paused = false
            }
            RingImage.draw(visual: visual, in: rect.insetBy(dx: 1, dy: 1), lineWidth: 2, template: !paused)
            if case .checkmark = visual {
                NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                    .draw(in: rect.insetBy(dx: 4, dy: 4))
            }
            return true
        }
        return image
    }
}

enum RingImage {
    static func draw(visual: DockTileVisual, in rect: NSRect, lineWidth: CGFloat, template: Bool) {
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        guard radius > 0 else { return }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        track.lineWidth = lineWidth
        track.lineCapStyle = .round
        strokeColor(for: visual, role: .track, template: template).setStroke()
        track.stroke()

        let fraction: Double
        switch visual {
        case .systemIcon:
            return
        case .checkmark:
            fraction = 1
        case .ring(let value, _):
            fraction = value
        }
        guard fraction > 0.001 else { return }
        let arc = RingGeometry.arc(fraction: fraction)
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: arc.startAngle,
            endAngle: arc.endAngle,
            clockwise: arc.clockwise
        )
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        strokeColor(for: visual, role: .progress, template: template).setStroke()
        path.stroke()
    }

    private enum Role {
        case track
        case progress
    }

    private static func strokeColor(for visual: DockTileVisual, role: Role, template: Bool) -> NSColor {
        if template {
            return .black
        }
        switch visual {
        case .ring(_, .paused):
            return .tertiaryLabelColor
        case .systemIcon, .checkmark, .ring:
            return role == .track ? NSColor.labelColor.withAlphaComponent(0.2) : .controlAccentColor
        }
    }
}

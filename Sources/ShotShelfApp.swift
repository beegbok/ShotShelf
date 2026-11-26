import AppKit
import CoreGraphics
import SwiftUI

private final class Holder: @unchecked Sendable {
    var controller: StatusBarController?
}

private let holder = Holder()

@main
enum ShotShelfMain {
    static func main() {
        let app = NSApplication.shared
        let controller = StatusBarController()
        holder.controller = controller
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let relay = ShelfRelay()
    private let store = ScreenshotStore.shared
    private var hosting: NSHostingController<ShelfView>!
    private var closedAt: Date?
    private var dragging = false
    private var keyMonitor: Any?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if quitIfDuplicate() { return }
        store.onIconChange = { [weak self] symbol in
            self?.setSymbol(symbol)
        }
        buildStatusItem()
        buildPanel()
        store.start()
        installDismissMonitors()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openPanel() }
        }
    }

    private func quitIfDuplicate() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.shotshelf.mac"
        let me = ProcessInfo.processInfo.processIdentifier
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !duplicates.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = menuImage(ScreenshotStore.menuSymbol)
        button.imagePosition = .imageOnly
        button.toolTip = "SC Pro"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func buildPanel() {
        let view = ShelfView(store: store, relay: relay)
        hosting = NSHostingController(rootView: view)
        let size = PanelLayout.size(for: store)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = PanelPlacement.level(above: 0)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        if let hostingView = hosting.view as? NSHostingView<ShelfView> {
            hostingView.sizingOptions = []
        }
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = 16
        hosting.view.layer?.masksToBounds = true
        panel.contentView = hosting.view
        wireRelay()
    }

    private func installDismissMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.keyCode == 53 {
                self.closePanel()
                return nil
            }
            guard event.characters == " ", self.spaceShouldPreview(event) else { return event }
            guard self.store.openInPreview(nil) else { return nil }
            self.closePanel()
            return nil
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.type == .leftMouseUp || event.type == .rightMouseUp {
                if self?.panel.isVisible == true { self?.placePanel() }
                return event
            }
            self?.closeIfClickOutside()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.closeIfClickOutside()
        }
    }

    private func wireRelay() {
        relay.suspendAutoClose = { [weak self] in
            self?.dragging = true
        }
        relay.resumeAutoClose = { [weak self] closeIfOutside in
            self?.finishPointer(closeIfOutside: closeIfOutside)
        }
        relay.relayout = { [weak self] in
            self?.relayout()
        }
        relay.close = { [weak self] in
            self?.closePanel()
        }
    }

    private func spaceShouldPreview(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) {
            return false
        }
        let responder = panel.firstResponder
        if responder is NSButton || responder is NSSegmentedControl || responder is NSTextView {
            return false
        }
        return true
    }

    private func finishPointer(closeIfOutside: Bool) {
        dragging = false
        guard closeIfOutside, panel.isVisible else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) {
            closePanel()
        }
    }

    private func relayout() {
        let size = PanelLayout.size(for: store)
        let frame = PanelGeometry.resized(keepingTopOf: panel.frame, to: size)
        hosting.view.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(frame, display: true)
        guard panel.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
        placePanel()
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        let isRightClick = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if isRightClick {
            closePanel()
            showMenu()
            return
        }
        togglePopover()
    }

    private func togglePopover() {
        if panel.isVisible {
            closePanel()
            return
        }
        if let closedAt, Date().timeIntervalSince(closedAt) < 0.2 { return }
        openPanel()
    }

    private func openPanel() {
        relayout()
        placePanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.placePanel()
            self.panel.orderFrontRegardless()
        }
    }

    private func placePanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let blockers = MenuBarWindows.blockerFrames(excludingPID: ProcessInfo.processInfo.processIdentifier)
        let frame = PanelGeometry.placed(
            anchor: anchor,
            size: panel.frame.size,
            visible: visible,
            blockers: blockers
        )
        let highest = MenuBarWindows.highestLevel(excludingPID: ProcessInfo.processInfo.processIdentifier, intersecting: frame)
        panel.level = PanelPlacement.level(above: highest)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        dragging = false
        closedAt = Date()
    }

    private func closeIfClickOutside() {
        guard panel.isVisible, !dragging else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) || statusItemHit(point) { return }
        closePanel()
    }

    private func statusItemHit(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(point)
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(item("Open SC Pro", action: #selector(openPopoverFromMenu)))
        menu.addItem(item("Open Screenshot Folder", action: #selector(openFolderFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item("Quit SC Pro", action: #selector(quit)))
        menu.addItem(.separator())
        let credit = NSMenuItem(title: "Created by DLProjects", action: nil, keyEquivalent: "")
        credit.isEnabled = false
        menu.addItem(credit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openPopoverFromMenu() { openPanel() }
    @objc private func openFolderFromMenu() { store.openFolder() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func setSymbol(_ symbol: String) {
        statusItem.button?.image = menuImage(symbol)
    }

    private func menuImage(_ symbol: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "SC Pro"),
              let image = base.withSymbolConfiguration(config) else { return nil }
        image.isTemplate = true
        return image
    }
}

enum PanelPlacement {
    static func level(above others: Int) -> NSWindow.Level {
        let popup = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let ceiling = Int(CGWindowLevelForKey(.screenSaverWindow)) - 1
        return NSWindow.Level(rawValue: min(max(popup + 2, others + 1), ceiling))
    }
}

enum MenuBarWindows {
    static func blockerFrames(excludingPID pid: Int32) -> [NSRect] {
        windows(excludingPID: pid).filter { entry in
            guard entry.layer >= Int(CGWindowLevelForKey(.floatingWindow)) else { return false }
            guard entry.frame.height >= 48, entry.frame.width >= 48 else { return false }
            return !coversScreen(entry.frame)
        }.map(\.frame)
    }

    static func highestLevel(excludingPID pid: Int32, intersecting frame: NSRect) -> Int {
        let hit = frame.insetBy(dx: -4, dy: -4)
        return windows(excludingPID: pid)
            .filter { $0.frame.intersects(hit) && $0.layer >= Int(CGWindowLevelForKey(.floatingWindow)) }
            .map(\.layer)
            .max() ?? 0
    }

    private static func coversScreen(_ frame: NSRect) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return false }
        return frame.width > screen.frame.width * 0.92 && frame.height > screen.frame.height * 0.92
    }

    private static func windows(excludingPID pid: Int32) -> [(frame: NSRect, layer: Int)] {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            window(entry, excludingPID: pid)
        }
    }

    private static func window(_ entry: [String: Any], excludingPID pid: Int32) -> (frame: NSRect, layer: Int)? {
        let owner = entry[kCGWindowOwnerPID as String] as? Int ?? -1
        if owner == Int(pid) { return nil }
        let layer = entry[kCGWindowLayer as String] as? Int ?? 0
        guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let x = number(bounds["X"]),
              let y = number(bounds["Y"]),
              let width = number(bounds["Width"]),
              let height = number(bounds["Height"]) else { return nil }
        return (appKitRect(x: x, y: y, width: width, height: height), layer)
    }

    private static func appKitRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let top = primary?.frame.maxY ?? (y + height)
        return NSRect(x: x, y: top - y - height, width: width, height: height)
    }

    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber else { return nil }
        return CGFloat(truncating: number)
    }
}

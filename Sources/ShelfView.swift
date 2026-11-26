import AppKit
import ImageIO
import SwiftUI

@MainActor
enum PanelLayout {
    static let width: CGFloat = 372
    static let columns = 3
    static let gridSpacing: CGFloat = 8
    /// Square preview. Wide and tall shots are cropped to this, so every cell matches.
    static var tileSide: CGFloat {
        let inner = width - 24
        let gaps = gridSpacing * CGFloat(columns - 1)
        return (inner - gaps) / CGFloat(columns)
    }

    static func size(for store: ScreenshotStore) -> NSSize {
        NSSize(width: width, height: height(for: store))
    }

    private static func height(for store: ScreenshotStore) -> CGFloat {
        let grid = gridHeight(for: store)
        return 12 + 78 + 8 + grid + 8 + 164 + 12
    }

    private static func gridHeight(for store: ScreenshotStore) -> CGFloat {
        if store.blockedMessage != nil || store.items.isEmpty { return 136 }
        let shown = min(store.visibleCount, store.items.count)
        let rows = Int(ceil(Double(shown) / Double(columns)))
        let row = tileSide + 18
        return CGFloat(rows) * row + CGFloat(max(rows - 1, 0)) * gridSpacing
    }
}

@MainActor
final class ShelfRelay {
    var suspendAutoClose: () -> Void = {}
    var resumeAutoClose: (Bool) -> Void = { _ in }
    var relayout: () -> Void = {}
    var holdPreview: (URL) -> Void = { _ in }
}

struct ShelfView: View {
    @Bindable var store: ScreenshotStore
    var relay: ShelfRelay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            shelf
            Divider()
            footer
        }
        .padding(12)
        .frame(width: PanelLayout.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { relay.relayout() }
        .onChange(of: store.visibleCount) { _, _ in scheduleRelayout() }
        .onChange(of: store.items.count) { _, _ in scheduleRelayout() }
        .onChange(of: store.blockedMessage) { _, _ in scheduleRelayout() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SC Pro")
                    .font(.headline)
                Text(store.statusLine)
                    .font(.caption)
                    .foregroundStyle(store.copiedURL == nil ? Color.secondary : Color.accentColor)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text("Show")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("Show", selection: $store.visibleCount) {
                    ForEach(ScreenshotStore.allowedCounts, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Number of screenshots")
            }
        }
    }

    @ViewBuilder
    private var shelf: some View {
        if let blockedMessage = store.blockedMessage {
            blocked(blockedMessage)
        } else if store.visibleItems.isEmpty {
            empty
        } else {
            grid
        }
    }

    private var grid: some View {
        let side = PanelLayout.tileSide
        let columns = Array(
            repeating: GridItem(.fixed(side), spacing: PanelLayout.gridSpacing),
            count: PanelLayout.columns
        )
        return LazyVGrid(columns: columns, spacing: PanelLayout.gridSpacing) {
            ForEach(store.visibleItems) { item in
                ShotCell(
                    item: item,
                    isNewest: item.id == store.visibleItems.first?.id,
                    isSelected: store.selectedURL == item.url,
                    isCopied: store.copiedURL == item.url,
                    relay: relay,
                    onCopy: {
                        store.selectedURL = item.url
                        store.copy(item.url)
                    },
                    onHover: { hovering in
                        if hovering {
                            store.hoveredURL = item.url
                        } else if store.hoveredURL == item.url {
                            store.hoveredURL = nil
                        }
                    },
                    onPreview: { openPreview(item.url) }
                )
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No screenshots yet")
                .font(.callout)
            Text("New ones land here and on the clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 136)
    }

    private func blocked(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Privacy Settings") { store.openPrivacySettings() }
                Button("Try Again") { store.scan() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 136)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow("Copy new screenshots", isOn: $store.autoCopy)
            toggleRow("Open at login", isOn: Binding(
                get: { store.loginEnabled },
                set: { store.setLaunchAtLogin($0) }
            ))
            HStack(spacing: 8) {
                Text("Trash after")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("Trash after", selection: Binding(
                    get: { store.purgeWindow },
                    set: { window in
                        relay.suspendAutoClose()
                        store.proposePurge(window) { relay.resumeAutoClose(false) }
                    }
                )) {
                    ForEach(PurgeWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .id(store.purgeRevision)
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Trash screenshots after")
            }
            HStack {
                Button(store.folderButtonTitle) { store.openFolder() }
                Spacer()
                Button("Preview") { openPreview(nil) }
                    .disabled(store.visibleItems.isEmpty)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Created by DLProjects")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func scheduleRelayout() {
        DispatchQueue.main.async { relay.relayout() }
    }

    private func openPreview(_ url: URL?) {
        guard let target = url ?? store.hoveredURL ?? store.visibleItems.first?.url else { return }
        relay.holdPreview(target)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.callout)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

private struct ShotCell: View {
    let item: ScreenshotItem
    let isNewest: Bool
    let isSelected: Bool
    let isCopied: Bool
    let relay: ShelfRelay
    let onCopy: () -> Void
    let onHover: (Bool) -> Void
    let onPreview: () -> Void
    @State private var image: NSImage?
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                thumb
                if isCopied { copiedBadge }
                FileDragSurface(
                    url: item.url,
                    preview: image,
                    onClick: onCopy,
                    onHover: { hovering in
                        hovered = hovering
                        onHover(hovering)
                    },
                    onPreview: onPreview,
                    onSuspend: { relay.suspendAutoClose() },
                    onResume: { relay.resumeAutoClose($0) }
                )
            }
            .frame(width: PanelLayout.tileSide, height: PanelLayout.tileSide)
            Text(Self.caption(for: item.modifiedAt))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: PanelLayout.tileSide)
        .task(id: item.id) { image = await Thumbnails.image(for: item) }
    }

    private var thumb: some View {
        let side = PanelLayout.tileSide
        return Color.primary.opacity(0.06)
            .frame(width: side, height: side)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected || isNewest ? 2 : 1)
            }
    }

    private var borderColor: Color {
        if isSelected || isNewest { return Color.accentColor.opacity(0.9) }
        if hovered { return Color.primary.opacity(0.28) }
        return Color.primary.opacity(0.08)
    }

    private var copiedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title2)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(5)
            .background(.black.opacity(0.45), in: Circle())
    }

    private static func caption(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return timeFormatter.string(from: date) }
        return dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd jm")
        return formatter
    }()
}

private enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for item: ScreenshotItem) async -> NSImage? {
        let key = item.id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let rendered = await Task.detached(priority: .userInitiated) {
            ThumbnailRender.cgImage(for: item.url)
        }.value
        guard let rendered else { return nil }
        let image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

private enum ThumbnailRender {
    static func cgImage(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct FileDragSurface: NSViewRepresentable {
    let url: URL
    let preview: NSImage?
    let onClick: () -> Void
    let onHover: (Bool) -> Void
    let onPreview: () -> Void
    let onSuspend: () -> Void
    let onResume: (Bool) -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DragSourceView) {
        view.url = url
        view.preview = preview
        view.onClick = onClick
        view.onHover = onHover
        view.onPreview = onPreview
        view.onSuspend = onSuspend
        view.onResume = onResume
    }
}

private final class DragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var preview: NSImage?
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onPreview: () -> Void = {}
    var onSuspend: () -> Void = {}
    var onResume: (Bool) -> Void = { _ in }

    private var armed = false
    private var origin: NSPoint = .zero
    private var sessionActive = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        armed = true
        origin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard armed, let url, window != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 4 else { return }
        armed = false
        sessionActive = true
        onSuspend()
        beginFileDrag(url: url, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        let wasArmed = armed
        armed = false
        guard !sessionActive else { return }
        if wasArmed { onClick() }
        onResume(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        sessionActive = false
        onResume(true)
    }

    private func beginFileDrag(url: URL, event: NSEvent) {
        guard let item = DragFile.item(for: url) else { return }
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func showContextMenu(with event: NSEvent) {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copyFromMenu), keyEquivalent: "")
        copy.target = self
        let preview = menu.addItem(withTitle: "Open in Preview", action: #selector(openInPreview), keyEquivalent: "")
        preview.target = self
        let reveal = menu.addItem(withTitle: "Show in Finder", action: #selector(revealInFinder), keyEquivalent: "")
        reveal.target = self
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func copyFromMenu() { onClick() }

    @objc private func openInPreview() { onPreview() }

    @objc private func revealInFinder() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

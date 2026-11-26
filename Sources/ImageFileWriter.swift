import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ImagePayload: Sendable {
    let url: URL
    let png: Data
    let modifiedAt: Date

    @MainActor
    func writeToPasteboard() -> Bool {
        // A custom pasteboard writer returns false here; setting PNG data directly sticks.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        return (pasteboard.data(forType: .png)?.count ?? 0) > 32
    }

    static func load(from url: URL) -> ImagePayload? {
        guard let png = ImageTranscode.pngData(from: url), png.count > 32 else { return nil }
        let modifiedAt = ScreenshotFilter.modificationDate(of: url) ?? Date()
        return ImagePayload(url: url, png: png, modifiedAt: modifiedAt)
    }
}

enum ImageTranscode {
    static func pngData(from url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" {
            return try? Data(contentsOf: url)
        }
        return render(url, type: .png)
    }

    private static func render(_ url: URL, type: UTType) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

enum FileStability {
    static func wait(_ url: URL) async -> Bool {
        var lastSize = -1
        var stableReads = 0
        for _ in 0..<40 {
            if Task.isCancelled { return false }
            let size = currentSize(url)
            if size > 32, size == lastSize, isComplete(url) {
                stableReads += 1
                if stableReads >= 2 { return true }
            } else {
                stableReads = 0
            }
            lastSize = size
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isComplete(url) && currentSize(url) > 32
    }

    private static func currentSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    private static func isComplete(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }
}

enum DragFile {
    static func item(for url: URL) -> NSDraggingItem? {
        guard let png = ImageTranscode.pngData(from: url) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(png, forType: .png)
        pasteboardItem.setString(url.absoluteString, forType: .fileURL)
        return NSDraggingItem(pasteboardWriter: pasteboardItem)
    }
}

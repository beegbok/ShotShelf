import CoreGraphics
import Foundation

@main
enum ScreenshotFilterTests {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotshelf-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_100)
        write("Screenshot old.png", modified: older, in: directory)
        write("Screenshot new.jpg", modified: newer, in: directory)
        write("Screen Shot legacy.heic", modified: older.addingTimeInterval(10), in: directory)
        write("Capture 1.png", modified: newer.addingTimeInterval(10), in: directory)
        write("notes.png", modified: newer.addingTimeInterval(20), in: directory)
        write("My Screenshot.png", modified: newer.addingTimeInterval(30), in: directory)
        write("Screenshots.png", modified: newer.addingTimeInterval(40), in: directory)

        assert(ScreenshotFilter.isScreenshot(fileName: "Screenshot 2026-11-26 at 11.21.08 am.png", prefix: "Screenshot"))
        assert(ScreenshotFilter.isScreenshot(fileName: "screenshot 1.PNG", prefix: "Screenshot"))
        assert(ScreenshotFilter.isScreenshot(fileName: "Screen Shot 2020-01-01 at 1.02.03 PM.jpg", prefix: "Screenshot"))
        assert(ScreenshotFilter.isScreenshot(fileName: "Capture 2.heic", prefix: "Capture"))
        assert(!ScreenshotFilter.isScreenshot(fileName: "notes.png", prefix: "Screenshot"))
        assert(!ScreenshotFilter.isScreenshot(fileName: "My Screenshot.png", prefix: "Screenshot"))
        assert(!ScreenshotFilter.isScreenshot(fileName: "Screenshots.png", prefix: "Screenshot"))
        assert(!ScreenshotFilter.isScreenshot(fileName: "Screenshot.pdf", prefix: "Screenshot"))

        guard case .ready(let files) = ScreenshotFilter.load(directory: directory, prefix: "Screenshot") else {
            fatalError("expected screenshots in \(directory.path)")
        }
        assert(files.map(\.name) == ["Screenshot new.jpg", "Screen Shot legacy.heic", "Screenshot old.png"])

        guard case .ready(let captures) = ScreenshotFilter.load(directory: directory, prefix: "Capture") else {
            fatalError("expected capture prefix to match")
        }
        assert(captures.first?.name == "Capture 1.png")
        assert(captures.contains { $0.name == "Screenshot new.jpg" })

        let now = Date(timeIntervalSince1970: 1_000_000)
        assert(ScreenshotFilter.shouldAutoCopy(modifiedAt: now.addingTimeInterval(-44), now: now, maxAge: 45))
        assert(!ScreenshotFilter.shouldAutoCopy(modifiedAt: now.addingTimeInterval(-46), now: now, maxAge: 45))
        assert(ScreenshotFilter.shouldAutoCopy(modifiedAt: now.addingTimeInterval(1), now: now, maxAge: 45))
        assert(!ScreenshotFilter.shouldAutoCopy(modifiedAt: now.addingTimeInterval(5), now: now, maxAge: 45))

        let missing = directory.appendingPathComponent("missing")
        guard case .blocked = ScreenshotFilter.load(directory: missing, prefix: "Screenshot") else {
            fatalError("missing folder should be blocked")
        }

        checkPlacement()
        print("ScreenshotFilter tests passed")
    }

    private static func checkPlacement() {
        let visible = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let anchor = CGRect(x: 1000, y: 870, width: 24, height: 24)
        let size = CGSize(width: 372, height: 420)
        let clear = PanelGeometry.placed(anchor: anchor, size: size, visible: visible, blockers: [])
        assert(abs(clear.midX - anchor.midX) < 1)
        assert(clear.maxY <= anchor.minY)

        let blocker = CGRect(x: 980, y: 400, width: 400, height: 480)
        let shifted = PanelGeometry.placed(anchor: anchor, size: size, visible: visible, blockers: [blocker])
        assert(!shifted.insetBy(dx: -8, dy: -8).intersects(blocker))
        assert(visible.contains(shifted))
    }

    private static func write(_ name: String, modified: Date, in directory: URL) {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x89, count: 64))
        try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}

import AppKit
import CoreServices
import Observation
import ServiceManagement

struct ScreenshotItem: Identifiable, Equatable {
    let url: URL
    let modifiedAt: Date

    var id: String {
        let stamp = (modifiedAt.timeIntervalSinceReferenceDate * 1000).rounded()
        return "\(url.path)|\(stamp)"
    }
}

@MainActor
@Observable
final class ScreenshotStore {
    static let shared = ScreenshotStore()
    static let allowedCounts = [3, 6, 9, 12]
    static let idleStatus = "Click to copy · drag anywhere"
    static let menuSymbol = "photo.on.rectangle.angled"

    private(set) var items: [ScreenshotItem] = []
    private(set) var totalCount = 0
    private(set) var folderURL: URL
    private(set) var blockedMessage: String?
    private(set) var statusLine = idleStatus
    private(set) var copiedURL: URL?
    var hoveredURL: URL?
    private(set) var loginEnabled = false

    var visibleCount: Int = 6 {
        didSet { clampAndSaveCount() }
    }

    var autoCopy: Bool = true {
        didSet { UserDefaults.standard.set(autoCopy, forKey: Key.autoCopy) }
    }

    var purgeWindow: PurgeWindow = .off {
        didSet {
            guard purgeWindow != oldValue else { return }
            UserDefaults.standard.set(purgeWindow.rawValue, forKey: Key.purgeWindow)
            if primed { scan() }
        }
    }

    private(set) var purgeRevision = 0
    var onIconChange: ((String) -> Void)?

    var visibleItems: [ScreenshotItem] {
        Array(items.prefix(visibleCount))
    }

    var folderButtonTitle: String {
        let name = folderURL.lastPathComponent
        if totalCount == 0 { return name }
        return "\(name) · \(totalCount)"
    }

    private var handled: [URL: Date] = [:]
    private var primed = false
    private var scanning = false
    private var watchedPath: String?
    private var watcher: DirectoryWatcher?
    private var pollTick: PollTick?
    private var timer: Timer?
    private var inFlightURL: URL?
    private var stabilityTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var clipboardToken = UUID()
    private var didLogStart = false

    private init() {
        folderURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        let defaults = UserDefaults.standard
        let storedCount = defaults.integer(forKey: Key.count)
        visibleCount = Self.allowedCounts.contains(storedCount) ? storedCount : 6
        if defaults.object(forKey: Key.autoCopy) != nil {
            autoCopy = defaults.bool(forKey: Key.autoCopy)
        }
        purgeWindow = PurgeWindow(rawValue: defaults.integer(forKey: Key.purgeWindow)) ?? .off
    }

    func start() {
        scan()
        startPolling()
        ensureLoginItem()
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        updateWatcher()
        switch ScreenshotFilter.load(directory: folderURL, prefix: ScreenshotLocation.prefix()) {
        case .blocked(let message):
            blockedMessage = message
            items = []
            totalCount = 0
        case .ready(let found):
            blockedMessage = nil
            let kept = withoutExpired(found)
            totalCount = kept.count
            items = kept.prefix(30).map(makeItem)
            consume(kept)
        }
        logStartIfNeeded()
    }

    func copy(_ url: URL) {
        let token = UUID()
        clipboardToken = token
        clipboardTask?.cancel()
        clipboardTask = Task { [weak self] in
            let payload = await Self.loadPayload(url)
            guard let self, !Task.isCancelled else { return }
            self.write(payload, automatic: false, token: token)
        }
    }

    func proposePurge(_ window: PurgeWindow, finished: @escaping () -> Void = {}) {
        guard window != purgeWindow else {
            finished()
            return
        }
        guard purgeWindow.requiresConfirmation(to: window) else {
            purgeWindow = window
            finished()
            return
        }
        let alert = purgeAlert(window)
        let host = NSApp.windows.first { $0 is NSPanel && $0.isVisible } ?? NSApp.keyWindow
        guard let host else {
            let accepted = alert.runModal() == .alertFirstButtonReturn
            applyPurge(window, accepted: accepted)
            finished()
            return
        }
        alert.beginSheetModal(for: host) { [weak self] response in
            Task { @MainActor in
                self?.applyPurge(window, accepted: response == .alertFirstButtonReturn)
                finished()
            }
        }
    }

    func openFolder() {
        NSWorkspace.shared.open(folderURL)
    }

    @discardableResult
    func openInPreview(_ url: URL?) -> Bool {
        let target = url ?? hoveredURL ?? visibleItems.first?.url
        guard let target, FileManager.default.fileExists(atPath: target.path) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.open(target)
        }
        return true
    }

    func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
        fail("Open System Settings → Privacy & Security → Files and Folders")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(true, forKey: Key.loginItemSet)
        } catch {
            fail("Open at login failed. Keep SC Pro in Applications, then try again.")
        }
        refreshLoginState()
    }

    private func consume(_ found: [ScreenshotFile]) {
        prune(found)
        guard primed else {
            prime(found)
            return
        }
        guard autoCopy, let newest = found.first else { return }
        let url = fileURL(newest)
        guard !isHandled(url, modifiedAt: newest.modifiedAt) else { return }
        guard ScreenshotFilter.shouldAutoCopy(
            modifiedAt: newest.modifiedAt,
            now: Date(),
            maxAge: ScreenshotFilter.autoCopyMaxAge
        ) else {
            handled[url] = newest.modifiedAt
            return
        }
        startAutoCopy(url)
    }

    private func prime(_ found: [ScreenshotFile]) {
        for file in found { handled[fileURL(file)] = file.modifiedAt }
        primed = true
    }

    private func startAutoCopy(_ url: URL) {
        guard inFlightURL != url else { return }
        inFlightURL = url
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            await self?.autoCopy(url)
        }
    }

    private func autoCopy(_ url: URL) async {
        defer { if inFlightURL == url { inFlightURL = nil } }
        guard await FileStability.wait(url), !Task.isCancelled else { return }
        guard autoCopy else {
            handled[url] = ScreenshotFilter.modificationDate(of: url)
            return
        }
        clipboardTask?.cancel()
        let token = UUID()
        clipboardToken = token
        let payload = await Self.loadPayload(url)
        guard !Task.isCancelled else { return }
        write(payload, automatic: true, token: token)
    }

    private func write(_ payload: ImagePayload?, automatic: Bool, token: UUID) {
        guard token == clipboardToken else { return }
        guard let payload else {
            fail("Couldn't read that screenshot")
            return
        }
        guard payload.writeToPasteboard() else {
            if automatic { handled[payload.url] = payload.modifiedAt }
            fail("Couldn't copy screenshot")
            return
        }
        if automatic { handled[payload.url] = payload.modifiedAt }
        noteCopied(payload.url, automatic: automatic)
    }

    private func noteCopied(_ url: URL, automatic: Bool) {
        copiedURL = url
        statusLine = automatic ? "On the clipboard" : "Copied"
        onIconChange?("checkmark.circle.fill")
        fputs("ShotShelf copied \(url.lastPathComponent)\n", stderr)
        scheduleFeedbackReset(for: url)
    }

    private func scheduleFeedbackReset(for url: URL) {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self, !Task.isCancelled, self.copiedURL == url else { return }
            self.copiedURL = nil
            self.statusLine = Self.idleStatus
            self.onIconChange?(Self.menuSymbol)
        }
    }

    private func updateWatcher() {
        let directory = ScreenshotLocation.directory()
        if directory.path != folderURL.path {
            handled.removeAll()
            primed = false
        }
        folderURL = directory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            watcher?.stop()
            watcher = nil
            watchedPath = nil
            return
        }
        guard directory.path != watchedPath else { return }
        watcher?.stop()
        watchedPath = directory.path
        watcher = DirectoryWatcher(path: directory.path) {
            Task { @MainActor in ScreenshotStore.shared.scan() }
        }
    }

    private func startPolling() {
        let tick = PollTick()
        tick.onFire = { [weak self] in self?.scan() }
        pollTick = tick
        let timer = Timer(timeInterval: 1.0, target: tick, selector: #selector(PollTick.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func ensureLoginItem() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Key.loginItemSet) {
            do {
                try SMAppService.mainApp.register()
                defaults.set(true, forKey: Key.loginItemSet)
            } catch {
                fputs("ShotShelf: login item not enabled (\(error))\n", stderr)
            }
        }
        refreshLoginState()
    }

    private func refreshLoginState() {
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func applyPurge(_ window: PurgeWindow, accepted: Bool) {
        if accepted {
            purgeWindow = window
        } else {
            purgeRevision += 1
        }
    }

    private func purgeAlert(_ window: PurgeWindow) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Trash screenshots after \(window.phrase)?"
        alert.informativeText = confirmDetail(count: pendingPurgeCount(window), window: window)
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private func confirmDetail(count: Int, window: PurgeWindow) -> String {
        switch count {
        case 0:
            return "Nothing is old enough yet. New screenshots will be moved to the Trash after \(window.phrase)."
        case 1:
            return "1 screenshot older than \(window.phrase) will be moved to the Trash. New ones will follow."
        default:
            return "\(count) screenshots older than \(window.phrase) will be moved to the Trash. New ones will follow."
        }
    }

    private func pendingPurgeCount(_ window: PurgeWindow) -> Int {
        guard case .ready(let found) = ScreenshotFilter.load(
            directory: folderURL,
            prefix: ScreenshotLocation.prefix()
        ) else { return 0 }
        return ScreenshotFilter.expired(files: found, now: Date(), maxAge: window.maxAge).count
    }

    private func withoutExpired(_ found: [ScreenshotFile]) -> [ScreenshotFile] {
        let expired = ScreenshotFilter.expired(files: found, now: Date(), maxAge: purgeWindow.maxAge)
        guard !expired.isEmpty else { return found }
        var removed: Set<String> = []
        for file in expired {
            let url = fileURL(file)
            if url == inFlightURL { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                handled.removeValue(forKey: url)
                removed.insert(file.name)
            } catch {
                fail("Couldn't move \(file.name) to Trash")
            }
        }
        if !removed.isEmpty {
            let noun = removed.count == 1 ? "screenshot" : "screenshots"
            fputs("ShotShelf moved \(removed.count) \(noun) to Trash\n", stderr)
        }
        return found.filter { !removed.contains($0.name) }
    }

    private func prune(_ found: [ScreenshotFile]) {
        let live = Set(found.map(fileURL))
        handled = handled.filter { live.contains($0.key) }
    }

    private func isHandled(_ url: URL, modifiedAt: Date) -> Bool {
        guard let previous = handled[url] else { return false }
        return abs(previous.timeIntervalSince(modifiedAt)) < 0.05
    }

    private func makeItem(_ file: ScreenshotFile) -> ScreenshotItem {
        ScreenshotItem(url: fileURL(file), modifiedAt: file.modifiedAt)
    }

    private func fileURL(_ file: ScreenshotFile) -> URL {
        folderURL.appendingPathComponent(file.name)
    }

    private func clampAndSaveCount() {
        if !Self.allowedCounts.contains(visibleCount) {
            visibleCount = 6
            return
        }
        UserDefaults.standard.set(visibleCount, forKey: Key.count)
    }

    private func fail(_ message: String) {
        statusLine = message
        fputs("ShotShelf: \(message)\n", stderr)
    }

    private func logStartIfNeeded() {
        guard !didLogStart else { return }
        didLogStart = true
        let state = blockedMessage ?? "\(totalCount) screenshots"
        fputs("ShotShelf watching \(folderURL.path) (\(state))\n", stderr)
    }

    private static func loadPayload(_ url: URL) async -> ImagePayload? {
        await Task.detached(priority: .userInitiated) {
            ImagePayload.load(from: url)
        }.value
    }

    private enum Key {
        static let count = "visibleCount"
        static let autoCopy = "autoCopy"
        static let loginItemSet = "loginItemSet"
        static let purgeWindow = "purgeWindow"
    }
}

enum ScreenshotLocation {
    static func directory() -> URL {
        if let path = preference("location") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    static func prefix() -> String {
        preference("name") ?? "Screenshot"
    }

    private static func preference(_ key: String) -> String? {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        guard let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.screencapture" as CFString) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
    }

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

@MainActor
private final class PollTick: NSObject {
    var onFire: (() -> Void)?
    @objc func fire() { onFire?() }
}

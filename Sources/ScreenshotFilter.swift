import Foundation

struct ScreenshotFile: Equatable {
    let name: String
    let modifiedAt: Date
}

enum ScreenshotCatalog: Equatable {
    case ready([ScreenshotFile])
    case blocked(String)
}

enum PurgeWindow: Int, CaseIterable, Identifiable {
    case off = 0
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case sixHours = 21_600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .thirtyMinutes: "30m"
        case .oneHour: "1h"
        case .sixHours: "6h"
        }
    }

    var phrase: String {
        switch self {
        case .off: "off"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .sixHours: "6 hours"
        }
    }

    var maxAge: TimeInterval { TimeInterval(rawValue) }

    /// Turning purge on, or making it sooner, trashes screenshots that are already sitting there.
    func requiresConfirmation(to next: PurgeWindow) -> Bool {
        guard next != self, next != .off else { return false }
        if self == .off { return true }
        return next.maxAge < maxAge
    }
}

enum ScreenshotFilter {
    static let autoCopyMaxAge: TimeInterval = 45
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]

    static func isScreenshot(fileName: String, prefix: String) -> Bool {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { return false }
        if !prefix.isEmpty, hasBoundaryPrefix(base, prefix: prefix) { return true }
        if hasBoundaryPrefix(base, prefix: "Screenshot") { return true }
        return hasBoundaryPrefix(base, prefix: "Screen Shot")
    }

    /// Screenshots older than `maxAge`. Zero means purging is off. A file dated in the future stays.
    static func expired(files: [ScreenshotFile], now: Date, maxAge: TimeInterval) -> [ScreenshotFile] {
        guard maxAge > 0 else { return [] }
        return files.filter { now.timeIntervalSince($0.modifiedAt) >= maxAge }
    }

    /// A file is worth auto-copying when it was just written, allowing a little clock skew.
    static func shouldAutoCopy(modifiedAt: Date, now: Date, maxAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(modifiedAt)
        return age >= -2 && age <= maxAge
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func load(directory: URL, prefix: String) -> ScreenshotCatalog {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .blocked("Can't find \(directory.path)")
        }
        do {
            let files = try screenshotFiles(in: directory, prefix: prefix)
            return .ready(files.sorted { $0.modifiedAt > $1.modifiedAt })
        } catch {
            return .blocked(message(for: error, directory: directory))
        }
    }

    private static func screenshotFiles(in directory: URL, prefix: String) throws -> [ScreenshotFile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            file(at: url, prefix: prefix)
        }
    }

    private static func file(at url: URL, prefix: String) -> ScreenshotFile? {
        guard isScreenshot(fileName: url.lastPathComponent, prefix: prefix) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let modifiedAt = values.contentModificationDate,
              (values.fileSize ?? 0) > 32 else { return nil }
        return ScreenshotFile(name: url.lastPathComponent, modifiedAt: modifiedAt)
    }

    private static func hasBoundaryPrefix(_ base: String, prefix: String) -> Bool {
        guard let range = base.range(of: prefix, options: [.caseInsensitive, .anchored]) else { return false }
        if range.upperBound == base.endIndex { return true }
        let next = base[range.upperBound]
        return next.isWhitespace || next.isNumber || next == "-" || next == "_" || next == "("
    }

    private static func message(for error: Error, directory: URL) -> String {
        let nsError = error as NSError
        if isPermissionError(nsError) {
            return "Allow ShotShelf to read \(directory.lastPathComponent) in Privacy settings."
        }
        return "Couldn't read \(directory.lastPathComponent)."
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && (error.code == 257 || error.code == 513) { return true }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES)
    }
}

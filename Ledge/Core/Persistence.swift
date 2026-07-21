import AppKit
import CryptoKit

/// Lightweight persistence helpers shared across features:
/// - a JSON store under Application Support for small Codable models,
/// - URL bookmarks so referenced files survive relaunches and moves,
/// - a thumbnail disk cache so QuickLook thumbnails aren't regenerated each launch.
enum Persistence {

    // MARK: Directories

    /// On-disk folder name. Deliberately still "NotchMate" after the Ledge
    /// rename: the shelf's bookmarks, favorites and thumbnail cache live
    /// here, and renaming the folder would orphan them for every existing
    /// install. Invisible legacy, like the bundle identifier.
    private static let storageFolderName = "NotchMate"

    /// `~/Library/Application Support/NotchMate/`
    static let supportDirectory: URL = {
        // The standard directories are always present in practice, but these
        // statics run on the launch path — degrading to a temp directory beats
        // crashing before the app has drawn anything.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(storageFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `~/Library/Caches/NotchMate/thumbnails/`
    static let thumbnailCacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("\(storageFolderName)/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: JSON store

    static func save<T: Encodable>(_ value: T, to filename: String) {
        let url = supportDirectory.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Ledge: failed to save \(filename): \(error)")
        }
    }

    static func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = supportDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog("Ledge: failed to load \(filename): \(error)")
            return nil
        }
    }

    /// Delete a stored JSON file — used when its model empties out (e.g. the
    /// pomodoro session store once the timer goes idle).
    static func remove(_ filename: String) {
        try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent(filename))
    }

    // MARK: File bookmarks

    /// Bookmark a file URL so it can be resolved after relaunch even if moved.
    /// The app is not sandboxed, so a plain bookmark suffices; this stays
    /// forward-compatible if a security-scoped variant is ever needed.
    static func bookmarkData(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            NSLog("Ledge: failed to bookmark \(url.path): \(error)")
            return nil
        }
    }

    /// Resolve a bookmark back to a URL. Returns nil if the file no longer exists.
    static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return url
    }

    // MARK: Thumbnail cache

    /// Stable cache filename derived from the file's resolved path.
    private static func thumbnailKey(for url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    static func cachedThumbnail(for url: URL) -> NSImage? {
        let cacheURL = thumbnailCacheDirectory.appendingPathComponent(thumbnailKey(for: url))
        return NSImage(contentsOf: cacheURL)
    }

    static func storeThumbnail(_ image: NSImage, for url: URL) {
        let cacheURL = thumbnailCacheDirectory.appendingPathComponent(thumbnailKey(for: url))
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: cacheURL, options: .atomic)
    }

    /// Evict the oldest cached thumbnails (by modification date) until the cache
    /// fits within `maxBytes`. Without this the cache grows unbounded as shelf
    /// files come and go. Safe to call off the main thread.
    static func pruneThumbnailCache(maxBytes: Int = 50 * 1024 * 1024) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(
            at: thumbnailCacheDirectory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }

        let entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }

        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        // Oldest first, delete until back under budget.
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > maxBytes else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Remove all persisted data and caches (used by Settings → reset), then
    /// recreate the empty directories so subsequent writes succeed.
    static func resetAll() {
        let fm = FileManager.default
        try? fm.removeItem(at: supportDirectory)
        try? fm.removeItem(at: thumbnailCacheDirectory)
        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbnailCacheDirectory, withIntermediateDirectories: true)
    }
}

import AppKit
import QuickLookThumbnailing

/// A single staged file. Holds a reference to the original URL so dragging it
/// out hands over the real file (move/copy is decided by the drop target).
final class ShelfItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    @Published var thumbnail: NSImage?
    /// True if the underlying file no longer exists on disk.
    @Published var isMissing: Bool = false

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
    }
}

final class FileShelfModel: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var isDropTargeted: Bool = false

    private let storeFile = "shelf.json"

    init() {
        restore()
    }

    func add(_ rawURL: URL) {
        // Normalize so a path and its symlink/case variant aren't seen as distinct.
        let url = rawURL.standardizedFileURL.resolvingSymlinksInPath()
        guard !items.contains(where: { $0.url == url }) else { return }
        let item = ShelfItem(url: url)
        items.append(item)
        loadThumbnail(for: item)
        persist()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    /// Re-check whether a file still exists (called before drag-out).
    @discardableResult
    func refreshExistence(of item: ShelfItem) -> Bool {
        let exists = FileManager.default.fileExists(atPath: item.url.path)
        if item.isMissing == exists { item.isMissing = !exists }
        return exists
    }

    // MARK: Persistence

    private func persist() {
        let bookmarks = items.compactMap { Persistence.bookmarkData(for: $0.url) }
        Persistence.save(bookmarks, to: storeFile)
    }

    private func restore() {
        guard let bookmarks = Persistence.load([Data].self, from: storeFile) else { return }
        for data in bookmarks {
            // A bookmark resolves moved files automatically; nil means it's gone.
            guard let url = Persistence.resolveBookmark(data) else { continue }
            let item = ShelfItem(url: url)
            item.isMissing = !FileManager.default.fileExists(atPath: url.path)
            items.append(item)
            loadThumbnail(for: item)
        }
    }

    // MARK: Thumbnails

    private func loadThumbnail(for item: ShelfItem) {
        if let cached = Persistence.cachedThumbnail(for: item.url) {
            item.thumbnail = cached
            return
        }
        generateThumbnail(for: item)
    }

    private func generateThumbnail(for item: ShelfItem) {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 80, height: 80),
            scale: 2,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let representation else { return }
            let image = representation.nsImage
            Persistence.storeThumbnail(image, for: item.url)
            DispatchQueue.main.async {
                item.thumbnail = image
            }
        }
    }
}

import AppKit

/// The panel's content view. The panel has a fixed (large) size, but only the
/// area covered by the island is interactive — `hitTest` returns `nil` elsewhere
/// so clicks fall through to the apps behind. Hover-to-expand is driven by a
/// global mouse-moved monitor in `NotchWindowController` (deterministic at the
/// top screen edge), not by a tracking area. The view is also a drag
/// destination so dragging a file onto it auto-expands the notch.
final class NotchContainerView: NSView {
    /// Current interactive island rect in this view's coordinates (origin bottom-left).
    var islandRect: () -> NSRect = { .zero }
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard islandRect().contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

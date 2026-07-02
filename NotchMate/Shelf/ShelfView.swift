import SwiftUI

struct ShelfView: View {
    @ObservedObject var shelf: FileShelfModel

    var body: some View {
        VStack(spacing: 6) {
            if !shelf.items.isEmpty {
                HStack {
                    Spacer()
                    Button(action: shelf.clear) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                }
            }

            ZStack {
                // Dashed frame only as live drop feedback; otherwise solid black.
                if shelf.isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .foregroundStyle(.white.opacity(0.85))
                }

                if shelf.items.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 18))
                        Text(String(localized: "shelf.dropHint", defaultValue: "Dateien hierher ziehen"))
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(shelf.items) { item in
                                ShelfItemView(item: item, shelf: shelf)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct ShelfItemView: View {
    @ObservedObject var item: ShelfItem
    @ObservedObject var shelf: FileShelfModel

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) {
                if item.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                }
            }

            Text(item.name)
                .font(.system(size: 8))
                .lineLimit(1)
                .frame(width: 50)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(4)
        .opacity(item.isMissing ? 0.5 : 1)
        .help(item.isMissing
              ? String(localized: "shelf.missing", defaultValue: "Datei nicht gefunden") + " — " + item.name
              : item.name)
        .onDrag {
            // Don't hand over a file that no longer exists.
            guard shelf.refreshExistence(of: item) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .contextMenu {
            ShareLink(item: item.url) {
                Label(String(localized: "shelf.share", defaultValue: "Teilen …"), systemImage: "square.and.arrow.up")
            }
            Button(String(localized: "shelf.remove", defaultValue: "Entfernen"), role: .destructive) { shelf.remove(item) }
        }
    }
}

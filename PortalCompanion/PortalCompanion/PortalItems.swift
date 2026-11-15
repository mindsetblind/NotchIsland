import CoreTransferable
import PhotosUI
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A photo or file waiting in the grid, already copied into the app's temporary folder.
struct PortalItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var thumbnail: UIImage?
}

/// A picked photo or video as a file with its original name (HEIC stays HEIC).
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try PickedMedia(copying: received.file) }
        FileRepresentation(importedContentType: .image) { received in try PickedMedia(copying: received.file) }
    }

    init(copying source: URL) throws {
        url = try Inbox.copy(source)
    }

    init(url: URL) { self.url = url }
}

enum Inbox {
    static var folder: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies into its own subfolder, so two files with the same name don't clash.
    static func copy(_ source: URL) throws -> URL {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func thumbnail(for url: URL, side: CGFloat = 300) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }
}

@MainActor
final class Outbox: ObservableObject {
    @Published var items: [PortalItem] = []
    @Published var importing = false

    func add(photos: [PhotosPickerItem]) async {
        importing = true
        defer { importing = false }
        for photo in photos {
            guard let media = try? await photo.loadTransferable(type: PickedMedia.self) else { continue }
            await append(media.url)
        }
    }

    func add(files: [URL]) async {
        for file in files {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            guard let copy = try? Inbox.copy(file) else { continue }
            await append(copy)
        }
    }

    private func append(_ url: URL) async {
        var item = PortalItem(url: url)
        items.append(item)
        item.thumbnail = await Inbox.thumbnail(for: url)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].thumbnail = item.thumbnail }
    }

    func remove(_ item: PortalItem) {
        items.removeAll { $0.id == item.id }
        Inbox.remove(item.url)
    }

    func restore(_ item: PortalItem, at index: Int) {
        items.insert(item, at: min(index, items.count))
    }
}

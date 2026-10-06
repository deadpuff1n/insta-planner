import SwiftUI
import SwiftData
import UIKit
import Photos

struct CropEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let post: FeedPost
    let onDelete: () -> Void

    @State private var scale: Double
    @State private var x: Double
    @State private var y: Double
    @State private var lastScale: Double
    @State private var lastX: Double
    @State private var lastY: Double
    @State private var notice: String?
    @State private var library = PhotoLibraryBrowser()

    init(post: FeedPost, onDelete: @escaping () -> Void = {}) {
        self.post = post
        self.onDelete = onDelete
        _scale = State(initialValue: post.cropScale); _lastScale = State(initialValue: post.cropScale)
        _x = State(initialValue: post.cropX); _lastX = State(initialValue: post.cropX)
        _y = State(initialValue: post.cropY); _lastY = State(initialValue: post.cropY)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let w = geo.size.width - 32
                let frame = CGSize(width: w, height: w / FeedLayout.cellAspect)
                VStack(spacing: 16) {
                    Spacer()
                    if let img = ImageStore.load(post.imageFile) {
                        editor(img, frame)
                    }
                    Text("Двигай и масштабируй фото. Оригинал не меняется.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if post.isDraft {
                        galleryStrip
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Кроп превью")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .principal) { Button("Сбросить") { reset() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        applyCrop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { saveCroppedToGallery() } label: {
                        Label("Сохранить в галерею", systemImage: "square.and.arrow.down")
                    }
                }
                if post.isDraft {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Label("Убрать из ленты", systemImage: "trash")
                        }
                    }
                }
            }
            .task { if post.isDraft { await library.load() } }
            .alert("Галерея", isPresented: .constant(notice != nil)) {
                Button("OK") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
    }

    private var galleryStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(library.albums) { album in
                        Button(album.title) { Task { await library.select(album) } }
                    }
                } label: {
                    Label(library.selectedAlbum?.title ?? "Недавние", systemImage: "rectangle.stack")
                        .font(.footnote.weight(.medium))
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(library.assets) { asset in
                        Button { Task { await replacePhoto(with: asset) } } label: {
                            if let thumb = asset.thumbnail {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle().fill(.secondary.opacity(0.2))
                            }
                        }
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 64)
        }
    }

    private func editor(_ img: UIImage, _ frame: CGSize) -> some View {
        let drag = DragGesture()
            .onChanged { v in
                x = lastX + v.translation.width / frame.width
                y = lastY + v.translation.height / frame.height
                limit(img.size, frame)
            }
            .onEnded { _ in lastX = x; lastY = y }
        let zoom = MagnifyGesture()
            .onChanged { v in
                scale = min(max(lastScale * v.magnification, 1), 5)
                limit(img.size, frame)
            }
            .onEnded { _ in lastScale = scale; lastX = x; lastY = y }

        return CroppedImage(image: img, scale: scale, x: x, y: y)
            .frame(width: frame.width, height: frame.height)
            .overlay(Rectangle().stroke(.white.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(drag.simultaneously(with: zoom))
    }

    /// Не даём сдвинуть картинку так, чтобы в рамке появились пустые поля
    private func limit(_ img: CGSize, _ frame: CGSize) {
        let fill = FeedLayout.fill(img, in: frame)
        let mx = max(0, (fill.width * scale - frame.width) / 2 / frame.width)
        let my = max(0, (fill.height * scale - frame.height) / 2 / frame.height)
        x = min(max(x, -mx), mx)
        y = min(max(y, -my), my)
    }

    private func applyCrop() {
        post.cropScale = scale; post.cropX = x; post.cropY = y
    }

    private func saveCroppedToGallery() {
        applyCrop()
        Task {
            do {
                try await CropExporter.saveToPhotoLibrary(post: post)
                notice = "Кроп сохранён в галерею"
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func replacePhoto(with asset: PhotoLibraryAsset) async {
        do {
            let selection = try await library.imageData(for: asset)
            guard let file = ImageStore.save(selection.data) else {
                notice = "Не удалось сохранить выбранное фото"
                return
            }
            ImageStore.delete(post.imageFile)
            post.imageFile = file
            post.sourceFilename = selection.filename
            reset()
            applyCrop()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func reset() {
        scale = 1; x = 0; y = 0; lastScale = 1; lastX = 0; lastY = 0
    }
}

enum CropExporter {
    enum ExportError: LocalizedError {
        case missingImage
        case noPhotoAccess
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .missingImage: "Не удалось открыть фото"
            case .noPhotoAccess: "Нет доступа для сохранения в галерею"
            case .writeFailed: "Не удалось сохранить фото в галерею"
            }
        }
    }

    @MainActor
    static func saveToPhotoLibrary(post: FeedPost) async throws {
        guard let image = ImageStore.load(post.imageFile), let data = croppedData(for: post, image: image) else {
            throw ExportError.missingImage
        }
        let filename = croppedFilename(for: post)
        let url = FileManager.default.temporaryDirectory.appending(path: filename)
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.noPhotoAccess }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                request.addResource(with: .photo, fileURL: url, options: options)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportError.writeFailed)
                }
            }
        }
    }

    @MainActor
    static func croppedData(for post: FeedPost, image: UIImage) -> Data? {
        croppedData(from: image, scale: post.cropScale, x: post.cropX, y: post.cropY)
    }

    static func croppedData(from image: UIImage, scale: Double, x: Double, y: Double) -> Data? {
        let outputSize = CGSize(width: 1080, height: 1080 / FeedLayout.cellAspect)
        let fill = FeedLayout.fill(image.size, in: outputSize)
        let drawSize = CGSize(width: fill.width * scale, height: fill.height * scale)
        let origin = CGPoint(
            x: outputSize.width / 2 + x * outputSize.width - drawSize.width / 2,
            y: outputSize.height / 2 + y * outputSize.height - drawSize.height / 2
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let cropped = renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return cropped.jpegData(compressionQuality: 0.92)
    }

    static func croppedFilename(for post: FeedPost) -> String {
        let raw = post.sourceFilename ?? post.imageFile
        let base = URL(fileURLWithPath: raw).deletingPathExtension().lastPathComponent
        let safeBase = base.isEmpty ? "photo" : base
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        return "\(safeBase)_crop_\(formatter.string(from: Date())).jpg"
    }
}

struct PhotoLibraryAlbum: Identifiable, Equatable {
    let id: String
    let title: String
    let collection: PHAssetCollection?
}

struct PhotoLibraryAsset: Identifiable, Equatable {
    let id: String
    let asset: PHAsset
    var thumbnail: UIImage?
}

struct PhotoLibrarySelection {
    let data: Data
    let filename: String
}

@MainActor
@Observable
final class PhotoLibraryBrowser {
    var albums: [PhotoLibraryAlbum] = []
    var selectedAlbum: PhotoLibraryAlbum?
    var assets: [PhotoLibraryAsset] = []
    var selectedAlbumID: String? { selectedAlbum?.id }

    private let manager = PHCachingImageManager()

    func load() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        albums = fetchAlbums()
        selectedAlbum = albums.first
        if let selectedAlbum { await select(selectedAlbum) }
    }

    func select(_ album: PhotoLibraryAlbum) async {
        selectedAlbum = album
        let fetched = fetchAssets(in: album).prefix(80).map {
            PhotoLibraryAsset(id: $0.localIdentifier, asset: $0, thumbnail: nil)
        }
        assets = Array(fetched)
        for item in assets.prefix(40) {
            if let image = await thumbnail(for: item.asset), let index = assets.firstIndex(where: { $0.id == item.id }) {
                assets[index].thumbnail = image
            }
        }
    }

    func selectAlbum(id: String?) async {
        guard let id, let album = albums.first(where: { $0.id == id }) else { return }
        await select(album)
    }

    func imageData(for item: PhotoLibraryAsset) async throws -> PhotoLibrarySelection {
        let data = try await imageData(for: item.asset)
        let filename = PHAssetResource.assetResources(for: item.asset).first?.originalFilename ?? "photo.jpg"
        return PhotoLibrarySelection(data: data, filename: filename)
    }

    private func fetchAlbums() -> [PhotoLibraryAlbum] {
        let recents = PhotoLibraryAlbum(id: "recents", title: "Недавние", collection: nil)
        var albums: [PhotoLibraryAlbum] = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle ?? "Альбом"
            let album = PhotoLibraryAlbum(id: collection.localIdentifier, title: title, collection: collection)
            if self.fetchAssets(in: album).isEmpty == false {
                albums.append(album)
            }
        }
        albums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return [recents] + albums
    }

    private func fetchAssets(in album: PhotoLibraryAlbum) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let fetch = album.collection.map { PHAsset.fetchAssets(in: $0, options: options) } ?? PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var didResume = false
            manager.requestImage(for: asset, targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFill, options: options) { image, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    private func imageData(for asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CropExporter.ExportError.missingImage)
                }
            }
        }
    }
}

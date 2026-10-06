import SwiftData
import Foundation

@Model final class Account {
    var id: UUID = UUID()
    var title: String
    var username: String
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \FeedPost.account)
    var posts: [FeedPost] = []

    init(title: String, username: String) {
        self.title = title
        self.username = username
    }

    var sortedPosts: [FeedPost] { posts.sorted { $0.order < $1.order } }
}

@Model final class FeedPost {
    var id: UUID = UUID()
    var order: Int
    var imageFile: String          // имя файла в ImageStore (оригинал не меняется)
    var sourceFilename: String?
    var sourceAssetID: String?
    var sourceAlbumID: String?
    var igMediaId: String?         // nil = локальный черновик
    var caption: String = ""
    // Кроп хранится отдельно от оригинала, в долях размера ячейки
    var cropScale: Double = 1
    var cropX: Double = 0
    var cropY: Double = 0
    var account: Account?

    init(order: Int, imageFile: String, sourceFilename: String? = nil, sourceAssetID: String? = nil, sourceAlbumID: String? = nil, igMediaId: String? = nil, caption: String = "") {
        self.order = order
        self.imageFile = imageFile
        self.sourceFilename = sourceFilename
        self.sourceAssetID = sourceAssetID
        self.sourceAlbumID = sourceAlbumID
        self.igMediaId = igMediaId
        self.caption = caption
    }

    var isDraft: Bool { igMediaId == nil }
}

enum FeedLayout {
    /// Соотношение ячейки сетки (ширина / высота). Сейчас в Instagram превью 3:4.
    /// Для старого квадрата поставь 1, для 4:5 — 0.8
    static let cellAspect: CGFloat = 3.0 / 4.0

    /// Размер картинки при scaledToFill в рамке
    static func fill(_ image: CGSize, in frame: CGSize) -> CGSize {
        let ia = image.width / image.height
        let fa = frame.width / frame.height
        return ia > fa
            ? CGSize(width: frame.height * ia, height: frame.height)
            : CGSize(width: frame.width, height: frame.width / ia)
    }
}

import UIKit
import Security

// MARK: - Keychain (токены Instagram)
enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrAccount as String: key] as CFDictionary)
    }
}

// MARK: - Локальное хранилище картинок
enum ImageStore {
    private static let dir: URL = {
        let d = URL.applicationSupportDirectory.appending(path: "Images")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let cache = NSCache<NSString, UIImage>()

    /// Сохраняет JPEG (с ограничением до 2048 px по длинной стороне), возвращает имя файла
    static func save(_ data: Data) -> String? {
        guard let src = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 2048
        let k = min(1, maxSide / max(src.size.width, src.size.height))
        let size = CGSize(width: src.size.width * k, height: src.size.height * k)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            src.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpg = img.jpegData(compressionQuality: 0.9) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do { try jpg.write(to: dir.appending(path: name)) } catch { return nil }
        return name
    }

    static func load(_ name: String) -> UIImage? {
        if let c = cache.object(forKey: name as NSString) { return c }
        guard let img = UIImage(contentsOfFile: dir.appending(path: name).path) else { return nil }
        cache.setObject(img, forKey: name as NSString)
        return img
    }

    static func delete(_ name: String) {
        cache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: dir.appending(path: name))
    }
}

// MARK: - Instagram API with Instagram Login
struct IGMedia: Decodable {
    let id: String
    let media_type: String
    let media_url: String?
    let thumbnail_url: String?   // у видео
    let caption: String?
    var imageURL: URL? { (thumbnail_url ?? media_url).flatMap(URL.init) }
}

enum InstagramService {
    private struct MediaResponse: Decodable { let data: [IGMedia] }
    private struct Me: Decodable { let username: String }
    private struct Refresh: Decodable { let access_token: String }

    enum IGError: LocalizedError {
        case bad(String)
        var errorDescription: String? { if case .bad(let m) = self { return m }; return nil }
    }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        var c = URLComponents(string: "https://graph.instagram.com/\(path)")!
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw IGError.bad(String(data: data, encoding: .utf8) ?? "Ошибка запроса")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func username(token: String) async throws -> String {
        let me: Me = try await get("me", ["fields": "username", "access_token": token])
        return me.username
    }

    static func latest(token: String, limit: Int = 12) async throws -> [IGMedia] {
        let r: MediaResponse = try await get("me/media", [
            "fields": "id,media_type,media_url,thumbnail_url,caption",
            "limit": String(limit), "access_token": token])
        return r.data
    }

    /// Продлевает long-lived токен (60 дней). Работает, если токену больше 24 часов.
    static func refresh(token: String) async throws -> String {
        let r: Refresh = try await get("refresh_access_token",
            ["grant_type": "ig_refresh_token", "access_token": token])
        return r.access_token
    }

    static func download(_ url: URL) async throws -> Data {
        try await URLSession.shared.data(from: url).0
    }
}


// MARK: - Источники ленты
struct RemotePost {
    let id: String
    let imageURL: URL
    let caption: String
}

protocol FeedSource {
    func latest(limit: Int) async throws -> [RemotePost]
}

/// Официальный API (нужен токен)
struct GraphAPISource: FeedSource {
    let token: String
    func latest(limit: Int) async throws -> [RemotePost] {
        try await InstagramService.latest(token: token, limit: limit).compactMap { m in
            m.imageURL.map { RemotePost(id: m.id, imageURL: $0, caption: m.caption ?? "") }
        }
    }
}

/// Неофициальные источники: сначала публичный JSON endpoint, затем парсинг HTML страницы.
/// Не документированы — Instagram может в любой момент вернуть 401/429 или изменить формат.
struct PublicProfileSource: FeedSource {
    let username: String

    private struct Root: Decodable {
        struct D: Decodable { let user: U? }
        struct U: Decodable { let edge_owner_to_timeline_media: Media }
        struct Media: Decodable { let edges: [Edge] }
        struct Edge: Decodable { let node: Node }
        struct Node: Decodable {
            let id: String
            let display_url: String
            let edge_media_to_caption: Caps?
        }
        struct Caps: Decodable { let edges: [CapEdge] }
        struct CapEdge: Decodable { let node: CapNode }
        struct CapNode: Decodable { let text: String }
        let data: D
    }

    func latest(limit: Int) async throws -> [RemotePost] {
        do {
            return try await webProfileInfo(limit: limit)
        } catch {
            let posts = try await profilePagePosts(limit: limit)
            if posts.isEmpty { throw error }
            return posts
        }
    }

    private func webProfileInfo(limit: Int) async throws -> [RemotePost] {
        var c = URLComponents(string: "https://i.instagram.com/api/v1/users/web_profile_info/")!
        c.queryItems = [URLQueryItem(name: "username", value: username)]
        var req = URLRequest(url: c.url!)
        req.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw InstagramService.IGError.bad("Instagram ответил \(code). Пробую разобрать страницу профиля.")
        }
        guard let user = try JSONDecoder().decode(Root.self, from: data).data.user else {
            throw InstagramService.IGError.bad("Профиль @\(username) не найден или закрыт")
        }
        return user.edge_owner_to_timeline_media.edges.prefix(limit).compactMap { e in
            URL(string: e.node.display_url).map {
                RemotePost(id: e.node.id, imageURL: $0,
                           caption: e.node.edge_media_to_caption?.edges.first?.node.text ?? "")
            }
        }
    }

    private func profilePagePosts(limit: Int) async throws -> [RemotePost] {
        let url = URL(string: "https://www.instagram.com/\(username)/")!
        var req = URLRequest(url: url)
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let html = String(data: data, encoding: .utf8) else {
            throw InstagramService.IGError.bad("Instagram не отдал страницу @\(username) без входа")
        }
        let posts = Self.extractPosts(from: html, limit: limit)
        guard !posts.isEmpty else {
            throw InstagramService.IGError.bad("Не удалось найти посты на странице @\(username). Instagram мог изменить разметку или скрыть данные без входа.")
        }
        return posts
    }

    private static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static func extractPosts(from html: String, limit: Int) -> [RemotePost] {
        var posts: [RemotePost] = []
        for candidate in jsonCandidates(from: html) {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectPosts(from: json, into: &posts, limit: limit)
            if posts.count >= limit { break }
        }
        return unique(posts).prefix(limit).map { $0 }
    }

    private static func jsonCandidates(from html: String) -> [String] {
        var candidates: [String] = []
        var searchStart = html.startIndex
        while let open = html.range(of: "<script", range: searchStart..<html.endIndex),
              let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: tagEnd.upperBound..<html.endIndex) {
            let tag = html[open.lowerBound..<tagEnd.upperBound]
            if tag.contains("application/json") || tag.contains("application/ld+json") {
                candidates.append(String(html[tagEnd.upperBound..<close.lowerBound]).htmlDecoded)
            }
            searchStart = close.upperBound
        }

        for marker in [
            "window._sharedData =",
            "\"edge_owner_to_timeline_media\":",
            "\"xdt_api__v1__feed__user_timeline_graphql_connection\":"
        ] {
            var markerStart = html.startIndex
            while let found = html.range(of: marker, range: markerStart..<html.endIndex),
                  let object = balancedJSONValue(after: found.upperBound, in: html) {
                candidates.append(object.htmlDecoded)
                markerStart = found.upperBound
            }
        }
        return candidates
    }

    private static func balancedJSONValue(after index: String.Index, in text: String) -> String? {
        guard let start = text[index...].firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opening = text[start]
        let closing: Character = opening == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaping = false
        var current = start
        while current < text.endIndex {
            let ch = text[current]
            if inString {
                if escaping {
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == opening {
                depth += 1
            } else if ch == closing {
                depth -= 1
                if depth == 0 { return String(text[start...current]) }
            }
            current = text.index(after: current)
        }
        return nil
    }

    private static func collectPosts(from value: Any, into posts: inout [RemotePost], limit: Int) {
        if posts.count >= limit { return }
        if let dict = value as? [String: Any] {
            if let post = post(from: dict) {
                posts.append(post)
                return
            }
            for item in dict.values {
                collectPosts(from: item, into: &posts, limit: limit)
                if posts.count >= limit { return }
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectPosts(from: item, into: &posts, limit: limit)
                if posts.count >= limit { return }
            }
        }
    }

    private static func post(from dict: [String: Any]) -> RemotePost? {
        let id = (dict["id"] as? String) ?? (dict["pk"] as? String) ?? (dict["code"] as? String)
        let image = (dict["thumbnail_src"] as? String)
            ?? (dict["display_url"] as? String)
            ?? imageFromVersions(dict["image_versions2"])
            ?? imageFromVersions(dict["image_versions"])
        guard let id, let image, let url = URL(string: image.replacingOccurrences(of: "\\/", with: "/")) else { return nil }
        return RemotePost(id: id, imageURL: url, caption: caption(from: dict))
    }

    private static func imageFromVersions(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any], let candidates = dict["candidates"] as? [[String: Any]] else { return nil }
        return candidates.first?["url"] as? String
    }

    private static func caption(from dict: [String: Any]) -> String {
        if let caption = dict["caption"] as? String { return caption }
        if let caption = dict["accessibility_caption"] as? String { return caption }
        if let caption = dict["edge_media_to_caption"] as? [String: Any],
           let edges = caption["edges"] as? [[String: Any]],
           let node = edges.first?["node"] as? [String: Any],
           let text = node["text"] as? String {
            return text
        }
        return ""
    }

    private static func unique(_ posts: [RemotePost]) -> [RemotePost] {
        var seen: Set<String> = []
        return posts.filter { seen.insert($0.id).inserted }
    }
}

private extension String {
    var htmlDecoded: String {
        replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\u0026", with: "&")
    }
}

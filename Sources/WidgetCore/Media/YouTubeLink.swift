import Foundation

/// A YouTube video reference parsed from any of the URL shapes people paste or drag.
public nonisolated struct YouTubeVideo: Codable, Hashable, Sendable, Identifiable {
    public var id: String { videoID }
    public var videoID: String
    /// Start offset in seconds (`t=1m30s`, `start=90`).
    public var start: Int?
    public var title: String?
    public var author: String?
    public var addedAt: Date

    public init(videoID: String, start: Int? = nil, title: String? = nil, author: String? = nil, addedAt: Date = Date()) {
        self.videoID = videoID
        self.start = start
        self.title = title
        self.author = author
        self.addedAt = addedAt
    }

    /// Medium-quality thumbnail served by YouTube's public image CDN.
    public var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg") }

    public var watchURL: URL? {
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: videoID)] + (start.map { [URLQueryItem(name: "t", value: "\($0)s")] } ?? [])
        return components?.url
    }
}

public nonisolated enum YouTubeLink {
    /// Video IDs are 11 characters from the URL-safe base64 alphabet.
    static func isVideoID(_ text: Substring) -> Bool {
        text.count == 11 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Parses watch, short (youtu.be), Shorts, embed, live and music.youtube.com links.
    /// Anything else (playlists without a video, channels, other sites) returns nil.
    public static func parse(_ text: String) -> YouTubeVideo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host?.lowercased() else { return nil }
        let hosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"]
        let query = components.queryItems ?? []
        let path = components.path.split(separator: "/")
        var id: Substring?
        if host == "youtu.be" {
            id = path.first
        } else if hosts.contains(host) {
            if path.first == "watch" {
                id = query.first { $0.name == "v" }?.value.map { Substring($0) }
            } else if path.count >= 2, ["shorts", "embed", "live", "v"].contains(path[0]) {
                id = path[1]
            }
        }
        guard let id, isVideoID(id) else { return nil }
        let startValue = query.first { $0.name == "t" || $0.name == "start" }?.value
        return YouTubeVideo(videoID: String(id), start: startValue.flatMap(parseTime))
    }

    /// "90", "90s", "1m30s", "1h2m3s" → seconds.
    static func parseTime(_ text: String) -> Int? {
        if let seconds = Int(text) { return seconds >= 0 ? seconds : nil }
        var total = 0
        var number = ""
        for character in text.lowercased() {
            if character.isNumber {
                number.append(character)
            } else {
                guard let value = Int(number) else { return nil }
                switch character {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                default: return nil
                }
                number = ""
            }
        }
        if !number.isEmpty { return nil }
        return total > 0 ? total : nil
    }

    /// Title and channel from YouTube's public oEmbed endpoint (no API key, no account).
    public static func fetchMetadata(for video: YouTubeVideo) async -> (title: String, author: String?)? {
        guard let watch = video.watchURL,
              var components = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: watch.absoluteString), URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String else { return nil }
        return (title, object["author_name"] as? String)
    }
}

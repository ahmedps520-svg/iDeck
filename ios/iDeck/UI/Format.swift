import Foundation
import SwiftUI
import UIKit

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func bytes(_ n: UInt64) -> String { bytes(Int64(clamping: n)) }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "—"
    }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }
}

/// Steam CDN artwork (public URLs) with a small in-memory cache.
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.totalCostLimit = 48 << 20 }

    static func url(appid: Int, kind: String) -> URL? {
        // kind: header (460x215), library_600x900, library_hero, capsule_616x353
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/\(kind).jpg")
    }

    func image(appid: Int, kind: String) async -> UIImage? {
        let key = "\(appid)/\(kind)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let url = ArtworkCache.url(appid: appid, kind: kind),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key, cost: data.count)
        return img
    }

    func purge() { cache.removeAllObjects() }
}

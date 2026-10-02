#if DEBUG
import Foundation
import UIKit

/// Canned Wallhaven responses for UI tests (launch argument `-wallhaven.mock YES`): six
/// wallpapers whose thumbnails and images are generated solid-color JPEGs. No network.
final class WallhavenStubProtocol: URLProtocol {
    static let isEnabled = UserDefaults.standard.bool(forKey: "wallhaven.mock")

    private static let palette: [(String, UIColor)] = [
        ("stub01", .systemTeal), ("stub02", .systemIndigo), ("stub03", .systemOrange),
        ("stub04", .systemPink), ("stub05", .systemGreen), ("stub06", .systemPurple),
    ]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.hasSuffix("wallhaven.cc")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (data, type) = Self.response(for: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func response(for url: URL) -> (Data, String) {
        if url.path.hasSuffix("/search") { return (searchJSON(), "application/json") }
        if let id = url.path.components(separatedBy: "/w/").last, url.path.contains("/api/v1/w/") {
            return (infoJSON(id: id), "application/json")
        }
        let id = palette.first { url.absoluteString.contains($0.0) }
        return (image(color: id?.1 ?? .gray), "image/jpeg")
    }

    private static func entry(_ id: String, withDetails: Bool) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id, "url": "https://wallhaven.cc/w/\(id)", "short_url": "https://whvn.cc/\(id)",
            "views": 100, "favorites": 5, "source": "", "purity": "sfw", "category": "general",
            "dimension_x": 2732, "dimension_y": 2048, "resolution": "2732x2048", "ratio": "1.33",
            "file_size": 412_000, "file_type": "image/jpeg", "colors": ["0066cc"],
            "path": "https://w.wallhaven.cc/full/st/wallhaven-\(id).jpg",
            "thumbs": ["large": "https://th.wallhaven.cc/lg/st/\(id).jpg",
                       "original": "https://th.wallhaven.cc/orig/st/\(id).jpg",
                       "small": "https://th.wallhaven.cc/small/st/\(id).jpg"],
        ]
        if withDetails {
            entry["uploader"] = ["username": "stubartist"]
            entry["tags"] = [["id": 1, "name": "landscape"], ["id": 2, "name": "minimal"]]
        }
        return entry
    }

    private static func searchJSON() -> Data {
        let body: [String: Any] = [
            "data": palette.map { entry($0.0, withDetails: false) },
            "meta": ["current_page": 1, "last_page": 1, "per_page": 24, "total": palette.count],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func infoJSON(id: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["data": entry(id, withDetails: true)])
    }

    private static func image(color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).jpegData(withCompressionQuality: 0.8) { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
    }
}
#endif

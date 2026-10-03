import CryptoKit
import SwiftUI
import UIKit

/// Icons and screenshots from AppStream's media servers, fetched over HTTPS when first
/// shown and kept in Caches/LinPadStore, so they show offline afterwards.
@MainActor
final class StoreImageLoader {
    static let shared = StoreImageLoader()

    private let memory = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let directory: URL?
    private let session: URLSession

    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LinPadStore", isDirectory: true),
         session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        memory.countLimit = 300
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    func cached(_ url: URL) -> UIImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        guard let file = file(for: url), let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    func image(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        if let task = inFlight[url] { return await task.value }
        let session = session
        let file = file(for: url)
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return nil }
            if let file { try? data.write(to: file, options: .atomic) }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    private func file(for url: URL) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32)) + "." + (url.pathExtension.isEmpty ? "img" : url.pathExtension))
    }
}

/// A remote image with a shimmering placeholder while loading and a quiet fallback when
/// it cannot be fetched (offline, or the server has no copy).
struct StoreRemoteImage<Fallback: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fit
    @ViewBuilder var fallback: () -> Fallback
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else if failed || url == nil {
                fallback()
            } else {
                StoreSkeleton()
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let hit = StoreImageLoader.shared.cached(url) {
                image = hit
                return
            }
            image = nil
            failed = false
            let loaded = await StoreImageLoader.shared.image(url)
            image = loaded
            failed = loaded == nil
        }
    }
}

/// A loading placeholder that pulses gently in the theme's colours.
struct StoreSkeleton: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 8
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.primaryText.opacity(bright ? 0.10 : 0.05))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
            }
            .accessibilityHidden(true)
    }
}

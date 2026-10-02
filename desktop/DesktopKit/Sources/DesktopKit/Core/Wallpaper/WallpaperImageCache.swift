import CoreImage
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Originals in Application Support/Wallpapers; screen-sized and blurred copies in
/// Caches/Wallpapers, made once with ImageIO's thumbnailer (HEIC, JPEG, PNG and WebP alike)
/// so the full-size original is never decoded on screen.
final class WallpaperImageCache: @unchecked Sendable {
    let originalsDirectory: URL
    let cacheDirectory: URL
    private let fileManager = FileManager.default
    /// The blurred variant only feeds a blur, so a small bitmap is enough.
    static let blurredPixelSize: CGFloat = 640

    init(root: URL? = nil) {
        let support = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        originalsDirectory = support.appendingPathComponent("Wallpapers", isDirectory: true)
        cacheDirectory = caches.appendingPathComponent(root == nil ? "Wallpapers" : "WallpaperCache", isDirectory: true)
        try? fileManager.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
    }

    func storeOriginal(_ data: Data, fileName: String) throws {
        try data.write(to: originalsDirectory.appendingPathComponent(fileName), options: .atomic)
    }

    func removeOriginal(_ fileName: String, id: String) {
        try? fileManager.removeItem(at: originalsDirectory.appendingPathComponent(fileName))
        let prefix = "\(id)-"
        for file in (try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [] where file.hasPrefix(prefix) {
            try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent(file))
        }
    }

    func originalURL(fileName: String) -> URL {
        if fileName.hasPrefix(BuiltInWallpapers.prefix) {
            return BuiltInWallpapers.url(for: fileName) ?? originalsDirectory.appendingPathComponent(fileName)
        }
        return originalsDirectory.appendingPathComponent(fileName)
    }

    /// The screen-sized and blurred bitmaps for an image, decoded off the main thread.
    func screenImages(fileName: String, id: String, maxPixelSize: CGSize) async -> (sharp: UIImage, blurred: UIImage)? {
        await Task.detached(priority: .userInitiated) { [self] in
            let edge = max(maxPixelSize.width, maxPixelSize.height)
            guard let sharp = self.downsampled(fileName: fileName, id: id, maxPixel: edge, suffix: "\(Int(edge))"),
                  let blurred = self.blurredImage(fileName: fileName, id: id) else { return nil }
            return (sharp, blurred)
        }.value
    }

    /// Reads the cached copy, or makes it from the original. Exposed for tests.
    func downsampled(fileName: String, id: String, maxPixel: CGFloat, suffix: String) -> UIImage? {
        let cached = cacheDirectory.appendingPathComponent("\(id)-\(suffix).jpg")
        if let image = Self.decode(url: cached) { return image }
        guard let cgImage = Self.thumbnail(url: originalURL(fileName: fileName), maxPixel: maxPixel) else { return nil }
        if let destination = CGImageDestinationCreateWithURL(cached as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        return UIImage(cgImage: cgImage).preparingForDisplay() ?? UIImage(cgImage: cgImage)
    }

    private func blurredImage(fileName: String, id: String) -> UIImage? {
        let cached = cacheDirectory.appendingPathComponent("\(id)-blur.jpg")
        if let image = Self.decode(url: cached) { return image }
        guard let small = Self.thumbnail(url: originalURL(fileName: fileName), maxPixel: Self.blurredPixelSize) else { return nil }
        let input = CIImage(cgImage: small)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 24)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.1])
            .cropped(to: input.extent)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let output = context.createCGImage(blurred, from: input.extent) else { return nil }
        if let destination = CGImageDestinationCreateWithURL(cached as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        return UIImage(cgImage: output)
    }

    static func thumbnail(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func decode(url: URL) -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path), let image = UIImage(contentsOfFile: url.path) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

/// The wallpapers that ship with the desktop (Resources/Wallpapers, CC0; see CREDITS.md).
enum BuiltInWallpapers {
    static let prefix = "builtin-"
    static let names = ["dunes", "peaks", "nebula", "waves"]

    static func url(for fileName: String) -> URL? {
        let name = String(fileName.dropFirst(prefix.count)).replacingOccurrences(of: ".jpg", with: "")
        return Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "Wallpapers")
    }

    static func install(into library: inout [WallpaperItem], cache: WallpaperImageCache) {
        for name in names.reversed() where !library.contains(where: { $0.id == prefix + name }) {
            library.append(WallpaperItem(id: prefix + name, fileName: "\(prefix)\(name).jpg", origin: .builtIn,
                                         attribution: "iSH built-in wallpaper (CC0)"))
        }
    }
}

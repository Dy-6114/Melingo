import AppKit
import ImageIO

/// Loads Telegram sticker / custom-emoji rasters (static + animated WebP/GIF → first frame).
enum TelegramRasterImage {
    private final class ImageCache: @unchecked Sendable {
        let store = NSCache<NSURL, NSImage>()
    }

    private static let cache = ImageCache()

    static func load(at url: URL, maxPixelSize: CGFloat? = nil) -> NSImage? {
        let key = url as NSURL
        if let cached = cache.store.object(forKey: key) {
            return cached
        }
        guard let image = decode(at: url, maxPixelSize: maxPixelSize) else { return nil }
        cache.store.setObject(image, forKey: key)
        return image
    }

    static func loadUncached(at url: URL, maxPixelSize: CGFloat? = nil) -> NSImage? {
        decode(at: url, maxPixelSize: maxPixelSize)
    }

    private static func decode(at url: URL, maxPixelSize: CGFloat?) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else {
            return NSImage(contentsOf: url).flatMap { $0.size.width > 0 ? $0 : nil }
        }

        var createOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
        ]
        if let maxPixelSize, maxPixelSize > 0 {
            createOpts[kCGImageSourceCreateThumbnailFromImageAlways] = true
            createOpts[kCGImageSourceCreateThumbnailWithTransform] = true
            createOpts[kCGImageSourceThumbnailMaxPixelSize] = Int(maxPixelSize)
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, createOpts as CFDictionary) {
                return nsImage(from: thumb)
            }
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, createOpts as CFDictionary) else {
            return nil
        }
        return nsImage(from: cgImage)
    }

    private static func nsImage(from cgImage: CGImage) -> NSImage {
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = false
        return image
    }

    static func isRasterPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["webp", "png", "jpg", "jpeg", "gif", "tif", "tiff"].contains(ext)
    }
}

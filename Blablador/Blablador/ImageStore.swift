import AVFoundation
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Stores chat images as files so the conversation JSON stays small.
enum ImageStore {
    private static var directory: URL {
        let url = AppFolder.url
            .appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A decrypted copy, for sharing.
    static func url(for name: String) -> URL {
        EncryptedStorage.decryptedCopy(of: directory.appendingPathComponent(name))
    }

    /// Saves image data encrypted and returns its file name.
    static func save(_ data: Data) -> String {
        let name = UUID().uuidString + (isPNG(data) ? ".png" : ".jpg")
        EncryptedStorage.write(data, to: directory.appendingPathComponent(name))
        return name
    }

    static func data(for name: String) -> Data? {
        EncryptedStorage.readFile(directory.appendingPathComponent(name), isPlain: EncryptedStorage.isMedia)
    }

    static func delete(_ names: [String]) {
        for name in names { EncryptedStorage.delete(directory.appendingPathComponent(name)) }
    }

    static func cgImage(for name: String, maxPixelSize: Int? = nil) -> CGImage? {
        guard let data = data(for: name), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return cgImage(from: source, maxPixelSize: maxPixelSize)
    }

    /// Downscales and re-encodes as JPEG, which keeps uploads to the API small.
    static func jpeg(from data: Data, maxPixelSize: Int = 1536, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = cgImage(from: source, maxPixelSize: maxPixelSize) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func cgImage(from source: CGImageSource, maxPixelSize: Int?) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }
}

/// Displays a stored chat image.
struct StoredImage: View {
    let name: String
    var maxPixelSize: Int? = 1200

    var body: some View {
        if let image = ImageStore.cgImage(for: name, maxPixelSize: maxPixelSize) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

/// Generated videos, kept next to the images.
enum VideoStore {
    private static var directory: URL {
        let url = AppFolder.url
            .appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A decrypted copy, for playing, sharing and saving.
    static func url(for name: String) -> URL { EncryptedStorage.decryptedCopy(of: directory.appendingPathComponent(name)) }

    static func save(_ data: Data) -> String {
        let name = UUID().uuidString + ".mp4"
        EncryptedStorage.write(data, to: directory.appendingPathComponent(name))
        return name
    }

    static func delete(_ names: [String]) {
        for name in names { EncryptedStorage.delete(directory.appendingPathComponent(name)) }
    }

    /// The final frame as JPEG, for continuing the video.
    static func lastFrame(of name: String) async -> Data? {
        let asset = AVURLAsset(url: url(for: name))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let duration = try? await asset.load(.duration) else { return nil }
        // A little before the end: the very last timestamp often has no frame.
        let time = CMTimeSubtract(duration, CMTime(value: 1, timescale: 24))
        guard let image = try? await generator.image(at: time).image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor CompanionMediaArtworkNormalizer {
    private let maximumEncodedCharacters: Int
    private let maximumPixelDimension: Int
    private var cachedSourceHash: String?
    private var cachedArtwork: SanitizedMediaArtwork?

    init(
        maximumEncodedCharacters: Int = 16 * 1024 * 1024,
        maximumPixelDimension: Int = 512
    ) {
        self.maximumEncodedCharacters = maximumEncodedCharacters
        self.maximumPixelDimension = maximumPixelDimension
    }

    func normalize(_ encodedArtwork: String?) -> SanitizedMediaArtwork? {
        guard let encodedArtwork,
              encodedArtwork.utf8.count <= maximumEncodedCharacters,
              let sourceData = decode(encodedArtwork)
        else {
            return nil
        }
        return normalizeSourceData(sourceData)
    }

    func normalize(_ sourceData: Data?) -> SanitizedMediaArtwork? {
        guard let sourceData,
              sourceData.count <= maximumEncodedCharacters
        else {
            return nil
        }
        return normalizeSourceData(sourceData)
    }

    private func normalizeSourceData(_ sourceData: Data) -> SanitizedMediaArtwork? {
        let sourceHash = sourceData.sha256()
        if cachedSourceHash == sourceHash {
            return cachedArtwork
        }
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let pngData = output as Data
        let artwork = SanitizedMediaArtwork(
            pngData: pngData,
            contentHash: pngData.sha256(),
            pixelWidth: image.width,
            pixelHeight: image.height
        )
        cachedSourceHash = sourceHash
        cachedArtwork = artwork
        return artwork
    }

    private func decode(_ value: String) -> Data? {
        let base64: Substring
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ","),
                  value[..<comma].lowercased().contains(";base64")
            else {
                return nil
            }
            base64 = value[value.index(after: comma)...]
        } else {
            base64 = value[...]
        }
        return Data(base64Encoded: String(base64))
    }
}

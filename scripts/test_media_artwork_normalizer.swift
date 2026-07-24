import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

@main
private enum MediaArtworkNormalizerHarness {
    static func main() async throws {
        let source = try makePNG(width: 1_024, height: 768)
        let normalizer = CompanionMediaArtworkNormalizer()
        guard let first = await normalizer.normalize(source.base64EncodedString()),
              let second = await normalizer.normalize(source.base64EncodedString())
        else {
            throw HarnessFailure.assertion("valid artwork was rejected")
        }

        try expect(first.pixelWidth == 512, "artwork width was not bounded")
        try expect(first.pixelHeight == 384, "artwork aspect ratio was not preserved")
        try expect(
            first.contentHash == first.pngData.sha256(),
            "content hash was not derived from normalized PNG bytes"
        )
        try expect(first.contentHash == second.contentHash, "normalization was not deterministic")
        guard let downloaded = await normalizer.normalize(source) else {
            throw HarnessFailure.assertion("downloaded artwork bytes were rejected")
        }
        try expect(
            downloaded.contentHash == first.contentHash,
            "downloaded artwork bytes used a different normalization path"
        )
        let invalidArtwork = await normalizer.normalize("not-base64")
        try expect(
            invalidArtwork == nil,
            "invalid artwork was accepted"
        )

        print("Media artwork normalization behavior passed")
    }

    private static func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw HarnessFailure.assertion("could not create source context")
        }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw HarnessFailure.assertion("could not create source image")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw HarnessFailure.assertion("could not create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HarnessFailure.assertion("could not encode source PNG")
        }
        return data as Data
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw HarnessFailure.assertion(message) }
    }
}

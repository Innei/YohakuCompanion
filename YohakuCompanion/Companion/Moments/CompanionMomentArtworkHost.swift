import Foundation

actor CompanionMomentArtworkHost {
    private struct HostedKey: Hashable, Sendable {
        let contentHash: String
        let targetFingerprint: String
    }

    private let uploader: any CompanionMediaArtworkUploading
    private var hostedKeys = Set<HostedKey>()

    init(
        uploader: any CompanionMediaArtworkUploading = S3CompanionMediaArtworkUploader()
    ) {
        self.uploader = uploader
    }

    func host(
        _ artwork: SanitizedMediaArtwork,
        configuration: CompanionMediaArtworkHostingConfiguration
    ) async throws -> URL {
        guard artwork.contentHash.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil else {
            throw CompanionMediaArtworkHostingError.invalidPublicURL
        }

        let objectKey = [
            configuration.basePath,
            "recently",
            "media-artwork",
            String(artwork.contentHash.prefix(2)),
            "\(artwork.contentHash).png",
        ].joined(separator: "/")
        let publicURL = try uploader.publicURL(
            for: objectKey,
            configuration: configuration
        )
        guard let components = URLComponents(
            url: publicURL,
            resolvingAgainstBaseURL: false
        ),
        components.scheme?.lowercased() == "https",
        components.host?.isEmpty == false,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        publicURL.absoluteString.utf8.count <= 2_048
        else {
            throw CompanionMediaArtworkHostingError.invalidPublicURL
        }

        let hostedKey = HostedKey(
            contentHash: artwork.contentHash,
            targetFingerprint: configuration.targetFingerprint
        )
        if !hostedKeys.contains(hostedKey) {
            try await uploader.upload(
                artwork.pngData,
                objectKey: objectKey,
                configuration: configuration
            )
            hostedKeys.insert(hostedKey)
        }
        return publicURL
    }
}

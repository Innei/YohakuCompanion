import Foundation

struct CompanionMediaArtworkHostingConfiguration: Equatable, Sendable {
    let bucket: String
    let region: String
    let accessKey: String
    let secretKey: String
    let endpoint: String?
    let customDomain: String?
    let basePath: String

    init(
        bucket: String,
        region: String,
        accessKey: String,
        secretKey: String,
        endpoint: String?,
        customDomain: String?,
        basePath: String
    ) {
        self.bucket = bucket
        self.region = region
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.endpoint = endpoint
        self.customDomain = customDomain
        self.basePath = basePath
    }

    var targetFingerprint: String {
        Data(
            [bucket, region, endpoint ?? "", customDomain ?? "", basePath]
                .joined(separator: "\u{0}")
                .utf8
        ).sha256()
    }

}

protocol CompanionMediaArtworkUploading: Sendable {
    func publicURL(
        for objectKey: String,
        configuration: CompanionMediaArtworkHostingConfiguration
    ) throws -> URL

    func upload(
        _ data: Data,
        objectKey: String,
        configuration: CompanionMediaArtworkHostingConfiguration
    ) async throws
}

enum CompanionMediaArtworkHostingError: Error, Equatable, Sendable {
    case invalidPublicURL
}

actor CompanionMediaArtworkHost {
    private struct HostedArtwork: Equatable, Sendable {
        let contentHash: String
        let deviceID: String
        let targetFingerprint: String
        let publicURL: URL
    }

    private let uploader: any CompanionMediaArtworkUploading
    private var latestHostedArtwork: HostedArtwork?

    init(uploader: any CompanionMediaArtworkUploading) {
        self.uploader = uploader
    }

    func host(
        _ artwork: SanitizedMediaArtwork,
        deviceID: String,
        configuration: CompanionMediaArtworkHostingConfiguration
    ) async throws -> SanitizedMediaArtwork {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard artwork.contentHash.unicodeScalars.count == 64,
              artwork.contentHash.unicodeScalars.allSatisfy(lowercaseHex.contains)
        else {
            throw CompanionMediaArtworkHostingError.invalidPublicURL
        }
        let deviceNamespace = Data(deviceID.utf8).sha256()
        let objectKey = [
            configuration.basePath,
            "media-artwork",
            deviceNamespace,
            "current.png",
        ].joined(separator: "/")
        let baseURL = try uploader.publicURL(
            for: objectKey,
            configuration: configuration
        )
        guard let baseComponents = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ),
        baseComponents.scheme?.lowercased() == "https",
        baseComponents.user == nil,
        baseComponents.password == nil,
        baseComponents.fragment == nil,
        baseComponents.host?.isEmpty == false
        else {
            throw CompanionMediaArtworkHostingError.invalidPublicURL
        }

        var versionedComponents = baseComponents
        versionedComponents.queryItems = [
            URLQueryItem(name: "v", value: artwork.contentHash),
        ]
        guard let versionedURL = versionedComponents.url,
              versionedURL.absoluteString.utf8.count <= 2_048
        else {
            throw CompanionMediaArtworkHostingError.invalidPublicURL
        }

        let hosted = HostedArtwork(
            contentHash: artwork.contentHash,
            deviceID: deviceID,
            targetFingerprint: configuration.targetFingerprint,
            publicURL: versionedURL
        )
        if latestHostedArtwork == hosted {
            return artwork.hosted(at: versionedURL)
        }

        // The public URL is published only after the replacement object is
        // durable. A failed PUT therefore leaves the Presence text-only.
        try await uploader.upload(
            artwork.pngData,
            objectKey: objectKey,
            configuration: configuration
        )
        latestHostedArtwork = hosted
        return artwork.hosted(at: versionedURL)
    }

}

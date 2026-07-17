import Foundation

extension CompanionMediaArtworkHostingConfiguration {
    init?(integration: S3Integration) {
        guard integration.isEnabled,
              integration.isValidAssetHostingConfiguration
        else {
            return nil
        }

        let normalizedEndpoint = integration.endpoint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedCustomDomain = integration.customDomain.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let configuredPath = integration.path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.init(
            bucket: integration.bucket,
            region: integration.region,
            accessKey: integration.accessKey,
            secretKey: integration.secretKey,
            endpoint: normalizedEndpoint.isEmpty ? nil : normalizedEndpoint,
            customDomain: normalizedCustomDomain.isEmpty ? nil : normalizedCustomDomain,
            basePath: configuredPath.isEmpty ? "app-icons" : configuredPath
        )
    }

    fileprivate func makeUploader() -> S3Uploader {
        S3Uploader(
            options: S3UploaderOptions(
                bucket: bucket,
                region: region,
                accessKey: accessKey,
                secretKey: secretKey,
                endpoint: endpoint,
                customDomain: customDomain
            )
        )
    }
}

struct S3CompanionMediaArtworkUploader: CompanionMediaArtworkUploading {
    func publicURL(
        for objectKey: String,
        configuration: CompanionMediaArtworkHostingConfiguration
    ) throws -> URL {
        try configuration.makeUploader().publicURL(for: objectKey)
    }

    func upload(
        _ data: Data,
        objectKey: String,
        configuration: CompanionMediaArtworkHostingConfiguration
    ) async throws {
        try await configuration.makeUploader().uploadToS3(
            objectKey: objectKey,
            fileData: data,
            contentType: "image/png",
            cacheControl: "public, max-age=31536000, immutable"
        )
    }
}

import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

private actor UploadRecorder {
    private(set) var objectKeys: [String] = []

    func record(_ objectKey: String) {
        objectKeys.append(objectKey)
    }
}

private struct RecordingUploader: CompanionMediaArtworkUploading {
    let recorder: UploadRecorder
    let baseURL: URL

    init(
        recorder: UploadRecorder,
        baseURL: URL = URL(string: "https://media.example.com")!
    ) {
        self.recorder = recorder
        self.baseURL = baseURL
    }

    func publicURL(
        for objectKey: String,
        configuration _: CompanionMediaArtworkHostingConfiguration
    ) throws -> URL {
        URL(string: "\(baseURL.absoluteString)/\(objectKey)")!
    }

    func upload(
        _: Data,
        objectKey: String,
        configuration _: CompanionMediaArtworkHostingConfiguration
    ) async throws {
        await recorder.record(objectKey)
    }
}

@main
private enum MediaArtworkHostHarness {
    static func main() async throws {
        let recorder = UploadRecorder()
        let host = CompanionMediaArtworkHost(
            uploader: RecordingUploader(recorder: recorder)
        )
        let configuration = CompanionMediaArtworkHostingConfiguration(
            bucket: "bucket",
            region: "auto",
            accessKey: "access",
            secretKey: "secret",
            endpoint: "https://account.r2.cloudflarestorage.com",
            customDomain: "https://media.example.com",
            basePath: "assets"
        )
        let first = artwork(byte: 1)
        let firstHosted = try await host.host(
            first,
            deviceID: "01K0A4VDWYSH1JQH4PGY4QM8YT",
            configuration: configuration
        )
        let duplicateHosted = try await host.host(
            first,
            deviceID: "01K0A4VDWYSH1JQH4PGY4QM8YT",
            configuration: configuration
        )
        let secondHosted = try await host.host(
            artwork(byte: 2),
            deviceID: "01K0A4VDWYSH1JQH4PGY4QM8YT",
            configuration: configuration
        )

        let keys = await recorder.objectKeys
        let deviceNamespace = Data(
            "01K0A4VDWYSH1JQH4PGY4QM8YT".utf8
        ).sha256()
        try expect(keys.count == 2, "identical artwork triggered a second upload")
        try expect(
            Set(keys) == ["assets/media-artwork/\(deviceNamespace)/current.png"],
            "artwork did not overwrite one stable object key"
        )
        try expect(
            firstHosted.publicURL == duplicateHosted.publicURL,
            "identical artwork did not reuse its cache key"
        )
        try expect(
            firstHosted.publicURL != secondHosted.publicURL,
            "changed artwork did not receive a new cache version"
        )

        do {
            _ = try await CompanionMediaArtworkHost(
                uploader: RecordingUploader(
                    recorder: recorder,
                    baseURL: URL(string: "http://media.example.com")!
                )
            ).host(
                first,
                deviceID: "01K0A4VDWYSH1JQH4PGY4QM8YT",
                configuration: configuration
            )
            throw HarnessFailure.assertion("an insecure public URL was uploaded")
        } catch CompanionMediaArtworkHostingError.invalidPublicURL {
            // Expected.
        }
        let keysAfterInsecureURL = await recorder.objectKeys
        try expect(
            keysAfterInsecureURL.count == 2,
            "public URL was validated after uploading"
        )

        do {
            _ = try await CompanionMediaArtworkHost(
                uploader: RecordingUploader(recorder: recorder)
            ).host(
                SanitizedMediaArtwork(
                    pngData: Data([3]),
                    contentHash: "not-a-sha256",
                    pixelWidth: 1,
                    pixelHeight: 1
                ),
                deviceID: "01K0A4VDWYSH1JQH4PGY4QM8YT",
                configuration: configuration
            )
            throw HarnessFailure.assertion("invalid artwork hash was uploaded")
        } catch CompanionMediaArtworkHostingError.invalidPublicURL {
            // Expected.
        }
        let keysAfterInvalidHash = await recorder.objectKeys
        try expect(
            keysAfterInvalidHash.count == 2,
            "artwork hash was checked after uploading"
        )

        print("Media artwork single-object hosting behavior passed")
    }

    private static func artwork(byte: UInt8) -> SanitizedMediaArtwork {
        let data = Data([byte])
        return SanitizedMediaArtwork(
            pngData: data,
            contentHash: data.sha256(),
            pixelWidth: 1,
            pixelHeight: 1
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw HarnessFailure.assertion(message) }
    }
}

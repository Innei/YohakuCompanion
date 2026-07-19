import Foundation

struct CompanionMomentOutboxEntry: Codable, Equatable, Sendable {
    let request: CompanionMomentRequestV1
    let enqueuedAt: Date
}

actor CompanionMomentOutbox {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            let namespace = Bundle.main.bundleIdentifier ?? "dev.innei.YohakuCompanion"
            self.directoryURL = applicationSupport
                .appendingPathComponent(namespace, isDirectory: true)
                .appendingPathComponent("moment-outbox", isDirectory: true)
        }
    }

    func enqueue(_ request: CompanionMomentRequestV1) throws {
        try ensureDirectory()
        let entry = CompanionMomentOutboxEntry(request: request, enqueuedAt: Date())
        let data = try CompanionJSON.makeEncoder().encode(entry)
        try data.write(to: fileURL(for: request.meta.requestID), options: .atomic)
    }

    func entries() throws -> [CompanionMomentOutboxEntry] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? CompanionJSON.makeDecoder().decode(
                CompanionMomentOutboxEntry.self,
                from: data
            )
        }
        .sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    func remove(requestID: String) throws {
        let url = fileURL(for: requestID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func count() throws -> Int {
        try entries().count
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func fileURL(for requestID: String) -> URL {
        directoryURL.appendingPathComponent("\(requestID).json", isDirectory: false)
    }
}

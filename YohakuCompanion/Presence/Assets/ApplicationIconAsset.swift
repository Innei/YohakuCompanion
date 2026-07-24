import Foundation

/// Local-only application icon input produced after application-sharing policy
/// has allowed the current process. Only the resulting public URL may enter a
/// sanitized Presence snapshot or leave the device.
struct ApplicationIconAsset: Equatable, Sendable {
    let applicationIdentifier: String
    let displayName: String?
    let pngData: Data?
}

import Foundation

/// LOCKED
/// Best-effort reconstruction from scope because the spec docs are absent.
/// Keep the case names, order, and associated-value shapes in sync unless the
/// senior engineer explicitly changes them.
/// Cases:
/// 1. idle
/// 2. checking
/// 3. updateAvailable
/// 4. downloading
/// 5. extracting
/// 6. readyToInstall
/// 7. installing
/// 8. noUpdateAvailable
/// 9. error
enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case updateAvailable(version: String, releaseNotes: String?)
    case downloading(version: String, receivedBytes: UInt64, totalBytes: UInt64?)
    case extracting(version: String, progress: Double)
    case readyToInstall(version: String, releaseNotes: String?)
    case installing(version: String)
    case noUpdateAvailable
    case error(message: String)
}

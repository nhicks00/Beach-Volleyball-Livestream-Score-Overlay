import Foundation

/// A simple, thread-safe store to hold the latest raw JSON data for each court.
/// The local WebSocketHub server reads from this store to serve data to the HTML overlay.
final class OverlayStore {
    static let shared = OverlayStore()
    private var rawByCourt: [Int: Data] = [:]
    private let lock = NSLock()

    private init() {} // Singleton

    func setRaw(courtId: Int, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        rawByCourt[courtId] = data
    }

    func getRaw(courtId: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return rawByCourt[courtId]
    }
}

import Foundation

/// The card's listing, kept between launches.
///
/// cmd=3015 returns every record on the card in one document — 83 clips took
/// 682 ms on a real unit, and a full card is several times that. Showing the
/// last known listing immediately, then replacing it with a fresh one, is the
/// difference between a screen that appears and a screen that spins.
///
/// What is stored is metadata only: names, sizes, timestamps and the lock
/// flag. No clip is ever cached; those are tens of megabytes each and belong
/// on the card until someone asks for one.
struct LibraryCache {
    private let url: URL

    /// Kept per camera, so two cameras cannot show each other's cards.
    init(cameraID: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = cameraID.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        url = base.appendingPathComponent("listing-\(String(safe)).json")
    }

    struct Stored: Codable {
        let fetchedAt: Date
        let files: [MediaFile]
    }

    func load() -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    func save(_ files: [MediaFile]) {
        let stored = Stored(fetchedAt: Date(), files: files)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

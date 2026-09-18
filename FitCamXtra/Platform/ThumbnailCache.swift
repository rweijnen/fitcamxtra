import Foundation
import UIKit

/// Thumbnails on disk, so they survive a relaunch.
///
/// A clip is immutable and its name is unique, so a thumbnail for it is
/// correct forever. Re-downloading them all on every launch costs the one
/// thing this camera has least of, which is time on its HTTP server.
///
/// Caches, not Application Support: losing these costs a refetch, not data.
final class ThumbnailCache: @unchecked Sendable {
    private let directory: URL
    private let byteLimit: Int
    private let queue = DispatchQueue(label: "nl.remkoweijnen.fitcamxtra.thumbnails")

    /// The most recent are also kept decoded, because scrolling asks for the
    /// same handful repeatedly.
    private let memory = NSCache<NSString, UIImage>()

    init(byteLimit: Int = 40 * 1024 * 1024) {
        self.byteLimit = byteLimit
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Thumbnails", isDirectory: true)
        memory.countLimit = 240
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for key: String) -> UIImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        memory.setObject(image, forKey: key as NSString)
        // Touched so the trim keeps what is being looked at.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    func store(_ data: Data, image: UIImage, for key: String) {
        memory.setObject(image, forKey: key as NSString)
        queue.async { [directory, byteLimit] in
            try? data.write(to: directory.appendingPathComponent(Self.fileName(for: key)), options: .atomic)
            Self.trim(directory: directory, to: byteLimit)
        }
    }

    func contains(_ key: String) -> Bool {
        if memory.object(forKey: key as NSString) != nil { return true }
        return FileManager.default.fileExists(atPath: fileURL(for: key).path)
    }

    func clear() {
        memory.removeAllObjects()
        queue.async { [directory] in
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: key))
    }

    /// A path is not a filename: the camera's own form carries a drive letter
    /// and backslashes. Only the characters that survive a file system are
    /// kept, with a hash to keep two different paths apart.
    private static func fileName(for key: String) -> String {
        let safe = key.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return "\(String(safe).suffix(60))-\(Self.digest(of: key))"
    }

    /// FNV-1a, not `hashValue`: Swift seeds hashing per process, so a
    /// `hashValue` filename is different on every launch. The cache looked for
    /// files that could not exist, re-downloaded the card's thumbnails every
    /// time, and wrote a duplicate of each — the exact opposite of what this
    /// type is for.
    private static func digest(of key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    /// Oldest touched first, until the directory is back under the limit.
    private static func trim(directory: URL, to byteLimit: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }

        let described = entries.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }

        var total = described.reduce(0) { $0 + $1.1 }
        guard total > byteLimit else { return }

        for entry in described.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
            if total <= byteLimit { return }
        }
    }
}

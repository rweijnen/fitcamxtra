import Foundation

/// What a download has done so far, in the terms someone watching it cares
/// about: how much of it has arrived, how fast, and how long is left.
///
/// A bare percentage was not enough on this camera. A clip is 80 MB over the
/// camera's own wifi and takes minutes, and "Saving 15%" tells you neither
/// whether it is moving nor whether it is worth waiting for.
public struct TransferProgress: Sendable, Equatable {
    public let bytesReceived: Int64
    /// Nil when the server never said how big the file is.
    public let totalBytes: Int64?
    /// Bytes per second over the transfer so far.
    public let bytesPerSecond: Double

    public init(bytesReceived: Int64, totalBytes: Int64?, bytesPerSecond: Double) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(Double(bytesReceived) / Double(totalBytes), 1)
    }

    /// Seconds left at the speed seen so far. Nil when there is nothing to
    /// base it on, rather than a number made up from one chunk.
    public var secondsRemaining: Double? {
        guard let totalBytes, totalBytes > bytesReceived, bytesPerSecond > 1024 else { return nil }
        return Double(totalBytes - bytesReceived) / bytesPerSecond
    }

    // MARK: - Labels

    public var receivedLabel: String { Self.size(bytesReceived) }

    public var sizeLabel: String {
        guard let totalBytes, totalBytes > 0 else { return Self.size(bytesReceived) }
        return "\(Self.size(bytesReceived)) of \(Self.size(totalBytes))"
    }

    public var speedLabel: String? {
        guard bytesPerSecond > 1024 else { return nil }
        return "\(Self.size(Int64(bytesPerSecond)))/s"
    }

    public var remainingLabel: String? {
        guard let seconds = secondsRemaining else { return nil }
        if seconds < 90 { return "\(Int(seconds.rounded())) s left" }
        return "\(Int((seconds / 60).rounded())) min left"
    }

    /// The whole line: what has arrived, how fast, how long left.
    public var detailLabel: String {
        [sizeLabel, speedLabel, remainingLabel]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }

    public static func size(_ bytes: Int64) -> String {
        let units: [(Double, String)] = [(1_073_741_824, "GB"), (1_048_576, "MB"), (1024, "KB")]
        for (scale, suffix) in units where Double(bytes) >= scale {
            let value = Double(bytes) / scale
            return value >= 10
                ? String(format: "%.0f %@", value, suffix)
                : String(format: "%.1f %@", value, suffix)
        }
        return "\(bytes) B"
    }
}

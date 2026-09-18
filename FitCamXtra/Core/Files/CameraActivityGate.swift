import Foundation

/// Keeps background work off the camera's back while someone is waiting on it.
///
/// The camera is a small embedded server on its own wifi. It serves one thing
/// at a time well and several things badly: an 80 MB download died mid-way
/// while thumbnail requests were being fired at it. So anything the app does
/// on its own initiative — filling the thumbnail cache, refreshing a listing
/// nobody asked for — waits here, and anything a person is watching happen
/// takes the camera for as long as it needs.
///
/// Portable: this is a scheduling decision, not an Apple one.
public actor CameraActivityGate {
    /// How many things a person is waiting on right now.
    private var interactiveCount = 0
    /// Resumed when the last of them finishes. Keyed so a waiter that is
    /// cancelled can take itself out again.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public var isBusy: Bool { interactiveCount > 0 }

    /// Runs `work` as something a person is waiting on. Background work yields
    /// for the duration.
    public func interactive<T: Sendable>(_ work: () async throws -> T) async rethrows -> T {
        interactiveCount += 1
        defer { finishInteractive() }
        return try await work()
    }

    /// For work whose start and end are not one scope, such as a live stream.
    public func beginInteractive() {
        interactiveCount += 1
    }

    public func endInteractive() {
        finishInteractive()
    }

    /// Background work calls this before each item. It returns immediately
    /// when nobody is waiting on the camera, once they are done, or at once
    /// if the caller is cancelled — a prefetch that is told to stop should
    /// not sit here until a live stream ends.
    public func waitUntilIdle() async {
        guard interactiveCount > 0 else { return }

        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    private func finishInteractive() {
        interactiveCount = max(interactiveCount - 1, 0)
        guard interactiveCount == 0, !waiters.isEmpty else { return }
        let resuming = waiters.values
        waiters.removeAll()
        for continuation in resuming {
            continuation.resume()
        }
    }
}

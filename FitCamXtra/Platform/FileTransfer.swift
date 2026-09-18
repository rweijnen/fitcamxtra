import Foundation

/// Downloads one file to disk, off the main thread, reporting progress as it
/// goes and able to pick up where a dropped connection left off.
///
/// Written against `URLSessionDataDelegate` rather than `URLSession.bytes`
/// because that sequence yields one byte at a time: an 80 MB clip is a hundred
/// million async resumptions, and the caller lives on the main actor, so the
/// transfer and every file write landed on the thread the UI runs on. The
/// delegate hands over whole chunks on its own queue instead.
///
/// One instance per attempt. The session is invalidated when it finishes,
/// because a delegate session retains its delegate until it is.
final class FileTransfer: NSObject, @unchecked Sendable {
    struct Result {
        let response: URLResponse
        /// Total bytes on disk afterwards, including anything a previous
        /// attempt left there.
        let bytesOnDisk: Int64
        /// True when the server honoured the range request and the new bytes
        /// were appended rather than replacing what was there.
        let resumed: Bool
    }

    enum TransferError: LocalizedError {
        case noResponse
        var errorDescription: String? { "The download ended without a reply." }
    }

    /// Serial: every callback touches the file handle and the counters.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "nl.remkoweijnen.fitcamxtra.transfer"
        return queue
    }()

    private var session: URLSession?
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Result, Error>?
    private var response: URLResponse?

    private var onProgress: (@Sendable (Double) -> Void)?
    private var landed: (@Sendable (Int64) -> Void)?

    private var offset: Int64 = 0
    private var written: Int64 = 0
    private var expected: Int64 = 0
    private var resumed = false
    private var lastReported = 0.0
    private var failure: Error?

    /// Appends the bytes missing from `destination` to it.
    ///
    /// - Parameters:
    ///   - offset: what is already on disk, and where to ask the server to
    ///     start. Zero for a first attempt.
    ///   - expected: the size the listing claims, used for progress when the
    ///     server does not say.
    ///   - landed: called with the running byte count as chunks are written,
    ///     so a failed attempt can still report how far it got.
    func run(
        url: URL,
        destination: URL,
        offset: Int64,
        expected: Int64,
        timeout: TimeInterval = 600,
        landed: @escaping @Sendable (Int64) -> Void,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Result {
        self.offset = offset
        self.written = offset
        self.expected = expected
        self.landed = landed
        self.onProgress = progress

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = timeout
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session

        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        handle = try FileHandle(forWritingTo: destination)

        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(with result: Swift.Result<Result, Error>) {
        try? handle?.close()
        handle = nil
        session?.finishTasksAndInvalidate()
        session = nil

        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension FileTransfer: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response

        // A server that ignores the range answers 200 and starts from the top,
        // so whatever is already on disk has to go.
        resumed = (response as? HTTPURLResponse)?.statusCode == 206
        if offset > 0 && !resumed {
            written = 0
        }
        do {
            // Cut back to what has actually been counted, so disk and counter
            // cannot disagree, then append from there.
            try handle?.truncate(atOffset: UInt64(written))
            try handle?.seekToEnd()
        } catch {
            failure = error
            dataTask.cancel()
            completionHandler(.cancel)
            return
        }
        landed?(written)

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }

        written += Int64(data.count)
        landed?(written)

        let reported = response?.expectedContentLength ?? -1
        let total = reported > 0 ? reported + (resumed ? offset : 0) : expected
        guard total > 0, let onProgress else { return }

        let fraction = min(Double(written) / Double(total), 1)
        // Only on visible movement: this drives a view.
        guard fraction - lastReported >= 0.01 else { return }
        lastReported = fraction
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error {
            finish(with: .failure(error))
            return
        }
        guard let response else {
            finish(with: .failure(TransferError.noResponse))
            return
        }
        finish(with: .success(Result(response: response, bytesOnDisk: written, resumed: resumed)))
    }
}

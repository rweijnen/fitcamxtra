import Foundation

/// Apple-side transport. Replaced wholesale on Android; nothing above this
/// file knows URLSession exists.
public final class URLSessionTransport: CameraTransport, @unchecked Sendable {
    private let session: URLSession

    public init(maxConnectionsPerHost: Int = 8) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        // The camera is a local device with no internet path. Waiting for
        // connectivity would stall every probe on a phone with no uplink.
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = true
        session = URLSession(configuration: configuration)
    }

    public func get(url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw CameraError.notReachable
            }
            return data
        } catch let error as CameraError {
            throw error
        } catch let error as URLError {
            throw error.code == .timedOut ? CameraError.timedOut : CameraError.notReachable
        }
    }
}

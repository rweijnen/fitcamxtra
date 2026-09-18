import AVFoundation
import Observation
import SwiftUI

/// Owns the RTSP session and the renderer, and exposes a state the Live screen
/// can show honestly: connecting, playing, or a reason it is not.
@Observable
@MainActor
final class LiveStream {
    enum Status: Equatable {
        case stopped
        case connecting
        case playing
        case failed(String)

        var isPlaying: Bool { self == .playing }
    }

    private(set) var status: Status = .stopped
    private(set) var framesRendered = 0

    @ObservationIgnored let renderer: VideoRenderer
    @ObservationIgnored private var client: RTSPClient?
    @ObservationIgnored private var host: String?
    @ObservationIgnored private let sink: LogSink
    /// Watching live is the most demanding thing the camera does, so the
    /// background prefetch stands down for as long as it runs.
    @ObservationIgnored private let gate: CameraActivityGate
    @ObservationIgnored private var holdsGate = false

    init(sink: LogSink, gate: CameraActivityGate) {
        self.sink = sink
        self.gate = gate
        self.renderer = VideoRenderer(sink: sink)
    }

    /// `camera` is used first: the stream has to be started over the CGI
    /// before the RTSP server will serve it.
    func start(host: String, camera: CameraClient?) {
        guard self.host != host || status == .stopped || isFailed else { return }
        stop()

        self.host = host
        status = .connecting
        renderer.reset()
        holdsGate = true
        Task { [gate] in await gate.beginInteractive() }

        Task { [weak self] in
            var streamURL: String?
            if let camera {
                do {
                    streamURL = try await camera.startLiveStream()
                } catch {
                    // Worth saying, not worth stopping for: the RTSP side may
                    // still serve a stream this firmware starts on its own.
                    self?.sink.log(.warning, .app,
                                   "The camera refused the start-live command: "
                                   + error.localizedDescription)
                }
            }
            await self?.openStream(host: host, url: streamURL)
        }
    }

    private func openStream(host: String, url: String?) async {
        guard self.host == host else { return }

        // The address that answered wins over the one the camera names: in
        // station mode it reports the address it thinks it has.
        let client = url.map { RTSPClient(url: $0, fallbackHost: host, sink: sink) }
            ?? RTSPClient(host: host, sink: sink)
        self.client = client

        Task {
            await client.start(
                onParameterSets: { [weak self] codec, sets in
                    Task { @MainActor [weak self] in
                        self?.renderer.setParameterSets(codec: codec, sets: sets)
                    }
                },
                onNAL: { [weak self] unit in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.renderer.handle(unit)
                        if self.renderer.framesRendered != self.framesRendered {
                            self.framesRendered = self.renderer.framesRendered
                        }
                    }
                },
                onStateChange: { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.apply(state)
                    }
                }
            )
        }
    }

    func stop() {
        if holdsGate {
            holdsGate = false
            Task { [gate] in await gate.endInteractive() }
        }
        let existing = client
        client = nil
        host = nil
        status = .stopped
        Task { await existing?.stop() }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func apply(_ state: RTSPClient.State) {
        switch state {
        case .idle, .connecting, .describing:
            status = .connecting
        case .playing:
            status = .playing
        case .failed(let reason):
            status = .failed(reason)
        case .stopped:
            if !isFailed { status = .stopped }
        }
    }
}

/// Hosts the display layer. The layer decodes and draws on its own, so this is
/// a thin wrapper that keeps it sized.
struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.attach(renderer.displayLayer)
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {
        uiView.attach(renderer.displayLayer)
    }

    final class LayerHostView: UIView {
        private weak var attached: AVSampleBufferDisplayLayer?

        func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
            guard attached !== displayLayer else { return }
            attached?.removeFromSuperlayer()
            layer.addSublayer(displayLayer)
            attached = displayLayer
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            attached?.frame = bounds
            CATransaction.commit()
        }
    }
}

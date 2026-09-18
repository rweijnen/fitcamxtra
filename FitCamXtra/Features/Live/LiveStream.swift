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

    init(sink: LogSink) {
        self.sink = sink
        self.renderer = VideoRenderer(sink: sink)
    }

    func start(host: String) {
        guard self.host != host || status == .stopped || isFailed else { return }
        stop()

        self.host = host
        status = .connecting
        renderer.reset()

        let client = RTSPClient(host: host, sink: sink)
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

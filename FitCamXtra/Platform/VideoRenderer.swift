import AVFoundation
import CoreMedia
import Foundation

/// Turns H.264 NAL units into frames on screen.
///
/// AVSampleBufferDisplayLayer decodes as well as displays, so there is no
/// VideoToolbox session to manage here. It wants AVCC framing, meaning each
/// NAL prefixed with its big-endian length, plus a format description built
/// from the SPS and PPS.
@MainActor
final class VideoRenderer {
    let displayLayer = AVSampleBufferDisplayLayer()

    private var formatDescription: CMVideoFormatDescription?
    private var codec: VideoCodec = .h264
    private var sets = ParameterSets()

    /// NAL units belonging to the frame currently being assembled. One frame
    /// can arrive as several slices sharing an RTP timestamp.
    private var pendingNALs: [[UInt8]] = []
    private var pendingTimestamp: UInt32?

    private(set) var framesRendered = 0
    private(set) var lastError: String?

    /// A black Live screen used to produce no diagnostics at all: the RTSP
    /// side logged that it was playing, and everything after that was silent.
    /// Decoding is where this fails most often, so it says what it did.
    private let sink: LogSink?
    /// Logged once each, because these fire per frame.
    private var hasLoggedFirstFrame = false
    private var hasLoggedFirstNAL = false

    init(sink: LogSink? = nil) {
        self.sink = sink
        displayLayer.videoGravity = .resizeAspect
    }

    func reset() {
        pendingNALs.removeAll()
        pendingTimestamp = nil
        formatDescription = nil
        sets = ParameterSets()
        framesRendered = 0
        lastError = nil
        hasLoggedFirstFrame = false
        hasLoggedFirstNAL = false
        displayLayer.flushAndRemoveImage()
    }

    func setParameterSets(codec newCodec: VideoCodec, sets newSets: ParameterSets) {
        guard codec != newCodec || sets != newSets else { return }
        codec = newCodec
        sets = newSets
        rebuildFormatDescription()
    }

    private func rebuildFormatDescription() {
        guard sets.isComplete(for: codec) else {
            sink?.log(.debug, .app,
                      "\(codec.label) parameter sets are still incomplete",
                      detail: describeSets())
            return
        }
        formatDescription = Self.makeFormatDescription(codec: codec, sets: sets)
        lastError = formatDescription == nil
            ? "The camera's \(codec.label) parameter sets could not be read"
            : nil

        if formatDescription == nil {
            sink?.log(.error, .app,
                      "CoreMedia would not build a \(codec.label) format description",
                      detail: describeSets())
        } else {
            sink?.log(.info, .app, "\(codec.label) format description ready", detail: describeSets())
        }
    }

    private func describeSets() -> String {
        """
        codec  \(codec.label)
        vps    \(sets.vps?.count.description ?? "none") bytes
        sps    \(sets.sps?.count.description ?? "none") bytes
        pps    \(sets.pps?.count.description ?? "none") bytes
        """
    }

    func handle(_ unit: VideoNALUnit) {
        // Parameter sets arrive in the SDP and are repeated in the stream.
        if unit.isParameterSet {
            var updated = sets
            updated.absorb(unit)
            if updated != sets {
                codec = unit.codec
                sets = updated
                rebuildFormatDescription()
            }
            return
        }
        guard unit.isVideoFrame else { return }

        if !hasLoggedFirstNAL {
            hasLoggedFirstNAL = true
            sink?.log(.info, .app,
                      "First video NAL from the camera: \(unit.bytes.count) bytes",
                      detail: formatDescription == nil
                          ? "No format description yet, so this frame cannot be decoded."
                          : nil)
        }

        // A change of timestamp means the previous frame is complete.
        if let pending = pendingTimestamp, pending != unit.timestamp {
            flushPendingFrame()
        }
        pendingTimestamp = unit.timestamp
        pendingNALs.append(unit.bytes)
        // The frame is emitted when the next timestamp arrives. That costs one
        // frame of latency, around 33 ms at 30fps, and in exchange a
        // multi-slice frame is never split across sample buffers.
    }

    private func flushPendingFrame() {
        defer {
            pendingNALs.removeAll(keepingCapacity: true)
            pendingTimestamp = nil
        }
        guard !pendingNALs.isEmpty else { return }
        guard let formatDescription else {
            // Frames arriving with no format description is the usual reason
            // for a black screen, and it is worth saying once.
            if lastError == nil {
                lastError = "Frames are arriving but the camera's \(codec.label) parameter sets have not"
                    + " been read, so nothing can be decoded"
                sink?.log(.warning, .app, lastError ?? "", detail: describeSets())
            }
            return
        }

        // AVCC: each NAL prefixed with a 4-byte big-endian length.
        var avcc: [UInt8] = []
        avcc.reserveCapacity(pendingNALs.reduce(0) { $0 + $1.count + 4 })
        for nal in pendingNALs {
            let length = UInt32(nal.count)
            avcc.append(UInt8((length >> 24) & 0xFF))
            avcc.append(UInt8((length >> 16) & 0xFF))
            avcc.append(UInt8((length >> 8) & 0xFF))
            avcc.append(UInt8(length & 0xFF))
            avcc.append(contentsOf: nal)
        }

        guard let sampleBuffer = Self.makeSampleBuffer(avcc: avcc, format: formatDescription) else {
            lastError = "A \(avcc.count)-byte frame could not be prepared for the decoder"
            sink?.log(.error, .app,
                      "CoreMedia would not wrap a \(avcc.count)-byte frame in a sample buffer")
            return
        }

        // A live monitor has nothing to synchronise against, so show each frame
        // as it arrives rather than running a clock that can drift.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let first = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if #available(iOS 17.0, *) {
            if displayLayer.sampleBufferRenderer.status == .failed {
                reportLayerFailure(displayLayer.sampleBufferRenderer.error)
                displayLayer.sampleBufferRenderer.flush()
            }
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            if displayLayer.status == .failed {
                reportLayerFailure(displayLayer.error)
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer)
        }
        framesRendered += 1

        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            sink?.log(.info, .app, "First frame decoded and shown (\(avcc.count) bytes)")
        }
    }

    /// The display layer fails asynchronously, inside the decoder, so this is
    /// the only place its reason is ever visible.
    private func reportLayerFailure(_ error: Error?) {
        let reason = error?.localizedDescription ?? "no reason given"
        lastError = "The decoder rejected the stream: \(reason)"
        sink?.log(.error, .app, "The display layer failed after \(framesRendered) frames: \(reason)")
    }

    // MARK: - CoreMedia plumbing

    /// H.264 takes SPS and PPS; H.265 takes VPS, SPS and PPS in that order.
    private static func makeFormatDescription(
        codec: VideoCodec,
        sets: ParameterSets
    ) -> CMVideoFormatDescription? {
        let ordered: [[UInt8]]
        switch codec {
        case .h264:
            guard let sps = sets.sps, let pps = sets.pps else { return nil }
            ordered = [sps, pps]
        case .h265:
            guard let vps = sets.vps, let sps = sets.sps, let pps = sets.pps else { return nil }
            ordered = [vps, sps, pps]
        }
        guard ordered.allSatisfy({ !$0.isEmpty }) else { return nil }

        // Flatten into one buffer so the pointers stay valid for the whole call.
        var flat: [UInt8] = []
        var offsets: [Int] = []
        for set in ordered {
            offsets.append(flat.count)
            flat.append(contentsOf: set)
        }
        let sizes = ordered.map(\.count)

        var format: CMVideoFormatDescription?
        let status: OSStatus = flat.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            let pointers = offsets.map { base + $0 }
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    switch codec {
                    case .h264:
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: pointers.count,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    case .h265:
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: pointers.count,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeSampleBuffer(
        avcc: [UInt8],
        format: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: avcc.count)
        data.initialize(from: avcc, count: avcc.count)

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: data,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,   // takes ownership of `data`
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            data.deallocate()
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }
}

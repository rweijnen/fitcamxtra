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
    private var sps: [UInt8]?
    private var pps: [UInt8]?

    /// NAL units belonging to the frame currently being assembled. One frame
    /// can arrive as several slices sharing an RTP timestamp.
    private var pendingNALs: [[UInt8]] = []
    private var pendingTimestamp: UInt32?

    private(set) var framesRendered = 0
    private(set) var lastError: String?

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    func reset() {
        pendingNALs.removeAll()
        pendingTimestamp = nil
        formatDescription = nil
        sps = nil
        pps = nil
        framesRendered = 0
        lastError = nil
        displayLayer.flushAndRemoveImage()
    }

    func setParameterSets(sps newSPS: [UInt8], pps newPPS: [UInt8]) {
        guard sps != newSPS || pps != newPPS else { return }
        sps = newSPS
        pps = newPPS
        formatDescription = Self.makeFormatDescription(sps: newSPS, pps: newPPS)
        if formatDescription == nil {
            lastError = "The camera's parameter sets could not be read"
        }
    }

    func handle(_ unit: H264Depacketizer.NALUnit) {
        // Parameter sets can arrive in the stream as well as in the SDP.
        if unit.isSPS {
            setParameterSets(sps: unit.bytes, pps: pps ?? [])
            return
        }
        if unit.isPPS {
            if let currentSPS = sps {
                setParameterSets(sps: currentSPS, pps: unit.bytes)
            } else {
                pps = unit.bytes
            }
            return
        }
        guard unit.isVideoFrame else { return }

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
        guard !pendingNALs.isEmpty, let formatDescription else { return }

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
                displayLayer.sampleBufferRenderer.flush()
            }
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer)
        }
        framesRendered += 1
    }

    // MARK: - CoreMedia plumbing

    private static func makeFormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        guard !sps.isEmpty, !pps.isEmpty else { return nil }

        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer -> OSStatus in
                guard let spsBase = spsBuffer.baseAddress, let ppsBase = ppsBuffer.baseAddress else {
                    return -1
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
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

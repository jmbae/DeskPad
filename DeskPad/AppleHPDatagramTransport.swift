import os
import Foundation


/// Experimental media receiver. Owned by a single RFB session and closed with it.
actor AppleHPDatagramTransport {
    private var sockets: [AppleHPUDPSocket] = []
    private var audio: HighPerformanceSRTPReceiver
    private var video: HighPerformanceSRTPReceiver
    private var audioControl: HighPerformanceSRTCPReceiver
    private var videoControl: HighPerformanceSRTCPReceiver
    private let pipeline: HighPerformanceMediaPipeline
    private let onPlaying: () async -> Void
    private let onFailure: () async -> Void
    private var lastAuthenticatedPacket = ProcessInfo.processInfo.systemUptime
    private var didStart = false
    private var negotiated = false
    private var remoteVideoSSRC: UInt32?
    private var remoteAudioSSRC: UInt32?
    private var lastPictureLossRequest = -Double.infinity
    private var counts = [0, 0]
    private var rejected = [0, 0]
    private var active = true
    private let heartbeat: HighPerformanceSRTPSender
    private let videoFeedback: HighPerformanceSRTCPSender
    private let videoSSRC: UInt32
    private var heartbeatTask: Task<Void, Never>?
    private let inbox = AppleHPDatagramInbox()
    private var receiverTask: Task<Void, Never>?

    init(offer: AppleHPMediaOffer, pipeline: HighPerformanceMediaPipeline, onPlaying: @escaping () async -> Void, onFailure: @escaping () async -> Void) throws {
        self.pipeline = pipeline; self.onPlaying = onPlaying; self.onFailure = onFailure
        heartbeat = try .init(masterKeyBlob: offer.audioKeys.viewerToServer, ssrc: offer.audioSSRC)
        videoFeedback = try .init(masterKeyBlob: offer.videoKeys.viewerToServer, ssrc: offer.videoSSRC)
        videoSSRC = offer.videoSSRC
        audio = try .init(masterKeyBlob: offer.audioKeys.serverToViewer)
        video = try .init(masterKeyBlob: offer.videoKeys.serverToViewer)
        audioControl = try .init(masterKeyBlob: offer.audioKeys.serverToViewer)
        videoControl = try .init(masterKeyBlob: offer.videoKeys.serverToViewer)
    }
    func start(host: String, port: UInt16) throws {
        guard port < UInt16.max else { throw HighPerformanceSRTPError.malformedPacket }
        guard active, sockets.isEmpty, receiverTask == nil else { throw HighPerformanceSRTPError.malformedPacket }
        do {
            for i in 0..<2 {
                let inbox = self.inbox
                let socket = try AppleHPUDPSocket(remoteIPv4: host, port: port + UInt16(i)) { data in
                    inbox.submit(data, stream: i)
                }
                sockets.append(socket)
            }
        } catch {
            close()
            throw error
        }
        let packets = inbox.packets
        receiverTask = Task { [weak self] in
            for await packet in packets {
                guard !Task.isCancelled else { break }
                await self?.consume(packet.data, stream: packet.stream)
            }
        }
        heartbeatTask = Task {
            while !Task.isCancelled {
                pulse()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func pulse() {
        guard active, sockets.count == 2 else { return }
        if negotiated, ProcessInfo.processInfo.systemUptime - lastAuthenticatedPacket > 15 {
            failMedia()
            return
        }
        do {
            let timestamp = UInt32(truncatingIfNeeded: UInt64(ProcessInfo.processInfo.systemUptime * 48_000))
            let packet = try heartbeat.protect(payload: Data([0, 0x68, 0x34, 0]), payloadType: 101, timestamp: timestamp)
            sockets[0].send(packet)
            var rr = Data([0x80, 201, 0, 1])
            rr.append(contentsOf: [UInt8(truncatingIfNeeded: videoSSRC >> 24), UInt8(truncatingIfNeeded: videoSSRC >> 16), UInt8(truncatingIfNeeded: videoSSRC >> 8), UInt8(truncatingIfNeeded: videoSSRC)])
            sockets[1].send(try videoFeedback.protect(rr))
        } catch { failMedia() }
    }
    func accept(_ answer: AppleHPMediaAnswer) throws {
        guard !negotiated, answer.secondVideo == nil, answer.video.codecPayloadType == 123 else {
            throw HighPerformanceMediaError.malformedPacket
        }
        remoteVideoSSRC = answer.video.ssrc
        remoteAudioSSRC = answer.audio.ssrc
        negotiated = true
        lastAuthenticatedPacket = ProcessInfo.processInfo.systemUptime
        requestKeyframe()
    }

    func requestKeyframe() {
        let now = ProcessInfo.processInfo.systemUptime
        guard active, sockets.count == 2, let remoteVideoSSRC, now - lastPictureLossRequest >= 0.5 else { return }
        do {
            let packet = AppleHPFeedback.pictureLoss(sender: videoSSRC, media: remoteVideoSSRC)
            sockets[1].send(try videoFeedback.protect(packet))
            lastPictureLossRequest = now
        } catch { failMedia() }
    }

    private func failMedia() {
        guard active else { return }
        close()
        Task { await onFailure() }
    }

    func close() {
        active = false
        inbox.finish()
        receiverTask?.cancel(); receiverTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        for socket in sockets { socket.close() }
        sockets.removeAll()
    }
    private func decodeControl(_ data: Data, stream: Int) throws -> Data {
        if stream == 0 { return try audioControl.receive(data) }
        return try videoControl.receive(data)
    }
    private func decodeMedia(_ data: Data, stream: Int) throws -> HighPerformanceRTPPacket {
        if stream == 0 { return try audio.receive(data) }
        return try video.receive(data)
    }
    private func consume(_ data: Data, stream: Int) async {
        guard active, negotiated, data.count >= 2 else { return }
        do {
            let isControl = (192...223).contains(data[data.startIndex + 1])
            if isControl {
                let plain = try decodeControl(data, stream: stream)
                lastAuthenticatedPacket = ProcessInfo.processInfo.systemUptime
                let reports = try HighPerformanceSenderReport.parseCompound(plain)
                try await pipeline.observe(reports, clockRate: stream == 0 ? 48000 : 90000)
                #if DEBUG
                if !reports.isEmpty { VNCControlDiagnostics.logger.notice("HP sender reports stream=\(stream) count=\(reports.count)") }
                #endif
            } else {
                let packet = try decodeMedia(data, stream: stream)
                lastAuthenticatedPacket = ProcessInfo.processInfo.systemUptime
                guard packet.ssrc == (stream == 0 ? remoteAudioSSRC : remoteVideoSSRC) else {
                    throw HighPerformanceMediaError.malformedPacket
                }
                if stream == 0 { try await pipeline.consumeAudioAccessUnit(packet) }
                else { try await pipeline.consumeVideo(packet) }
                if !didStart, await pipeline.isPlaying {
                    didStart = true; await onPlaying()
                }
                counts[stream] += 1
                if counts[stream] == 1 || counts[stream] % 500 == 0 {
                    #if DEBUG
                    VNCControlDiagnostics.logger.notice("HP authenticated media stream=\(stream) packets=\(self.counts[stream]) pt=\(packet.payloadType) bytes=\(packet.payload.count)")
                    #endif
                }
            }
        } catch {
            if let playbackError = error as? HighPerformancePlaybackError {
                switch playbackError {
                case .backpressure: requestKeyframe()
                default: failMedia(); return
                }
            }
            rejected[stream] += 1
            if rejected[stream] == 1 {
                #if DEBUG
                VNCControlDiagnostics.logger.notice("HP UDP rejected stream=\(stream) reason=\(String(describing: error), privacy: .public)")
                #endif
            }
        }
    }
}

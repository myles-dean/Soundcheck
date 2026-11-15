// AirPlay audio sender for Soundcheck.
//
// RAOP's UDP side: packet formats, the timing (NTP) server receivers sync their clocks to, and
// the control channel that carries sync packets and retransmit requests. Ported from pyatv
// (pyatv/protocols/raop/packets.py, protocols/__init__.py TimingServer, stream_client.py
// ControlClient): https://github.com/postlund/pyatv, MIT License, © Pierre Ståhl.

import Foundation
import Network

enum AirPlayPacket {
    static let framesPerPacket = 352

    /// Reply to a timing request (pyatv's TimingServer.datagram_received): our receive and send
    /// times are both "now"; the request's send time comes back as the reference time.
    static func timingReply(to request: Data, now: UInt64) -> Data? {
        guard request.count >= 32 else { return nil }
        let start = request.startIndex
        var reply = Data()
        reply.append(request[start])          // proto
        reply.append(0x53 | 0x80)             // type
        reply.appendBigEndian(UInt16(7))      // seqno
        reply.appendBigEndian(UInt32(0))      // padding
        reply.append(request[(start + 24)..<(start + 32)]) // reftime = request's sendtime
        reply.appendBigEndian(now)            // recvtime
        reply.appendBigEndian(now)            // sendtime
        return reply
    }

    /// SyncPacket: RTP time `rtpNow - latency` plays at `ntp`; `rtpNow` is the next packet's.
    static func sync(first: Bool, rtpNowMinusLatency: UInt32, ntp: UInt64, rtpNow: UInt32) -> Data {
        var packet = Data()
        packet.append(first ? 0x90 : 0x80)
        packet.append(0xD4)
        packet.appendBigEndian(UInt16(0x0007))
        packet.appendBigEndian(rtpNowMinusLatency)
        packet.appendBigEndian(ntp)
        packet.appendBigEndian(rtpNow)
        return packet
    }

    /// Frames between a type-215 sync packet's time and when the receiver renders the RTP time in
    /// bytes 4-7: OwnTone's AIRPLAY_AUDIO_LATENCY_MS (250 ms, also the latencyMin it sends) and
    /// shairport-sync's ap2_realttime_stream_latency_fudge_factor, which anchors that frame minus
    /// 11025 at the packet's time.
    static let ptpRenderOffsetFrames: UInt32 = 11_025

    /// PTP sync packet, type 215 "time announce" (OwnTone's sync_packet_ptp_make; shairport-sync's
    /// case 215): bytes 4-7 the RTP time rendered `ptpRenderOffsetFrames` after `networkNs` (ns on
    /// the grandmaster's timeline, bytes 8-15), bytes 16-19 the RTP time that is "now" at that
    /// moment (the difference is the stream's latency), bytes 20-27 the grandmaster's identity.
    static func ptpSync(first: Bool, rtpRendered: UInt32, networkNs: UInt64, rtpNow: UInt32, clockID: UInt64) -> Data {
        var packet = Data()
        packet.append(first ? 0x90 : 0x80)
        packet.append(0xD7)
        packet.appendBigEndian(UInt16(0x0006))
        packet.appendBigEndian(rtpRendered)
        packet.appendBigEndian(networkNs)
        packet.appendBigEndian(rtpNow)
        packet.appendBigEndian(clockID)
        return packet
    }

    /// AudioPacketHeader: the marker bit is set on the first packet.
    static func audioHeader(first: Bool, sequence: UInt16, timestamp: UInt32, ssrc: UInt32) -> Data {
        var header = Data(capacity: 12)
        header.append(0x80)
        header.append(first ? 0xE0 : 0x60)
        header.appendBigEndian(sequence)
        header.appendBigEndian(timestamp)
        header.appendBigEndian(ssrc)
        return header
    }
}

/// Waits for an NWListener to be ready and returns its port.
private func startListener(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
    let once = AirPlayOnce()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
            case .failed(let error), .waiting(let error):
                if once.claim() { continuation.resume(throwing: AirPlayError.connectionFailed("UDP listener: \(error)")) }
            case .cancelled:
                if once.claim() { continuation.resume(throwing: AirPlayError.cancelled) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }
}

private func udpParameters() -> NWParameters {
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    return parameters
}

/// Answers the receiver's NTP-style timing requests with our clock (AirPlayClock).
final class AirPlayTimingServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    private init(listener: NWListener, queue: DispatchQueue) {
        self.listener = listener
        self.queue = queue
    }

    static func start(queue: DispatchQueue) async throws -> AirPlayTimingServer {
        let listener = try NWListener(using: udpParameters())
        let server = AirPlayTimingServer(listener: listener, queue: queue)
        listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
        server.port = try await startListener(listener, queue: queue)
        return server
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let reply = AirPlayPacket.timingReply(to: data, now: AirPlayClock.ntpNow) {
                connection.send(content: reply, completion: .idempotent)
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    func close() {
        queue.async {
            self.listener.cancel()
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }
}

/// Our control port: sync packets go out from it, retransmit requests come in to it.
final class AirPlayControlChannel: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private var inbound: [NWConnection] = []
    private var outbound: NWConnection?
    private(set) var port: UInt16 = 0
    /// Given (first lost sequence number, count), returns the packets to resend, already wrapped.
    /// Called on the session queue.
    var retransmissions: ((UInt16, UInt16) -> [Data])?

    private init(listener: NWListener, queue: DispatchQueue) {
        self.listener = listener
        self.queue = queue
    }

    static func start(queue: DispatchQueue) async throws -> AirPlayControlChannel {
        let listener = try NWListener(using: udpParameters())
        let channel = AirPlayControlChannel(listener: listener, queue: queue)
        listener.newConnectionHandler = { [weak channel] connection in channel?.accept(connection) }
        channel.port = try await startListener(listener, queue: queue)
        return channel
    }

    private func accept(_ connection: NWConnection) {
        inbound.append(connection)
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.handle(data, from: connection) }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) {
        guard data.count >= 8 else { return }
        let type = data[data.startIndex + 1] & 0x7F
        guard type == 0x55,
              let lost = data.readBigEndian(UInt16.self, at: 4),
              let count = data.readBigEndian(UInt16.self, at: 6) else {
            AirPlayLog.debug("Unhandled control packet type 0x\(String(type, radix: 16))")
            return
        }
        let packets = retransmissions?(lost, count) ?? []
        AirPlayLog.debug("Retransmit request for \(count) packet(s) from #\(lost): resending \(packets.count)")
        for packet in packets { connection.send(content: packet, completion: .idempotent) }
    }

    /// Opens the path to the receiver's control port, from our control port when the system lets
    /// two sockets share it (as pyatv's single socket does), otherwise from any port.
    func connect(to host: NWEndpoint.Host, port remotePort: UInt16) async {
        guard let remote = NWEndpoint.Port(rawValue: remotePort) else { return }
        let shared = udpParameters()
        if let local = NWEndpoint.Port(rawValue: port) {
            shared.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: local)
        }
        if let connection = await open(NWConnection(host: host, port: remote, using: shared)) {
            queue.sync { outbound = connection }
            receive(on: connection)
            return
        }
        AirPlayLog.debug("Couldn't send from control port \(port); sending sync packets from another port")
        if let connection = await open(NWConnection(host: host, port: remote, using: .udp)) {
            queue.sync { outbound = connection }
            receive(on: connection)
        }
    }

    private func open(_ connection: NWConnection) async -> NWConnection? {
        let once = AirPlayOnce()
        let ready: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume(returning: true) }
                case .failed, .waiting, .cancelled: if once.claim() { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
        if !ready { connection.cancel() }
        return ready ? connection : nil
    }

    /// Sends a sync packet. Call on the session queue.
    func send(_ packet: Data) {
        outbound?.send(content: packet, completion: .idempotent)
    }

    func close() {
        queue.async {
            self.listener.cancel()
            self.outbound?.cancel()
            self.outbound = nil
            self.inbound.forEach { $0.cancel() }
            self.inbound.removeAll()
        }
    }
}

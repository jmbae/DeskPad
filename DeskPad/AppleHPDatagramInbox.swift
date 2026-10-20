import Foundation

/// One bounded queue for the two socket callbacks, consumed by one task.
/// Overflow is packet loss, never an unbounded backlog of actor tasks. RTP
/// sequence gaps are handled by the authenticated media recovery path.
final class AppleHPDatagramInbox: Sendable {
    struct Packet: Sendable { let data: Data; let stream: Int }
    let packets: AsyncStream<Packet>
    private let continuation: AsyncStream<Packet>.Continuation

    init(capacity: Int = 64) {
        precondition((1...256).contains(capacity))
        let pair = AsyncStream<Packet>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        packets = pair.stream
        continuation = pair.continuation
    }

    @discardableResult func submit(_ data: Data, stream: Int) -> Bool {
        guard !data.isEmpty, data.count <= 65535, (0...1).contains(stream) else { return false }
        if case .enqueued = continuation.yield(Packet(data: data, stream: stream)) { return true }
        return false
    }

    func finish() { continuation.finish() }
    deinit { continuation.finish() }
}

import Foundation

private actor BlockedTransport {
    var events: [RFBInputCommand] = []
    private var release: CheckedContinuation<Void, Never>?
    func send(_ command: RFBInputCommand) async {
        events.append(command)
        if events.count == 1 { await withCheckedContinuation { release = $0 } }
    }
    func unblock() { release?.resume(); release = nil }
    var blocked: Bool { release != nil }
}

@main struct InputQueueHarness {
    @MainActor static func wait(_ label: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline, label)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor static func main() async throws {
        let queue = RFBInputQueue()
        let transport = BlockedTransport()
        func enqueue(_ command: RFBInputCommand) {
            queue.enqueue(command, send: { await transport.send($0) }, onError: { fatalError("\($0)") })
        }
        let start = RFBInputCommand.key(keysym: 65, pressed: true)
        enqueue(start)
        try await wait("initial send blocked") { await transport.blocked }
        for x in 0..<2000 { enqueue(.pointer(x: UInt16(x), y: 0, mask: 0)) }
        enqueue(.pointer(x: 2000, y: 0, mask: 1)) // press origin must survive
        for x in 2001..<4000 { enqueue(.pointer(x: UInt16(x), y: 0, mask: 1)) }
        enqueue(.pointer(x: 4000, y: 0, mask: 0)) // release edge must survive
        enqueue(.pointer(x: 4001, y: 0, mask: 0))
        enqueue(.key(keysym: 65, pressed: false))
        enqueue(.pointer(x: 4002, y: 0, mask: 0))
        enqueue(.clipboard(Data([65])))
        enqueue(.pointer(x: 4003, y: 0, mask: 0))
        enqueue(.pointer(x: 4003, y: 0, mask: 8))
        enqueue(.pointer(x: 4003, y: 0, mask: 8))
        enqueue(.pointer(x: 4003, y: 0, mask: 0))
        let expected: [RFBInputCommand] = [start,
            .pointer(x: 1999, y: 0, mask: 0), .pointer(x: 2000, y: 0, mask: 1),
            .pointer(x: 3999, y: 0, mask: 1), .pointer(x: 4000, y: 0, mask: 0),
            .pointer(x: 4001, y: 0, mask: 0), .key(keysym: 65, pressed: false),
            .pointer(x: 4002, y: 0, mask: 0), .clipboard(Data([65])),
            .pointer(x: 4003, y: 0, mask: 0), .pointer(x: 4003, y: 0, mask: 8),
            .pointer(x: 4003, y: 0, mask: 8), .pointer(x: 4003, y: 0, mask: 0)]
        await transport.unblock()
        try await wait("burst drained") { await transport.events.count == expected.count }
        let delivered = await transport.events
        precondition(delivered == expected, "Motion coalescing lost input boundaries: \(delivered)")
        print("PASS blocked 4000-motion burst, button positions, key/clipboard/wheel barriers")

        let old = BlockedTransport()
        queue.enqueue(start, send: { await old.send($0) }, onError: { fatalError("\($0)") })
        try await wait("old blocked") { await old.blocked }
        queue.enqueue(.key(keysym: 99, pressed: true), send: { await old.send($0) }, onError: { fatalError("\($0)") })
        queue.cancel()
        let fresh = BlockedTransport()
        queue.enqueue(.key(keysym: 66, pressed: true), send: { await fresh.send($0) }, onError: { fatalError("\($0)") })
        try await wait("new blocked") { await fresh.blocked }
        queue.enqueue(.key(keysym: 66, pressed: false), send: { await fresh.send($0) }, onError: { fatalError("\($0)") })
        await old.unblock()
        try await Task.sleep(for: .milliseconds(20))
        let oldEvents = await old.events
        let newEvents = await fresh.events
        precondition(oldEvents == [start], "Cancelled queue sent stale input")
        precondition(newEvents == [.key(keysym: 66, pressed: true)], "Old task drained new session")
        await fresh.unblock()
        try await wait("fresh release") { await fresh.events.count == 2 }
        print("PASS cancel removes queued input and stale drain cannot touch replacement session")

        weak var probe: RFBInputQueue?
        let pending = BlockedTransport()
        do {
            let ephemeral = RFBInputQueue()
            probe = ephemeral
            ephemeral.enqueue(start, send: { await pending.send($0) }, onError: { fatalError("\($0)") })
            try await wait("lifetime probe blocked") { await pending.blocked }
        }
        precondition(probe == nil, "Blocked transport retained queue")
        await pending.unblock()
        print("PASS queue deallocates while send is suspended")
    }
}

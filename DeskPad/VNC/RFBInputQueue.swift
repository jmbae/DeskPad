import Foundation

nonisolated enum RFBInputCommand: Equatable, Sendable {
    case pointer(x: UInt16, y: UInt16, mask: UInt8)
    case key(keysym: UInt32, pressed: Bool)
    case clipboard(Data)
}

/// Serializes input, retaining only the latest *pending* movement between input
/// edges. A press/release position, wheel tick or key is never replaced.
@MainActor
final class RFBInputQueue {
    private struct Entry {
        let command: RFBInputCommand
        let isMotion: Bool
    }
    private var entries: [Entry?] = []
    private var head = 0
    private var lastPointerMask: UInt8 = 0
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func enqueue(_ command: RFBInputCommand,
                 send: @escaping @Sendable (RFBInputCommand) async throws -> Void,
                 onError: @escaping @MainActor (Error) -> Void) {
        let isMotion: Bool
        if case .pointer(_, _, let mask) = command {
            // Bits 3...6 are wheel buttons. Repeated identical wheel masks
            // remain discrete events, even if a peer sends no release between.
            isMotion = mask == lastPointerMask && mask & 0x78 == 0
            lastPointerMask = mask
        } else {
            isMotion = false
        }
        let entry = Entry(command: command, isMotion: isMotion)
        if isMotion, entries.count > head, let last = entries.last ?? nil, last.isMotion {
            entries[entries.count - 1] = entry
        } else {
            entries.append(entry)
        }
        guard task == nil else { return }
        let generation = self.generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let command = self?.next(generation: generation) else { return }
                do { try await send(command) }
                catch {
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.cancel()
                    onError(error)
                    return
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        entries.removeAll(keepingCapacity: false)
        head = 0
        lastPointerMask = 0
    }

    private func next(generation: UUID) -> RFBInputCommand? {
        guard self.generation == generation else { return nil }
        guard head < entries.count else {
            task = nil
            entries.removeAll(keepingCapacity: true)
            head = 0
            return nil
        }
        let command = entries[head]!.command
        entries[head] = nil
        head += 1
        if head >= 256 && head * 2 >= entries.count {
            entries.removeFirst(head)
            head = 0
        }
        return command
    }

    isolated deinit { task?.cancel() }
}

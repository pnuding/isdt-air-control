import Foundation

enum ChargerError: LocalizedError {
    case timeout
    case notConnected
    case bluetoothUnavailable(String)
    case missingCharacteristics
    case pairingTimedOut
    case rejected(slot: Int)

    var errorDescription: String? {
        switch self {
        case .timeout: String(localized: "The charger didn't answer in time.")
        case .notConnected: String(localized: "Not connected to the charger.")
        case .bluetoothUnavailable(let why): why
        case .missingCharacteristics: String(localized: "This device doesn't expose the ISDT charger service.")
        case .pairingTimedOut: String(localized: "Pairing timed out. Press a button on the charger when it beeps, then try again.")
        case .rejected(let slot): String(localized: "Slot \(slot + 1): the charger rejected the settings.")
        }
    }
}

/// Serialises async work: only one holder at a time, FIFO. Used so a poll
/// and a settings write never interleave their request/response pairs.
@MainActor
final class AsyncLock {
    private var locked = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    func release() {
        if queue.isEmpty {
            locked = false
        } else {
            queue.removeFirst().resume()
        }
    }

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// Matches incoming messages to whoever is waiting for them.
///
/// `wait` registers the waiter *before* running `send`, so a fast reply can't
/// slip past, and races the reply against a deadline. Messages nobody is
/// waiting for are dropped (they're stale duplicates or late replies, and
/// replaying them later would answer the wrong question).
@MainActor
final class ResponseRouter<Message: Sendable> {
    private struct Waiter {
        let isMatch: (Message) -> Bool
        let continuation: CheckedContinuation<Message, Error>
        let timeout: Task<Void, Never>
    }

    private var waiters: [Int: Waiter] = [:]
    private var nextID = 0

    func deliver(_ message: Message) {
        guard let (id, waiter) = waiters.first(where: { $0.value.isMatch(message) }) else { return }
        waiters[id] = nil
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: message)
    }

    func wait(timeout: Double,
              match: @escaping (Message) -> Bool,
              send: @escaping @MainActor () async throws -> Void) async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            let id = nextID
            nextID += 1
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.fail(id, ChargerError.timeout)
            }
            waiters[id] = Waiter(isMatch: match, continuation: continuation, timeout: deadline)
            Task { [weak self] in
                do { try await send() } catch { self?.fail(id, error) }
            }
        }
    }

    func failAll(_ error: Error) {
        let pending = waiters
        waiters.removeAll()
        for (_, w) in pending {
            w.timeout.cancel()
            w.continuation.resume(throwing: error)
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }
}

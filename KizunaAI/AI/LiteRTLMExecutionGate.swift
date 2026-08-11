import Foundation

/// Serializes native LiteRT-LM work without letting a cancelled waiter own a
/// later execution slot.
///
/// A release hands the slot directly to the oldest still-waiting continuation.
/// Cancellation removes the waiter before resuming it, so the cancellation and
/// release paths cannot resume the same continuation twice.
actor LiteRTLMExecutionGate {
    private var isLocked = false
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Returns `false` when this task was cancelled while it waited for a slot.
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }

        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if !isLocked {
                    isLocked = true
                    continuation.resume(returning: true)
                } else {
                    waiterOrder.append(waiterID)
                    waiters[waiterID] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        })
    }

    /// Releases the current holder. The slot remains locked when ownership is
    /// handed to the next waiter.
    func release() {
        while !waiterOrder.isEmpty {
            let waiterID = waiterOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: waiterID) {
                continuation.resume(returning: true)
                return
            }
        }
        isLocked = false
    }

    /// Internal test hook used to establish deterministic cancellation order.
    func waitingCount() -> Int {
        waiters.count
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(returning: false)
    }
}

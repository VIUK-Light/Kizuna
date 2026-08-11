import Foundation

@main
struct LiteRTLMExecutionGateTests {
    static func main() async {
        await cancelledWaiterDoesNotAcquireAfterRelease()
        await cancellationPreservesRemainingFIFOOrder()
        await cancelReleaseRaceDoesNotStartWorkOrLeakTheGate()
        print("LiteRT-LM execution gate tests passed")
    }

    private static func cancelledWaiterDoesNotAcquireAfterRelease() async {
        let gate = LiteRTLMExecutionGate()
        let firstAcquired = await gate.acquire()
        precondition(firstAcquired)

        let cancelledWaiter = Task { await gate.acquire() }
        await waitUntil(gate, hasWaitingCount: 1)
        cancelledWaiter.cancel()

        let waiterAcquired = await cancelledWaiter.value
        precondition(!waiterAcquired, "A cancelled waiter must not acquire the released slot")
        await gate.release()

        let nextAcquired = await gate.acquire()
        precondition(nextAcquired, "A cancelled waiter must not leave the gate locked")
        await gate.release()
    }

    private static func cancellationPreservesRemainingFIFOOrder() async {
        let gate = LiteRTLMExecutionGate()
        let firstAcquired = await gate.acquire()
        precondition(firstAcquired)

        let firstWaiter = Task { await gate.acquire() }
        await waitUntil(gate, hasWaitingCount: 1)
        let secondWaiter = Task { await gate.acquire() }
        await waitUntil(gate, hasWaitingCount: 2)

        firstWaiter.cancel()
        let firstWaiterAcquired = await firstWaiter.value
        precondition(!firstWaiterAcquired)

        await gate.release()
        let secondWaiterAcquired = await secondWaiter.value
        precondition(secondWaiterAcquired, "The next non-cancelled waiter must receive the slot")
        await gate.release()
    }

    private static func cancelReleaseRaceDoesNotStartWorkOrLeakTheGate() async {
        for _ in 0..<32 {
            let gate = LiteRTLMExecutionGate()
            let firstAcquired = await gate.acquire()
            precondition(firstAcquired)

            let waiter = Task { () -> Bool in
                let acquired = await gate.acquire()
                guard acquired else { return false }
                guard !Task.isCancelled else {
                    await gate.release()
                    return false
                }

                // `generateAsync` performs the same cancellation check before
                // any Engine initialization, token probe, or sendMessage call.
                await gate.release()
                return true
            }
            await waitUntil(gate, hasWaitingCount: 1)

            waiter.cancel()
            await gate.release()

            let wouldStartNativeWork = await waiter.value
            precondition(
                !wouldStartNativeWork,
                "A cancelled waiter must not start native work after a release race"
            )

            let reacquired = await gate.acquire()
            precondition(reacquired, "The gate must remain usable after a cancel/release race")
            await gate.release()
        }
    }

    private static func waitUntil(
        _ gate: LiteRTLMExecutionGate,
        hasWaitingCount expectedCount: Int
    ) async {
        for _ in 0..<200 {
            if await gate.waitingCount() == expectedCount {
                return
            }
            await Task.yield()
        }
        fatalError("Timed out waiting for LiteRT-LM execution-gate test setup")
    }
}

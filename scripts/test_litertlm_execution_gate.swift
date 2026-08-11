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
                if acquired {
                    await gate.release()
                }
                return acquired
            }
            await waitUntil(gate, hasWaitingCount: 1)

            waiter.cancel()
            await gate.release()

            let cancelledWaiterAcquired = await waiter.value
            precondition(
                !cancelledWaiterAcquired,
                "A cancelled waiter must not receive the released slot"
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
        for _ in 0..<2_000 {
            if await gate.waitingCount() == expectedCount {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out waiting for LiteRT-LM execution-gate test setup")
    }
}

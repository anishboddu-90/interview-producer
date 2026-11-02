import Foundation

/// Cancelling a task does not guarantee its underlying network operation will return.
/// Resume the UI exactly once when either draining finishes or the deadline expires.
@MainActor enum PipelineDrain {
    private final class Gate {
        var continuation: CheckedContinuation<Bool,Never>?
        var cleanup: (() -> Void)?
        func finish(_ drained: Bool) {
            guard let continuation else { return }; self.continuation = nil
            cleanup?(); cleanup = nil; continuation.resume(returning:drained)
        }
    }
    static func wait(feed: Task<Void,Never>?,pipeline: TranscriptPipeline?,seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = Gate(); gate.continuation = continuation
            let worker = Task { await feed?.value; await pipeline?.drain(); gate.finish(true) }
            let timeout = Task {
                do { try await Task.sleep(for:.seconds(max(0.01,seconds))); try Task.checkCancellation() } catch { return }
                await pipeline?.cancel(); feed?.cancel(); gate.finish(false)
            }
            gate.cleanup = { worker.cancel(); timeout.cancel() }
        }
    }
}

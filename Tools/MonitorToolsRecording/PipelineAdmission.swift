import Foundation

struct PipelineAdmissionDecision: Sendable {
    let accepted:Bool
    let waitSeconds:Double
    let rejection:String?
}
struct PipelineAdmissionSnapshot: Sendable {
    let pending:Int
    let maximumPending:Int
    let capacityRejected:Int
}
/// Metadata-only admission for the qualification pipeline, with the same bounded
/// pending contract as CaptureController. Histogram storage belongs to its worker.
final class PipelineAdmission: @unchecked Sendable {
    private let lock:NSLock
    private let capacity:Int
    private var pending=0,maximumPending=0,capacityRejected=0
    init(capacity:Int,lock:NSLock=NSLock()) {
        precondition(capacity>0)
        self.capacity=capacity;self.lock=lock
    }
    func acquire()->PipelineAdmissionDecision {
        let started=ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer{lock.unlock()}
        let wait=ProcessInfo.processInfo.systemUptime-started
        guard pending<capacity else {capacityRejected += 1;return PipelineAdmissionDecision(accepted:false,waitSeconds:wait,rejection:"capacity")}
        pending += 1;maximumPending=max(maximumPending,pending)
        return PipelineAdmissionDecision(accepted:true,waitSeconds:wait,rejection:nil)
    }
    func release(){lock.lock();defer{lock.unlock()};precondition(pending>0);pending -= 1}
    func snapshot()->PipelineAdmissionSnapshot {
        lock.lock();defer{lock.unlock()}
        return PipelineAdmissionSnapshot(pending:pending,maximumPending:maximumPending,capacityRejected:capacityRejected)
    }
}

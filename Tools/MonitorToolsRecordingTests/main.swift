import Foundation
import Darwin

final class DecisionBox: @unchecked Sendable {
    private let lock=NSLock()
    private var value:PipelineAdmissionDecision?
    func store(_ next:PipelineAdmissionDecision){lock.lock();value=next;lock.unlock()}
    func read()->PipelineAdmissionDecision? {lock.lock();defer{lock.unlock()};return value}
}
var failures:[String]=[]
@MainActor func check(_ condition:Bool,_ message:String){if !condition{failures.append(message)}}

// Exercise the real gate under deterministic metadata contention at pending zero.
let metadataLock=NSLock(),gate=PipelineAdmission(capacity:12,lock:metadataLock)
let entered=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),decision=DecisionBox()
metadataLock.lock()
DispatchQueue.global(qos:.userInitiated).async {
    entered.signal();decision.store(gate.acquire());done.signal()
}
check(entered.wait(timeout:.now()+2) == .success,"contending admission did not start")
let returnedWhileHeld=done.wait(timeout:.now()+0.05) == .success
metadataLock.unlock()
if !returnedWhileHeld {check(done.wait(timeout:.now()+2) == .success,"metadata admission did not finish after unlock")}
let observed=decision.read()
print("METADATA_CONTENTION pending_before=0 returned_while_held=\(returnedWhileHeld) accepted=\(observed?.accepted ?? false) rejection=\(observed?.rejection ?? "none")")
check(!returnedWhileHeld,"free capacity rejected while metadata lock was held")
check(observed?.accepted == true,"metadata contention must wait and admit")
if observed?.accepted == true {gate.release()}

// Capacity remains strict across rejection, release and subsequent admission.
let bounded=PipelineAdmission(capacity:12)
for _ in 0..<12 {check(bounded.acquire().accepted,"capacity rejected before 12 pending")}
let full=bounded.acquire();check(!full.accepted && full.rejection == "capacity","13th pending frame was not capacity-rejected")
check(bounded.snapshot().maximumPending == 12,"pending high-water exceeds capture bound")
bounded.release();check(bounded.acquire().accepted,"released capacity was not reusable")
for _ in 0..<12 {bounded.release()}
let final=bounded.snapshot()
check(final.pending == 0 && final.capacityRejected == 1,"capacity or teardown accounting mismatch")
print("CAPACITY bound=12 maximum_pending=\(final.maximumPending) capacity_rejected=\(final.capacityRejected) final_pending=\(final.pending)")
if failures.isEmpty {print("PIPELINE_ADMISSION_CHECKS PASS");exit(0)}
for failure in failures {fputs("FAIL \(failure)\n",stderr)}
exit(1)

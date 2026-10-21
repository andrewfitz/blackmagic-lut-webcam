import Foundation
import Darwin

struct Distribution {
    // A fixed 0.1 ms histogram bounds instrumentation memory (0...1 second).
    var bins = [UInt64](repeating:0,count:10001), count: UInt64 = 0
    mutating func add(_ seconds: Double) { bins[max(0,min(10000,Int(seconds*10000)))] += 1; count += 1 }
    func percentile(_ q: Double) -> Double {
        guard count > 0 else { return 0 }; let rank = UInt64((Double(count-1)*q).rounded(.down))+1
        var total: UInt64 = 0
        for (index,n) in bins.enumerated() { total += n; if total >= rank { return Double(index)/10 } }
        return 1000
    }
}

final class MainQueueHeartbeat: @unchecked Sendable {
    private let lock=NSLock(),timer:DispatchSourceTimer
    private var pending=false,ages=Distribution(),skippedWhilePending=0
    init() {
        timer=DispatchSource.makeTimerSource(flags:.strict,queue:DispatchQueue(label:"synthetic.main-heartbeat",qos:.userInteractive))
        timer.schedule(deadline:.now(),repeating:.milliseconds(50),leeway:.milliseconds(1))
        timer.setEventHandler{[weak self] in self?.offer()};timer.resume()
    }
    private func offer() {
        guard lock.try() else{return}
        if pending {skippedWhilePending += 1;lock.unlock();return}
        pending=true;lock.unlock()
        let posted=ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async{[weak self] in
            guard let self else{return}
            self.lock.lock();self.ages.add(ProcessInfo.processInfo.systemUptime-posted);self.pending=false;self.lock.unlock()
        }
    }
    func stop(){timer.cancel()}
    func snapshot()->(Distribution,Int){lock.lock();defer{lock.unlock()};return(ages,skippedWhilePending)}
    deinit{timer.cancel()}
}

func footprint() -> UInt64 {
    var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
    let status=withUnsafeMutablePointer(to:&info){$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
    return status == KERN_SUCCESS ? info.phys_footprint:0
}

// Same bounded, hardware-clock-like scheduling policy used by EndToEndChecks.
// Only this dedicated source thread receives it; processing/writer queues do not.
struct ProducerSchedulerReceipt {
    var setup:Int32=0,read:Int32=0,endRead:Int32=0,restore:Int32=0,active=false,endActive=false
    var dictionary:[String:Any] {["policy":"dedicated Mach time-constraint producer","setup_status":setup,"read_status":read,"restore_status":restore,"active":active,"end_read_status":endRead,"end_active":endActive]}
}
private final class ProducerJob:@unchecked Sendable {
    let body:() throws -> Void,done=DispatchSemaphore(value:0)
    var result:Result<ProducerSchedulerReceipt,Error>?
    init(_ body:@escaping() throws -> Void){self.body=body}
}
struct ProducerSchedulerFailure:Error {let reason:String}
func onPacedProducer(period:Double,feeds:Int,body:@escaping() throws -> Void) throws -> ProducerSchedulerReceipt {
    let job=ProducerJob(body)
    let producer=Thread {
        var receipt=ProducerSchedulerReceipt(),timebase=mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func ticks(_ seconds:Double)->UInt32 {UInt32((seconds*1_000_000_000*Double(timebase.denom)/Double(timebase.numer)).rounded())}
        let thread=pthread_mach_thread_np(pthread_self())
        let words=mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size/MemoryLayout<integer_t>.size)
        var policy=thread_time_constraint_policy_data_t(period:ticks(period),computation:ticks(0.0005*Double(feeds)),constraint:ticks(0.001*Double(feeds)),preemptible:1)
        receipt.setup=withUnsafeMutablePointer(to:&policy){$0.withMemoryRebound(to:integer_t.self,capacity:Int(words)){thread_policy_set(thread,thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),$0,words)}}
        var observed=thread_time_constraint_policy_data_t(),count=words,defaults:boolean_t=0
        receipt.read=withUnsafeMutablePointer(to:&observed){$0.withMemoryRebound(to:integer_t.self,capacity:Int(words)){thread_policy_get(thread,thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),$0,&count,&defaults)}}
        receipt.active=receipt.setup==KERN_SUCCESS && receipt.read==KERN_SUCCESS && defaults==0 && observed.period==policy.period && observed.computation==policy.computation && observed.constraint==policy.constraint
        var failure:Error?
        do {
            guard receipt.active else{throw ProducerSchedulerFailure(reason:"Mach producer policy unavailable: \(receipt.setup)/\(receipt.read)")}
            try job.body()
        } catch {failure=error}
        observed=thread_time_constraint_policy_data_t();count=words;defaults=0
        receipt.endRead=withUnsafeMutablePointer(to:&observed){$0.withMemoryRebound(to:integer_t.self,capacity:Int(words)){thread_policy_get(thread,thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),$0,&count,&defaults)}}
        receipt.endActive=receipt.endRead==KERN_SUCCESS && defaults==0 && observed.period==policy.period && observed.computation==policy.computation && observed.constraint==policy.constraint
        if !receipt.endActive {failure=ProducerSchedulerFailure(reason:"Mach producer policy changed during measurement: \(receipt.endRead)")}
        var standard:integer_t=0
        receipt.restore=thread_policy_set(thread,thread_policy_flavor_t(THREAD_STANDARD_POLICY),&standard,0)
        if receipt.restore != KERN_SUCCESS {failure=ProducerSchedulerFailure(reason:"Mach producer policy restoration failed: \(receipt.restore)")}
        job.result=failure.map{.failure($0)} ?? .success(receipt)
        job.done.signal()
    }
    producer.name="Synthetic hardware-clock producer";producer.qualityOfService = .userInteractive;producer.start()
    job.done.wait()
    return try job.result!.get()
}
func waitForProducerDeadline(_ deadline:Double) {
    var timebase=mach_timebase_info_data_t();mach_timebase_info(&timebase)
    while true {
        let delay=deadline-ProcessInfo.processInfo.systemUptime
        if delay<=0{return}
        mach_wait_until(mach_absolute_time()+UInt64(delay*1_000_000_000*Double(timebase.denom)/Double(timebase.numer)))
    }
}

// VM/ledger telemetry must never run on the time-constrained source thread.
final class QualificationSampler: @unchecked Sendable {
    struct Snapshot {var maxima:[String:Double]=[:];var gpu=Distribution();var count=0;var elapsed:Double=0}
    private let queue=DispatchQueue(label:"synthetic.telemetry",qos:.utility)
    private let timer:DispatchSourceTimer
    private let provider:()->[String:Double]
    private var state=Snapshot()
    private let started=ProcessInfo.processInfo.systemUptime
    init(provider:@escaping()->[String:Double]) {
        self.provider=provider;timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(500),leeway:.milliseconds(25))
        timer.setEventHandler{[weak self] in self?.sample()};timer.resume()
    }
    private func sample() {
        let values=provider();state.count += 1
        for (key,value) in values {state.maxima[key]=max(state.maxima[key] ?? 0,value)}
        if let gpu=values["gpuFraction"] {state.gpu.add(gpu)}
    }
    func stop()->Snapshot {timer.cancel();return queue.sync {state.elapsed=ProcessInfo.processInfo.systemUptime-started;return state}}
    deinit{timer.cancel()}
}
func producerThreadCPU()->Double {
    var value=timespec();clock_gettime(CLOCK_THREAD_CPUTIME_ID,&value)
    return Double(value.tv_sec)+Double(value.tv_nsec)/1_000_000_000
}
struct ProducerWorkMetrics {
    var wall=Distribution(),cpu=Distribution(),maxWall:Double=0,maxCPU:Double=0
    mutating func record(wallStart:Double,cpuStart:Double) {
        let w=ProcessInfo.processInfo.systemUptime-wallStart,c=producerThreadCPU()-cpuStart
        wall.add(w);cpu.add(c);maxWall=max(maxWall,w);maxCPU=max(maxCPU,c)
    }
    func dictionary(feeds:Int)->[String:Any] {["samples":wall.count,"wall_p95_ms":wall.percentile(0.95),"wall_p99_ms":wall.percentile(0.99),"wall_max_ms":maxWall*1000,"thread_cpu_p95_ms":cpu.percentile(0.95),"thread_cpu_p99_ms":cpu.percentile(0.99),"thread_cpu_max_ms":maxCPU*1000,"declared_computation_ms":Double(feeds)*0.5,"declared_constraint_ms":Double(feeds),"diagnostics_thread":"independent utility timer"]}
}

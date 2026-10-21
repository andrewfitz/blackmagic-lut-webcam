import Foundation
import Darwin
import CoreVideo
import Metal
import MonitorToolsCore
import MonitorToolsMetal
import MonitorToolsUI

// This executable only creates synthetic buffers. No capture/device APIs are imported.
struct Failure: Error { let reason: String }
func require(_ value: @autoclosure () -> Bool, _ reason: String) throws { if !value() { throw Failure(reason: reason) } }
final class Results: @unchecked Sendable {
    let lock = NSLock()
    var counts: [Int: Int] = [:], ages=Distribution(), releases=Distribution(), errors: [String] = []
    var dimensions:[String:Int]=[:],stages:[String:Int]=[:]
    private var held:[Int:MonitorOwnedFrame]=[:]
    func releaseHeld(){lock.lock();held.removeAll();lock.unlock()}
    func record(feed: Int, result: Result<MonitorOwnedFrame, Error>, expected: UInt8, width:Int,height:Int,useOutput:Bool,start: Double) {
        var previous:MonitorOwnedFrame?
        lock.lock()
        switch result {
        case .failure(let error): if errors.count<16 {errors.append(String(describing: error))}
        case .success(let frame):
            let observedWidth=CVPixelBufferGetWidth(frame.pixelBuffer),observedHeight=CVPixelBufferGetHeight(frame.pixelBuffer)
            dimensions["\(observedWidth)x\(observedHeight)",default:0] += 1
            stages[useOutput ? "processedOutput":"source",default:0] += 1
            if (observedWidth != width || observedHeight != height) && errors.count<16 {errors.append("clean dimensions differ from declared native stage")}
            CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
            let byte = CVPixelBufferGetBaseAddress(frame.pixelBuffer)!.load(as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly)
            if byte != expected && errors.count<16 { errors.append("feed identity/pixel copy mismatch") }
            previous=held.updateValue(frame,forKey:feed)
            counts[feed, default: 0] += 1
            ages.add(ProcessInfo.processInfo.systemUptime - start)
        }
        lock.unlock()
        // Releasing a native 4K surface can be expensive. Keep it outside the shared observer lock.
        let releaseStarted=ProcessInfo.processInfo.systemUptime
        withExtendedLifetime(previous) {};previous=nil
        let releaseSeconds=ProcessInfo.processInfo.systemUptime-releaseStarted
        lock.lock();releases.add(releaseSeconds);lock.unlock()
    }
}
func buffer(_ value:UInt8,width:Int=320,height:Int=180,format:OSType=kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
    var result:CVPixelBuffer?
    let attrs=[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary
    try require(CVPixelBufferCreate(nil,width,height,format,attrs,&result)==kCVReturnSuccess,"allocation")
    let image=result!
    CVBufferSetAttachment(image,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(image,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(image,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
    CVPixelBufferLockBaseAddress(image,[])
    if format==kCVPixelFormatType_422YpCbCr10 {
        let words=CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to:UInt32.self),stride=CVPixelBufferGetBytesPerRow(image)/4
        memset(words,0,CVPixelBufferGetDataSize(image))
        let cb=UInt32(512+Int(value)),cr:UInt32=512,y=UInt32(64+Int(value)*876/255)
        for row in 0..<height {for x in Swift.stride(from:0,to:width,by:6) {
            let i=row*stride+x/6*4
            words[i]=cb | (y<<10) | (cr<<20);words[i+1]=y | (cb<<10) | (y<<20)
            words[i+2]=cr | (y<<10) | (cb<<20);words[i+3]=y | (cr<<10) | (y<<20)
        }}
    } else {memset(CVPixelBufferGetBaseAddress(image),Int32(value),CVPixelBufferGetDataSize(image))}
    CVPixelBufferUnlockBaseAddress(image,[])
    return image
}
func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
}
let qualificationActivity=ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.latencyCritical],reason:"Paced native video qualification")
DispatchQueue.global(qos:.userInitiated).async {
let exitCode:Int32
do {
    var seconds=10.0,feeds=2,width=320,height=180,format:OSType=kCVPixelFormatType_32BGRA,fps=30000.0/1001
    var index = 1
    while index < CommandLine.arguments.count {
        let arg = CommandLine.arguments[index]
        guard index + 1 < CommandLine.arguments.count else { throw Failure(reason: "missing argument") }
        if arg == "--seconds", let v = Double(CommandLine.arguments[index+1]), v >= 1, v <= 7200 { seconds = v }
        else if arg == "--feeds", let v = Int(CommandLine.arguments[index+1]), [1,2,4].contains(v) { feeds = v }
        else if arg == "--width",let v=Int(CommandLine.arguments[index+1]),(16...3840).contains(v),v%2==0 {width=v}
        else if arg == "--height",let v=Int(CommandLine.arguments[index+1]),(16...2160).contains(v),v%2==0 {height=v}
        else if arg == "--format",["v210","bgra"].contains(CommandLine.arguments[index+1]) {format=CommandLine.arguments[index+1] == "v210" ? kCVPixelFormatType_422YpCbCr10:kCVPixelFormatType_32BGRA}
        else if arg == "--fps",["29.97","59.94"].contains(CommandLine.arguments[index+1]) {fps=CommandLine.arguments[index+1] == "29.97" ? 30000.0/1001:60000.0/1001}
        else { throw Failure(reason: "usage: --seconds N --feeds 1|2|4 --width W --height H --format v210|bgra --fps29.97|59.94") }
        index += 2
    }
    let ledger = MonitorAdmissionLedger(maximumCleanCopyJobs: 4, maximumBytes:256*1024*1024,cleanReserveBytes:64*1024*1024)
    let a = MonitorTargetID("synthetic-a"), b = MonitorTargetID("synthetic-b")
    let old = ledger.tryAcquire(target: a, generation: 1, kind: .analysis, bytes: 1024)!
    ledger.retire(target: a, generation: 1)
    try require(ledger.tryAcquire(target: a, generation: 2, kind: .analysis, bytes: 1024) == nil, "retired same-target slot was reused")
    let other = ledger.tryAcquire(target: b, generation: 1, kind: .analysis, bytes: 1024)!
    try require(ledger.tryAcquire(target: MonitorTargetID("third"), generation: 1, kind: .analysis, bytes: 1024) == nil, "global bound exceeded")
    try require(ledger.snapshot.retiredBytes == 1024, "retired memory disappeared")
    old.release(); other.release()
    try require(ledger.snapshot.retainedBytes == 0, "retirement failed to release")
    let oneCopy = MonitorAdmissionLedger(maximumCleanCopyJobs: 1)
    let heldCopy = oneCopy.tryAcquireClean(target: a, generation: 1, bytes: 1024)!
    oneCopy.retire(target: a, generation: 1)
    try require(oneCopy.tryAcquireClean(target: b, generation: 1, bytes: 1024) == nil, "one-copy retired job bound bypassed")
    heldCopy.copy.release(); heldCopy.presentation.release()
    try require(oneCopy.snapshot.retainedBytes == 0 && oneCopy.snapshot.cleanCopyJobs == 0, "one-copy retirement leaked")
    let stale = MonitorFrameStamp(target: a, generation: 1, sequence: 1, sourcePTS: 0, hostTime: 0, configurationRevision: 1)
    try require(!stale.matches(target: a, generation: 2, configurationRevision: 1), "stale generation accepted")
    var configs = (0..<feeds).map { _ in MonitorConfiguration() }
    configs[0].zebra.thresholdIRE = 80
    if feeds > 1 { try require(configs[1].zebra.thresholdIRE == 95, "feed configuration leaked") }
    // Exercise actual package shader resource loading and independent shader-failure clean fallback.
    let gpuAvailable = MTLCreateSystemDefaultDevice() != nil
    let fixtureSource = try buffer(32), fixtureOutput = try buffer(240)
    func checkRuntime(shader: String?, expectDecoration: Bool) throws {
        let runtime = MonitorRuntime(sharedDevice: { MTLCreateSystemDefaultDevice() }, shaderSource: shader)
        var config = MonitorConfiguration(); config.toolsEnabled = true; config.zebra.enabled = true
        config.zebra.thresholdIRE = 50; config.scopes.enabled = true
        let target = MonitorTargetID("runtime-fixture")
        runtime.configure(target: target, generation: 1, configurationRevision: 1, configuration: config)
        let stamp = MonitorFrameStamp(target: target, generation: 1, sequence: 1, sourcePTS: 0, hostTime: ProcessInfo.processInfo.systemUptime, configurationRevision: 1)
        let checked = Results(), done = DispatchSemaphore(value: 0)
        let producerIdentity = ObjectIdentifier(fixtureOutput)
        let accepted = runtime.offer(MonitorFrameBundle(stamp: stamp, source: fixtureSource, output: fixtureOutput, sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "sRGB"), outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "sRGB"))) { result in
            switch result {
            case .failure(let error): checked.lock.lock(); if checked.errors.count < 16 { checked.errors.append(String(describing: error)) }; checked.lock.unlock()
            case .success(let display):
                checked.record(feed: 0, result: .success(display.clean), expected: 240,width:320,height:180,useOutput:true,start: stamp.hostTime)
                checked.lock.lock()
                if expectDecoration && (display.decorated == nil || display.scope == nil) { checked.errors.append("shader output/scope missing") }
                if !expectDecoration && display.decorated != nil { checked.errors.append("invalid shader failed to fall back") }
                if let decorated = display.decorated, ObjectIdentifier(decorated.pixelBuffer) == producerIdentity { checked.errors.append("decorated producer buffer reused") }
                checked.lock.unlock()
            }
            done.signal()
        }
        try require(accepted, "runtime fixture not admitted")
        try require(done.wait(timeout: .now() + 20) == .success, "runtime completion watchdog")
        try require(checked.errors.isEmpty, checked.errors.joined(separator: ", "))
        CVPixelBufferLockBaseAddress(fixtureOutput, .readOnly)
        let original = CVPixelBufferGetBaseAddress(fixtureOutput)!.load(as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(fixtureOutput, .readOnly)
        try require(original == 240, "monitor decorated source/recording branch in place")
    }
    try checkRuntime(shader: "deliberately invalid shader", expectDecoration: false)
    if gpuAvailable { try checkRuntime(shader: nil, expectDecoration: true) }
    let presentationBytes=MonitorPresentationEstimate.bytes(backingWidth:1280,backingHeight:720,scopes:true)
    var presentationAllowances:[MonitorResourceLease]=[]
    for feed in 0..<feeds {
        guard let lease=ledger.tryAcquire(target:MonitorTargetID("surface:synthetic-\(feed)"),generation:0,kind:.cleanPresentation,bytes:presentationBytes) else {throw Failure(reason:"visible workspace presentation allowance rejected")}
        presentationAllowances.append(lease)
    }
    let service = CleanPreviewService(budget: ledger), results = Results(), group = DispatchGroup()
    let sources = try (0..<feeds).map { try buffer(UInt8(20 + $0),width:width,height:height,format:format) }
    let outputs = try (0..<feeds).map { try buffer(UInt8(90 + $0),width:width,height:height,format:format) }
    let cleanWidth=width,cleanHeight=height
    let heartbeat=MainQueueHeartbeat()
    let started = ProcessInfo.processInfo.systemUptime
    let startFootprint=footprint()
    let sampler=QualificationSampler { ["footprint":Double(footprint()),"ledger":Double(ledger.snapshot.retainedBytes)] }
    var producerWork=ProducerWorkMetrics()
    var offered = 0, admitted = 0, peakBytes = 0, tick = 0
    var intervals=[Distribution](repeating:Distribution(),count:feeds),lastOffer=[Double?](repeating:nil,count:feeds)
    let scheduler=try onPacedProducer(period:1/fps,feeds:feeds) {
    var nextDeadline=ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - started < seconds {
        waitForProducerDeadline(nextDeadline)
        if ProcessInfo.processInfo.systemUptime-started >= seconds {break}
        nextDeadline=ProcessInfo.processInfo.systemUptime+1/fps
        let workStart=ProcessInfo.processInfo.systemUptime,cpuStart=producerThreadCPU()
        for offset in 0..<feeds {
            let feed = (tick + offset) % feeds
            let now = ProcessInfo.processInfo.systemUptime
            if let old=lastOffer[feed] {intervals[feed].add(now-old)};lastOffer[feed]=now
            let stamp = MonitorFrameStamp(target: MonitorTargetID("synthetic-\(feed)"), generation: 1, sequence: UInt64(tick), sourcePTS: Double(tick) / fps, hostTime: now, configurationRevision: 1)
            offered += 1; group.enter()
            let useOutput = (tick+feed) % 2 == 0
            let accepted = service.offer(MonitorFrameBundle(stamp: stamp, source: sources[feed], output: outputs[feed]), useOutput: useOutput) { result in
                results.record(feed: feed, result: result, expected: UInt8((useOutput ? 90 : 20) + feed),width:cleanWidth,height:cleanHeight,useOutput:useOutput,start: now)
                group.leave()
            }
            if accepted { admitted += 1 } else { group.leave() }
        }
        producerWork.record(wallStart:workStart,cpuStart:cpuStart)
        tick += 1

    }
    }
    let sampled=sampler.stop()
    peakBytes=Int(sampled.maxima["ledger"] ?? 0)
    let peakFootprint=UInt64(sampled.maxima["footprint"] ?? Double(startFootprint))
    try require(group.wait(timeout: .now() + 10) == .success, "copy completion watchdog")
    try require(results.errors.isEmpty, results.errors.joined(separator: ", "))
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    heartbeat.stop();let main=heartbeat.snapshot()
    let heldBytesAtClose=ledger.snapshot.retainedBytes
    results.releaseHeld()
    for lease in presentationAllowances {lease.release()}
    let releaseDeadline = ProcessInfo.processInfo.systemUptime + 3
    while ledger.snapshot.retainedBytes != 0 && ProcessInfo.processInfo.systemUptime < releaseDeadline { Thread.sleep(forTimeInterval: 0.001) }
    try require(ledger.snapshot.retainedBytes == 0, "owned-copy resources remain after completion")
    let rates = (0..<feeds).map { Double(results.counts[$0, default: 0]) / elapsed }
    // These are predeclared fixture minimums, not full-resolution product qualification.
    let minimumHz = 20.0
    let producerHz=Double(tick)/elapsed
    var failureReasons:[String]=[]
    if producerHz < fps*0.98 {failureReasons.append("producer pacing below98% target")}
    if !rates.allSatisfy({$0>=minimumHz}) {failureReasons.append("native clean cadence below20Hz/tile")}
    if results.ages.percentile(0.99)>200 {failureReasons.append("native clean p99 age exceeds200ms")}
    if main.0.count<UInt64(seconds*10) || main.0.percentile(0.95)>50 || main.0.percentile(0.99)>100 {failureReasons.append("main queue responsiveness gate")}
    let receipt: [String: Any] = ["declared_clean_stages":"alternating source/processedOutput; both native input dimensions","expected_clean_dimensions":"\(width)x\(height)","observed_clean_dimensions":results.dimensions,"observed_clean_stage_counts":results.stages,"activity_lifetime":"explicit matched end after completed workload","process_id":ProcessInfo.processInfo.processIdentifier,"source_essential_work":producerWork.dictionary(feeds:feeds),"telemetry_samples":sampled.count,"telemetry_observed_hz":Double(sampled.count)/sampled.elapsed,"status":failureReasons.isEmpty ? "passed":"failed","failure_reasons":failureReasons, "width":width,"height":height,"presentation_allowance_bytes_per_tile":presentationBytes,"presentation_allowance_total_bytes":presentationBytes*feeds,"presentation_backing_width":1280,"presentation_backing_height":720,"presentation_picture_buffer_count":2,"presentation_scope_drawable_count":2,"presentation_scope_width":768,"presentation_scope_height":256,"presentation_allowance_kind":"cleanPresentation","compositor_throughput":"unqualified: conservative budget estimate only; no actual display compositor","presentation_workload":"additional owned workspace surfaces","pixel_format":format == kCVPixelFormatType_422YpCbCr10 ? "v210":"BGRA","held_latest_frames_per_feed":1,"held_bytes_at_close":heldBytesAtClose,"teardown_retained_bytes":ledger.snapshot.retainedBytes,"process_footprint_start":startFootprint,"sampled_peak_process_footprint":peakFootprint,"process_footprint_end":footprint(),"main_queue_observed":main.0.count,"main_queue_p95_ms":main.0.percentile(0.95),"main_queue_p99_ms":main.0.percentile(0.99),"main_queue_pending_skips":main.1, "workload":"Clean\(width)x\(height)-\(format == kCVPixelFormatType_422YpCbCr10 ? "v210":"BGRA")-\(feeds)Feed-\(fps)Hz", "synthetic_only":true,
        "producer_scheduler":scheduler.dictionary,"seconds":elapsed,"producer_effective_hz":producerHz,"producer_offer_interval_p95_ms":intervals.map{$0.percentile(0.95)},"producer_offer_interval_p99_ms":intervals.map{$0.percentile(0.99)},"producer_pacing":"latencyCritical activity; host-clock no catchup; minimum98% nominal", "offered":offered, "admitted":admitted, "skipped":offered-admitted,
        "per_feed_hz":rates, "minimum_per_feed_hz":minimumHz, "age_p95_ms":results.ages.percentile(0.95),
        "age_p99_ms":results.ages.percentile(0.99), "old_surface_release_p95_ms":results.releases.percentile(0.95),"old_surface_release_p99_ms":results.releases.percentile(0.99), "maximum_age_p99_ms":200, "sampled_peak_ledger_bytes":peakBytes, "ledger_sample_hz":2, "maximum_clean_copy_jobs":4, "maximum_analysis_bundles":2,
        "camera_p95_regression_tolerance_ms":2, "camera_p99_regression_tolerance_ms":5,
        "camera_qualification":"unqualified: no active consumer", "analysis_qualification":gpuAvailable ? "functional shader/scope fixture passed; sustained analysis pending" : "skipped: GPU unavailable",
        "gpu_available":MTLCreateSystemDefaultDevice() != nil, "recording_qualification":"pending separate encoder comparisons"]
    print(String(data: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), encoding: .utf8)!);fflush(stdout)
    try require(failureReasons.isEmpty,failureReasons.joined(separator:", "))
    exitCode=0
} catch { fputs("MONITOR_SYNTHETIC FAIL \(error)\n", stderr); exitCode=1 }
ProcessInfo.processInfo.endActivity(qualificationActivity)
exit(exitCode)
}
dispatchMain()

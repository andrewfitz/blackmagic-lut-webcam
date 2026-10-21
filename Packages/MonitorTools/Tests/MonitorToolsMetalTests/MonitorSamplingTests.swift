import Foundation
@preconcurrency import Metal
import XCTest
@testable import MonitorToolsMetal

final class MonitorSamplingTests: XCTestCase {
  private func context(extra: String = "") throws -> (MTLDevice, MTLCommandQueue, MTLLibrary) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("Metal unavailable") }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("Sources/MonitorToolsMetal/Resources/MonitorTools.metal.txt"), encoding: .utf8)
    let options = MTLCompileOptions(); options.mathMode = .safe
    return (device, queue, try device.makeLibrary(source: text + extra, options: options))
  }

  func testRotatingScopeLatticeConservesEveryPixelIncludingPartialEdgeCells() throws {
    let (device, queue, library) = try context()
    let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "scopes")))
    let w = 13, h = 7, step = 4
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    var expected = [UInt32](repeating: 0, count: 768 * 256)
    for y in 0..<h { for x in 0..<w {
      let channels = [UInt8((x * 17 + y * 7) % 256),UInt8((x * 3 + y * 31) % 256),UInt8((x * 11 + y * 13) % 256)]
      let at = (y*w+x)*4
      bytes[at] = channels[2]; bytes[at+1] = channels[1]; bytes[at+2] = channels[0]; bytes[at+3] = 255
      for c in 0..<3 {
        let bin = Int(min(1,max(0,(Double(channels[c])/255+0.1)/1.2))*255)
        expected[bin*768+c*256+x*256/w] += 1
      }
    }}
    let raw = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared))
    var actual = [UInt32](repeating: 0, count: expected.count)
    for phase in 0..<(step*step) {
      let bins = try XCTUnwrap(device.makeBuffer(length: expected.count * 4, options: .storageModeShared))
      memset(bins.contents(),0,bins.length)
      var p = KernelParameters(); p.width = UInt32(w); p.height = UInt32(h); p.stride = UInt32(w*4); p.format = 1
      p.scopeSamplingStride = UInt32(step); p.scopeSamplingPhase = UInt32(phase)
      let command = try XCTUnwrap(queue.makeCommandBuffer()), encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
      encoder.setComputePipelineState(pipeline); encoder.setBuffer(raw, offset: 0,index: 0)
      encoder.setBytes(&p,length: MemoryLayout<KernelParameters>.stride,index: 1); encoder.setBuffer(bins,offset: 0,index: 2)
      encoder.dispatchThreads(.init(width: (w+step-1)/step,height: (h+step-1)/step,depth: 1),threadsPerThreadgroup: .init(width: 4,height: 4,depth: 1))
      encoder.endEncoding(); command.commit(); command.waitUntilCompleted(); XCTAssertEqual(command.status,.completed)
      let values = bins.contents().assumingMemoryBound(to: UInt32.self)
      for i in actual.indices { actual[i] += values[i] }
    }
    XCTAssertEqual(actual.reduce(0,+), UInt32(w*h*3))
    XCTAssertEqual(actual,expected,"Every source pixel must appear exactly once across the sampling cycle")
  }

  func testDirectYMatchesMatrixWeightedRGBForEverySupportedLayoutAndRange() throws {
    let extra = """
    kernel void verifyY(device const uchar* raw [[buffer(0)]],constant Params& p [[buffer(1)]],device float2* values [[buffer(2)]],uint2 xy [[thread_position_in_grid]]) {
      if(xy.x<p.width&&xy.y<p.height)values[xy.y*p.width+xy.x]=float2(readSignalY(raw,xy.x,xy.y,p),signalLuma(readRGB(raw,xy.x,xy.y,p),p));
    }
    """
    let (device,queue,library) = try context(extra: extra)
    let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "verifyY")))
    for format: UInt32 in 0...7 { for full in [false,true] { for coefficients in [SIMD4<Float>(0.2126,0.7152,0.0722,0),SIMD4<Float>(0.2627,0.678,0.0593,0)] {
      let w = 12,h = 4,stride = format == 0 ? 32 : format == 1 ? 48 : format >= 4 ? 32 : 16
      var bytes = [UInt8](repeating: 0,count: stride*h + (format < 2 ? 0 : stride*(format>=6 ? h : h/2)))
      if format == 0 {
        bytes.withUnsafeMutableBytes { storage in
          let words = storage.bindMemory(to: UInt32.self)
          for y in 0..<h { for group in 0..<2 {
            let yv = (0..<6).map { UInt32((50+(group*6+$0)*79+y*31)%1024) }
            let base = y*stride/4+group*4
            words[base] = 300 | (yv[0]<<10) | (700<<20)
            words[base+1] = yv[1] | (400<<10) | (yv[2]<<20)
            words[base+2] = 600 | (yv[3]<<10) | (500<<20)
            words[base+3] = yv[4] | (550<<10) | (yv[5]<<20)
          }}
        }
      } else if format == 1 {
        for y in 0..<h { for x in 0..<w { let at=y*stride+x*4;bytes[at]=UInt8((x*29+y*3)%256);bytes[at+1]=UInt8((x*13+y*11)%256);bytes[at+2]=UInt8((x*7+y*17)%256);bytes[at+3]=255 }}
      } else if format >= 4 {
        bytes.withUnsafeMutableBytes { storage in
          let words = storage.bindMemory(to: UInt16.self)
          for y in 0..<h { for x in 0..<w { words[y*stride/2+x]=UInt16((50+x*79+y*31)%1024)<<6 }}
          for i in (stride*h/2)..<words.count { words[i]=UInt16(300+(i%5)*80)<<6 }
        }
      } else {
        for y in 0..<h { for x in 0..<w { bytes[y*stride+x]=UInt8((20+x*19+y*11)%256) }}
        for i in (stride*h)..<bytes.count { bytes[i]=UInt8(64+(i%5)*25) }
      }
      let raw = try XCTUnwrap(device.makeBuffer(bytes:bytes,length:bytes.count,options:.storageModeShared))
      let output = try XCTUnwrap(device.makeBuffer(length:w*h*8,options:.storageModeShared))
      var p=KernelParameters();p.width=UInt32(w);p.height=UInt32(h);p.stride=UInt32(stride);p.format=format;p.coefficients=coefficients;p.coefficients.w=full ? 1 : 0
      let command=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(command.makeComputeCommandEncoder())
      encoder.setComputePipelineState(pipeline);encoder.setBuffer(raw,offset:0,index:0);encoder.setBytes(&p,length:MemoryLayout<KernelParameters>.stride,index:1);encoder.setBuffer(output,offset:0,index:2)
      encoder.dispatchThreads(.init(width:w,height:h,depth:1),threadsPerThreadgroup:.init(width:4,height:4,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted();XCTAssertEqual(command.status,.completed)
      let values=output.contents().assumingMemoryBound(to:SIMD2<Float>.self)
      for i in 0..<(w*h) { XCTAssertEqual(values[i].x,values[i].y,accuracy:0.000002,"format \(format),full \(full),pixel \(i)") }
    }}}
  }
}

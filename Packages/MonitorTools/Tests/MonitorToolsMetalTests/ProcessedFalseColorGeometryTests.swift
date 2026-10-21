import Foundation
@preconcurrency import Metal
import MonitorToolsCore
import XCTest
@testable import MonitorToolsMetal

final class ProcessedFalseColorGeometryTests: XCTestCase {
  /// Independent pixel-center oracle: preview center -> continuous picture
  /// coordinate -> continuous source coordinate -> one final source floor.
  func testFalseColorMapsContinuousProcessedCentersBeforeSourceQuantization() throws {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw XCTSkip("Metal unavailable") }
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source=try String(contentsOf:root.appendingPathComponent("Sources/MonitorToolsMetal/Resources/MonitorTools.metal.txt"),encoding:.utf8)
    let options=MTLCompileOptions();options.mathMode = .safe
    let library=try device.makeLibrary(source:source,options:options)
    let pipeline=try device.makeComputePipelineState(function:XCTUnwrap(library.makeFunction(name:"compose")))
    let codes:[UInt8]=[24,105,124,137,212,225,60,170,91,200,15]
    let cases:[(sw:Int,sh:Int,pw:Int,ph:Int,ow:Int,oh:Int,m:SIMD4<Float>)]=[
      (96,24,48,12,32,8,SIMD4(0.5,0.5,0,0)),
      (96,24,48,12,32,8,SIMD4(0.5,0.5,1.25,-0.75)),
      (24,12,48,24,24,12,SIMD4(2,2,0,0)),
      // Source-view control keeps identity correspondence through minification.
      (96,24,96,24,64,16,SIMD4(1,1,0,0)),
    ]
    for c in cases {
      var native=[UInt8](repeating:0,count:c.sw*c.sh*4)
      for y in 0..<c.sh { for x in 0..<c.sw {
        let value=codes[(x+3*y)%codes.count],i=(y*c.sw+x)*4
        native[i]=value;native[i+1]=value;native[i+2]=value;native[i+3]=255
      }}
      let nativeBuffer=try XCTUnwrap(device.makeBuffer(bytes:native,length:native.count,options:.storageModeShared))
      let picture=try XCTUnwrap(device.makeBuffer(length:c.pw*c.ph*4,options:.storageModeShared))
      memset(picture.contents(),200,picture.length)
      let focus=try XCTUnwrap(device.makeTexture(descriptor:.texture2DDescriptor(pixelFormat:.r8Unorm,width:1,height:1,mipmapped:false)))
      for flag in [MonitorKernelFlag.sonySLog3,MonitorKernelFlag.elZone,MonitorKernelFlag.logC3,MonitorKernelFlag.logC4] {
        var p=KernelParameters();p.width=UInt32(c.pw);p.height=UInt32(c.ph);p.stride=UInt32(c.pw*4);p.format=1
        p.outWidth=UInt32(c.ow);p.outHeight=UInt32(c.oh);p.flags=flag;p.mapping=c.m;p.coefficients.w=1
        var sp=KernelParameters();sp.width=UInt32(c.sw);sp.height=UInt32(c.sh);sp.stride=UInt32(c.sw*4);sp.format=1;sp.coefficients.w=1
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:c.ow,height:c.oh,mipmapped:false)
        descriptor.usage=[.shaderRead,.shaderWrite]
        let output=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
        let readback=try XCTUnwrap(device.makeBuffer(length:c.ow*c.oh*4,options:.storageModeShared))
        let command=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline);encoder.setBuffer(picture,offset:0,index:0)
        encoder.setBytes(&p,length:MemoryLayout<KernelParameters>.stride,index:1)
        encoder.setBuffer(nativeBuffer,offset:0,index:3);encoder.setBytes(&sp,length:MemoryLayout<KernelParameters>.stride,index:4)
        encoder.setTexture(focus,index:0);encoder.setTexture(output,index:1)
        encoder.dispatchThreads(.init(width:c.ow,height:c.oh,depth:1),threadsPerThreadgroup:.init(width:8,height:8,depth:1));encoder.endEncoding()
        let blit=try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from:output,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:c.ow,height:c.oh,depth:1),to:readback,destinationOffset:0,destinationBytesPerRow:c.ow*4,destinationBytesPerImage:c.ow*c.oh*4)
        blit.endEncoding();command.commit();command.waitUntilCompleted();XCTAssertEqual(command.status,.completed)
        let actual=readback.contents().assumingMemoryBound(to:UInt8.self)
        for y in 0..<c.oh { for x in 0..<c.ow {
          let px=(Double(x)+0.5)*Double(c.pw)/Double(c.ow)-0.5
          let py=(Double(y)+0.5)*Double(c.ph)/Double(c.oh)-0.5
          let sx=Int(max(0,min(Double(c.sw-1),(px+0.5-Double(c.m.z))/Double(c.m.x)-0.5)))
          let sy=Int(max(0,min(Double(c.sh-1),(py+0.5-Double(c.m.w))/Double(c.m.y)-0.5)))
          let value=Double(codes[(sx+3*sy)%codes.count])/255
          let rgb=MonitorRGB(r:value,g:value,b:value)
          let expected:MonitorRGB
          if flag==MonitorKernelFlag.sonySLog3 { expected=try XCTUnwrap(SonySLog3FalseColor.color(rgb:rgb)) }
          else if flag==MonitorKernelFlag.elZone { expected=try XCTUnwrap(ELZoneProfile.color(rgb:rgb,gamut:.sGamut3Cine)) }
          else {
            let profile:ARRIFalseColorProfile=flag==MonitorKernelFlag.logC3 ? .logC3EI800 : .alexa35LogC4EI800
            expected=profile.category(achromaticCode:value*1023,range:.full)?.color ?? rgb
          }
          for (channel,component) in [expected.b,expected.g,expected.r].enumerated() {
            XCTAssertEqual(Int(actual[(y*c.ow+x)*4+channel]),Int((component*255).rounded()),accuracy:1,
              "mode\(flag),preview(\(x),\(y))->source(\(sx),\(sy)),picture\(c.pw)x\(c.ph),preview\(c.ow)x\(c.oh),mapping\(c.m)")
          }
        }}
      }
    }
  }
}

import CoreVideo
@preconcurrency import Metal
import MonitorToolsCore
import XCTest
@testable import MonitorToolsMetal

final class SourceInterpretationGuardTests: XCTestCase {
  func testSonyAndFocusRejectSourceGeometryThatDoesNotDescribeSourceBuffer() throws {
    try assertRejected(mode:.sonySLog3,focus:true,geometry:MonitorGeometry(width:16,height:32),mapping:.identity)
  }

  func testELZoneRejectsFiniteDoubleCorrespondenceThatBecomesZeroOrInfiniteFloat() throws {
    for mapping in [
      MonitorCorrespondence(scaleX:1e-300,scaleY:1,offsetX:0,offsetY:0),
      MonitorCorrespondence(scaleX:1e300,scaleY:1,offsetX:0,offsetY:0),
      MonitorCorrespondence(scaleX:1,scaleY:1,offsetX:1e300,offsetY:0),
    ] {
      try assertRejected(mode:.elZone,focus:false,geometry:nil,mapping:mapping)
    }
  }

  private final class Box:@unchecked Sendable { var result:Result<MonitorDisplayResult,Error>? }
  private func assertRejected(mode:MonitorFalseColorMode,focus:Bool,geometry:MonitorGeometry?,mapping:MonitorCorrespondence) throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let source=try image(value:105),output=try image(value:17)
    var config=MonitorConfiguration();config.toolsEnabled=true;config.pictureStage = .processedOutput
    config.sourceProfileID="sony-slog3-sgamut3cine";config.falseColor.mode=mode;config.focus.enabled=focus
    config.falseColor.profileID=mode == .sonySLog3 ? SonySLog3FalseColor.profileID : ELZoneProfile.profileID
    let runtime=MonitorRuntime(),target=MonitorTargetID(UUID().uuidString)
    runtime.configure(target:target,generation:1,configurationRevision:1,configuration:config)
    defer { runtime.remove(target:target) }
    let stamp=MonitorFrameStamp(target:target,generation:1,sequence:1,sourcePTS:1,hostTime:1,configurationRevision:1)
    let done=expectation(description:"invalid source interpretation rejected"),box=Box()
    XCTAssertTrue(runtime.offer(MonitorFrameBundle(stamp:stamp,source:source,output:output,
      sourceGeometry:geometry,correspondence:mapping,
      sourceSignal:MonitorFrameSignal(range:.full,matrix:.bt709,transfer:"S-Log3",profileID:config.sourceProfileID),
      outputSignal:MonitorFrameSignal(range:.full,matrix:.bt709,transfer:"Rec709"))) { result in box.result=result;done.fulfill() })
    wait(for:[done],timeout:10)
    let display=try XCTUnwrap(box.result).get()
    XCTAssertTrue(display.availability.contains { $0.contains("False color unavailable") },"\(display.availability),\(mapping)")
    if focus { XCTAssertTrue(display.availability.contains { $0.contains("Focus unavailable") },"\(display.availability)") }
    try assertGray(display.clean.pixelBuffer)
    try assertGray(XCTUnwrap(display.decorated,"Valid Rec709 picture composition remains available").pixelBuffer)
  }

  private func image(value:UInt8) throws -> CVPixelBuffer {
    var pb:CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pb),kCVReturnSuccess)
    let buffer=try XCTUnwrap(pb)
    CVPixelBufferLockBaseAddress(buffer,[]);defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
    let base=try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to:UInt8.self)
    let stride=CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<32 { for x in 0..<32 { let i=y*stride+x*4;base[i]=value;base[i+1]=value;base[i+2]=value;base[i+3]=255 }}
    return buffer
  }
  private func assertGray(_ buffer:CVPixelBuffer,file:StaticString=#filePath,line:UInt=#line) throws {
    CVPixelBufferLockBaseAddress(buffer,.readOnly);defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
    let bytes=try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to:UInt8.self)
    for channel in 0..<3 { XCTAssertEqual(bytes[channel],17,file:file,line:line) }
  }
}

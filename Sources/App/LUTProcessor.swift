import CoreImage
import CoreVideo
import Metal

// Capture-queue ownership. Core Image is only for preview. All production
// processing uses explicit 32-bit float Metal textures and LUT samples.
final class LUTProcessor {
  let context: CIContext
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let states: [String: MTLComputePipelineState]
  private var textureCache: CVMetalTextureCache!
  private var pool: CVPixelBufferPool?
  private var poolConfiguration: PipelineConfiguration?
  private var cube: CubeLUT?
  private var cubeBuffer: MTLBuffer
  private var packedBuffer: MTLBuffer?
  private var fullTexture: MTLTexture?
  private var horizontalTexture: MTLTexture?
  private var scaledTexture: MTLTexture?

  private struct Parameters {
    var geometry: SIMD4<UInt32>
    var domainLow: SIMD4<Float>
    var domainScale: SIMD4<Float>
    var decodeRange: SIMD4<Float>
    var decodeMatrix: SIMD4<Float>
    var encodeMatrix: SIMD4<Float>
    var options: SIMD4<UInt32>
  }

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw VideoError.message("A Metal GPU is required.")
    }
    self.device = device
    commandQueue = queue
    context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let library: MTLLibrary
    if let path = ProcessInfo.processInfo.environment["ULTRASTUDIO_LUT_METALLIB"] {
      library = try device.makeLibrary(URL: URL(fileURLWithPath: path))
    } else {
      let url = ProcessInfo.processInfo.environment["ULTRASTUDIO_LUT_SHADER"].map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.url(forResource: "LUTShaders", withExtension: "metal")
      guard let url else { throw VideoError.message("GPU shader resource is missing.") }
      library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }
    var states: [String: MTLComputePipelineState] = [:]
    for name in ["planarLUT", "packedLUT", "lanczosHorizontal", "lanczosVertical", "encodeNV12", "encode422"] {
      guard let function = library.makeFunction(name: name) else { throw VideoError.message("Missing GPU function \(name).") }
      states[name] = try device.makeComputePipelineState(function: function)
    }
    self.states = states
    guard let buffer = device.makeBuffer(length: 16, options: .storageModeShared) else {
      throw VideoError.message("Cannot allocate LUT buffer.")
    }
    cubeBuffer = buffer
    let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    guard status == kCVReturnSuccess else { throw VideoError.message("Cannot create GPU texture cache.") }
  }

  func load(_ cube: CubeLUT) throws {
    let data = cube.data
    guard let buffer = data.withUnsafeBytes({ bytes in
      device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
    }) else { throw VideoError.message("Cannot upload LUT to GPU.") }
    self.cube = cube
    cubeBuffer = buffer
  }

  private func preparePool(_ configuration: PipelineConfiguration) throws -> CVPixelBufferPool {
    if poolConfiguration == configuration, let pool { return pool }
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, [
      kCVPixelBufferPixelFormatTypeKey: configuration.pixelFormat,
      kCVPixelBufferWidthKey: configuration.width,
      kCVPixelBufferHeightKey: configuration.height,
      kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw VideoError.message("Cannot allocate output pool.") }
    self.pool = pool
    poolConfiguration = configuration
    return pool
  }

  private func texture(width: Int, height: Int, existing: inout MTLTexture?) throws -> MTLTexture {
    if let existing, existing.width == width, existing.height == height { return existing }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let result = device.makeTexture(descriptor: descriptor) else { throw VideoError.message("Cannot allocate GPU working texture.") }
    existing = result
    return result
  }

  private func plane(_ buffer: CVPixelBuffer, index: Int, format: MTLPixelFormat) throws -> (CVMetalTexture, MTLTexture) {
    var wrapper: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
      CVPixelBufferGetWidthOfPlane(buffer, index), CVPixelBufferGetHeightOfPlane(buffer, index), index, &wrapper)
    guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
      throw VideoError.message("Cannot map video plane \(index) to GPU (\(status)).")
    }
    return (wrapper, texture)
  }

  private func dispatch(_ name: String, on command: MTLCommandBuffer, width: Int, height: Int,
    configure: (MTLComputeCommandEncoder) -> Void) throws {
    guard let state = states[name], let encoder = command.makeComputeCommandEncoder() else {
      throw VideoError.message("Cannot create GPU encoder.")
    }
    encoder.label = name
    encoder.setComputePipelineState(state)
    configure(encoder)
    let w = state.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: w, height: min(8, state.maxTotalThreadsPerThreadgroup / w), depth: 1))
    encoder.endEncoding()
  }

  func process(_ input: CVPixelBuffer, configuration: PipelineConfiguration) throws -> CVPixelBuffer {
    if configuration.untouched { return input }
    guard !configuration.applyLUT || cube != nil else { throw VideoError.message("Load a log-to-Rec.709 LUT before starting.") }
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
    guard VideoContract.tenBit422.contains(type) else { throw VideoError.message("Expected 10-bit 4:2:2 input.") }
    let matrix = CVBufferCopyAttachment(input, kCVImageBufferYCbCrMatrixKey, nil) as? String
    let kr: Float = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? 0.2627 :
      (matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 0.299 : 0.2126)
    let kb: Float = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? 0.0593 :
      (matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 0.114 : 0.0722)
    let kg = 1 - kr - kb
    let fullRange = type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    let low = cube?.domainMin ?? .zero
    let scale = SIMD3<Float>(repeating: 1) / ((cube?.domainMax ?? SIMD3(repeating: 1)) - low)
    var parameters = Parameters(
      geometry: SIMD4(UInt32(width), UInt32(height), UInt32(CVPixelBufferGetBytesPerRow(input) / 4), UInt32(cube?.dimension ?? 2)),
      domainLow: SIMD4(low.x, low.y, low.z, 0), domainScale: SIMD4(scale.x, scale.y, scale.z, 0),
      decodeRange: SIMD4(fullRange ? 0 : 64, fullRange ? 1023 : 876, 512, fullRange ? 1023 : 896),
      decodeMatrix: SIMD4(2 * (1 - kr), 2 * (1 - kb), 2 * kb * (1 - kb) / kg, 2 * kr * (1 - kr) / kg),
      encodeMatrix: SIMD4(configuration.applyLUT ? 0.2126 : kr, configuration.applyLUT ? 0.0722 : kb, 0, 0),
      options: SIMD4(configuration.applyLUT ? 1 : 0, 0, 0, 0))
    guard let command = commandQueue.makeCommandBuffer() else { throw VideoError.message("GPU is unavailable.") }
    command.label = "LUT → Lanczos → output format"
    let full = try texture(width: width, height: height, existing: &fullTexture)
    var wrappers: [CVMetalTexture] = []
    if type == kCVPixelFormatType_422YpCbCr10 {
      CVPixelBufferLockBaseAddress(input, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
      let length = CVPixelBufferGetBytesPerRow(input) * height
      if packedBuffer == nil || packedBuffer!.length < length { packedBuffer = device.makeBuffer(length: length, options: .storageModeShared) }
      guard let packedBuffer, let base = CVPixelBufferGetBaseAddress(input) else { throw VideoError.message("Cannot read packed capture frame.") }
      memcpy(packedBuffer.contents(), base, length)
      try dispatch("packedLUT", on: command, width: width, height: height) { encoder in
        encoder.setBuffer(packedBuffer, offset: 0, index: 2)
        encoder.setBuffer(cubeBuffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 1)
        encoder.setTexture(full, index: 2)
      }
    } else {
      let (yWrapper, y) = try plane(input, index: 0, format: .r16Unorm)
      let (uvWrapper, uv) = try plane(input, index: 1, format: .rg16Unorm)
      wrappers += [yWrapper, uvWrapper]
      try dispatch("planarLUT", on: command, width: width, height: height) { encoder in
        encoder.setTexture(y, index: 0); encoder.setTexture(uv, index: 1); encoder.setTexture(full, index: 2)
        encoder.setBuffer(cubeBuffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 1)
      }
    }
    var final = full
    if configuration.downscale {
      let horizontal = try texture(width: configuration.width, height: height, existing: &horizontalTexture)
      let scaled = try texture(width: configuration.width, height: configuration.height, existing: &scaledTexture)
      try dispatch("lanczosHorizontal", on: command, width: horizontal.width, height: horizontal.height) {
        $0.setTexture(full, index: 0); $0.setTexture(horizontal, index: 1)
      }
      try dispatch("lanczosVertical", on: command, width: scaled.width, height: scaled.height) {
        $0.setTexture(horizontal, index: 0); $0.setTexture(scaled, index: 1)
      }
      final = scaled
    }
    let pool = try preparePool(configuration)
    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
      [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output)
    guard status == kCVReturnSuccess, let output else { throw VideoError.message("Output buffers are busy (\(status)).") }
    let (yWrapper, y) = try plane(output, index: 0, format: configuration.convertTo420 ? .r8Unorm : .r16Unorm)
    let (uvWrapper, uv) = try plane(output, index: 1, format: configuration.convertTo420 ? .rg8Unorm : .rg16Unorm)
    wrappers += [yWrapper, uvWrapper]
    try dispatch(configuration.convertTo420 ? "encodeNV12" : "encode422", on: command, width: final.width, height: final.height) {
      $0.setTexture(final, index: 0); $0.setTexture(y, index: 1); $0.setTexture(uv, index: 2)
      $0.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 1)
    }
    command.commit()
    command.waitUntilCompleted()
    withExtendedLifetime(wrappers) {}
    guard command.status == .completed else { throw VideoError.message(command.error?.localizedDescription ?? "GPU processing failed.") }
    if !configuration.applyLUT { CVBufferPropagateAttachments(input, output) }
    let outputMatrix = configuration.applyLUT ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 :
      (matrix.map { $0 as CFString } ?? kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, outputMatrix, .shouldPropagate)
    if configuration.applyLUT {
      CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }
    return output
  }
}

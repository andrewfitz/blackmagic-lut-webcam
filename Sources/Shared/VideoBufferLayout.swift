import CoreVideo

// Core Video accepts caller-supplied plane dimensions and strides independently
// of the image's declared format. Validate those before bypass, transport or GPU
// mapping; an overall 4K label does not prove that both 4K planes exist.
enum VideoBufferLayout {
  static func validate(_ image: CVPixelBuffer) throws {
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    let type = CVPixelBufferGetPixelFormatType(image)
    guard width > 0, height > 0 else {
      throw VideoError.message("Invalid video image dimensions.")
    }
    if type == kCVPixelFormatType_422YpCbCr10 {
      let (paddedWidth, widthOverflow) = width.addingReportingOverflow(5)
      let (minimumStride, strideOverflow) = (paddedWidth / 6).multipliedReportingOverflow(by: 16)
      let stride = CVPixelBufferGetBytesPerRow(image)
      let (length, lengthOverflow) = stride.multipliedReportingOverflow(by: height)
      guard !CVPixelBufferIsPlanar(image), CVPixelBufferGetPlaneCount(image) == 0,
        !widthOverflow, !strideOverflow, !lengthOverflow, length > 0,
        stride >= minimumStride, stride.isMultiple(of: 4) else {
        throw VideoError.message("Invalid packed 10-bit video layout.")
      }
      return
    }
    let is420 = type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    guard is420 || type == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ||
      type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange else {
      throw VideoError.message("Unsupported video pixel format.")
    }
    guard width.isMultiple(of: 2), !is420 || height.isMultiple(of: 2),
      CVPixelBufferIsPlanar(image), CVPixelBufferGetPlaneCount(image) == 2 else {
      throw VideoError.message("Invalid bi-planar video layout.")
    }
    let bytesPerComponent = is420 ? 1 : 2
    let (minimumStride, strideOverflow) = width.multipliedReportingOverflow(by: bytesPerComponent)
    guard !strideOverflow else { throw VideoError.message("Invalid video row stride.") }
    for plane in 0..<2 {
      let rows = plane == 1 && is420 ? height / 2 : height
      let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
      let (length, lengthOverflow) = stride.multipliedReportingOverflow(by: rows)
      guard CVPixelBufferGetWidthOfPlane(image, plane) == (plane == 0 ? width : width / 2),
        CVPixelBufferGetHeightOfPlane(image, plane) == rows,
        stride >= minimumStride, stride.isMultiple(of: bytesPerComponent),
        !lengthOverflow, length > 0 else {
        throw VideoError.message("Invalid video plane \(plane) dimensions or row stride.")
      }
    }
  }
}

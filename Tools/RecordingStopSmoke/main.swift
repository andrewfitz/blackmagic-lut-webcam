import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Synthetic v210 only. Exercise the real remote ProRes encoder, callback
// queue, audio interleave and movie finalization without opening any device.
DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
  fputs("RECORDING_STOP FAIL watchdog expired\n", stderr)
  _exit(124)
}
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw SourceRecordingError.writerFailure(message) }
}
do {
  guard let path = CommandLine.arguments.dropFirst().first else {
    throw SourceRecordingError.invalidConfiguration("Pass a temporary output directory.")
  }
  let root = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var buffer: CVPixelBuffer?
  let result = CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
  try require(result == kCVReturnSuccess && buffer != nil, "Cannot allocate synthetic v210 input.")
  let image = buffer!
  CVPixelBufferLockBaseAddress(image, [])
  memset(CVPixelBufferGetBaseAddress(image)!, 0, CVPixelBufferGetDataSize(image))
  CVPixelBufferUnlockBaseAddress(image, [])
  let duration = CMTime(value: 1001, timescale: 60000)
  for (codecName, codec) in [("ProRes", kCMVideoCodecType_AppleProRes422HQ), ("HEVC", kCMVideoCodecType_HEVC)] {
  for take in 1...3 {
    let url = root.appendingPathComponent("Synthetic \(codecName) \(take).mov")
    let configuration = try SourceRecordingConfiguration(feedID: SourceRecordingFeedID("synthetic"),
      outputURL: url, width: 3840, height: 2160, videoCodec: codec,
      queueCapacity: 24)
    let recorder = try SourceRecorderCore(configuration: configuration)
    try recorder.start()
    let started = ProcessInfo.processInfo.systemUptime
    for frame in 0..<60 {
      let target = started + Double(frame) * duration.seconds
      while ProcessInfo.processInfo.systemUptime < target { Thread.sleep(forTimeInterval: 0.001) }
      let pts = CMTimeMultiply(duration, multiplier: Int32(frame))
      let sample = try VideoContract.sample(image, at: pts, duration: duration)
      try require(recorder.appendVideo(sample), "Synthetic video admission failed.")
      let packet = try EmbeddedAudioPacket(sourcePCM32: Data(repeating: 0, count: 800 * 2 * 4),
        sampleFrameCount: 800, presentationTime: CMTime(value: Int64(frame) * 800, timescale: 48000))
      try require(recorder.appendAudio(EmbeddedAudioRecording.makeSampleBuffer(for: packet)),
        "Synthetic audio admission failed.")
    }
    let stopping = ProcessInfo.processInfo.systemUptime
    try recorder.stop()
    try require(recorder.state == .finished, "Recorder did not finish.")
    let telemetry = recorder.telemetry
    try require(telemetry.encodedVideo == 60 && telemetry.encoderErrors == 0 && telemetry.totalDrops == 0,
      "Encoded frames were lost or the encoder reported an error: \(telemetry)")
    try require(telemetry.encodedVideoBytes > 0 && telemetry.hardwareEncoder == true,
      "Missing encoded-byte or hardware-encoder telemetry.")
    try require(telemetry.encoderLatencyMS != nil && telemetry.maxEncoderLatencyMS != nil
      && telemetry.encoderPendingFrames == 0 && telemetry.queueSamples == 0,
      "Latency or drained queue telemetry is wrong.")
    let asset = AVURLAsset(url: url)
    let readable = DispatchSemaphore(value: 0)
    let keys = ["tracks", "duration"]
    asset.loadValuesAsynchronously(forKeys: keys) { readable.signal() }
    try require(readable.wait(timeout: .now() + 5) == .success, "Movie readback timed out.")
    try require(asset.tracks(withMediaType: .video).count == 1 && asset.tracks(withMediaType: .audio).count == 1,
      "Final movie is missing its video or audio track.")
    try require(asset.duration.seconds > 0.9, "Final movie duration is truncated.")
    print("RECORDING_STOP PASS codec=\(codecName) take=\(take) encoded=60 stopSeconds=\(ProcessInfo.processInfo.systemUptime - stopping) tracks=video,audio encodedBytes=\(telemetry.encodedVideoBytes) hardware=\(telemetry.hardwareEncoder == true) latencyMS=\(telemetry.encoderLatencyMS ?? -1) physicalCapture=false")
  }
  }
} catch {
  fputs("RECORDING_STOP FAIL \(error.localizedDescription)\n", stderr)
  exit(1)
}

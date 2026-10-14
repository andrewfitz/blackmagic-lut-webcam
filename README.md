# UltraStudio LUT

A standalone native macOS app and Core Media I/O camera extension for a Sony
FX3 log feed through an UltraStudio Mini Recorder 12G. Select **UltraStudio LUT**
as the camera in Zoom or another macOS camera application.

## Processing

The four checkboxes are independent and ordered:

1. **Apply LUT:** decode source 10-bit Y′CbCr to floating-point log RGB and apply
   a `.cube` at the original 3840 × 2160 resolution. No implicit linearization
   or additional log-to-display transform is applied. The LUT must match
   S-Gamut3.Cine/S-Log3 or S-Gamut3/S-Log3 and output display Rec.709.
2. **Downscale:** use a separable Lanczos-3 filter with scale-adjusted support
   and normalized weights to reduce 4K to 1920 × 1080. Intermediate textures
   remain 32-bit float.
3. **Color format:** produce 4:2:0 8-bit video-range NV12. When disabled, produce
   4:2:2 10-bit video-range `x422`. Chroma sampling and integer quantization occur
   after LUT processing and spatial scaling.
4. **Frame rate:** reduce 59.94 to 29.97 by selecting every second source frame
   after pixel processing. This does not affect a 29.97 source.

Defaults: LUT off, downscale and color conversion enabled, frame-rate reduction
disabled. A LUT is optional; loading one enables its checkbox. Both source rates use their exact rational values, 30000/1001 and
60000/1001. DF is a timecode convention, not a pixel-processing operation.

With all pixel-processing switches disabled, the original input pixel buffer
is forwarded without color conversion. A bounded bit-exact IOSurface copy is
used only when camera transport or native display requires shareable memory. Frame-rate reduction
can still be enabled independently. A processed 10-bit output is high-precision
video, but the LUT intentionally changes its pixel values.

Controls are locked while streaming. Stop the feed before changing its format.
The camera publishes supported 4K/1080p, 10-bit 4:2:2/8-bit 4:2:0 modes. Consumers
must accept the selected format; the extension refuses silent format changes
while the producer is running. Apps restricted to another format need compatible
checkbox settings.

## Build and synthetic checks

Requirements: Apple silicon, Xcode, macOS 15 or later, Blackmagic Desktop Video
with its camera extension enabled. The development target is macOS 27.0.1.

```sh
bash scripts/build.sh
bash scripts/test.sh
```

These commands require the mounted `/Volumes/8TB` drive and keep all build
products, test binaries, module caches and temporary files under
`/Volumes/8TB/cinesomatic-director-work/`. The generated Xcode project and shared
scheme are checked in; `scripts/generate_project.py` regenerates them without
third-party tools. Metal shader source is bundled and compiled through Metal at
runtime, so the separate downloadable Xcode Metal toolchain is not required.

The app is built unsigned with Release optimization by default. Use
`bash scripts/build.sh --debug` for a debugger build. The default app is at:

```text
/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultrastudio-lut/Build/Products/Release/UltraStudio LUT.app
```

## Install the camera

An unsigned build is for compilation/UI review and cannot activate a camera
system extension. Use an Apple Developer signing identity and configure the
same team for the app and extension, including their shared app group.

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID bash scripts/build.sh --signed
```

The script does not register identifiers, download provisioning profiles, change
system-extension developer mode, install certificates, or install the app.
In Xcode, configure Signing & Capabilities for both targets if signing needs
setup. Keep bundle IDs synchronized with `VideoContract.extensionID` and the
producer signing ID in `CameraStream.authorizedToStartStream`.

After signing, place the app in `/Applications`, launch it and click **Install
camera**. Approve the camera extension in System Settings when macOS asks.
**Remove camera** requests deactivation of this app's extension.

Configure the FX3 for clean 4K 10-bit 4:2:2 HDMI log output, with RAW output off
and any HDMI display LUT disabled. Optionally load the matching LUT here. Select the
correct source frame rate, select the processing checkboxes, and start the
feed. In Zoom, choose **UltraStudio LUT**. Zoom determines transmitted quality
and frame rate from its own supported features, settings, and meeting conditions.

## Qualification status and boundaries

See [VALIDATION.md](VALIDATION.md) for executed checks and outstanding live tests.
Capture uses the native DeckLink SDK directly and validates every received frame
as 3840 × 2160 10-bit 4:2:2. It stops on incompatible format changes. The build
fetches checksum-pinned, permissively licensed Blackmagic headers and dispatch
source from official OBS upstream; Blackmagic Desktop Video supplies the runtime.

The preview receives the same final pixel buffer and timing as camera output.
AVSampleBufferDisplayLayer renders it through native video hardware without
CGImage readback or per-frame SwiftUI state. Preview sample attachments are
independent from camera transport. Its only extra operation is display fitting
and the native display color conversion; every selected processing checkbox
affects both preview and camera output. Capture can run in preview mode before
the camera extension is signed and installed.

On Apple silicon, eligible packed capture memory is read directly by Metal.
The allocation is retained and locked through GPU completion; page alignment,
VM-region bounds and layout are checked before using it. Incompatible buffers
use a bounded CPU upload fallback. Raw transport staging uses a bit-exact GPU
blit when eligible, and preview/camera share the same staged IOSurface. No color
or precision change is introduced by these optimizations. Frame descriptions
are cached only while Core Media confirms their metadata and layout still match.

GPU resources and output buffers are warmed before capture starts. Capture
retains at most six source frames to absorb callback bursts, GPU output pools
are limited to eight buffers, and preview keeps one latest pending sample.
Camera transport is also bounded. The UI shows
source timestamp gaps, capture admission drops, pool pressure, transport drops
and native preview delivery separately. Intentional frame-rate reduction does
not count as a dropped frame.
No footage is recorded or written to disk. There is no audio virtual device or
SMPTE/DF timecode transport in this version. Select your existing microphone or
Blackmagic audio input separately in Zoom and qualify A/V synchronization.
Signal loss stops capture; the extension clears its latest image and emits black
after 0.5 seconds without a producer frame. Queue depth and pixel-buffer
allocation are bounded; late frames are discarded instead of building latency.

## References

- [UltraStudio Mini Recorder 12G specifications](https://www.blackmagicdesign.com/products/ultrastudiomini/techspecs/W-DLUS-15)
- [Apple camera extension architecture](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)
- [Sony FX3 help guide](https://helpguide.sony.net/ilc/2210/v1/en/print.pdf)
- [Zoom camera/system requirements](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060748)

GPU buffer contract: [Apple Metal no-copy memory API](https://developer.apple.com/documentation/metal/mtldevice/makebuffer%28bytesnocopy%3Alength%3Aoptions%3Adeallocator%3A%29).

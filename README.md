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

**Processing enabled** controls the whole pipeline independently of preview.
Turn it off for complete bypass: original resolution, color format, pixel values
and frame rate. The four saved effect selections remain available when it is
enabled again. **Video preview** controls rendering only; camera output continues
with the selected effects or bypass. Hidden or occluded previews submit no video
rendering work. With no connected camera output and no visible preview, capture
keeps detecting the source without processing unused frames.

Effects can change while capture runs. The producer stops and drains its camera
transport before negotiating a changed output format, then resumes delivery.
The camera publishes supported 4K/1080p, 10-bit 4:2:2/8-bit 4:2:0 modes; consumers
must accept the selected format. Installed-service format changes still need
qualification with a signed extension.

Settings and read-only scoped LUT bookmarks persist between launches. Capture
starts manually by default. Enable **Start when camera is in use** in the window,
menu bar panel or Feed menu to let Zoom and other camera apps manage it:
opening the virtual camera starts capture with your saved effects, and closing
the last camera client stops capture, video processing and preview rendering.
This works with preview hidden and with the main window closed. Keep the app
running in the menu bar; this setting does not launch a fully quit app.
Zoom's camera settings preview also counts as camera use.

Automatic mode listens for source-stream activity without polling or opening
its own source stream. Waiting releases working video buffers, cancels capture
and processing timers, and submits no video GPU work. Normal macOS/app runtime
memory and event handling remain. A failed start is attempted once per camera
session, with an explicit Retry action rather than a background retry loop.
Turn automatic mode off to regain manual Start/Stop controls; an already live
feed continues under manual control.

The metadata panel also reports the detected RP188 video timecode when the HDMI
source carries one. It shows two embedded-audio meters from the UltraStudio's
48 kHz, 16-bit stereo input, with peak and RMS values for left and right. The
diagnostics disclosure includes audio channels, sample rate, packet/sample/byte
counts, estimated audio bitrate and audio gaps, plus video bitrate and separate
video drop counters. If the source carries no audio or timecode, the UI says so
instead of fabricating values.

A missing or invalid saved LUT leaves capture usable and keeps
the saved choice for recovery. The menu bar popover shares the window's controls
and includes its own native mini preview; closing the window does not stop capture.

The Feed menu provides **⌘Return** to start/stop, **⇧⌘B** to enable/bypass
processing, and **⇧⌘P** to show/hide previews. The tray keeps feed and processing
controls above its scrolling details. Diagnostics expand separately from the
everyday controls. LUTs display their actual filename, and failed loads remain
visible without replacing a working LUT. Start is unavailable when the selected
device is missing. Preview errors include a retry action that leaves camera
output running.

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
`bash scripts/build.sh --debug` for a debugger build. The stable app-bundle
alias, overwritten on every build, is at:

```text
/Volumes/8TB/cinesomatic-director-work/agent-work/ultrastudio-lut/UltraStudio LUT.app
```

Xcode derived data and test objects use a unique UTC timestamp/PID directory
under `/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultrastudio-lut/`
so overlapping builds and test runs cannot overwrite one another. The stable
`build.log`, `test-compile.log`, and `tests.log` aliases point to the latest
run; timestamped logs remain in the `logs/` directory.

## Install the camera

An unsigned build is for compilation/UI review and cannot activate a camera
system extension. Use an Apple Developer signing identity and configure the
same team for the app and extension, including their shared app group.
The app checks its running signature and effective install entitlement before
offering installation. Unsupported builds explain the signing requirement and
keep Install/Remove disabled; capture and preview remain available.

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

For local testing on a Mac already configured to permit unsigned system
extensions (including SIP disabled), build an explicitly marked development
package without an Apple Developer identity:

```sh
bash scripts/build.sh --local-development
```

The ad-hoc signed package is staged at
`/Volumes/8TB/cinesomatic-director-work/agent-work/ultrastudio-lut/local-development/UltraStudio LUT.app`.
Quit the previous app, copy this package into `/Applications`, launch it there,
then request **Install camera** and approve **UltraStudio LUT Camera** in
System Settings → General → Login Items & Extensions → Camera Extensions.
This mode embeds the actual install entitlement and matching local app groups;
its compile-time policy accepts a valid local signature. Production builds
still require developer signing. The script never changes SIP, extension
developer mode, certificates or other macOS security settings, and never
installs the package. macOS retains control over activation and approval.
Both build modes validate the built bundle metadata before finishing.

With the local development extension installed and approved, stop the app's feed
and run
`bash scripts/camera-smoke.sh --run` to check actual camera transport with
synthetic numbered frames. The helper checks received pixels, frame counts and
timestamps in memory; it never opens the physical capture device, records video
or submits an installation request. Running the script without `--run` only
builds the helper. Use `--full` instead of `--run` to include 4K 10-bit x422 and
packed v210 at both rates. Build products and receipts stay on the external drive.
Use `bash scripts/camera-smoke.sh --consumer` for a bounded 20-second source-only
client request to test automatic start/stop. That mode may start physical capture
through the running host app; it inspects frame metadata only and never reads,
displays or records image pixels.

Configure the FX3 for clean 4K 10-bit 4:2:2 HDMI log output, with RAW output off
and any HDMI display LUT disabled. Optionally load the matching LUT here. Select the
processing checkboxes and start the
feed. In Zoom, choose **UltraStudio LUT**. Zoom determines transmitted quality
and frame rate from its own supported features, settings, and meeting conditions.

## Natural talking-head auto-switcher

Program mode includes a **Natural talking head** strategy. When enabled, the
app feeds live audio cues to the Rust director in `Tools/auto-switcher`, queues
decisions at Program frame boundaries, and acknowledges them only after the
target frame is applied. The hard shot maximum forces a bounded cut, preferring
the nearest speech gap and using the configured grace period only when no safe
gap arrives. The standalone package also accepts realtime JSONL or PCM16LE and
can analyze complete audio/video files offline; see
[Tools/auto-switcher/README.md](Tools/auto-switcher/README.md).
Recorded source movies use the stable feed identifier plus a UTC datetime in
their filenames, while each switcher session writes a matching datetime JSON
sidecar in the recording folder.

## Qualification status and boundaries

See [VALIDATION.md](VALIDATION.md) for executed checks and outstanding live tests.
Capture uses the native DeckLink SDK directly and validates every received frame
as 3840 × 2160 10-bit 4:2:2. It detects 29.97/59.94 input automatically and reports
the actual captured dimensions, format and rate. Unsupported HDMI modes are
reported while the detector waits for a supported signal. The build
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

GPU resources and three output buffers are warmed before capture when needed.
Capture retains at most twelve source frames to absorb callback bursts. Each
preview has a bounded 24-sample FIFO; it drains immediately when native display
is ready and discards the oldest pending sample on overflow. Output pools grow
only on demand, up to 64 images shared across their consumers. Idle/bypass
releases unused processing textures and pools. Camera transport is also bounded.
The UI shows
source timestamp gaps, capture admission drops, pool pressure, transport drops
and native preview delivery separately. Intentional frame-rate reduction does
not count as a dropped frame.
No footage is recorded or written to disk. There is no audio virtual device or
SMPTE/DF timecode transport in this version. Select your existing microphone or
Blackmagic audio input separately in Zoom and qualify A/V synchronization.
Signal loss leaves automatic HDMI detection armed; the extension clears its latest image and emits black
after 0.5 seconds without a producer frame. Queue depth and pixel-buffer
allocation are bounded; late frames are discarded instead of building latency.

## References

- [UltraStudio Mini Recorder 12G specifications](https://www.blackmagicdesign.com/products/ultrastudiomini/techspecs/W-DLUS-15)
- [Apple camera extension architecture](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)
- [Sony FX3 help guide](https://helpguide.sony.net/ilc/2210/v1/en/print.pdf)
- [Zoom camera/system requirements](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060748)

GPU buffer contract: [Apple Metal no-copy memory API](https://developer.apple.com/documentation/metal/mtldevice/makebuffer%28bytesnocopy%3Alength%3Aoptions%3Adeallocator%3A%29).

# Validation

Development machine: M4 Max Mac Studio, 48 GB RAM, macOS 27.0.1, Xcode 27.0,
Blackmagic Desktop Video 16.4. Executed October 14, 2026.

## Executed checks

- Unsigned arm64 app and embedded camera extension build successfully with
  `bash scripts/build.sh`, including strict Swift concurrency and warnings as errors.
- Direct DeckLink SDK discovers the UltraStudio Mini Recorder 12G and opens its
  native 3840 × 2160 v210 10-bit 4:2:2 modes at 29.97 and 59.94.
- Live 4K 59.94 input was received after the camera was powered on. The earlier
  preview refreshed only at 4 Hz; that implementation has been replaced and
  does not establish smoothness of the new native preview.
- The latest integrated synthetic suite executes 45 tests. Forty-four pass;
  the paced 180-frame controller test currently detects drops under host load.
  Its assertions have not been weakened. It records actual callback cadence,
  camera/preview sample identity, output timing, and drop counters.
- All 12 attached native preview format/rate combinations deliver their exact
  frame counts (30 at 59.94, 15 at 29.97), with zero native renderer drops or
  corruption. Cases include 1080p/4K NV12 and x422, and shareable/borrowed v210.
- Checks cover all 16 processing switch combinations at both source rates;
  cube parsing/order/domain/finite bounds; independent nonlinear color and
  Lanczos references; preserved 10-bit precision; metadata reuse; bounded pool
  pressure and recovery; camera stream negotiation, ownership, disconnects,
  cadence and recovery; SDK failure cleanup; optional LUT and lifecycle races.
- Standalone 300-frame GPU benchmark with a 33-cube LUT: 4K packed v210 → LUT →
  Lanczos → 1080p NV12, median 2.150 ms, p95 3.274 ms. This excludes UI, camera
  transport and Zoom and is not a sustained hardware qualification.

The old Core Image pipeline failed the precision check and was replaced by
explicit float32 Metal processing. Core Image/CGImage readback has now also
been removed from preview. GPU resources warm before capture; the preview
receives the exact final buffer and timing sent to camera transport.

During the paced drop investigation, the host showed approximately 100% CPU
usage, load average above 47, approximately 24 GB of compressed memory, and
concurrent browser workers, virtual-machine, synchronization and native build
work. No unrelated processes were stopped. Source timestamp gaps, capture
admission, output-pool pressure, camera transport and native renderer loss are
counted separately. Intentional temporal reduction is not a drop.

## Remaining qualification

- Finish profiling and resolving the paced controller drop failures; verify
  sustained hardware capture/display with the new native preview. The camera
  was subsequently turned off or its output changed, preventing that live check.
- Sign/approve the camera extension and verify service IPC and actual Zoom
  consumption. No valid signing identity is installed and the owner has not
  enrolled in the Apple Developer Program. In-process camera tests do not
  substitute for installed-service evidence.
- Qualify the actual Sony LUT, gamut, levels and chroma siting against a trusted
  reference chart; measure hardware latency and A/V synchronization.
- Verify actual remote Zoom quality at both rates and 4K 10-bit consumption in
  another compatible application. The app does not supply an audio device.

No footage has been recorded or retained. Live UI checks use accessibility
text without screenshots of camera imagery. Private raw build/test/profiling
logs remain under
`/Volumes/8TB/cinesomatic-director-work/agent-work/ultrastudio-lut/`.

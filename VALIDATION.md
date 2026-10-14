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
- The final integrated synthetic suite passes all **45 tests, zero failures**
  in 18.382 seconds (`bash scripts/test.sh`). Its paced controller test delivers
  all 180 packed-v210 source frames, yielding exactly 180 camera/preview samples
  at 59.94 or 90 with temporal reduction, with zero reported drops and identical
  camera/preview sample objects. Output timing follows the source cadence.
  Fast processing measured p95 4.324 ms, max 11.511 ms; queue wait p95 10.632 ms,
  max 17.026 ms. The producer still exhibited approximately 82 ms scheduling
  gaps and catch-up bursts; six-frame bounded admission handles this case.
  Assertions were not relaxed. Earlier three-frame failure receipts are retained.
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

- A separate borrowed-v210 profile under host load compares bounded capture
  capacities of three and six. Three admitted 165/159 of 180 frames at the two
  output rates; six admitted all 180 at both, yielding exactly 180/90 output
  frames with zero drops/errors. For the six-frame fast case, total processing
  p95 was 6.076 ms, max 12.644 ms; actual GPU execution p95 2.755 ms, max 3.016 ms.
  No page-ins occurred. Most variation was scheduler/CPU resume delay, while
  callback gaps reached approximately 83 ms and then arrived in catch-up bursts.
  This is synthetic burst tolerance evidence, not physical display qualification.

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

- Verify sustained hardware capture/display with the new native preview. The
  owner requested leaving this pending while the camera is off or its output
  changed. Synthetic delivery and renderer counters do not establish physical
  smoothness of the complete hardware path.
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

Final passing test receipt: `logs/tests-20261014T064354Z.log`.

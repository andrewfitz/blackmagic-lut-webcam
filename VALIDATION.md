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
- The original integrated synthetic suite passed all **45 tests, zero failures**
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

## CPU/GPU optimization qualification

The updated Release build passes **55 tests, zero failures**, in 18.609 seconds
(`logs/tests-20261014T184250Z.log`). Added checks validate no-copy GPU memory
ownership through command completion, exactly-once release, alignment and
split-VM fallback, invalid packed strides, cached format identity and metadata
invalidation, and actual bit-exact GPU raw transport across every 4K word.
Synthetic camera/preview delivery remains exactly 180/180 or 90/90 with zero
drops. Metal API/GPU validation also passed the focused ten-test GPU suite.

Matched Release processor benchmarks alternate 360 frames per path. Thread
CPU median decreased from 0.512 to 0.190 ms/frame; aggregate CPU from 202.602 to
70.901 ms (approximately 65% less processor CPU). Wall median decreased from
2.324 to 2.000 ms. This compares copied versus eligible no-copy inputs and does
not measure driver, UI or native display CPU. Receipt:
`gpu-review/no-copy-profile/comparison.log`.

The owner subsequently ran the camera with a real 33-cube LUT, source 4K v210
59.94, Lanczos to 1080p NV12, and reduction to 29.97. On the same settings,
20-second whole-process CPU windows measured 30.448% of one core for the old
Debug app and 18.370% for the optimized Release app (approximately 40% lower).
These are observed live before/after windows, not a controlled host-load or
isolated attribution study. The changes combine no-copy input, GPU raw staging,
format caching, a smaller SwiftUI update subtree and Release optimization.
Private receipts: `cpu-preview/before-cpu.json` and `cpu-preview/after-cpu.json`.

Live diagnostics confirmed every packed input used the no-copy path and none
used the CPU fallback. Before/after stack samples confirm the hot packed-frame
memcpy disappeared; remaining work includes driver/framework and GPU submission
bookkeeping. No footage was recorded. Native renderer counters showed zero
preview losses during the observed run. Ten capture admission losses first
appeared at 13:48:34, inside the intrusive 1-ms stack sampling interval starting
13:48:32; the count did not increase after sampling. Earlier receipts retain
that result rather than silently removing it. A fresh ordinary run follows
without the sampler; the user's LUT and four processing selections are restored.

## Remaining qualification

- Broaden sustained hardware/display qualification to other output modes,
  actual 29.97 source input, and controlled host workloads. The observed live
  59.94-source/29.97-output run and counters do not establish all hardware modes
  or a universal zero-drop guarantee.
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

Original passing test receipt: `logs/tests-20261014T064354Z.log`.
Current passing test receipt: `logs/tests-20261014T184250Z.log`.

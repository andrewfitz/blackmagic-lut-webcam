# Validation

Development machine: macOS 27.0.1, Xcode 27.0, Blackmagic Desktop Video 16.4.

Executed on October 14, 2026:

- Unsigned arm64 app and embedded camera extension built successfully with
  `bash scripts/build.sh`.
- Eight synthetic checks passed with `bash scripts/test.sh`: cube ordering,
  whitespace/comments, invalid and non-finite data, domain bounds, actual GPU
  10-bit gradient precision, nonlinear LUT to Lanczos to NV12, full-buffer
  passthrough, independent switches, and rational frame selection. Several
  checks share test functions; the executed XCTest count is eight.
- The nonlinear synthetic cube maps mid-gray to approximately quarter-gray in
  the final video-range NV12 plane, checking against an independent expected
  code value rather than merely inspecting a pixel-format label.

The original Core Image production renderer failed the precision check. It was
replaced by explicit Metal processing. Core Image is now only used for preview.

No valid code-signing identities were available. The camera extension has not
been installed or activated. No live footage was captured or retained.

Still required before declaring the complete hardware-to-Zoom path working:

- Sign/approve the extension and verify source/sink negotiation, queue ownership,
  repeated start/stop, disconnect/reconnect, signal loss, and multiple consumers.
- Confirm Blackmagic's AVFoundation interface exposes native 3840 × 2160 10-bit
  4:2:2 at both 29.97 and 59.94, and qualifies its delivered sample precision.
- Verify the exact Sony LUT, camera gamut, source levels and chroma siting against
  a reference chart and trusted color pipeline.
- Measure sustained throughput, frame drops, latency and A/V sync with the FX3.
- Confirm Zoom receives the chosen 1080p NV12 mode at both rates and verify the
  remote call's actual received quality. Qualify 4K 10-bit output in another
  compatible camera consumer separately.

Private raw build/test logs live under
`/Volumes/8TB/cinesomatic-director-work/agent-work/ultrastudio-lut/logs/`.

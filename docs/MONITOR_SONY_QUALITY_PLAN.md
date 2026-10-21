# Sony monitoring quality and performance execution

The approved change improves monitor-only processing. Recording, LUT processing,
and virtual-camera delivery continue to consume the original pipeline images.
Sony false color uses Sony Monitor & Control Pattern 2's published S-Log3 IRE
bands. Camera exposure index does not move these bands.

## Work and verification

1. Replace binary five-point focus detection with Scharr confidence peaking,
   reject isolated noise, and verify edges, flat noise, and source correspondence.
2. Filter reduced-size previews and chroma; preserve thin focus marks. Verify
   checkerboards, identity size, and reduced quality scales against CPU references.
3. Improve waveform/parade sampling and density normalization. Verify sampled
   count conservation, temporal phase coverage, and resolution/stride behavior.
4. Bound composite backing storage and reuse it. Bind already-owned clean monitor
   buffers directly to Metal where layout, VM ownership, and unified memory permit;
   otherwise keep the copying path. Test held frames, budget pressure, lifetime,
   no alias mutation, and teardown.
5. Read Y directly for YUV focus and dispatch scope sampling work only for samples
   that contribute. Measure the combined implementation against frozen code;
   report changes in quality separately from changes in speed.
6. Name shader parameters and flags, verify the Swift/Metal ABI, and expand
   profile/range/stage/geometry regressions. Preserve cancellation and stale-result
   suppression, producer-borrow release before GPU commit, and clean fallback.

Normal false-color choices are Off, Sony S-Log3, and EL Zone. Legacy saved ARRI
data remains decodable and visibly unsupported until a Sony input is selected.
The user clarified that EL Zone must be implemented; only the Sony M&C app test
is deferred. Implement a versioned public-chart EL Zone profile for Sony S-Log3.
Decode native RGB channels, calculate source-gamut scene-linear Y, then
`log2(Y / 0.18) + referenceOffsetStops`. The manual offset is additive and does
not infer camera EI. Nonpositive finite Y is black. Use the published Panasonic
vector-chart palette. Document Ultracam's continuous-band convention: interior
transitions are label midpoints, except published black <=-6 / white >=+6
extrema; all other boundaries belong to the upper band. This explicitly defined
mapping is tested against the CPU reference and is not a claim of Sony M&C
operational parity. The UI identifies the public-chart mapping. Sony M&C matching,
its extended shadow palette, and automated EI/LUT behavior remain untested.

## Evidence and gates

Evidence root:
`/Volumes/8TB/cinesomatic-build/ultracam-monitor-upgrade-20261021`.
The immutable baseline contains 188 source files with a SHA-256 manifest.
Its declared 30-second comparisons passed single-feed ProRes and HEVC; two-feed
ProRes failed the existing 20 Hz monitoring cadence gate on feed 0 (18.88 Hz
decorated), while all 7,200 decoded video frames and recording equivalence checks
passed. Preserve this failure and every candidate observation; do not relax gates
or retry selectively. The benchmark has false color off, so Sony classifier
correctness and cost require separate synthetic tests.

Run meaningful failing tests before implementations, then targeted checks, full
package checks, application checks, and independent review. GPU/build runs are
serialized. Candidate integration uses the same workload/order/duration/gates as
baseline. Measure recording equivalence, pipeline p95/p99, monitor cadence and
age, CPU, instrumented GPU duration, upload/allocation counts, memory, and teardown.
Instrumented GPU interval sums are not system GPU utilization.

## Workspace and delivery

Work continues in the existing dirty workspace because it contains the approved
uncommitted application implementation. Do not reset, stash, or blanket-commit it.
Independent agents own separate files; root integrates ownership and runtime.
All scratch, builds, and test media go to the external evidence volume. Never
touch user recordings in `/Volumes/8TB/capture`.

Install only after tests and review, preserve signing/entitlements and unchanged
camera extension, then verify the installed app and actual virtual consumer.
Remove only task-generated redundant builds/media after retaining compact evidence.

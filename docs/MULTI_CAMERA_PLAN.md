# Multi-camera and Program switcher plan

## Goal

Extend UltraStudio LUT from one Blackmagic input and one virtual camera to a reusable multi-feed system. Each feed can have its own LUT, effects, preview, audio/video telemetry, and saved settings. Feeds can be exposed as separate virtual cameras or routed through one Program virtual camera with manual or fixed-interval switching.

The design stores an arbitrary number of feed descriptors. It does not impose a four-feed limit. The UI can recommend four active feeds for the intended Mac Studio workflow, while the runtime resource governor reports when the hardware cannot sustain the requested active pipelines.

## Core architecture

```text
FeedDescriptor
    ↓
FeedSession
    ↓
CaptureController → ProcessedFrame stream
    ↓
Output routes
    ├── Dedicated virtual camera
    └── Program switcher → Program virtual camera
```

`AppModel` becomes a `FeedCoordinator` that owns a stable ordered collection of `FeedDescriptor` values and lazily-created `FeedSession` instances. The current single-camera behavior becomes Feed 1 using the same reusable path.

Each `FeedSession` owns or references:

- one physical Blackmagic input assignment
- one `CaptureController`
- one DeckLink backend and camera sink
- one main preview renderer and one tray renderer
- one automatic camera-demand monitor
- one LUT/effects configuration
- one telemetry snapshot
- one or more output routes

The pipeline must remain single-source. A processed frame is published through a queue-owned `ProcessedFrame` or `FrameLease` abstraction with explicit ownership and timestamp rules. Output routes may consume the same processed frame without re-running the LUT, scaling, or color conversion.

## Feed persistence

Introduce stable `FeedID` values and versioned `FeedDescriptor` records containing:

- stable ID, display name, and ordering
- selected Blackmagic device ID
- LUT security-scoped bookmark and LUT-enabled state
- downscale, color-format, frame-rate, processing, and preview settings
- automatic-start preference
- enabled state

Global settings contain:

- selected feed ID
- output mode: separate cameras or Program
- switcher configuration
- virtual-camera registry version

Migrate the current single-feed v1 settings into Feed 1 without losing the selected device, LUT bookmark, effects, or preview preferences. Decode old settings with defaults for new fields.

## Physical input ownership

A device manager reserves each physical Blackmagic input for at most one feed. Feed assignment states are explicit:

```text
available
reserved
capturing
unavailable
conflict
```

Two feeds cannot silently claim the same UltraStudio. Conflicts appear before capture starts and remain visible in the feed UI. A feed may be persisted while its physical device is unavailable.

The runtime resource governor permits any number of configured feeds but limits active capture and processing based on actual device availability, GPU memory, queue pressure, and measured frame timing. It reports inability to sustain a feed instead of silently dropping frames.

## Virtual-camera registry and extension

Store a versioned virtual-camera registry in the shared app group. The app writes complete registry snapshots transactionally. The extension loads the last valid snapshot, reconciles changes, and never publishes a partial update. If the app exits, the extension retains the last valid registry.

Refactor the extension into one generic descriptor-driven implementation:

```text
CameraProvider
  ├── VirtualCameraDevice(feedID: ...)
  │     ├── source stream
  │     └── sink stream
  ├── VirtualCameraDevice(feedID: ...)
  │     ├── source stream
  │     └── sink stream
  └── ...
```

Every virtual device has stable:

- feed ID
- device UID
- source stream ID
- sink stream ID
- display name
- demand property

There are no Camera 1, Camera 2, or Program-specific implementations. All devices use the same source/sink, negotiation, standby, producer authorization, and demand-count code.

When a feed is removed while an application is using it, mark it unavailable, stop accepting new clients, and remove it only after existing consumers release it. This avoids dangling Zoom camera references. Camera applications may need a restart after registry changes because they can cache device enumeration.

## Demand and lifecycle

Demand is route-aware. A feed remains active when any of these needs it:

- its dedicated virtual camera has a consumer
- the Program camera selects it
- an explicitly requested manual output route needs it

Capture stops only when all routes release demand. Preview alone does not create automatic camera demand. Automatic mode continues to use event-driven source-stream notifications rather than polling.

The idle path must release capture timers, working GPU resources, processing queues, preview queues, and DeckLink resources. The app may retain ordinary process state and the persisted LUT.

## Separate-camera mode

In Separate Cameras mode, each enabled feed publishes its own virtual camera, for example:

```text
UltraStudio LUT · Camera 1
UltraStudio LUT · Camera 2
UltraStudio LUT · Camera N
```

Each feed independently reports:

- input and output format/rate
- LUT and effects state
- audio channels, sample rate, meters, packets, samples, bytes, bitrate, and gaps
- video timecode, bitrate, frame rate, and drop counters
- preview and camera-client demand

Two synthetic feeds must qualify independent configuration, telemetry, demand, and shutdown behavior before hardware testing.

## Program switcher

Add a `SwitcherCoordinator` separate from `CaptureController`. Its persisted state contains:

- selected feed ID
- manual/automatic mode
- fixed interval in seconds
- switch strategy
- future Program audio policy

Strategies are represented explicitly:

```text
fixedInterval
 dynamicAnalysis
```

`dynamicAnalysis` is initially disabled and reports “Coming later.” It must not silently fall back or pretend to analyze content.

Program output uses one virtual device:

```text
Camera 1 ─┐
Camera 2 ─┼─> Switcher → UltraStudio LUT · Program
Camera N ─┘
```

Initial behavior:

- manual cuts select the next feed at the next valid processed-frame boundary
- fixed auto-switching advances after the configured interval
- feeds without a valid signal are skipped
- Program timestamps remain monotonic across cuts
- source-to-Program timestamp mapping resets on a cut without moving backward
- Program demand keeps only the selected feed active initially
- the switcher timer runs only while the Program camera has a consumer

The first audio policy is monitoring-only: Program meters follow the selected feed. Virtual audio output is not part of this phase. Add a future `ProgramAudioPolicy` field with `selectedFeed`, `muted`, and `mix` values so the model can evolve without another persistence migration.

## User interface

The main window becomes a feed-oriented workspace:

- sidebar with a scrollable list of feeds
- per-feed name, input, live/idle state, signal state, audio meter, and drop warning
- selected-feed preview and effects/LUT controls
- detected metadata and diagnostics for the selected feed
- Separate Cameras / Program output selector
- Program preview and switcher controls in Program mode

The tray uses the same parameterized views in compact form:

- selected feed
- Program output state
- manual cut and automatic switching controls
- compact feed statuses and meters

The UI must use collections and scrolling rather than assuming two or four feeds.

## Implementation sequence

1. Add `FeedID`, `FeedDescriptor`, versioned persistence, and migration from current v1 settings.
2. Extract the current single feed into `FeedSession` and `FeedCoordinator` without changing one-feed behavior.
3. Introduce the ownership-safe `ProcessedFrame`/output-route abstraction while retaining the current dedicated camera route.
4. Add physical-device reservation and runtime resource-governor states.
5. Refactor the camera extension around a descriptor-driven virtual-device collection and transactional shared registry.
6. Add Separate Cameras mode with independent demand and telemetry.
7. Add the Program route and manual frame-boundary switching.
8. Add fixed-interval auto-switching.
9. Add the disabled dynamic-analysis strategy stub and future Program audio-policy model.
10. Refine main-window/tray UI and qualify two-feed hardware behavior.

## Verification gates

Before calling the refactor complete, test:

- migration and per-feed LUT/effects persistence
- arbitrary feed descriptor counts and stable ordering
- two feeds attempting the same physical input
- multiple virtual devices with independent source demand
- one processed frame consumed by two routes
- one route stopping while another continues
- feed removal with an active camera client
- separate-output routing for two synthetic feeds
- Program switching without timestamp regression or duplicate cuts
- fixed auto-switch timer start/stop tied to Program demand
- isolated audio/video/timecode telemetry
- clearing meters, timecode, bitrates, and counters when each feed stops
- idle release of GPU, DeckLink, preview, and output resources
- Zoom enumeration and restart behavior after registry changes

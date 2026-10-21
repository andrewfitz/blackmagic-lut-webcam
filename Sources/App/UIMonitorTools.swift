import MonitorToolsCore
import SwiftUI

/// Split-button monitor tools for one camera: the icon toggles the tool, the
/// chevron opens that tool's settings. Settings are remembered per camera.
struct UIMonitorToolButtons: View {
  let targetID: String
  let name: String
  let activeTools: [UIMonitorTool]
  /// Program has no source correspondence, so source-only tools are disabled there.
  let isProgram: Bool
  let toggle: @MainActor (UIMonitorTool) -> Void
  let monitor: any UIMonitorSettingsProviding
  @State private var openTool: UIMonitorTool?

  /// A camera's tools; toggles go through the interface's actions.
  init(camera: UICameraPresentation, context: UIContext) {
    targetID = camera.id
    name = camera.name
    activeTools = camera.activeTools
    isProgram = camera.id == "program"
    let send = context.send
    let id = camera.id
    toggle = { send(.toggleTool(cameraID: id, $0)) }
    monitor = context.monitor
  }

  /// Any monitor target, for example "program".
  init(targetID: String, name: String, activeTools: [UIMonitorTool], isProgram: Bool,
    toggle: @escaping @MainActor (UIMonitorTool) -> Void, monitor: any UIMonitorSettingsProviding) {
    self.targetID = targetID
    self.name = name
    self.activeTools = activeTools
    self.isProgram = isProgram
    self.toggle = toggle
    self.monitor = monitor
  }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(UIMonitorTool.allCases, id: \.self) { tool in
        UIMonitorToolSplitButton(tool: tool, isOn: activeTools.contains(tool),
          unavailableReason: UIMonitorToolSettingsView.unavailableReason(tool, isProgram: isProgram),
          toggle: { toggle(tool) },
          openSettings: { openTool = tool })
          .popover(isPresented: Binding(get: { openTool == tool }, set: { if !$0 { openTool = nil } }),
            arrowEdge: .bottom) {
            UIMonitorToolSettingsView(tool: tool, cameraID: targetID, cameraName: name,
              isProgram: isProgram, provider: monitor)
          }
      }
    }
    .uiPictureControls()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Monitor tools for \(name)")
  }
}

private struct UIMonitorToolSplitButton: View {
  let tool: UIMonitorTool
  let isOn: Bool
  let unavailableReason: String?
  let toggle: () -> Void
  let openSettings: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Button(action: toggle) {
        Image(systemName: tool.symbol)
          .font(.callout.weight(.medium))
          .frame(width: 24, height: 24)
          .foregroundStyle(.white)
          .background(isOn ? Color.white.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(unavailableReason != nil)
      .help(unavailableReason ?? "\(isOn ? "Turn off" : "Turn on") \(tool.title)")
      .accessibilityLabel(tool.title)
      .accessibilityValue(isOn ? "On" : "Off")
      .accessibilityAddTraits(isOn ? .isSelected : [])
      // The settings half of the split button. A system split-button Menu can't
      // host the settings form, so this stays a button, wide enough to hit.
      Button(action: openSettings) {
        Image(systemName: "chevron.down")
          .font(.caption.weight(.bold)).imageScale(.small)
          .frame(width: 16, height: 24)
          .foregroundStyle(.white.opacity(0.75))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("\(tool.title) settings")
      .accessibilityLabel("\(tool.title) settings")
    }
    .opacity(unavailableReason == nil ? 1 : 0.45)
  }
}

/// Settings for one monitor tool, bound to the camera's monitor configuration.
struct UIMonitorToolSettingsView: View {
  let tool: UIMonitorTool
  let cameraID: String
  let cameraName: String
  let isProgram: Bool
  let provider: any UIMonitorSettingsProviding
  @State private var configuration: MonitorConfiguration

  init(tool: UIMonitorTool, cameraID: String, cameraName: String, isProgram: Bool, provider: any UIMonitorSettingsProviding) {
    self.tool = tool
    self.cameraID = cameraID
    self.cameraName = cameraName
    self.isProgram = isProgram
    self.provider = provider
    _configuration = State(initialValue: provider.configuration(for: cameraID))
  }

  static func unavailableReason(_ tool: UIMonitorTool, isProgram: Bool) -> String? {
    guard isProgram else { return nil }
    switch tool {
    case .falseColor: return "False color needs a camera's source picture. It is unavailable on Program."
    case .focus: return "Focus peaking needs a camera's source picture. It is unavailable on Program."
    default: return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(tool.title, systemImage: tool.symbol).font(.headline)
        Spacer()
        Text(cameraName).font(.uiMeta).foregroundStyle(.secondary)
      }
      if let reason = Self.unavailableReason(tool, isProgram: isProgram) {
        Text(reason).font(.uiMeta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Form { settings }
        .formStyle(.grouped)
        .disabled(Self.unavailableReason(tool, isProgram: isProgram) != nil)
    }
    .padding(14)
    .frame(width: 320)
    .controlSize(.small)
    .onChange(of: configuration) { _, value in provider.setConfiguration(value, for: cameraID) }
  }

  @ViewBuilder private var settings: some View {
    switch tool {
    case .guides:
      Toggle("Guides", isOn: binding(\.guides.enabled))
      Toggle("Rule of thirds", isOn: $configuration.guides.thirds)
      Toggle("Center cross", isOn: $configuration.guides.centerCross)
      Toggle("Safe area", isOn: $configuration.guides.safeArea)
      slider("Opacity", value: $configuration.guides.opacity, range: 0...1, percent: true)
      slider("Contrast", value: $configuration.guides.contrast, range: 0...1, percent: true)
    case .zebra:
      Toggle("Zebra", isOn: binding(\.zebra.enabled))
      Picker("Mode", selection: $configuration.zebra.mode) {
        Text("Above threshold").tag(MonitorZebraMode.aboveThreshold)
        Text("Band").tag(MonitorZebraMode.band)
      }
      slider("Threshold", value: $configuration.zebra.thresholdIRE, range: 0...109, suffix: " IRE")
      slider("Width", value: $configuration.zebra.widthIRE, range: 0...30, suffix: " IRE")
        .disabled(configuration.zebra.mode != .band)
      slider("Opacity", value: $configuration.zebra.opacity, range: 0...1, percent: true)
      if configuration.falseColor.mode != .off {
        Text("Zebra is bypassed while false color is on.").font(.uiMeta).foregroundStyle(.secondary)
      }
    case .falseColor:
      falseColorSettings
    case .focus:
      Toggle("Focus peaking", isOn: binding(\.focus.enabled))
      Picker("Highlight", selection: $configuration.focus.color) {
        ForEach(MonitorPeakingColor.allCases, id: \.self) { color in
          Text(color.rawValue.capitalized).tag(color)
        }
      }
      slider("Sensitivity", value: $configuration.focus.sensitivity, range: 0...1, percent: true)
      slider("Noise rejection", value: $configuration.focus.noiseRejection, range: 0...1, percent: true)
      slider("Opacity", value: $configuration.focus.opacity, range: 0...1, percent: true)
      Text("Edges are found on the camera's source picture at full resolution.")
        .font(.uiMeta).foregroundStyle(.secondary)
    case .scopes:
      Toggle("Scope", isOn: binding(\.scopes.enabled))
      Picker("Type", selection: $configuration.scopes.mode) {
        Text("RGB parade").tag(MonitorScopeMode.rgbParade)
        Text("Luma waveform").tag(MonitorScopeMode.lumaWaveform)
      }
      Picker("Signal", selection: $configuration.scopeStage) {
        Text("Source").tag(MonitorStage.source).disabled(isProgram)
        Text("Output").tag(MonitorStage.processedOutput)
      }
      Picker("Refresh", selection: $configuration.scopes.refreshHz) {
        ForEach([10, 15, 30], id: \.self) { Text("\($0) Hz").tag($0) }
      }
      slider("Trace gain", value: $configuration.scopes.gain, range: 0.25...4, suffix: "×")
      Toggle("Graticule", isOn: $configuration.scopes.graticule)
      Text("One scope per camera. Sampled signal, −10…110 IRE.").font(.uiMeta).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var falseColorSettings: some View {
    let sonySource = SonySLog3FalseColor.supports(sourceProfileID: configuration.sourceProfileID)
    let elZoneAvailable = !isProgram && ELZoneProfile.supports(sourceProfileID: configuration.sourceProfileID)
    Picker("Mode", selection: falseColorMode) {
      Text("Off").tag(MonitorFalseColorMode.off)
      Text("Sony S-Log3").tag(MonitorFalseColorMode.sonySLog3).disabled(isProgram || !sonySource)
      Text("EL Zone").tag(MonitorFalseColorMode.elZone).disabled(!elZoneAvailable)
      if configuration.falseColor.mode == .arri {
        Text("Unsupported saved mode").tag(MonitorFalseColorMode.arri).disabled(true)
      }
    }
    Picker("Camera / Log", selection: sourceProfile) {
      if configuration.sourceProfileID != "" { Text("Unknown").tag("") }
      Text("Sony S-Gamut3.Cine / S-Log3").tag("sony-slog3-sgamut3cine")
      Text("Sony S-Gamut3 / S-Log3").tag("sony-slog3-sgamut3")
      if let source = configuration.sourceProfileID, !SonySLog3FalseColor.supports(sourceProfileID: source) {
        Text("Unsupported saved input").tag(source).disabled(true)
      }
    }
    Picker("Input code range", selection: $configuration.sourceCodeRange) {
      Text("Format native / unspecified").tag(Optional<MonitorCodeRange>.none)
      Text("Legal (64…940 at 10-bit)").tag(Optional(MonitorCodeRange.legal))
      Text("Full (0…1023 at 10-bit)").tag(Optional(MonitorCodeRange.full))
    }
    Picker("Log transport", selection: $configuration.sourceLogMapping) {
      Text("Declared native 10-bit codes").tag(MonitorSourceLogMapping.native10Bit)
      Text("Full codes rescaled to legal").tag(MonitorSourceLogMapping.fullRescaledToLegal10Bit)
    }
    if configuration.falseColor.mode == .elZone {
      Stepper(value: $configuration.falseColor.referenceOffsetStops, in: -10...10, step: 0.25) {
        Text("Exposure offset \(configuration.falseColor.referenceOffsetStops, specifier: "%+.2f") stops")
      }
      .disabled(!elZoneAvailable)
      .help("Adds stops to measured source exposure. Camera EI is independent.")
    }
    Text(configuration.falseColor.mode == .elZone
      ? (elZoneAvailable ? "Public-chart mapping. Sony Monitor & Control match not tested." : "EL Zone needs a supported Sony S-Log3 source.")
      : sonySource ? "Sony source IRE thresholds are independent of EI and don't guarantee sensor clipping."
        : "Choose the Sony S-Log3 profile that matches the camera.")
      .font(.uiMeta).foregroundStyle(.secondary)
    Text("Match the actual camera output. These settings don't change the camera output.")
      .font(.uiMeta).foregroundStyle(.secondary)
  }

  /// Enabling a tool from its settings also turns the camera's tools on.
  private func binding(_ keyPath: WritableKeyPath<MonitorConfiguration, Bool>) -> Binding<Bool> {
    Binding(
      get: { configuration.toolsEnabled && configuration[keyPath: keyPath] },
      set: { on in
        var next = configuration
        if on && !next.toolsEnabled {
          next.guides.enabled = false; next.zebra.enabled = false; next.focus.enabled = false
          next.scopes.enabled = false; next.falseColor.mode = .off
        }
        next[keyPath: keyPath] = on
        next.toolsEnabled = next.guides.enabled || next.zebra.enabled || next.focus.enabled
          || next.scopes.enabled || next.falseColor.mode != .off
        configuration = next
      })
  }

  private var falseColorMode: Binding<MonitorFalseColorMode> {
    Binding(
      get: { configuration.toolsEnabled ? configuration.falseColor.mode : .off },
      set: { mode in
        var next = configuration
        if mode != .off && !next.toolsEnabled {
          next.guides.enabled = false; next.zebra.enabled = false; next.focus.enabled = false
          next.scopes.enabled = false
        }
        next.falseColor.mode = mode
        if mode == .sonySLog3, SonySLog3FalseColor.supports(sourceProfileID: next.sourceProfileID) {
          next.falseColor.profileID = SonySLog3FalseColor.profileID
          next.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
        } else if mode == .elZone, ELZoneProfile.supports(sourceProfileID: next.sourceProfileID) {
          next.falseColor.profileID = ELZoneProfile.profileID
          next.falseColor.specificationVersion = ELZoneProfile.specificationVersion
        }
        next.toolsEnabled = next.guides.enabled || next.zebra.enabled || next.focus.enabled
          || next.scopes.enabled || next.falseColor.mode != .off
        configuration = next
      })
  }

  private var sourceProfile: Binding<String> {
    Binding(
      get: { configuration.sourceProfileID ?? "" },
      set: { value in
        var next = configuration
        next.sourceProfileID = value.isEmpty ? nil : value
        if SonySLog3FalseColor.supports(sourceProfileID: value) {
          if next.falseColor.mode == .elZone {
            next.falseColor.profileID = ELZoneProfile.profileID
            next.falseColor.specificationVersion = ELZoneProfile.specificationVersion
          } else {
            next.falseColor.profileID = SonySLog3FalseColor.profileID
            next.falseColor.specificationVersion = SonySLog3FalseColor.specificationVersion
          }
          if next.falseColor.mode == .arri { next.falseColor.mode = .sonySLog3 }
        } else {
          next.falseColor.profileID = nil
          next.falseColor.specificationVersion = nil
        }
        configuration = next
      })
  }

  private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
    percent: Bool = false, suffix: String = "") -> some View {
    LabeledContent {
      HStack {
        Slider(value: value, in: range).frame(minWidth: 110)
        Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : String(format: suffix == "×" ? "%.2f" : "%.0f", value.wrappedValue) + suffix)
          .font(.uiMeta.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
      }
    } label: { Text(title) }
    .accessibilityElement(children: .combine)
  }
}

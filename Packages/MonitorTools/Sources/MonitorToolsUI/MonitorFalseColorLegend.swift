import MonitorToolsCore
import SwiftUI

public enum MonitorProfileName {
  public static func display(_ id: String?) -> String {
    switch id {
    case "sony-slog3-sgamut3cine": return "Sony S-Gamut3.Cine / S-Log3"
    case "sony-slog3-sgamut3": return "Sony S-Gamut3 / S-Log3"
    default: return "Unknown source profile"
    }
  }
}

public struct MonitorFalseColorLegend: View {
  public let configuration: MonitorConfiguration
  public init(configuration: MonitorConfiguration) { self.configuration = configuration }
  public var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(
        "\(modeName) · \(analysisLabel) · \(MonitorProfileName.display(configuration.sourceProfileID))"
      )
      if configuration.falseColor.mode == .elZone,
        ELZoneProfile.supports(sourceProfileID: configuration.sourceProfileID),
        configuration.falseColor.profileID == ELZoneProfile.profileID,
        configuration.falseColor.specificationVersion == ELZoneProfile.specificationVersion
      {
        Text("Public-chart mapping · Sony M&C match not tested")
        Text("18% gray = 0 stops before monitor offset")
        Text(
          "Additive monitor offset: \(configuration.falseColor.referenceOffsetStops, specifier: "%+.2f") stops · camera EI independent"
        )
        elZoneColorItems
        Text("Chart labels in stops · midpoint interior bands · black ≤−6, white ≥+6")
      } else if configuration.falseColor.mode == .sonySLog3,
        SonySLog3FalseColor.supports(sourceProfileID: configuration.sourceProfileID),
        configuration.falseColor.profileID == SonySLog3FalseColor.profileID,
        configuration.falseColor.specificationVersion == SonySLog3FalseColor.specificationVersion
      {
        Text("Sony Monitor & Control thresholds · Ultracam display colors")
        colorItems
        Text("Lower edge included; upper excluded. Unassigned IRE stays gray.")
        Text("EI-independent source IRE bands do not guarantee Sony sensor clipping.")
      } else {
        Text("Unavailable: choose a supported Sony S-Log3 source profile")
      }
    }.font(.caption2).accessibilityElement(children: .combine)
  }
  private var analysisLabel: String {
    switch configuration.falseColor.mode {
    case .elZone: return "Source stops"
    case .sonySLog3: return "Source IRE"
    default: return "Source"
    }
  }
  private var modeName: String {
    switch configuration.falseColor.mode {
    case .off: return "False Color off"
    case .elZone: return "EL Zone"
    case .sonySLog3: return "Sony S-Log3"
    case .arri: return "Unsupported saved mode"
    }
  }
  private var colorItems: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 7) { items }
      VStack(alignment: .leading, spacing: 3) { items }
    }
  }
  private var elZoneColorItems: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), alignment: .leading)], alignment: .leading) {
      ForEach(ELZoneProfile.stopLabels.indices, id: \.self) { index in
        HStack(spacing: 3) {
          let rgb = ELZoneProfile.palette[index]
          Rectangle().fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b)).frame(width: 9, height: 9)
          if index == 0 {
            Text("≤−6")
          } else if index == ELZoneProfile.stopLabels.count - 1 {
            Text("≥+6")
          } else {
            Text("\(ELZoneProfile.stopLabels[index], specifier: "%+g")")
          }
        }
      }
    }
  }
  @ViewBuilder private var items: some View {
    ForEach(SonySLog3FalseColor.zones, id: \.category) { zone in
      HStack(spacing: 3) {
        let rgb = zone.category.color
        Rectangle().fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b)).frame(width: 9, height: 9)
        Text(
          "\(label(zone.category)): \(zone.lowerIRE, specifier: "%.1f")–\(zone.upperIRE, specifier: "%.1f") IRE"
        )
      }
    }
  }
  private func label(_ category: SonyFalseColorCategory) -> String {
    switch category {
    case .lightPink: return "Light pink"
    case .lightBlue: return "Light blue"
    default: return category.rawValue.capitalized
    }
  }
}

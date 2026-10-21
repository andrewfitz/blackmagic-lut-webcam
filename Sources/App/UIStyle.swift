import SwiftUI

// Shared visual language for the new interface. System colors and materials
// only, so light, dark, Increase Contrast and Reduce Transparency all work.

extension UITone {
  var color: Color {
    switch self {
    case .neutral: return .secondary
    case .positive: return .green
    case .warning: return .orange
    case .critical, .onAir: return .red
    }
  }
}

extension UITally {
  var ringColor: Color? {
    switch self {
    case .none: return nil
    case .onAir: return .red
    case .program: return nil
    case .next: return .green
    }
  }
}

/// Glass on macOS 26 and later; a regular material before that, and an opaque
/// fill when Reduce Transparency is on.
struct UIGlassBackground<S: Shape>: ViewModifier {
  var shape: S
  var tint: Color? = nil
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Color(nsColor: .windowBackgroundColor), in: shape)
    } else if #available(macOS 26.0, *) {
      content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
    } else {
      content.background(.regularMaterial, in: shape)
    }
  }
}

extension View {
  func uiGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View { modifier(UIGlassBackground(shape: shape, tint: tint)) }

  /// Dark backing for text drawn over video, so it stays readable over bright pictures (≥ 4.5:1).
  func uiPictureOverlay() -> some View {
    padding(.horizontal, 8).frame(height: 24)
      .background(Color.black.opacity(0.72), in: Capsule())
      .foregroundStyle(.white)
      .environment(\.colorScheme, .dark)
  }
}

/// A small status badge. Tone sets the color; the text always carries the meaning.
struct UIBadge: View {
  let text: String
  var tone: UITone = .neutral
  var filled = false

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 6).frame(height: 18)
      .foregroundStyle(filled ? .white : (tone == .neutral ? .secondary : tone.color))
      .background(filled ? tone.color : tone.color.opacity(tone == .neutral ? 0.12 : 0.16), in: Capsule())
      .accessibilityLabel(text)
  }
}

/// The tally badge drawn on a picture: ON AIR (red), PROGRAM (outlined), NEXT (green).
struct UITallyBadge: View {
  let tally: UITally
  var body: some View {
    if let text = tally.badge {
      Text(text)
        .font(.caption.weight(.bold))
        .padding(.horizontal, 9).frame(height: 22)
        .foregroundStyle(tally == .next ? Color.black : .white)
        .background(background, in: Capsule())
        .overlay(Capsule().strokeBorder(tally == .program ? Color.white.opacity(0.6) : .clear, lineWidth: 1.5))
        .accessibilityLabel(text.capitalized)
    }
  }
  private var background: Color {
    switch tally {
    case .onAir: return .red
    case .next: return .green
    default: return .black.opacity(0.72)
    }
  }
}

/// The single record control for a take: a round red button that becomes a stop square.
struct UIRecordButton: View {
  let active: Bool
  let enabled: Bool
  let help: String
  var size: CGFloat = 28
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().strokeBorder(Color.primary.opacity(0.75), lineWidth: 2)
        if active {
          RoundedRectangle(cornerRadius: size * 0.1).fill(.red).frame(width: size * 0.38, height: size * 0.38)
        } else {
          Circle().fill(.red).frame(width: size * 0.66, height: size * 0.66)
        }
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.35)
    .help(help)
    .accessibilityLabel(active ? "Stop Recording" : "Record")
  }
}

/// An effect toggle chip. State is shown with a checkmark, not color alone.
struct UIChipToggle: View {
  let chip: UIChip
  var compact = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 3) {
        if chip.isOn { Image(systemName: "checkmark").font(.system(size: compact ? 8 : 9, weight: .bold)) }
        Text(chip.title)
      }
      .font((compact ? Font.caption2 : .caption).weight(.semibold))
      .padding(.horizontal, compact ? 5 : 7).frame(height: compact ? 18 : 22)
      .foregroundStyle(chip.isOn ? Color.primary : .secondary)
      .background(chip.isOn ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chip.isOn ? .clear : Color.secondary.opacity(0.35), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(!chip.enabled)
    .opacity(chip.enabled ? 1 : 0.45)
    .help(chip.help)
    .accessibilityLabel(chip.title)
    .accessibilityValue(chip.isOn ? "On" : "Off")
    .accessibilityAddTraits(chip.isOn ? .isSelected : [])
  }
}

enum UIAudioMath {
  static func normalized(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
  static func decibels(_ linear: Double) -> String {
    let level = normalized(linear)
    guard level > 0.000001 else { return "−∞ dB" }
    return String(format: "%.1f dB", max(-60, 20 * log10(level)))
  }
}

/// Peak/RMS bar for one channel: the filled bar is RMS, the marker is peak.
struct UILevelBar: View {
  let rms: Double
  let peak: Double
  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.12))
        Capsule().fill(LinearGradient(colors: [.green, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
          .frame(width: max(2, width * UIAudioMath.normalized(rms)))
        Capsule().fill(Color.primary).frame(width: 2).offset(x: max(0, width * UIAudioMath.normalized(peak) - 1))
      }
      .clipShape(Capsule())
    }
    .accessibilityHidden(true)
  }
}

/// Two-channel meter with a dB readout of the louder peak.
struct UIAudioMeter: View {
  let audio: UIAudioLevels
  var compact = false
  var body: some View {
    if compact {
      VStack(spacing: 2) {
        UILevelBar(rms: audio.rmsLeft, peak: audio.peakLeft).frame(height: 3)
        UILevelBar(rms: audio.rmsRight, peak: audio.peakRight).frame(height: 3)
      }
      .frame(width: 42)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Audio level")
      .accessibilityValue(audio.present ? UIAudioMath.decibels(max(audio.peakLeft, audio.peakRight)) : "No embedded audio")
    } else {
      HStack(spacing: 8) {
        Text("L").font(.caption2.monospaced()).foregroundStyle(.secondary)
        UILevelBar(rms: audio.rmsLeft, peak: audio.peakLeft).frame(height: 6)
        Text("R").font(.caption2.monospaced()).foregroundStyle(.secondary)
        UILevelBar(rms: audio.rmsRight, peak: audio.peakRight).frame(height: 6)
        Text(audio.present ? UIAudioMath.decibels(max(audio.peakLeft, audio.peakRight)) : "No audio")
          .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Embedded audio")
      .accessibilityValue(audio.present
        ? "Left peak \(UIAudioMath.decibels(audio.peakLeft)), right peak \(UIAudioMath.decibels(audio.peakRight))"
        : "No embedded audio")
    }
  }
}

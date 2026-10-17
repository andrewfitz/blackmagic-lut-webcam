import Foundation

struct CubeLUT: Sendable {
  // Cube 1.0 limits every numeric token to the range supported by a 32-bit
  // float implementation. Keep a stricter bound than `Float.isFinite` so a
  // value near Float.greatestFiniteMagnitude cannot overflow interpolation
  // or color conversion later in the GPU pipeline.
  private static let maximumNumber = Float(1e37)

  let title: String
  let dimension: Int
  let domainMin: SIMD3<Float>
  let domainMax: SIMD3<Float>
  // .cube ordering: red varies fastest, then green, then blue.
  let rgba: [Float]

  enum ParseError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
      switch self { case .invalid(let reason): return "Invalid LUT: \(reason)" }
    }
  }

  init(text: String, fallbackTitle: String = "Untitled LUT") throws {
    guard text.utf8.count <= 32 * 1024 * 1024 else {
      throw ParseError.invalid("file exceeds 32 MB")
    }
    // A number of LUT exporters write a UTF-8 byte-order mark even though
    // the .cube format is otherwise plain UTF-8.  `String` preserves that
    // marker as U+FEFF, which would otherwise make the first header key
    // unknown (for example, `\u{FEFF}LUT_3D_SIZE`).  It is metadata rather
    // than part of the title or first directive, so remove it before parsing.
    var source = text
    if source.first == "\u{FEFF}" { source.removeFirst() }
    // Callers commonly pass a filename-derived fallback, but a malformed or
    // extensionless URL can still produce an empty string. Keep the parsed
    // model displayable even when an explicit TITLE is empty.
    var title = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Untitled LUT" : fallbackTitle
    var dimension: Int?
    var low = SIMD3<Float>(repeating: 0)
    var high = SIMD3<Float>(repeating: 1)
    var values: [Float] = []
    var headers: Set<String> = []
    for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
      guard raw.utf8.count <= 250 else {
        throw ParseError.invalid("line \(index + 1): line exceeds 250 bytes")
      }
      // The specification defines comments as lines beginning with `#`, but
      // inline comments are common in exported files. Strip an inline marker
      // only when it is outside a quoted TITLE so a title such as
      // `TITLE "Look #1"` remains intact.
      var quoted = false
      var commentStart: String.Index?
      for cursor in raw.indices {
        let character = raw[cursor]
        if character == "\"" { quoted.toggle() }
        else if character == "#" && !quoted {
          commentStart = cursor
          break
        }
      }
      let uncommented = commentStart.map { String(raw[..<$0]) } ?? raw
      let line = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let key = parts.first else { continue }
      func invalid(_ reason: String) -> ParseError {
        .invalid("line \(index + 1): \(reason)")
      }
      if key == "TITLE" {
        guard values.isEmpty, headers.insert(key).inserted else {
          throw invalid("duplicate or misplaced TITLE")
        }
        let payload = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard payload.count >= 2, payload.first == "\"", payload.last == "\"" else {
          throw invalid("TITLE must be enclosed in quotes")
        }
        let parsed = String(payload.dropFirst().dropLast())
        guard !parsed.contains("\"") else {
          throw invalid("TITLE contains an unescaped quote")
        }
        // Preserve the filename fallback for an explicitly empty TITLE so the
        // UI never renders a blank LUT name.
        if !parsed.isEmpty { title = parsed }
        continue
      }
      if ["LUT_3D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX"].contains(key) {
        guard values.isEmpty, headers.insert(key).inserted else {
          throw invalid("duplicate or misplaced \(key)")
        }
        if key == "LUT_3D_SIZE" {
          guard parts.count == 2, let size = Int(parts[1]), (2...65).contains(size) else {
            throw invalid("3D size must be between 2 and 65")
          }
          dimension = size
          values.reserveCapacity(size * size * size * 4)
        } else {
          guard parts.count == 4 else { throw invalid("domain requires three numbers") }
          let numbers = parts.dropFirst().compactMap(Float.init)
          guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite && abs($0) <= Self.maximumNumber }) else {
            throw invalid("domain numbers must be finite and within ±1e37")
          }
          let vector = SIMD3(numbers[0], numbers[1], numbers[2])
          if key == "DOMAIN_MIN" { low = vector } else { high = vector }
        }
        continue
      }
      guard let size = dimension else { throw invalid("expected LUT_3D_SIZE before data") }
      guard parts.count == 3 else { throw invalid("expected an RGB triplet; 1D/shaper LUTs are unsupported") }
      let numbers = parts.compactMap(Float.init)
      guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite && abs($0) <= Self.maximumNumber }) else {
        throw invalid("expected three finite RGB numbers within ±1e37")
      }
      guard values.count < size * size * size * 4 else { throw invalid("too many entries") }
      values.append(contentsOf: numbers)
      values.append(1)
    }
    guard let size = dimension, values.count == size * size * size * 4 else {
      throw ParseError.invalid("missing size or incomplete cube")
    }
    guard high.x > low.x, high.y > low.y, high.z > low.z else {
      throw ParseError.invalid("DOMAIN_MAX must exceed DOMAIN_MIN")
    }
    let span = high - low
    let inverse = SIMD3<Float>(repeating: 1) / span
    guard [span.x, span.y, span.z, inverse.x, inverse.y, inverse.z].allSatisfy(\.isFinite) else {
      throw ParseError.invalid("domain span cannot be represented safely in floating-point processing")
    }
    self.title = title
    self.dimension = size
    self.domainMin = low
    self.domainMax = high
    self.rgba = values
  }

  var data: Data { rgba.withUnsafeBytes { Data($0) } }
}

import Foundation

struct CubeLUT: Sendable {
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
    var title = fallbackTitle
    var dimension: Int?
    var low = SIMD3<Float>(repeating: 0)
    var high = SIMD3<Float>(repeating: 1)
    var values: [Float] = []
    var headers: Set<String> = []
    for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
      let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let key = parts.first else { continue }
      func invalid(_ reason: String) -> ParseError {
        .invalid("line \(index + 1): \(reason)")
      }
      if key == "TITLE" {
        title = String(line.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
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
          guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
            throw invalid("non-finite domain")
          }
          let vector = SIMD3(numbers[0], numbers[1], numbers[2])
          if key == "DOMAIN_MIN" { low = vector } else { high = vector }
        }
        continue
      }
      guard let size = dimension else { throw invalid("expected LUT_3D_SIZE before data") }
      guard parts.count == 3 else { throw invalid("expected an RGB triplet; 1D/shaper LUTs are unsupported") }
      let numbers = parts.compactMap(Float.init)
      guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
        throw invalid("expected three finite RGB numbers")
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
    self.title = title
    self.dimension = size
    self.domainMin = low
    self.domainMax = high
    self.rgba = values
  }

  var data: Data { rgba.withUnsafeBytes { Data($0) } }
}

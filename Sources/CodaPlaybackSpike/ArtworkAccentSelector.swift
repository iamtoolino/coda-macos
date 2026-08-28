import Foundation

struct ArtworkPixel: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
  let alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
}

enum ArtworkAccentSelectionKind: Equatable {
  case chromatic
  case tintedNeutral
  case neutral
  case brand
}

struct ArtworkAccentSelection: Equatable {
  let color: ArtworkColor
  let kind: ArtworkAccentSelectionKind
}

enum ArtworkAccentSelector {
  private struct PerceptualPixel {
    let lightness: Double
    let a: Double
    let b: Double
    let chroma: Double
    let hue: Double
    let alpha: Double
    let visibility: Double
  }

  static func select(from sourcePixels: [ArtworkPixel]) -> ArtworkAccentSelection {
    let pixels = sourcePixels.compactMap(perceptualPixel)
    guard !pixels.isEmpty else { return brandSelection }

    let visibleArea = pixels.reduce(0.0) { $0 + $1.alpha * $1.visibility }
    guard visibleArea > 0 else { return brandSelection }

    let chromaticCoverage = pixels.reduce(0.0) { partial, pixel in
      partial + (pixel.chroma >= 0.035 ? pixel.alpha * pixel.visibility : 0)
    } / visibleArea

    let binCount = 36
    var histogram = Array(repeating: 0.0, count: binCount)
    for pixel in pixels where pixel.chroma >= 0.025 && pixel.visibility > 0 {
      let index = min(Int(pixel.hue / 360 * Double(binCount)), binCount - 1)
      histogram[index] += pixel.alpha * pixel.visibility * min(pixel.chroma / 0.12, 1)
    }
    let kernel = [0.25, 0.60, 1.0, 0.60, 0.25]
    let smoothed = histogram.indices.map { index in
      kernel.indices.reduce(0.0) { partial, kernelIndex in
        let offset = kernelIndex - 2
        let wrapped = (index + offset + binCount) % binCount
        return partial + histogram[wrapped] * kernel[kernelIndex]
      }
    }
    let winningIndex = smoothed.indices.max { smoothed[$0] < smoothed[$1] } ?? 0
    let winningCenter = (Double(winningIndex) + 0.5) * 360 / Double(binCount)
    let familyPixels = pixels.filter {
      $0.chroma >= 0.025 && circularDistance($0.hue, winningCenter) <= 30
    }
    let familySupport = familyPixels.reduce(0.0) {
      $0 + $1.alpha * $1.visibility
    } / visibleArea

    if chromaticCoverage >= 0.12, familySupport >= 0.12, !familyPixels.isEmpty {
      let weights = familyPixels.map {
        $0.alpha * $0.visibility * min($0.chroma / 0.12, 1)
      }
      let x = zip(familyPixels, weights).reduce(0.0) {
        $0 + cos($1.0.hue * .pi / 180) * $1.1
      }
      let y = zip(familyPixels, weights).reduce(0.0) {
        $0 + sin($1.0.hue * .pi / 180) * $1.1
      }
      var hue = atan2(y, x) * 180 / .pi
      if hue < 0 { hue += 360 }
      let lightness = weightedQuantile(
        zip(familyPixels, weights).map { ($0.0.lightness, $0.1) },
        quantile: 0.50
      )
      let chroma = weightedQuantile(
        zip(familyPixels, weights).map { ($0.0.chroma, $0.1) },
        quantile: 0.60
      )
      guard let color = convertedColor(
        lightness: min(max(lightness, 0.48), 0.62),
        chroma: min(max(chroma, 0.07), 0.16),
        hue: hue
      ) else { return brandSelection }
      return ArtworkAccentSelection(color: color, kind: .chromatic)
    }

    let weights = pixels.map { $0.alpha * max($0.visibility, 0.15) }
    let weightTotal = weights.reduce(0, +)
    guard weightTotal > 0 else { return brandSelection }
    let lightness = weightedQuantile(
      zip(pixels, weights).map { ($0.0.lightness, $0.1) },
      quantile: 0.50
    )
    let averageA = zip(pixels, weights).reduce(0.0) { $0 + $1.0.a * $1.1 } / weightTotal
    let averageB = zip(pixels, weights).reduce(0.0) { $0 + $1.0.b * $1.1 } / weightTotal
    let averageChroma = hypot(averageA, averageB)
    var hue = atan2(averageB, averageA) * 180 / .pi
    if hue < 0 { hue += 360 }
    let isTinted = averageChroma >= 0.012 || chromaticCoverage >= 0.08
    guard let color = convertedColor(
      lightness: min(max(lightness, 0.48), 0.62),
      chroma: min(averageChroma, isTinted ? 0.045 : 0.020),
      hue: hue
    ) else { return brandSelection }
    return ArtworkAccentSelection(
      color: color,
      kind: isTinted ? .tintedNeutral : .neutral
    )
  }

  private static var brandSelection: ArtworkAccentSelection {
    ArtworkAccentSelection(color: .fallback, kind: .brand)
  }

  private static func perceptualPixel(_ pixel: ArtworkPixel) -> PerceptualPixel? {
    guard pixel.alpha > 0.01 else { return nil }
    let red = linearized(pixel.red)
    let green = linearized(pixel.green)
    let blue = linearized(pixel.blue)
    let l = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue
    let m = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue
    let s = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue
    let lRoot = cbrt(l)
    let mRoot = cbrt(m)
    let sRoot = cbrt(s)
    let lightness = 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot
    let a = 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot
    let b = 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
    let chroma = hypot(a, b)
    var hue = atan2(b, a) * 180 / .pi
    if hue < 0 { hue += 360 }
    let visibility = smoothstep(0.05, 0.18, lightness)
      * (1 - smoothstep(0.88, 0.98, lightness))
    return PerceptualPixel(
      lightness: lightness,
      a: a,
      b: b,
      chroma: chroma,
      hue: hue,
      alpha: pixel.alpha,
      visibility: visibility
    )
  }

  private static func weightedQuantile(
    _ values: [(value: Double, weight: Double)],
    quantile: Double
  ) -> Double {
    let ordered = values.filter { $0.weight > 0 }.sorted { $0.value < $1.value }
    guard let last = ordered.last else { return 0 }
    let target = ordered.reduce(0.0) { $0 + $1.weight }
      * min(max(quantile, 0), 1)
    var cumulative = 0.0
    for item in ordered {
      cumulative += item.weight
      if cumulative >= target { return item.value }
    }
    return last.value
  }

  private static func convertedColor(
    lightness: Double,
    chroma: Double,
    hue: Double
  ) -> ArtworkColor? {
    let radians = hue * .pi / 180
    func components(chromaScale: Double) -> (Double, Double, Double) {
      let a = cos(radians) * chroma * chromaScale
      let b = sin(radians) * chroma * chromaScale
      let lRoot = lightness + 0.3963377774 * a + 0.2158037573 * b
      let mRoot = lightness - 0.1055613458 * a - 0.0638541728 * b
      let sRoot = lightness - 0.0894841775 * a - 1.2914855480 * b
      let l = lRoot * lRoot * lRoot
      let m = mRoot * mRoot * mRoot
      let s = sRoot * sRoot * sRoot
      return (
        encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
      )
    }

    var low = 0.0
    var high = 1.0
    var result = components(chromaScale: 0)
    for _ in 0..<18 {
      let scale = (low + high) / 2
      let candidate = components(chromaScale: scale)
      if candidate.0 >= 0, candidate.0 <= 1,
        candidate.1 >= 0, candidate.1 <= 1,
        candidate.2 >= 0, candidate.2 <= 1
      {
        result = candidate
        low = scale
      } else {
        high = scale
      }
    }
    guard result.0.isFinite, result.1.isFinite, result.2.isFinite else { return nil }
    return ArtworkColor(
      red: min(max(result.0, 0), 1),
      green: min(max(result.1, 0), 1),
      blue: min(max(result.2, 0), 1)
    )
  }

  private static func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
    let unit = min(max((value - lower) / (upper - lower), 0), 1)
    return unit * unit * (3 - 2 * unit)
  }

  private static func circularDistance(_ lhs: Double, _ rhs: Double) -> Double {
    let direct = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
    return min(direct, 360 - direct)
  }

  private static func linearized(_ component: Double) -> Double {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }

  private static func encoded(_ component: Double) -> Double {
    component <= 0.0031308
      ? 12.92 * component
      : 1.055 * pow(component, 1 / 2.4) - 0.055
  }
}

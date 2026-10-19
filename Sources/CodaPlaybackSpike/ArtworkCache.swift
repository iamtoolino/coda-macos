import AppKit
import Combine
import Foundation
import ImageIO

enum ArtworkURLCachePolicy {
  static let memoryCapacity = 256 * 1_024 * 1_024
  static let diskCapacity = 0
  static let requestCachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy

  static func makeCache() -> URLCache {
    URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity)
  }

  static func makeSession(cache: URLCache) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = cache
    configuration.requestCachePolicy = requestCachePolicy
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    return URLSession(configuration: configuration)
  }

  static func request(for url: URL) -> URLRequest {
    URLRequest(url: url, cachePolicy: requestCachePolicy, timeoutInterval: 30)
  }
}

@MainActor
final class ArtworkImageCache: ObservableObject {
  static let shared = ArtworkImageCache()
  static let decodedImageCapacity = 128 * 1_024 * 1_024

  @Published private(set) var generation = 0

  private struct LoadingRequest: Hashable {
    let url: URL
    let generation: Int
  }

  private let images = NSCache<NSURL, NSImage>()
  /// Accents computed while decoding, keyed weakly by the decoded image.
  private let accents = NSMapTable<NSImage, ArtworkAccentBox>.weakToStrongObjects()
  private var loadingTasks: [LoadingRequest: Task<Data?, Never>] = [:]
  private let responseCache: URLCache
  private let session: URLSession

  init(
    responseCache: URLCache = CodaURLSessions.artworkCache,
    session: URLSession = CodaURLSessions.artwork
  ) {
    self.responseCache = responseCache
    self.session = session
    images.countLimit = 300
    images.totalCostLimit = Self.decodedImageCapacity
  }

  func image(for url: URL?) async -> NSImage {
    guard let url else { return CodaPlaceholderArtwork.image }
    if let image = images.object(forKey: url as NSURL) {
      return image
    }

    let loadingRequest = LoadingRequest(url: url, generation: generation)
    let task: Task<Data?, Never>
    if let existingTask = loadingTasks[loadingRequest] {
      task = existingTask
    } else {
      task = Task {
        do {
          let (data, response) = try await session.data(
            for: ArtworkURLCachePolicy.request(for: url)
          )
          if let response = response as? HTTPURLResponse {
            guard (200..<300).contains(response.statusCode) else { return nil }
          }
          return data
        } catch {
          return nil
        }
      }
      loadingTasks[loadingRequest] = task
    }

    let data = await task.value
    loadingTasks[loadingRequest] = nil
    guard loadingRequest.generation == generation else {
      return CodaPlaceholderArtwork.image
    }
    guard let data, let decoded = await Self.decode(data) else {
      return CodaPlaceholderArtwork.image
    }
    guard loadingRequest.generation == generation else {
      return CodaPlaceholderArtwork.image
    }
    let image = NSImage(
      cgImage: decoded.image,
      size: NSSize(width: decoded.image.width, height: decoded.image.height)
    )
    accents.setObject(ArtworkAccentBox(decoded.accent), forKey: image)
    images.setObject(
      image,
      forKey: url as NSURL,
      cost: Self.decodedMemoryCost(of: image, fallback: data.count)
    )
    return image
  }

  func cachedAccent(for image: NSImage) -> ArtworkColor? {
    accents.object(forKey: image)?.accent
  }

  /// Decodes fully and derives the accent away from the main actor, so drawing the
  /// artwork later does not decode it on the main thread.
  @concurrent
  private nonisolated static func decode(_ data: Data) async -> DecodedArtwork? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source,
        0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      )
    else { return nil }
    return DecodedArtwork(image: image, accent: ArtworkAccentExtraction.accent(from: image))
  }

  func invalidate(urls: [URL]) async {
    let invalidatedURLs = Set(urls)
    guard !invalidatedURLs.isEmpty else { return }
    generation &+= 1
    for url in invalidatedURLs {
      images.removeObject(forKey: url as NSURL)
      responseCache.removeCachedResponse(for: ArtworkURLCachePolicy.request(for: url))
    }
    for (request, task) in loadingTasks where invalidatedURLs.contains(request.url) {
      task.cancel()
      loadingTasks[request] = nil
    }
  }

  func invalidateAll() async {
    resetMemory()
    responseCache.removeAllCachedResponses()
  }

  func resetMemory() {
    generation &+= 1
    images.removeAllObjects()
    loadingTasks.values.forEach { $0.cancel() }
    loadingTasks.removeAll()
  }

  private static func decodedMemoryCost(of image: NSImage, fallback: Int) -> Int {
    let largestRepresentation = image.representations.max {
      $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
    }
    guard let largestRepresentation else { return fallback }
    return max(fallback, largestRepresentation.pixelsWide * largestRepresentation.pixelsHigh * 4)
  }
}

private struct DecodedArtwork: Sendable {
  let image: CGImage
  let accent: ArtworkColor
}

private final class ArtworkAccentBox {
  let accent: ArtworkColor

  init(_ accent: ArtworkColor) {
    self.accent = accent
  }
}

enum ArtworkAccentExtraction {
  static let sampleDimension = 32

  /// Samples a small sRGB thumbnail; pure, so it can run on any thread.
  static func accent(from image: CGImage) -> ArtworkColor {
    let dimension = sampleDimension
    let bytesPerRow = dimension * 4
    var bytes = [UInt8](repeating: 0, count: dimension * bytesPerRow)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: buffer.baseAddress,
          width: dimension,
          height: dimension,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
      return true
    }
    guard drawn else { return .fallback }

    var pixels: [ArtworkPixel] = []
    pixels.reserveCapacity(dimension * dimension)
    for offset in stride(from: 0, to: bytes.count, by: 4) {
      let alpha = Double(bytes[offset + 3]) / 255
      guard alpha > 0 else {
        pixels.append(ArtworkPixel(red: 0, green: 0, blue: 0, alpha: 0))
        continue
      }
      // Undo premultiplication so translucent pixels keep their hue.
      pixels.append(
        ArtworkPixel(
          red: min(1, Double(bytes[offset]) / 255 / alpha),
          green: min(1, Double(bytes[offset + 1]) / 255 / alpha),
          blue: min(1, Double(bytes[offset + 2]) / 255 / alpha),
          alpha: alpha
        )
      )
    }
    return ArtworkAccentSelector.select(from: pixels).color
  }
}

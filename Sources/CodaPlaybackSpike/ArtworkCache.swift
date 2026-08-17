import AppKit
import Combine
import Foundation

enum ArtworkURLCachePolicy {
  static let memoryCapacity = 256 * 1_024 * 1_024
  static let diskCapacity = 0
  static let requestCachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy

  static func makeCache() -> URLCache {
    URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity)
  }

  static func makeSession(cache: URLCache) -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = cache
    configuration.requestCachePolicy = requestCachePolicy
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
    guard let data, let image = NSImage(data: data) else {
      return CodaPlaceholderArtwork.image
    }
    images.setObject(
      image,
      forKey: url as NSURL,
      cost: Self.decodedMemoryCost(of: image, fallback: data.count)
    )
    return image
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

import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

struct ArtworkDiskCacheKey: Hashable, Sendable {
  enum Kind: String, Sendable {
    case artist
    case album
  }

  enum Variant: String, Sendable {
    case presentation1200
    case browsing500

    var filename: String {
      switch self {
      case .presentation1200: "1200.image"
      case .browsing500: "500.image"
      }
    }
  }

  let account: String
  let kind: Kind
  let entity: String
  let variant: Variant

  init?(url: URL) {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme,
      let host = components.host,
      let queryItems = components.queryItems
    else { return nil }

    let parameters = Dictionary(
      queryItems.map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { first, _ in first }
    )
    guard
      let username = parameters["u"], !username.isEmpty,
      let artworkID = parameters["id"],
      let requestedSize = Int(parameters["size"] ?? ""), requestedSize > 0,
      let identity = Self.entityIdentity(from: artworkID)
    else { return nil }

    var serverIdentity = "\(scheme.lowercased())://\(host.lowercased())"
    if let port = components.port {
      serverIdentity += ":\(port)"
    }
    if let range = components.path.range(of: "/rest/getCoverArt", options: .backwards) {
      serverIdentity += String(components.path[..<range.lowerBound])
    } else {
      return nil
    }

    account = NavidromeConfiguration.md5("\(serverIdentity)\0\(username)")
    kind = identity.kind
    entity = NavidromeConfiguration.md5(identity.id)
    variant = requestedSize <= ArtworkPurpose.standard.rawValue
      ? .browsing500 : .presentation1200
  }

  func withVariant(_ variant: Variant) -> ArtworkDiskCacheKey {
    ArtworkDiskCacheKey(account: account, kind: kind, entity: entity, variant: variant)
  }

  static func originalRequestURL(from url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.queryItems = components.queryItems?.filter { $0.name != "size" }
    return components.url
  }

  private init(account: String, kind: Kind, entity: String, variant: Variant) {
    self.account = account
    self.kind = kind
    self.entity = entity
    self.variant = variant
  }

  private static func entityIdentity(from artworkID: String) -> (kind: Kind, id: String)? {
    guard artworkID.count > 3 else { return nil }
    let kind: Kind
    let versionedID: Substring
    switch artworkID.prefix(3) {
    case "ar-":
      kind = .artist
      versionedID = artworkID.dropFirst(3)
    case "al-", "dc-", "mf-":
      kind = .album
      versionedID = artworkID.dropFirst(3)
    default:
      // Navidrome accepts a raw album ID for getCoverArt. Its typed album
      // artwork ID embeds the same stable ID as al-<album-id>_<version>.
      guard artworkID.dropFirst(2).first != "-" else { return nil }
      return (.album, artworkID)
    }

    let stableID: Substring
    if let separator = versionedID.lastIndex(of: "_") {
      let version = versionedID[versionedID.index(after: separator)...]
      if !version.isEmpty, version.allSatisfy(\.isHexDigit) {
        stableID = versionedID[..<separator]
      } else {
        stableID = versionedID
      }
    } else {
      stableID = versionedID
    }
    guard !stableID.isEmpty else { return nil }
    return (kind, String(stableID))
  }
}

enum ArtworkProcessingPreference {
  static let workerCountKey = "artwork-processing-worker-count"
  static let availableWorkerCounts = Array(1...maxWorkerCount)
  static let defaultWorkerCount = min(3, maxWorkerCount)

  static func workerCount(defaults: UserDefaults = .standard) -> Int {
    let stored = defaults.integer(forKey: workerCountKey)
    return clamped(stored == 0 ? defaultWorkerCount : stored)
  }

  static func clamped(_ value: Int) -> Int {
    min(max(1, value), maxWorkerCount)
  }

  private static var maxWorkerCount: Int {
    min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
  }
}

@MainActor
final class ArtworkProcessingSettings: ObservableObject {
  @Published var workerCount: Int {
    didSet {
      let normalized = ArtworkProcessingPreference.clamped(workerCount)
      if workerCount != normalized {
        workerCount = normalized
        return
      }
      defaults.set(workerCount, forKey: ArtworkProcessingPreference.workerCountKey)
      Task { await ArtworkProcessingPool.shared.setWorkerLimit(workerCount) }
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    workerCount = ArtworkProcessingPreference.workerCount(defaults: defaults)
    Task { await ArtworkProcessingPool.shared.setWorkerLimit(workerCount) }
  }
}

struct ArtworkDerivatives: Sendable {
  let browsing500: Data
  let presentation1200: Data
}

actor ArtworkProcessingPool {
  static let shared = ArtworkProcessingPool(
    workerLimit: ArtworkProcessingPreference.workerCount()
  )

  private var workerLimit: Int
  private var activeWorkers = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(workerLimit: Int) {
    self.workerLimit = ArtworkProcessingPreference.clamped(workerLimit)
  }

  func setWorkerLimit(_ value: Int) {
    workerLimit = ArtworkProcessingPreference.clamped(value)
    resumeAvailableWaiters()
  }

  func makeDerivatives(from sourceData: Data) async -> ArtworkDerivatives? {
    await run {
      ArtworkDerivativeProcessor.makeDerivatives(from: sourceData)
    }
  }

  func run<Result: Sendable>(
    _ operation: @escaping @Sendable () async -> Result
  ) async -> Result {
    await acquireWorker()
    defer { releaseWorker() }
    return await Task.detached(priority: .userInitiated) {
      await operation()
    }.value
  }

  private func acquireWorker() async {
    if activeWorkers < workerLimit {
      activeWorkers += 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func releaseWorker() {
    activeWorkers -= 1
    resumeAvailableWaiters()
  }

  private func resumeAvailableWaiters() {
    while activeWorkers < workerLimit, !waiters.isEmpty {
      activeWorkers += 1
      waiters.removeFirst().resume()
    }
  }
}

enum ArtworkDerivativeProcessor {
  static func makeDerivatives(from sourceData: Data) -> ArtworkDerivatives? {
    guard
      let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
      let presentationImage = makeThumbnail(
        from: source,
        maxPixelSize: ArtworkPurpose.nowPlaying.rawValue
      ),
      let browsingImage = resizedImage(
        presentationImage,
        maxPixelSize: ArtworkPurpose.standard.rawValue
      ),
      let browsingData = encodedData(for: browsingImage),
      let presentationData = encodedData(for: presentationImage)
    else { return nil }

    return ArtworkDerivatives(
      browsing500: browsingData,
      presentation1200: presentationData
    )
  }

  private static func makeThumbnail(
    from source: CGImageSource,
    maxPixelSize: Int
  ) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func resizedImage(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
    let longestEdge = max(image.width, image.height)
    guard longestEdge > maxPixelSize else { return image }
    let scale = CGFloat(maxPixelSize) / CGFloat(longestEdge)
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
    let hasAlpha = imageHasAlpha(image)
    let bitmapInfo = hasAlpha
      ? CGImageAlphaInfo.premultipliedLast.rawValue
      : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  private static func encodedData(for image: CGImage) -> Data? {
    let hasAlpha = imageHasAlpha(image)
    let output = NSMutableData()
    let type = hasAlpha ? UTType.png.identifier : UTType.jpeg.identifier
    guard let destination = CGImageDestinationCreateWithData(
      output,
      type as CFString,
      1,
      nil
    ) else { return nil }
    let properties: [CFString: Any] = hasAlpha
      ? [:]
      : [kCGImageDestinationLossyCompressionQuality: 0.9]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  private static func imageHasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
      true
    case .none, .noneSkipFirst, .noneSkipLast:
      false
    @unknown default:
      true
    }
  }
}

actor ArtworkDiskCache {
  static let shared = ArtworkDiskCache()

  private let directoryURL: URL?

  init(
    directoryURL: URL? = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first?
      .appendingPathComponent("io.github.iamtoolino.coda.macos", isDirectory: true)
      .appendingPathComponent("Artwork", isDirectory: true)
      .appendingPathComponent("v3", isDirectory: true)
  ) {
    self.directoryURL = directoryURL
  }

  func data(for key: ArtworkDiskCacheKey) -> Data? {
    guard let fileURL = fileURL(for: key), FileManager.default.fileExists(atPath: fileURL.path)
    else { return nil }
    do {
      let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      guard Self.isArtworkData(data) else {
        try? FileManager.default.removeItem(at: fileURL)
        return nil
      }
      return data
    } catch {
      return nil
    }
  }

  func store(_ data: Data, for key: ArtworkDiskCacheKey) {
    guard Self.isArtworkData(data), let fileURL = fileURL(for: key) else { return }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // Artwork remains available from the RAM cache for this session.
    }
  }

  func storeDerivatives(
    _ derivatives: ArtworkDerivatives,
    for key: ArtworkDiskCacheKey
  ) {
    store(derivatives.browsing500, for: key.withVariant(.browsing500))
    store(derivatives.presentation1200, for: key.withVariant(.presentation1200))
  }

  func remove(_ keys: Set<ArtworkDiskCacheKey>) {
    let entityDirectories = Set(keys.compactMap(entityDirectoryURL(for:)))
    for directory in entityDirectories {
      try? FileManager.default.removeItem(at: directory)
      removeEmptyParents(startingAt: directory.deletingLastPathComponent())
    }
  }

  func fileURL(for key: ArtworkDiskCacheKey) -> URL? {
    entityDirectoryURL(for: key)?
      .appendingPathComponent(key.variant.filename, isDirectory: false)
  }

  private func entityDirectoryURL(for key: ArtworkDiskCacheKey) -> URL? {
    directoryURL?
      .appendingPathComponent(key.account, isDirectory: true)
      .appendingPathComponent(key.kind.rawValue, isDirectory: true)
      .appendingPathComponent(key.entity, isDirectory: true)
  }

  private func removeEmptyParents(startingAt directory: URL) {
    guard let root = directoryURL else { return }
    var candidate = directory
    while candidate.path.hasPrefix(root.path), candidate != root {
      guard
        let contents = try? FileManager.default.contentsOfDirectory(
          at: candidate,
          includingPropertiesForKeys: nil
        ),
        contents.isEmpty
      else { return }
      try? FileManager.default.removeItem(at: candidate)
      candidate.deleteLastPathComponent()
    }
  }

  private static func isArtworkData(_ data: Data) -> Bool {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      CGImageSourceGetStatus(source) == .statusComplete,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0,
      (properties[kCGImagePropertyPixelHeight] as? Int ?? 0) > 0
    else { return false }
    return true
  }

}

@MainActor
final class ArtworkImageCache: ObservableObject {
  static let shared = ArtworkImageCache()

  @Published private(set) var generation = 0

  private struct LoadingRequest: Hashable {
    let key: String
    let generation: Int
  }

  private let images = NSCache<NSString, NSImage>()
  private var loadingTasks: [LoadingRequest: Task<Data?, Never>] = [:]
  private var derivativeTasks: [LoadingRequest: Task<ArtworkDerivatives?, Never>] = [:]
  private var requestedDiskKeys: Set<ArtworkDiskCacheKey> = []
  private let diskCache: ArtworkDiskCache
  private let session: URLSession

  init(
    diskCache: ArtworkDiskCache = .shared,
    session: URLSession = CodaURLSessions.artwork
  ) {
    self.diskCache = diskCache
    self.session = session
    images.countLimit = 300
    images.totalCostLimit = 256 * 1_024 * 1_024
    URLCache.shared.removeAllCachedResponses()
  }

  func image(for url: URL?) async -> NSImage {
    guard let url else { return CodaPlaceholderArtwork.image }
    let diskKey = ArtworkDiskCacheKey(url: url)
    let memoryKey = Self.memoryKey(for: url, diskKey: diskKey)
    if let image = images.object(forKey: memoryKey) {
      return image
    }

    if let diskKey {
      requestedDiskKeys.insert(diskKey)
      if let data = await diskCache.data(for: diskKey), let image = NSImage(data: data) {
        store(image, dataCount: data.count, for: memoryKey)
        return image
      }
    }

    let originalURL = diskKey.flatMap { _ in ArtworkDiskCacheKey.originalRequestURL(from: url) }
      ?? url
    let loadingKey: String
    if let diskKey {
      loadingKey = "source:\(diskKey.account):\(diskKey.kind.rawValue):\(diskKey.entity)"
    } else {
      loadingKey = memoryKey as String
    }
    let loadingRequest = LoadingRequest(key: loadingKey, generation: generation)
    let task: Task<Data?, Never>
    if let existingTask = loadingTasks[loadingRequest] {
      task = existingTask
    } else {
      task = Task {
        do {
          let request = URLRequest(
            url: originalURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
          )
          let (data, response) = try await session.data(for: request)
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
    guard let data else {
      return CodaPlaceholderArtwork.image
    }
    let displayData: Data
    if let diskKey {
      if let storedData = await diskCache.data(for: diskKey) {
        displayData = storedData
      } else {
        let derivativeRequest = LoadingRequest(key: loadingKey, generation: generation)
        let derivativeTask: Task<ArtworkDerivatives?, Never>
        if let existingTask = derivativeTasks[derivativeRequest] {
          derivativeTask = existingTask
        } else {
          derivativeTask = Task {
            guard let derivatives = await ArtworkProcessingPool.shared.makeDerivatives(from: data)
            else { return nil }
            guard !Task.isCancelled else { return nil }
            await diskCache.storeDerivatives(derivatives, for: diskKey)
            return derivatives
          }
          derivativeTasks[derivativeRequest] = derivativeTask
        }
        let derivatives = await derivativeTask.value
        derivativeTasks[derivativeRequest] = nil
        guard derivativeRequest.generation == generation, let derivatives else {
          return CodaPlaceholderArtwork.image
        }
        switch diskKey.variant {
        case .browsing500:
          displayData = derivatives.browsing500
        case .presentation1200:
          displayData = derivatives.presentation1200
        }
      }
    } else {
      displayData = data
    }
    guard let image = NSImage(data: displayData) else { return CodaPlaceholderArtwork.image }
    store(image, dataCount: displayData.count, for: memoryKey)
    return image
  }

  func invalidate(urls: [URL]) async {
    let diskKeys = Set(urls.compactMap(ArtworkDiskCacheKey.init(url:)))
    let diskMemoryKeys = diskKeys.flatMap { key in
      [
        Self.memoryKey(for: nil, diskKey: key.withVariant(.presentation1200)),
        Self.memoryKey(for: nil, diskKey: key.withVariant(.browsing500)),
      ]
    }
    let uncachedMemoryKeys = urls.compactMap { url -> NSString? in
      guard ArtworkDiskCacheKey(url: url) == nil else { return nil }
      return Self.memoryKey(for: url, diskKey: nil)
    }
    let memoryKeys = Set(diskMemoryKeys + uncachedMemoryKeys)
    generation &+= 1
    for key in memoryKeys {
      images.removeObject(forKey: key)
    }
    let loadingKeys = Set(memoryKeys.map(String.init))
      .union(diskKeys.map {
        "source:\($0.account):\($0.kind.rawValue):\($0.entity)"
      })
    for (request, task) in loadingTasks where loadingKeys.contains(request.key) {
      task.cancel()
      loadingTasks[request] = nil
    }
    for (request, task) in derivativeTasks where loadingKeys.contains(request.key) {
      task.cancel()
      derivativeTasks[request] = nil
    }
    requestedDiskKeys.subtract(diskKeys)
    await diskCache.remove(diskKeys)
  }

  func invalidateAll() async {
    let diskKeys = requestedDiskKeys
    resetMemory()
    requestedDiskKeys.removeAll()
    await diskCache.remove(diskKeys)
  }

  func resetMemory() {
    generation &+= 1
    images.removeAllObjects()
    loadingTasks.values.forEach { $0.cancel() }
    loadingTasks.removeAll()
    derivativeTasks.values.forEach { $0.cancel() }
    derivativeTasks.removeAll()
  }

  private func store(_ image: NSImage, dataCount: Int, for key: NSString) {
    images.setObject(
      image,
      forKey: key,
      cost: Self.decodedMemoryCost(of: image, fallback: dataCount)
    )
  }

  private static func memoryKey(for url: URL?, diskKey: ArtworkDiskCacheKey?) -> NSString {
    if let diskKey {
      return "disk:\(diskKey.account):\(diskKey.kind.rawValue):\(diskKey.entity):\(diskKey.variant.rawValue)"
        as NSString
    }
    return "url:\(url?.absoluteString ?? "")" as NSString
  }

  private static func decodedMemoryCost(of image: NSImage, fallback: Int) -> Int {
    let largestRepresentation = image.representations.max {
      $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
    }
    guard let largestRepresentation else { return fallback }
    return max(fallback, largestRepresentation.pixelsWide * largestRepresentation.pixelsHigh * 4)
  }
}

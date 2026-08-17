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
    case original
    case browsing500

    var filename: String {
      switch self {
      case .original: "original.image"
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
    variant = requestedSize <= ArtworkPurpose.standard.rawValue ? .browsing500 : .original
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
    switch artworkID.prefix(3) {
    case "ar-": kind = .artist
    case "al-", "dc-", "mf-": kind = .album
    default: return nil
    }

    let versionedID = artworkID.dropFirst(3)
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
      .appendingPathComponent("v2", isDirectory: true)
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

  func storeOriginalAndBrowsingImage(
    _ originalData: Data,
    for key: ArtworkDiskCacheKey
  ) -> Data? {
    let originalKey = key.withVariant(.original)
    store(originalData, for: originalKey)
    guard let browsingData = Self.makeBrowsingData(from: originalData) else { return nil }
    store(browsingData, for: key.withVariant(.browsing500))
    return browsingData
  }

  func makeAndStoreBrowsingImage(
    from originalData: Data,
    for key: ArtworkDiskCacheKey
  ) -> Data? {
    guard let browsingData = Self.makeBrowsingData(from: originalData) else { return nil }
    store(browsingData, for: key.withVariant(.browsing500))
    return browsingData
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

  private static func makeBrowsingData(from originalData: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(originalData as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: ArtworkPurpose.standard.rawValue,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }

    let hasAlpha: Bool
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
      hasAlpha = true
    case .none, .noneSkipFirst, .noneSkipLast:
      hasAlpha = false
    @unknown default:
      hasAlpha = true
    }

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
      if diskKey.variant == .browsing500,
        let originalData = await diskCache.data(for: diskKey.withVariant(.original)),
        let browsingData = await diskCache.makeAndStoreBrowsingImage(
          from: originalData,
          for: diskKey
        ),
        let image = NSImage(data: browsingData)
      {
        store(image, dataCount: browsingData.count, for: memoryKey)
        return image
      }
    }

    let originalURL = diskKey.flatMap { _ in ArtworkDiskCacheKey.originalRequestURL(from: url) }
      ?? url
    let loadingKey: String
    if let diskKey {
      loadingKey = "original:\(diskKey.account):\(diskKey.kind.rawValue):\(diskKey.entity)"
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
        let browsingData = await diskCache.storeOriginalAndBrowsingImage(data, for: diskKey)
        if diskKey.variant == .browsing500 {
          guard let browsingData else { return CodaPlaceholderArtwork.image }
          displayData = browsingData
        } else {
          displayData = data
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
        Self.memoryKey(for: nil, diskKey: key.withVariant(.original)),
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
        "original:\($0.account):\($0.kind.rawValue):\($0.entity)"
      })
    for (request, task) in loadingTasks where loadingKeys.contains(request.key) {
      task.cancel()
      loadingTasks[request] = nil
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

import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ArtworkColor: Equatable {
  let red: Double
  let green: Double
  let blue: Double

  static let fallback = ArtworkColor(red: 43.0 / 255.0, green: 122.0 / 255.0, blue: 130.0 / 255.0)
  static let brandAction = ArtworkColor(red: 0.82, green: 0.58, blue: 0.20)
  static let monochromeFallback = ArtworkColor(red: 0.56, green: 0.58, blue: 0.60)
  var color: Color { Color(red: red, green: green, blue: blue) }

  var contrastingColor: Color {
    let luminance = 0.2126 * linearized(red) + 0.7152 * linearized(green)
      + 0.0722 * linearized(blue)
    return luminance > 0.46 ? .black.opacity(0.82) : .white
  }

  private func linearized(_ component: Double) -> Double {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }
}

enum ArtworkDisplayContext: Equatable {
  case brand
  case album(String)
  case standard(activePlaybackIdentity: String?)

  static func resolve(
    hasEstablishedConnection: Bool,
    displayedAlbumID: String?,
    playbackIdentity: String?
  ) -> ArtworkDisplayContext {
    guard hasEstablishedConnection else { return .brand }
    if let displayedAlbumID {
      return .album(displayedAlbumID)
    }
    return .standard(activePlaybackIdentity: playbackIdentity)
  }
}

private struct StoredArtworkTheme {
  let artwork: NSImage
  let accent: ArtworkColor
  let identity: String
}

@MainActor
final class ArtworkTreatmentSettings: ObservableObject {
  private static let showsRatingLabelsKey = "shows-album-rating-labels"

  @Published var accent: ArtworkColor = .fallback
  @Published var artwork: NSImage?
  @Published private(set) var artworkRevision = UUID()
  @Published var showsAlbumRatingLabels: Bool {
    didSet { UserDefaults.standard.set(showsAlbumRatingLabels, forKey: Self.showsRatingLabelsKey) }
  }
  private var playbackArtwork: NSImage?
  private var playbackAccent: ArtworkColor?
  private var playbackArtworkIdentity: String?
  private var displayedArtworkIdentity: String?
  private var albumTheme: StoredArtworkTheme?

  var displayedIdentity: String? { displayedArtworkIdentity }

  init() {
    let defaults = UserDefaults.standard
    showsAlbumRatingLabels = defaults.object(forKey: Self.showsRatingLabelsKey) as? Bool
      ?? true
  }

  private func applyArtwork(
    _ image: NSImage?,
    accent: ArtworkColor,
    identity: String?
  ) {
    if let artwork,
      let image,
      artwork === image,
      self.accent == accent,
      displayedArtworkIdentity == identity
    {
      return
    }
    if artwork == nil, image == nil,
      self.accent == accent,
      displayedArtworkIdentity == identity
    {
      return
    }
    withAnimation(.easeInOut(duration: 0.85)) {
      artwork = image
      self.accent = accent
      displayedArtworkIdentity = identity
      artworkRevision = UUID()
    }
  }

  func rememberPlaybackArtwork(
    _ image: NSImage,
    accent: ArtworkColor,
    identity: String
  ) {
    playbackArtwork = image
    playbackAccent = accent
    playbackArtworkIdentity = identity
  }

  func rememberAlbumArtwork(
    _ image: NSImage,
    accent: ArtworkColor,
    identity: String
  ) {
    albumTheme = StoredArtworkTheme(
      artwork: image,
      accent: accent,
      identity: identity
    )
  }

  func promoteDisplayedArtworkToPlayback(ifIdentity identity: String?) {
    guard let identity,
      displayedArtworkIdentity == identity,
      let artwork
    else { return }
    playbackArtwork = artwork
    playbackAccent = accent
    playbackArtworkIdentity = identity
  }

  func applyDisplayContext(_ context: ArtworkDisplayContext) {
    switch context {
    case .brand:
      applyBrandTheme()

    case .album(let identity):
      // A route change can arrive before its artwork task. Keep the previous
      // valid theme until the requested album is ready, then crossfade once.
      guard let albumTheme, albumTheme.identity == identity else { return }
      applyArtwork(
        albumTheme.artwork,
        accent: albumTheme.accent,
        identity: albumTheme.identity
      )

    case .standard(let activePlaybackIdentity):
      guard let activePlaybackIdentity else {
        applyBrandTheme()
        return
      }
      // Track changes have the same prepare-then-commit behavior as album
      // navigation. Never insert the brand color while artwork is loading.
      guard
        playbackArtworkIdentity == activePlaybackIdentity,
        let playbackArtwork,
        let playbackAccent
      else { return }
      applyArtwork(
        playbackArtwork,
        accent: playbackAccent,
        identity: activePlaybackIdentity
      )
    }
  }

  func applyBrandTheme() {
    applyArtwork(nil, accent: .fallback, identity: nil)
  }
}

struct CollectionHeroMetrics: Equatable {
  let artworkSize: CGFloat
  let spacing: CGFloat
  let trailingPadding: CGFloat
  let height: CGFloat

  init(width: CGFloat) {
    artworkSize = Self.interpolatedValue(
      for: width, minimum: 188, maximum: 236, from: 430, to: 760)
    spacing = Self.interpolatedValue(
      for: width, minimum: 18, maximum: 26, from: 430, to: 820)
    trailingPadding = Self.interpolatedValue(
      for: width, minimum: 20, maximum: 42, from: 430, to: 900)
    height = max(224, artworkSize + 52)
  }

  private static func interpolatedValue(
    for width: CGFloat,
    minimum: CGFloat,
    maximum: CGFloat,
    from lowerWidth: CGFloat,
    to upperWidth: CGFloat
  ) -> CGFloat {
    guard upperWidth > lowerWidth else { return maximum }
    let progress = min(max((width - lowerWidth) / (upperWidth - lowerWidth), 0), 1)
    return minimum + ((maximum - minimum) * progress)
  }
}

enum CollectionHeroArtworkStyle {
  static let shadowOpacity = 0.58
  static let shadowRadius: CGFloat = 16
  static let shadowY: CGFloat = 9
}

enum AlbumRatingBadgeStyle {
  static let size: CGFloat = 24
  static let fontSize: CGFloat = 14
  static let fontWeight = Font.Weight.regular
  static let cornerInset: CGFloat = 4
  static let tintOpacity = 0.35
}

private enum ArtworkBackgroundStyle {
  static let artworkOpacity = 0.15
  static let artworkBlur: CGFloat = 72
  static let artworkScale: CGFloat = 1.20
  static let artworkSaturation = 0.78
  static let accentOpacity = 0.34
  static let glowOpacity = 0.26
}

@MainActor
enum CodaPlaceholderArtwork {
  static let image: NSImage = {
    if let url = Bundle.main.url(
      forResource: "CodaPlaceholderCover",
      withExtension: "png"
    ), let image = NSImage(contentsOf: url) {
      return image
    }

    // SwiftPM's raw executable does not carry app-bundle resources. Keep a
    // deterministic Coda-styled fallback for tests and development tools.
    let size = NSSize(width: 1_024, height: 1_024)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(calibratedRed: 0.025, green: 0.030, blue: 0.034, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

    let recordRect = NSRect(x: 82, y: 82, width: 860, height: 860)
    NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
    NSBezierPath(ovalIn: recordRect).fill()
    NSColor(calibratedRed: 0.72, green: 0.47, blue: 0.20, alpha: 0.92).setStroke()
    let arc = NSBezierPath()
    arc.appendArc(
      withCenter: NSPoint(x: 512, y: 512),
      radius: 280,
      startAngle: 42,
      endAngle: 318,
      clockwise: false
    )
    arc.lineWidth = 34
    arc.lineCapStyle = .round
    arc.stroke()
    image.unlockFocus()
    return image
  }()
}

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

@MainActor
final class AlbumArtworkLoader: ObservableObject {
  @Published private(set) var image: NSImage?
  @Published private(set) var accent: ArtworkColor = .fallback

  private struct Request: Equatable {
    let url: URL?
    let placeholderIdentity: String?
    let cacheGeneration: Int
  }

  private var loadedRequest: Request?

  func load(url: URL?, placeholderIdentity: String? = nil) async {
    let request = Request(
      url: url,
      placeholderIdentity: placeholderIdentity,
      cacheGeneration: ArtworkImageCache.shared.generation
    )
    guard loadedRequest != request else { return }
    loadedRequest = request
    image = nil
    accent = .fallback

    let artwork = await ArtworkImageCache.shared.image(for: url)
    guard loadedRequest == request else { return }
    image = artwork
    accent = Self.extractAccent(from: artwork)
  }

  static func extractAccent(from image: NSImage) -> ArtworkColor {
    let size = NSSize(width: 32, height: 32)
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width),
      pixelsHigh: Int(size.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return .fallback }

    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    struct Bucket {
      var score = 0.0
      var red = 0.0
      var green = 0.0
      var blue = 0.0
      var weight = 0.0
    }
    var buckets = Array(repeating: Bucket(), count: 18)

    for y in 0..<Int(size.height) {
      for x in 0..<Int(size.width) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let r = Double(color.redComponent)
        let g = Double(color.greenComponent)
        let b = Double(color.blueComponent)
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let brightness = maximum
        let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum
        guard brightness > 0.12, brightness < 0.94, saturation > 0.16 else { continue }

        let hue = Double(color.hueComponent)
        let bucketIndex = min(Int(hue * Double(buckets.count)), buckets.count - 1)
        let middleBrightness = 1 - abs(brightness - 0.58)
        let weight = saturation * saturation * (0.45 + middleBrightness)
        buckets[bucketIndex].score += weight
        buckets[bucketIndex].red += r * weight
        buckets[bucketIndex].green += g * weight
        buckets[bucketIndex].blue += b * weight
        buckets[bucketIndex].weight += weight
      }
    }

    guard let winner = buckets.max(by: { $0.score < $1.score }), winner.weight > 0 else {
      // A successfully loaded image without a useful saturated color is most
      // likely monochrome. Keep its treatment neutral instead of introducing
      // the generic cyan used while artwork is unavailable.
      return .monochromeFallback
    }
    let r = winner.red / winner.weight
    let g = winner.green / winner.weight
    let b = winner.blue / winner.weight
    let lift = max(0, 0.50 - max(r, g, b))
    return ArtworkColor(red: min(r + lift, 1), green: min(g + lift, 1), blue: min(b + lift, 1))
  }
}

struct AlbumMockupHero: View {
  @EnvironmentObject private var settings: ArtworkTreatmentSettings
  @State private var hoveredRating: Int?

  let availableWidth: CGFloat
  let image: NSImage?
  let fallbackURL: URL?
  let title: String
  let artist: String
  let metadata: String
  let rating: Int?
  let ratingIsUpdating: Bool
  let ratingHighlightTrigger: Int
  let ratingAction: (Int) -> Void
  let artistAction: (() -> Void)?
  let playAction: () -> Void
  let queueAction: () -> Void
  let queueDragItem: LibraryQueueDragItem

  var body: some View {
    fluidHero
      .frame(height: metrics.height)
    .frame(maxWidth: .infinity)
  }

  private var fluidHero: some View {
    HStack(alignment: .center, spacing: metrics.spacing) {
      heroArtwork(size: metrics.artworkSize)
      albumInfo
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, 22)
    .padding(.trailing, metrics.trailingPadding)
    .padding(.bottom, 10)
  }

  private var metrics: CollectionHeroMetrics {
    CollectionHeroMetrics(width: availableWidth)
  }

  private var albumIdentity: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 32, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.60)
        .allowsTightening(true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)

      if let artistAction {
        Button(artist, action: artistAction)
          .buttonStyle(.plain)
          .font(.title3)
          .foregroundStyle(settings.accent.color)
      } else {
        Text(artist)
          .font(.title3)
          .foregroundStyle(settings.accent.color)
      }

      Text(metadata)
        .foregroundStyle(.secondary)
    }
  }

  private var ratingStars: some View {
    let displayedRating = hoveredRating ?? max(0, min(rating ?? 0, 5))
    return HStack(spacing: 3) {
      ForEach(1...5, id: \.self) { star in
        Button {
          ratingAction(star)
        } label: {
          Image(systemName: star <= displayedRating ? "star.fill" : "star")
            .contentShape(Rectangle())
            .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .disabled(ratingIsUpdating)
        .onHover { isHovering in
          if isHovering {
            hoveredRating = star
          }
        }
        .help("Rate this album \(star) out of 5")
        .accessibilityLabel("Rate album \(star) out of 5")
      }
    }
    .font(.body)
    .foregroundStyle(settings.accent.color)
    .opacity(ratingIsUpdating ? 0.78 : 1)
    .animation(.easeInOut(duration: 0.18), value: ratingIsUpdating)
    .animation(.easeInOut(duration: 0.16), value: rating)
    .ratingPromptEffect(
      trigger: ratingHighlightTrigger,
      accent: settings.accent.color
    )
    .onHover { isHovering in
      if !isHovering {
        hoveredRating = nil
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var albumInfo: some View {
    VStack(alignment: .leading, spacing: 8) {
      albumIdentity

      ratingStars
        .padding(.top, 2)

      controls
        .padding(.top, 8)
    }
  }

  private var controls: some View {
    CollectionPlaybackControls(
      collectionKind: "album",
      playAction: playAction,
      queueAction: queueAction
    )
  }

  @ViewBuilder
  private func heroArtwork(size: CGFloat) -> some View {
    ZStack(alignment: .bottom) {
      Ellipse()
        .fill(Color.black.opacity(0.66))
        .frame(width: size * 0.78, height: 28)
        .blur(radius: 11)
        .offset(y: 12)

      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
          .scaleEffect(0.98)
          .shadow(
            color: .black.opacity(CollectionHeroArtworkStyle.shadowOpacity),
            radius: CollectionHeroArtworkStyle.shadowRadius,
            y: CollectionHeroArtworkStyle.shadowY
          )
      } else {
        ArtworkImage(url: fallbackURL, cornerRadius: 13)
          .frame(width: size, height: size)
          .shadow(
            color: .black.opacity(CollectionHeroArtworkStyle.shadowOpacity),
            radius: CollectionHeroArtworkStyle.shadowRadius,
            y: CollectionHeroArtworkStyle.shadowY
          )
      }
    }
    .frame(width: size + 30, height: size + 36)
    .draggable(QueueDropItem.library(queueDragItem))
    .dragConfiguration(.codaInternal())
    .help("Drag album to queue")
  }
}

struct CollectionPlaybackControls: View {
  @EnvironmentObject private var settings: ArtworkTreatmentSettings

  let collectionKind: String
  let playAction: () -> Void
  let queueAction: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: playAction) {
        PlayAlbumQueueIcon()
          .frame(width: 42, height: 42)
          .background(
            settings.accent.color,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
          )
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .help("Play \(collectionKind)")
      .accessibilityLabel("Play \(collectionKind)")

      Button(action: queueAction) {
        Image(systemName: "text.badge.plus")
          .frame(width: 42, height: 42)
          .glassControl()
      }
      .buttonStyle(.plain)
      .help("Add \(collectionKind) to queue")
      .accessibilityLabel("Add \(collectionKind) to queue")
    }
  }
}

private struct PlayAlbumQueueIcon: View {
  var body: some View {
    HStack(spacing: 2.5) {
      Image(systemName: "play.fill")
        .font(.system(size: 12, weight: .semibold))

      VStack(spacing: 2.5) {
        queueLine
        queueLine
        queueLine
      }
    }
    .frame(width: 23, height: 23)
    .accessibilityHidden(true)
  }

  private var queueLine: some View {
    Capsule(style: .continuous)
      .fill(.white)
      .frame(width: 7, height: 1.5)
  }
}

extension View {
  func glassControl() -> some View {
    background {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(.ultraThinMaterial)
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Color.white.opacity(0.035))
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.7)
    }
  }
}

struct AppArtworkBackground: View {
  @EnvironmentObject private var settings: ArtworkTreatmentSettings

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color(red: 0.035, green: 0.043, blue: 0.050)

        if let artwork = settings.artwork {
          Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(ArtworkBackgroundStyle.artworkScale)
            .blur(radius: ArtworkBackgroundStyle.artworkBlur)
            .saturation(ArtworkBackgroundStyle.artworkSaturation)
            .opacity(ArtworkBackgroundStyle.artworkOpacity)
            .clipped()
            .id(settings.artworkRevision)
            .transition(.opacity)
        }

        RadialGradient(
          colors: [settings.accent.color.opacity(ArtworkBackgroundStyle.accentOpacity), .clear],
          center: UnitPoint(x: 0.34, y: 0.38),
          startRadius: 24,
          endRadius: max(geometry.size.width, geometry.size.height) * 0.72
        )

        RadialGradient(
          colors: [
            settings.accent.color.opacity(ArtworkBackgroundStyle.glowOpacity),
            settings.accent.color.opacity(0.08),
            .clear,
          ],
          center: UnitPoint(x: 0.34, y: 0.27),
          startRadius: 8,
          endRadius: max(geometry.size.width, geometry.size.height) * 0.48
        )
        RadialGradient(
          colors: [.clear, Color.black.opacity(0.48)],
          center: UnitPoint(x: 0.50, y: 0.43),
          startRadius: min(geometry.size.width, geometry.size.height) * 0.24,
          endRadius: max(geometry.size.width, geometry.size.height) * 0.78
        )

        LinearGradient(
          colors: [
            Color.black.opacity(0.18),
            Color(red: 0.025, green: 0.032, blue: 0.038).opacity(0.48),
            Color.black.opacity(0.72),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
      .clipped()
      .animation(.easeInOut(duration: 0.85), value: settings.artworkRevision)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }
}

struct NowPlayingArtworkBackground: View {
  let theme: NowPlayingPreparedTheme?

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color(red: 0.035, green: 0.043, blue: 0.050)

        if let artwork = theme?.artwork {
          Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(ArtworkBackgroundStyle.artworkScale)
            .blur(radius: ArtworkBackgroundStyle.artworkBlur)
            .saturation(ArtworkBackgroundStyle.artworkSaturation)
            .opacity(ArtworkBackgroundStyle.artworkOpacity)
            .clipped()
            .id(ObjectIdentifier(artwork))
            .transition(.opacity)
        }

        let accent = theme?.accent.color ?? ArtworkColor.fallback.color
        RadialGradient(
          colors: [accent.opacity(ArtworkBackgroundStyle.accentOpacity), .clear],
          center: UnitPoint(x: 0.34, y: 0.38),
          startRadius: 24,
          endRadius: max(geometry.size.width, geometry.size.height) * 0.72
        )

        RadialGradient(
          colors: [
            accent.opacity(ArtworkBackgroundStyle.glowOpacity),
            accent.opacity(0.08),
            .clear,
          ],
          center: UnitPoint(x: 0.34, y: 0.27),
          startRadius: 8,
          endRadius: max(geometry.size.width, geometry.size.height) * 0.48
        )
        RadialGradient(
          colors: [.clear, Color.black.opacity(0.48)],
          center: UnitPoint(x: 0.50, y: 0.43),
          startRadius: min(geometry.size.width, geometry.size.height) * 0.24,
          endRadius: max(geometry.size.width, geometry.size.height) * 0.78
        )

        LinearGradient(
          colors: [
            Color.black.opacity(0.18),
            Color(red: 0.025, green: 0.032, blue: 0.038).opacity(0.48),
            Color.black.opacity(0.72),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      }
      .clipped()
      .animation(.easeInOut(duration: 0.85), value: artworkIdentity)
    }
    .allowsHitTesting(false)
  }

  private var artworkIdentity: ObjectIdentifier? {
    theme?.artwork.map(ObjectIdentifier.init)
  }
}

enum FloatingPanelStyle {
  static let transparency = 0.42
  static let darkness = 0.64
  static let border = 0.07
  static let shadow = 0.37
  static let cornerRadius = 11.95

  static let darkOverlayOpacity = darkness * (1 - transparency)
}

private enum RatingPromptPhase: CaseIterable {
  case resting
  case illuminated
  case settled

  var brightness: Double { self == .illuminated ? 0.10 : 0 }
  var scale: CGFloat { self == .illuminated ? 1.012 : 1 }
  var glowOpacity: Double { self == .illuminated ? 0.20 : 0 }
}

private struct RatingPromptEffectModifier: ViewModifier {
  let trigger: Int
  let accent: Color

  func body(content: Content) -> some View {
    content.phaseAnimator(RatingPromptPhase.allCases, trigger: trigger) { view, phase in
      view
        .brightness(phase.brightness)
        .scaleEffect(phase.scale)
        .shadow(color: accent.opacity(phase.glowOpacity), radius: 6)
    } animation: { phase in
      switch phase {
      case .resting: .linear(duration: 0)
      case .illuminated: .easeOut(duration: 0.14)
      case .settled: .easeInOut(duration: 0.30)
      }
    }
  }
}

struct FloatingPanelModifier: ViewModifier {
  @Environment(\.controlActiveState) private var controlActiveState
  @EnvironmentObject private var settings: ArtworkTreatmentSettings
  let material: Bool
  let materialAccent: Color?
  let capsule: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if capsule {
      styledPanel(content: content, shape: Capsule())
    } else {
      styledPanel(
        content: content,
        shape: RoundedRectangle(
          cornerRadius: FloatingPanelStyle.cornerRadius,
          style: .continuous
        )
      )
    }
  }

  private func styledPanel<S: InsettableShape>(content: Content, shape: S) -> some View {
    content
      .background {
        Group {
          if material {
            ZStack {
              shape.fill(.ultraThinMaterial)
              shape.fill(Color.black.opacity(0.68))
              shape.fill(
                (materialAccent ?? settings.accent.color).opacity(
                  controlActiveState == .inactive ? 0.012 : 0.040
                )
              )
            }
          } else {
            shape
              .fill(Color.black.opacity(FloatingPanelStyle.darkOverlayOpacity))
              .glassEffect(.regular, in: shape)
          }
        }
        .allowsHitTesting(false)
      }
      .clipShape(shape)
      .overlay {
        shape
          .strokeBorder(
            LinearGradient(
              colors: [
                Color.white.opacity(FloatingPanelStyle.border * 1.45),
                Color.white.opacity(FloatingPanelStyle.border * 0.34),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 0.8
          )
          .allowsHitTesting(false)
      }
      .shadow(
        color: .black.opacity(
          material ? 0.22 : FloatingPanelStyle.shadow
        ),
        radius: material ? 12 : 18,
        y: material ? 5 : 8
      )
      .animation(
        .easeInOut(duration: 0.20),
        value: material ? controlActiveState : .key
      )
  }
}

extension View {
  func ratingPromptEffect(
    trigger: Int,
    accent: Color
  ) -> some View {
    modifier(RatingPromptEffectModifier(trigger: trigger, accent: accent))
  }

  func floatingPanel(
    material: Bool = false,
    materialAccent: Color? = nil,
    capsule: Bool = false
  ) -> some View {
    modifier(
      FloatingPanelModifier(
        material: material,
        materialAccent: materialAccent,
        capsule: capsule
      )
    )
  }
}

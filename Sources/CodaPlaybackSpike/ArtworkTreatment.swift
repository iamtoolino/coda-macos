import AppKit
import Combine
import ImageIO
import SwiftUI

struct ArtworkColor: Equatable {
  let red: Double
  let green: Double
  let blue: Double

  static let fallback = ArtworkColor(red: 0.20, green: 0.72, blue: 0.76)
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

  var hasPlaybackArtwork: Bool { playbackArtwork != nil }

  init() {
    let defaults = UserDefaults.standard
    showsAlbumRatingLabels = defaults.object(forKey: Self.showsRatingLabelsKey) as? Bool
      ?? true
  }

  func displayArtwork(_ image: NSImage, accent: ArtworkColor, identity: String? = nil) {
    if let artwork,
      artwork === image,
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
    identity: String? = nil,
    displaysImmediately: Bool
  ) {
    playbackArtwork = image
    playbackAccent = accent
    playbackArtworkIdentity = identity
    if displaysImmediately {
      displayArtwork(image, accent: accent, identity: identity)
    }
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

  func restorePlaybackArtwork() {
    guard let playbackArtwork, let playbackAccent else { return }
    displayArtwork(
      playbackArtwork,
      accent: playbackAccent,
      identity: playbackArtworkIdentity
    )
  }
}

enum AlbumHeroStyle {
  static let coverSize: CGFloat = 236
  static let titleSize: CGFloat = 40
}

enum AlbumRatingBadgeStyle {
  static let size: CGFloat = 24
  static let opacity = 1.0
  static let fontSize: CGFloat = 14
  static let fontWeight = Font.Weight.regular
  static let cornerInset: CGFloat = 4
}

private enum ArtworkBackgroundStyle {
  static let artworkOpacity = 0.15
  static let artworkBlur: CGFloat = 72
  static let artworkScale: CGFloat = 1.20
  static let artworkSaturation = 0.78
  static let accentOpacity = 0.34
  static let glowOpacity = 0.26
}

private actor ArtworkDiskCache {
  static let shared = ArtworkDiskCache()

  private static let maximumBytes: Int64 = 3 * 1_024 * 1_024 * 1_024
  private static let trimTargetBytes: Int64 = 2_700 * 1_024 * 1_024
  private static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

  private let directoryURL: URL?
  private var isPrepared = false
  private var writesUntilTrim = 1

  private init() {
    let cacheRoot = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first
    let currentDirectory = cacheRoot?
      .appendingPathComponent("io.github.iamtoolino.coda.macos", isDirectory: true)
      .appendingPathComponent("Artwork", isDirectory: true)
    let legacyDirectory = cacheRoot?
      .appendingPathComponent("com.toolino.coda.macos", isDirectory: true)
      .appendingPathComponent("Artwork", isDirectory: true)

    if let currentDirectory, let legacyDirectory,
      !FileManager.default.fileExists(atPath: currentDirectory.path),
      FileManager.default.fileExists(atPath: legacyDirectory.path)
    {
      try? FileManager.default.createDirectory(
        at: currentDirectory.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? FileManager.default.moveItem(at: legacyDirectory, to: currentDirectory)
    }
    directoryURL = currentDirectory
  }

  func data(for url: URL) -> Data? {
    guard prepare(), let fileURL = fileURL(for: url) else { return nil }

    do {
      let values = try fileURL.resourceValues(forKeys: [
        .creationDateKey,
        .contentModificationDateKey,
      ])
      let created = values.creationDate ?? values.contentModificationDate ?? .distantPast
      guard Date().timeIntervalSince(created) <= Self.maximumAge else {
        try? FileManager.default.removeItem(at: fileURL)
        return nil
      }

      let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      guard Self.isArtworkData(data) else {
        try? FileManager.default.removeItem(at: fileURL)
        return nil
      }
      try? FileManager.default.setAttributes(
        [.modificationDate: Date()],
        ofItemAtPath: fileURL.path
      )
      return data
    } catch {
      return nil
    }
  }

  func store(_ data: Data, for url: URL) {
    guard Self.isArtworkData(data), prepare(), let fileURL = fileURL(for: url) else { return }
    do {
      try data.write(to: fileURL, options: .atomic)
      writesUntilTrim -= 1
      if writesUntilTrim <= 0 {
        trimToBudget()
        writesUntilTrim = 25
      }
    } catch {
      // Artwork remains available from the RAM cache for this session.
    }
  }

  private func prepare() -> Bool {
    guard let directoryURL else { return false }
    if isPrepared { return true }
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      isPrepared = true
      return true
    } catch {
      return false
    }
  }

  private func fileURL(for url: URL) -> URL? {
    directoryURL?.appendingPathComponent(
      NavidromeConfiguration.md5(url.absoluteString),
      isDirectory: false
    )
  }

  private func trimToBudget() {
    guard let directoryURL else { return }
    let keys: Set<URLResourceKey> = [
      .fileAllocatedSizeKey,
      .fileSizeKey,
      .contentModificationDateKey,
    ]
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else { return }

    let entries = files.compactMap { fileURL -> DiskEntry? in
      guard let values = try? fileURL.resourceValues(forKeys: keys) else { return nil }
      let size = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
      return DiskEntry(
        url: fileURL,
        size: size,
        lastAccess: values.contentModificationDate ?? .distantPast
      )
    }
    var totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
    guard totalBytes > Self.maximumBytes else { return }

    for entry in entries.sorted(by: { $0.lastAccess < $1.lastAccess }) {
      guard totalBytes > Self.trimTargetBytes else { break }
      do {
        try FileManager.default.removeItem(at: entry.url)
        totalBytes -= entry.size
      } catch {
        continue
      }
    }
  }

  private static func isArtworkData(_ data: Data) -> Bool {
    CGImageSourceCreateWithData(data as CFData, nil) != nil
  }

  private struct DiskEntry {
    let url: URL
    let size: Int64
    let lastAccess: Date
  }
}

@MainActor
final class ArtworkImageCache {
  static let shared = ArtworkImageCache()

  private let images = NSCache<NSURL, NSImage>()
  private var loadingTasks: [URL: Task<Data?, Never>] = [:]
  private let diskCache = ArtworkDiskCache.shared

  private init() {
    images.countLimit = 300
    images.totalCostLimit = 256 * 1_024 * 1_024
  }

  func image(for url: URL) async -> NSImage? {
    if let image = images.object(forKey: url as NSURL) {
      return image
    }

    let task: Task<Data?, Never>
    if let existingTask = loadingTasks[url] {
      task = existingTask
    } else {
      let diskCache = diskCache
      task = Task {
        if let data = await diskCache.data(for: url) {
          return data
        }
        do {
          let (data, response) = try await URLSession.shared.data(from: url)
          if let response = response as? HTTPURLResponse {
            guard (200..<300).contains(response.statusCode) else { return nil }
          }
          await diskCache.store(data, for: url)
          return data
        } catch {
          return nil
        }
      }
      loadingTasks[url] = task
    }

    let data = await task.value
    loadingTasks[url] = nil
    guard let data, let image = NSImage(data: data) else { return nil }
    images.setObject(
      image,
      forKey: url as NSURL,
      cost: Self.decodedMemoryCost(of: image, fallback: data.count)
    )
    return image
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

  private var loadedURL: URL?

  func load(url: URL?) async {
    guard loadedURL != url else { return }
    loadedURL = url
    image = nil
    accent = .fallback
    guard let url else { return }

    if let artwork = await ArtworkImageCache.shared.image(for: url) {
      guard loadedURL == url else { return }
      image = artwork
      accent = Self.extractAccent(from: artwork)
    }
  }

  private static func extractAccent(from image: NSImage) -> ArtworkColor {
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

private struct AlbumHeroWidthPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 1_000

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

struct AlbumMockupHero: View {
  @EnvironmentObject private var settings: ArtworkTreatmentSettings
  @State private var availableWidth: CGFloat = 1_000
  @State private var hoveredRating: Int?

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
    Group {
      if availableWidth < 760 {
        compactHero
          .frame(height: compactHeroHeight)
      } else {
        wideHero
          .frame(height: wideHeroHeight)
      }
    }
    .frame(maxWidth: .infinity)
    .background {
      GeometryReader { geometry in
        Color.clear.preference(
          key: AlbumHeroWidthPreferenceKey.self,
          value: geometry.size.width
        )
      }
    }
    .onPreferenceChange(AlbumHeroWidthPreferenceKey.self) { width in
      guard width > 0, abs(width - availableWidth) > 0.5 else { return }
      availableWidth = width
    }
  }

  private var wideHero: some View {
    HStack(alignment: .center, spacing: 34) {
      heroArtwork(size: AlbumHeroStyle.coverSize)
      albumInfo(titleSize: AlbumHeroStyle.titleSize)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 42)
    .padding(.bottom, 28)
  }

  private func albumIdentity(titleSize: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Text(title)
        .font(.system(size: titleSize, weight: .bold, design: .default))
        .tracking(titleTracking)
        .lineLimit(2)
        .minimumScaleFactor(0.82)
        .allowsTightening(true)
        .fixedSize(horizontal: false, vertical: true)
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
    .opacity(ratingIsUpdating ? 0.62 : 1)
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

  private var titleTracking: CGFloat {
    let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
    guard !letters.isEmpty else { return -0.7 }
    let uppercaseCount = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
    return Double(uppercaseCount) / Double(letters.count) >= 0.85 ? 0.15 : -0.7
  }

  private var compactHero: some View {
    VStack(alignment: .leading, spacing: 22) {
      heroArtwork(size: AlbumHeroStyle.coverSize)
        .frame(maxWidth: .infinity, alignment: .center)
      albumInfo(titleSize: min(AlbumHeroStyle.titleSize, 36))
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 26)
  }

  private var wideHeroHeight: CGFloat {
    max(306, AlbumHeroStyle.coverSize + 70)
  }

  private var compactHeroHeight: CGFloat {
    AlbumHeroStyle.coverSize + 350
  }

  private func albumInfo(titleSize: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      albumIdentity(titleSize: titleSize)

      ratingStars
        .padding(.top, 4)

      controls
        .padding(.top, 14)
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
          .shadow(color: .black.opacity(0.58), radius: 16, y: 9)
      } else {
        ArtworkImage(url: fallbackURL, cornerRadius: 13)
          .frame(width: size, height: size)
          .shadow(color: .black.opacity(0.58), radius: 16, y: 9)
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

  var brightness: Double { self == .illuminated ? 0.18 : 0 }
  var scale: CGFloat { self == .illuminated ? 1.025 : 1 }
  var glowOpacity: Double { self == .illuminated ? 0.34 : 0 }
}

private struct RatingPromptEffectModifier: ViewModifier {
  let trigger: Int
  let accent: Color

  func body(content: Content) -> some View {
    content.phaseAnimator(RatingPromptPhase.allCases, trigger: trigger) { view, phase in
      view
        .brightness(phase.brightness)
        .scaleEffect(phase.scale)
        .shadow(color: accent.opacity(phase.glowOpacity), radius: 8)
    } animation: { phase in
      switch phase {
      case .resting: .linear(duration: 0)
      case .illuminated: .easeOut(duration: 0.22)
      case .settled: .easeInOut(duration: 0.56)
      }
    }
  }
}

struct FloatingPanelModifier: ViewModifier {
  @Environment(\.controlActiveState) private var controlActiveState
  @EnvironmentObject private var settings: ArtworkTreatmentSettings
  let adaptsWhenInactive: Bool
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
          if adaptsWhenInactive && controlActiveState == .inactive {
            ZStack {
              shape.fill(Color.black.opacity(0.68))
              shape.fill(settings.accent.color.opacity(0.055))
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
          adaptsWhenInactive && controlActiveState == .inactive
            ? 0.22 : FloatingPanelStyle.shadow
        ),
        radius: adaptsWhenInactive && controlActiveState == .inactive ? 12 : 18,
        y: adaptsWhenInactive && controlActiveState == .inactive ? 5 : 8
      )
      .animation(
        .easeInOut(duration: 0.20),
        value: adaptsWhenInactive ? controlActiveState : .key
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

  func floatingPanel(adaptsWhenInactive: Bool = false, capsule: Bool = false) -> some View {
    modifier(
      FloatingPanelModifier(
        adaptsWhenInactive: adaptsWhenInactive,
        capsule: capsule
      )
    )
  }
}

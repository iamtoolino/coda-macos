import AppKit
import Combine
import SwiftUI

struct ArtworkColor: Equatable {
  let red: Double
  let green: Double
  let blue: Double

  static let fallback = ArtworkColor(red: 43.0 / 255.0, green: 122.0 / 255.0, blue: 130.0 / 255.0)
  static let brandAction = ArtworkColor(red: 0.82, green: 0.58, blue: 0.20)
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
    let dimension = 32
    let size = NSSize(width: dimension, height: dimension)
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: dimension,
      pixelsHigh: dimension,
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

    var pixels: [ArtworkPixel] = []
    pixels.reserveCapacity(dimension * dimension)
    for y in 0..<dimension {
      for x in 0..<dimension {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        pixels.append(
          ArtworkPixel(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
          )
        )
      }
    }
    return ArtworkAccentSelector.select(from: pixels).color
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
  let theme: NowPlayingPreparedTheme

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color(red: 0.035, green: 0.043, blue: 0.050)

        if let artwork = theme.artwork {
          Image(nsImage: artwork)
            .resizable()
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(ArtworkBackgroundStyle.artworkScale)
            .blur(radius: ArtworkBackgroundStyle.artworkBlur)
            .saturation(ArtworkBackgroundStyle.artworkSaturation)
            .opacity(ArtworkBackgroundStyle.artworkOpacity)
            .clipped()
        }

        let accent = theme.accent.color
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
    }
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

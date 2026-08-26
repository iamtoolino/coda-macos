import AppKit
import SwiftUI

enum NowPlayingPresentationMotion {
  static let duration: TimeInterval = 0.34
  static let verticalOffset: CGFloat = 18
}

enum NowPlayingPresentationPhase: Equatable {
  case hidden
  case presenting
  case visible
  case dismissing

  var browsingIsInteractive: Bool { self == .hidden }
  var presentationIsInteractive: Bool { self == .visible }
  var isTransitioning: Bool { self == .presenting || self == .dismissing }
}

enum NowPlayingPresentationHoverRegion: Hashable {
  case background
  case cover
}

struct NowPlayingPreparedTheme: Identifiable {
  let id = UUID()
  let playbackKey: String
  let artwork: NSImage?
  let accent: ArtworkColor
}

enum NowPlayingAutomaticPresentationTiming {
  static let activeDelay = Duration.seconds(60)
  static let inactiveDelayCap = Duration.seconds(15)

  static func delayAfterBecomingInactive(remaining: Duration?) -> Duration {
    guard let remaining else { return inactiveDelayCap }
    return min(max(.zero, remaining), inactiveDelayCap)
  }
}

@MainActor
final class NowPlayingPresentationController: ObservableObject {
  private static let automaticallyPresentsKey = "automatically-show-now-playing"
  private static let experimentalAutomaticallyPresentsKey =
    "automatically-shows-now-playing"

  @Published private(set) var isPresented = false
  @Published private(set) var phase = NowPlayingPresentationPhase.hidden
  @Published private(set) var preparedTheme: NowPlayingPreparedTheme?
  @Published private(set) var isPointerInsidePresentation = false
  @Published var automaticallyPresents: Bool {
    didSet {
      defaults.set(automaticallyPresents, forKey: Self.automaticallyPresentsKey)
      if automaticallyPresents {
        scheduleAutomaticPresentation()
      } else {
        cancelAutomaticPresentation()
        presentationRetryTask?.cancel()
        presentationRetryTask = nil
        presentationRetryIsAutomatic = false
      }
    }
  }

  private let defaults: UserDefaults
  private weak var observedWindow: NSWindow?
  private var isApplicationActive: Bool?
  private var hasEstablishedConnection = false
  private var playbackKey: String?
  private var isPlaying = false
  private var inactivityTask: Task<Void, Never>?
  private var automaticPresentationDeadline: ContinuousClock.Instant?
  private var presentationRetryTask: Task<Void, Never>?
  private var presentationRetryIsAutomatic = false
  private var phaseTask: Task<Void, Never>?
  private var hoveredRegions: Set<NowPlayingPresentationHoverRegion> = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    automaticallyPresents =
      defaults.object(forKey: Self.automaticallyPresentsKey) as? Bool
      ?? defaults.object(forKey: Self.experimentalAutomaticallyPresentsKey) as? Bool
      ?? true
    defaults.set(automaticallyPresents, forKey: Self.automaticallyPresentsKey)
    defaults.removeObject(forKey: Self.experimentalAutomaticallyPresentsKey)
  }

  private var presentationAccent: ArtworkColor? {
    isPresented ? preparedTheme?.accent : nil
  }

  func resolvedAccent(_ browsingAccent: ArtworkColor) -> ArtworkColor {
    presentationAccent ?? browsingAccent
  }

  func prepare(
    playbackKey: String,
    artwork: NSImage?,
    accent: ArtworkColor
  ) {
    preparedTheme = NowPlayingPreparedTheme(
      playbackKey: playbackKey,
      artwork: artwork,
      accent: accent
    )
  }

  func updateContext(
    window: NSWindow?,
    isApplicationActive: Bool,
    hasEstablishedConnection: Bool,
    playbackKey: String?,
    isPlaying: Bool
  ) {
    let playbackContextChanged =
      observedWindow !== window
      || self.hasEstablishedConnection != hasEstablishedConnection
      || self.playbackKey != playbackKey
      || self.isPlaying != isPlaying
    let applicationActivityChanged = self.isApplicationActive != isApplicationActive

    observedWindow = window
    self.isApplicationActive = isApplicationActive
    self.hasEstablishedConnection = hasEstablishedConnection
    self.playbackKey = playbackKey
    self.isPlaying = isPlaying

    if playbackKey == nil, preparedTheme != nil {
      self.preparedTheme = nil
    }

    guard hasEstablishedConnection, playbackKey != nil else {
      dismiss(restartsTimer: false)
      return
    }

    guard isPlaying else {
      cancelAutomaticPresentation()
      return
    }

    guard !isPresented else { return }
    if applicationActivityChanged {
      if isApplicationActive {
        scheduleAutomaticPresentation(after: NowPlayingAutomaticPresentationTiming.activeDelay)
      } else {
        capAutomaticPresentationForInactiveApplication()
      }
    } else if playbackContextChanged {
      scheduleAutomaticPresentation()
    }
  }

  func noteMeaningfulInteraction() {
    guard !isPresented else { return }
    scheduleAutomaticPresentation()
  }

  func updatePointerInsidePresentation(
    _ region: NowPlayingPresentationHoverRegion,
    isInside: Bool
  ) {
    guard isPresented else {
      hoveredRegions.removeAll()
      isPointerInsidePresentation = false
      return
    }
    if isInside {
      hoveredRegions.insert(region)
    } else {
      hoveredRegions.remove(region)
    }
    isPointerInsidePresentation = !hoveredRegions.isEmpty
  }

  func present() {
    present(automatically: false)
  }

  private func present(automatically: Bool) {
    guard !isPresented,
      phase == .hidden,
      hasEstablishedConnection,
      let playbackKey
    else { return }
    if automatically {
      guard automaticallyPresents, isPlaying else { return }
    }
    guard preparedTheme?.playbackKey == playbackKey else {
      schedulePresentationRetry(automatically: automatically)
      return
    }

    cancelAutomaticPresentation()
    presentationRetryTask?.cancel()
    presentationRetryTask = nil
    presentationRetryIsAutomatic = false
    phaseTask?.cancel()
    observedWindow?.makeFirstResponder(nil)
    phase = .presenting
    withAnimation(.easeInOut(duration: NowPlayingPresentationMotion.duration)) {
      isPresented = true
    }
    settlePhase(forPresentedState: true)
  }

  func dismiss(restartsTimer: Bool = true) {
    cancelAutomaticPresentation()
    presentationRetryTask?.cancel()
    presentationRetryTask = nil
    presentationRetryIsAutomatic = false
    guard isPresented else {
      if restartsTimer { scheduleAutomaticPresentation() }
      return
    }

    phaseTask?.cancel()
    phase = .dismissing
    hoveredRegions.removeAll()
    isPointerInsidePresentation = false
    withAnimation(.easeInOut(duration: NowPlayingPresentationMotion.duration)) {
      isPresented = false
    }
    settlePhase(forPresentedState: false)
    if restartsTimer { scheduleAutomaticPresentation() }
  }

  private func settlePhase(forPresentedState presented: Bool) {
    phaseTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(
          for: .milliseconds(Int64(NowPlayingPresentationMotion.duration * 1_000))
        )
      } catch {
        return
      }
      guard let self, self.isPresented == presented else { return }
      self.phase = presented ? .visible : .hidden
    }
  }

  private func scheduleAutomaticPresentation(
    after delay: Duration? = nil
  ) {
    cancelAutomaticPresentation()
    guard automaticallyPresents,
      !isPresented,
      hasEstablishedConnection,
      playbackKey != nil,
      isPlaying
    else { return }

    let delay = delay ?? (
      isApplicationActive == false
        ? NowPlayingAutomaticPresentationTiming.inactiveDelayCap
        : NowPlayingAutomaticPresentationTiming.activeDelay
    )
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: delay)
    automaticPresentationDeadline = deadline

    inactivityTask = Task { @MainActor [weak self] in
      do {
        try await clock.sleep(until: deadline)
      } catch {
        return
      }
      guard let self,
        self.automaticPresentationDeadline == deadline,
        self.automaticallyPresents,
        !self.isPresented,
        self.phase == .hidden,
        self.hasEstablishedConnection,
        self.playbackKey != nil,
        self.isPlaying
      else { return }
      self.inactivityTask = nil
      self.automaticPresentationDeadline = nil
      self.present(automatically: true)
    }
  }

  private func capAutomaticPresentationForInactiveApplication() {
    let clock = ContinuousClock()
    let remaining = automaticPresentationDeadline.map { clock.now.duration(to: $0) }
    scheduleAutomaticPresentation(
      after: NowPlayingAutomaticPresentationTiming.delayAfterBecomingInactive(
        remaining: remaining
      )
    )
  }

  private func cancelAutomaticPresentation() {
    inactivityTask?.cancel()
    inactivityTask = nil
    automaticPresentationDeadline = nil
    if presentationRetryIsAutomatic {
      presentationRetryTask?.cancel()
      presentationRetryTask = nil
      presentationRetryIsAutomatic = false
    }
  }

  private func schedulePresentationRetry(automatically: Bool) {
    presentationRetryTask?.cancel()
    presentationRetryIsAutomatic = automatically
    presentationRetryTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return
      }
      guard let self else { return }
      self.presentationRetryTask = nil
      self.presentationRetryIsAutomatic = false
      self.present(automatically: automatically)
    }
  }
}

struct NowPlayingPreparationObserver: View {
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var presentation: NowPlayingPresentationController
  @ObservedObject private var artworkCache = ArtworkImageCache.shared

  private struct Request: Hashable {
    let playbackKey: String?
    let artworkURL: URL?
    let nextArtworkURL: URL?
    let cacheGeneration: Int
  }

  private var request: Request {
    Request(
      playbackKey: player.currentEntry?.nowPlayingPlaybackKey,
      artworkURL: player.currentEntry?.nowPlayingArtworkURL ?? player.currentEntry?.artworkURL,
      nextArtworkURL: player.nextEntry?.nowPlayingArtworkURL ?? player.nextEntry?.artworkURL,
      cacheGeneration: artworkCache.generation
    )
  }

  var body: some View {
    Color.clear
      .task(id: request) {
        let request = request
        guard let playbackKey = request.playbackKey else { return }
        let artwork = await artworkCache.image(for: request.artworkURL)
        guard self.request == request else { return }
        presentation.prepare(
          playbackKey: playbackKey,
          artwork: artwork,
          accent: AlbumArtworkLoader.extractAccent(from: artwork)
        )
        if let nextArtworkURL = request.nextArtworkURL,
          nextArtworkURL != request.artworkURL
        {
          _ = await artworkCache.image(for: nextArtworkURL)
        }
      }
  }
}

struct NowPlayingActivityObserver: NSViewRepresentable {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var presentation: NowPlayingPresentationController

  func makeNSView(context: Context) -> NowPlayingActivityView {
    let view = NowPlayingActivityView()
    update(view)
    return view
  }

  func updateNSView(_ nsView: NowPlayingActivityView, context: Context) {
    update(nsView)
  }

  static func dismantleNSView(_ nsView: NowPlayingActivityView, coordinator: ()) {
    nsView.stopObserving()
  }

  private func update(_ view: NowPlayingActivityView) {
    view.presentation = presentation
    view.hasEstablishedConnection = session.hasEstablishedConnection
    view.playbackKey = player.currentEntry?.nowPlayingPlaybackKey
    view.isPlaying = player.isPlaying
    view.reportContext()
  }
}

@MainActor
final class NowPlayingActivityView: NSView {
  weak var presentation: NowPlayingPresentationController?
  var hasEstablishedConnection = false
  var playbackKey: String?
  var isPlaying = false

  private weak var observedWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []
  private var eventMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard observedWindow !== window else {
      reportContext()
      return
    }
    stopObserving()
    observedWindow = window
    startObserving()
    reportContext()
  }

  func reportContext() {
    presentation?.updateContext(
      window: observedWindow,
      isApplicationActive: NSApp.isActive,
      hasEstablishedConnection: hasEstablishedConnection,
      playbackKey: playbackKey,
      isPlaying: isPlaying
    )
  }

  func stopObserving() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    notificationTokens.removeAll()
    observedWindow = nil
  }

  private func startObserving() {
    guard let window = observedWindow else { return }
    let center = NotificationCenter.default
    let windowNames: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
    ]
    notificationTokens = windowNames.map { name in
      center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reportContext() }
      }
    }
    notificationTokens += [
      NSApplication.didBecomeActiveNotification,
      NSApplication.didResignActiveNotification,
    ].map { name in
      center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reportContext() }
      }
    }

    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .keyDown, .swipe, .magnify, .rotate,
      ]
    ) { [weak self, weak window] event in
      guard let self,
        event.window === window || (event.window == nil && window?.isKeyWindow == true)
      else { return event }
      self.presentation?.noteMeaningfulInteraction()
      return event
    }
  }
}

struct NowPlayingPresentationView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var presentation: NowPlayingPresentationController
  @State private var album: RemoteAlbum?

  private struct AlbumMetadataRequest: Hashable {
    let albumID: String?
    let hasConnection: Bool
  }

  var body: some View {
    GeometryReader { geometry in
      if let entry = player.currentEntry {
        let layout = layoutMetrics(for: geometry.size)
        VStack(spacing: 0) {
          Spacer(minLength: 0)

          VStack(spacing: 0) {
            preparedArtwork(for: entry)
              .frame(width: layout.coverSize, height: layout.coverSize)
              .shadow(color: .black.opacity(0.34), radius: 24, y: 14)
              .contentShape(Rectangle())
              .onHover { isInside in
                withAnimation(.easeInOut(duration: 0.16)) {
                  presentation.updatePointerInsidePresentation(
                    .cover,
                    isInside: isInside
                  )
                }
              }
              .onTapGesture { presentation.dismiss() }

            VStack(spacing: 8) {
              Text(entry.title)
                .font(.system(size: 32, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.60)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .contentShape(Rectangle())
                .onTapGesture { presentation.dismiss() }

              if !entry.artist.isEmpty {
                if let artistID = album?.artistId {
                  Text(entry.artist)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(presentationAccent)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                      showArtist(artistID)
                    }
                    .accessibilityAddTraits(.isLink)
                    .accessibilityAction {
                      showArtist(artistID)
                    }
                    .help("Show \(entry.artist)")
                } else {
                  Text(entry.artist)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(presentationAccent)
                    .lineLimit(1)
                }
              }

              if !entry.album.isEmpty {
                Group {
                  if let albumID = entry.albumID {
                    Text(entry.album)
                      .foregroundStyle(.primary)
                      .fontWeight(.semibold)
                      .contentShape(Rectangle())
                      .onTapGesture {
                        showAlbum(albumID)
                      }
                      .accessibilityAddTraits(.isLink)
                      .accessibilityAction {
                        showAlbum(albumID)
                      }
                      .help("Show \(entry.album)")
                  } else {
                    Text(entry.album).fontWeight(.semibold)
                  }
                }
                .font(.callout)
                .lineLimit(1)
              }
            }
            .padding(.top, 22)

            if let albumID = entry.albumID {
              NowPlayingAlbumRating(
                albumID: albumID,
                fallbackRating: album?.userRating,
                accent: presentationAccent
              )
              .padding(.top, 18)
            }
          }
          .frame(maxWidth: .infinity)
          .overlay(alignment: .top) {
            Button { presentation.dismiss() } label: {
              Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .help("Back to Browsing")
            .accessibilityLabel("Back to Browsing")
            .opacity(presentation.isPointerInsidePresentation ? 0.72 : 0)
            .scaleEffect(presentation.isPointerInsidePresentation ? 1 : 0.94)
            .offset(y: -18)
            .allowsHitTesting(presentation.isPointerInsidePresentation)
          }

          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, layout.topClearance)
        .padding(.bottom, layout.bottomClearance)
        .padding(.horizontal, 40)
        .task(
          id: AlbumMetadataRequest(
            albumID: entry.albumID,
            hasConnection: session.hasEstablishedConnection
          )
        ) {
          album = nil
          guard let albumID = entry.albumID, let client = session.client else { return }
          let loadedAlbum = try? await client.album(id: albumID).album
          guard player.currentEntry?.albumID == albumID else { return }
          album = loadedAlbum
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Now Playing")
  }

  @ViewBuilder
  private func preparedArtwork(for entry: QueueEntry) -> some View {
    ZStack {
      if let artwork = presentation.preparedTheme?.artwork {
        Image(nsImage: artwork)
          .resizable()
          .scaledToFill()
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .id(ObjectIdentifier(artwork))
          .transition(.opacity.combined(with: .scale(scale: 0.985)))
      } else {
        ArtworkImage(
          url: entry.nowPlayingArtworkURL ?? entry.artworkURL,
          cornerRadius: 16
        )
      }
    }
    .animation(.easeInOut(duration: 0.45), value: preparedArtworkIdentity)
  }

  private var preparedArtworkIdentity: ObjectIdentifier? {
    presentation.preparedTheme?.artwork.map(ObjectIdentifier.init)
  }

  private var presentationAccent: Color {
    presentation.preparedTheme?.accent.color ?? ArtworkColor.fallback.color
  }

  private func showArtist(_ artistID: String) {
    let route = LibraryRoute.artist(artistID)
    if session.path.last == route {
      presentation.dismiss()
    } else {
      session.open(route)
    }
  }

  private func showAlbum(_ albumID: String) {
    let route = LibraryRoute.album(albumID)
    if session.path.last == route {
      presentation.dismiss()
    } else {
      session.open(route)
    }
  }

  private struct LayoutMetrics {
    let coverSize: CGFloat
    let topClearance: CGFloat
    let bottomClearance: CGFloat
  }

  private func layoutMetrics(for size: CGSize) -> LayoutMetrics {
    let minimumCoverSize: CGFloat = 190
    let maximumCoverSize: CGFloat = 600
    let topClearance: CGFloat = 18
    let bottomClearance: CGFloat = 82
    let reservedVerticalSpace: CGFloat = 190
    let verticalGrowthFactor: CGFloat = 0.78
    let widthLimitedMaximum = min(maximumCoverSize, max(minimumCoverSize, size.width * 0.68))
    let heightLimitedSize = max(
      minimumCoverSize,
      (size.height - reservedVerticalSpace) * verticalGrowthFactor
    )
    return LayoutMetrics(
      coverSize: min(widthLimitedMaximum, heightLimitedSize),
      topClearance: topClearance,
      bottomClearance: bottomClearance
    )
  }
}

private struct NowPlayingAlbumRating: View {
  @EnvironmentObject private var session: AppSession
  let albumID: String
  let fallbackRating: Int?
  let accent: Color

  @State private var confirmedRating: Int?
  @State private var hoveredRating: Int?
  @State private var errorMessage: String?
  @State private var ratingHighlightTrigger = 0

  private var rating: Int? {
    session.rating(forAlbumID: albumID, fallback: confirmedRating ?? fallbackRating)
  }

  var body: some View {
    VStack(spacing: 7) {
      Text("Album rating")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        ForEach(1...5, id: \.self) { value in
          Button {
            ratingHighlightTrigger &+= 1
            Task { await updateRating(value) }
          } label: {
            Image(systemName: value <= displayedRating ? "star.fill" : "star")
              .font(.system(size: 22, weight: .medium))
              .foregroundStyle(accent)
              .contentShape(Rectangle())
              .contentTransition(.opacity)
          }
          .buttonStyle(.plain)
          .disabled(session.isUpdatingAlbumRating)
          .onHover { isHovering in
            if isHovering { hoveredRating = value }
          }
          .help("Rate this album \(value) out of 5")
          .accessibilityLabel("Rate album \(value) out of 5")
        }
      }
      .opacity(session.isUpdatingAlbumRating ? 0.78 : 1)
      .animation(.easeInOut(duration: 0.30), value: albumID)
      .animation(.easeInOut(duration: 0.18), value: session.isUpdatingAlbumRating)
      .animation(.easeInOut(duration: 0.16), value: rating)
      .ratingPromptEffect(
        trigger: ratingHighlightTrigger,
        accent: accent
      )
      .onHover { isHovering in
        if !isHovering { hoveredRating = nil }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .onChange(of: albumID) {
      confirmedRating = nil
      hoveredRating = nil
      errorMessage = nil
    }
  }

  private var displayedRating: Int {
    hoveredRating ?? max(0, min(rating ?? 0, 5))
  }

  @MainActor
  private func updateRating(_ newRating: Int) async {
    guard let request = session.sessionRequestContext() else { return }
    guard session.beginAlbumRatingUpdate() else { return }
    defer { session.finishAlbumRatingUpdate(for: request) }

    let requestedAlbumID = albumID
    let previousRating = rating
    errorMessage = nil
    session.rememberRating(newRating, forAlbumID: requestedAlbumID)
    do {
      try await request.client.setRating(id: requestedAlbumID, rating: newRating)
      guard session.isCurrent(request) else { return }
      if albumID == requestedAlbumID { confirmedRating = newRating }
    } catch {
      guard session.isCurrent(request) else { return }
      session.rememberRating(previousRating, forAlbumID: requestedAlbumID)
      if albumID == requestedAlbumID { errorMessage = "Could not update rating" }
    }
  }
}

extension QueueEntry {
  var artworkThemeIdentity: String {
    if let albumID, !albumID.isEmpty { return albumID }
    if let artworkURL { return artworkURL.absoluteString }
    return sourceID
  }

  var nowPlayingPlaybackKey: String {
    if let albumID, !albumID.isEmpty { return "album:\(albumID)" }
    if let artworkURL { return "artwork:\(artworkURL.absoluteString)" }
    return "track:\(sourceID)"
  }
}

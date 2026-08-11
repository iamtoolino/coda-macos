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

@MainActor
final class NowPlayingPresentationController: ObservableObject {
  private static let automaticPresentationDelay = Duration.seconds(30)

  @Published private(set) var isPresented = false
  @Published private(set) var phase = NowPlayingPresentationPhase.hidden
  @Published private(set) var preparedTheme: NowPlayingPreparedTheme?
  @Published private(set) var isPointerInsidePresentation = false

  private weak var observedWindow: NSWindow?
  private var hasEstablishedConnection = false
  private var playbackKey: String?
  private var isPlaying = false
  private var inactivityTask: Task<Void, Never>?
  private var phaseTask: Task<Void, Never>?
  private var hoveredRegions: Set<NowPlayingPresentationHoverRegion> = []

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
    hasEstablishedConnection: Bool,
    playbackKey: String?,
    isPlaying: Bool
  ) {
    let contextChanged =
      observedWindow !== window
      || self.hasEstablishedConnection != hasEstablishedConnection
      || self.playbackKey != playbackKey
      || self.isPlaying != isPlaying

    observedWindow = window
    self.hasEstablishedConnection = hasEstablishedConnection
    self.playbackKey = playbackKey
    self.isPlaying = isPlaying

    if let preparedTheme, preparedTheme.playbackKey != playbackKey {
      self.preparedTheme = nil
    }

    guard hasEstablishedConnection, playbackKey != nil else {
      dismiss(restartsTimer: false)
      return
    }

    guard isPlaying else {
      inactivityTask?.cancel()
      inactivityTask = nil
      return
    }

    if contextChanged, !isPresented {
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
    guard !isPresented,
      phase == .hidden,
      hasEstablishedConnection,
      let playbackKey,
      preparedTheme?.playbackKey == playbackKey
    else {
      if !isPresented {
        scheduleAutomaticPresentation(after: .milliseconds(250))
      }
      return
    }

    inactivityTask?.cancel()
    inactivityTask = nil
    phaseTask?.cancel()
    observedWindow?.makeFirstResponder(nil)
    phase = .presenting
    withAnimation(.easeInOut(duration: NowPlayingPresentationMotion.duration)) {
      isPresented = true
    }
    settlePhase(forPresentedState: true)
  }

  func dismiss(restartsTimer: Bool = true) {
    inactivityTask?.cancel()
    inactivityTask = nil
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
    after delay: Duration = automaticPresentationDelay
  ) {
    inactivityTask?.cancel()
    inactivityTask = nil
    guard !isPresented,
      hasEstablishedConnection,
      playbackKey != nil,
      isPlaying
    else { return }

    inactivityTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard let self,
        !self.isPresented,
        self.phase == .hidden,
        self.hasEstablishedConnection,
        self.playbackKey != nil,
        self.isPlaying
      else { return }
      self.present()
    }
  }
}

struct NowPlayingPreparationObserver: View {
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var presentation: NowPlayingPresentationController

  private struct Request: Hashable {
    let playbackKey: String?
    let artworkURL: URL?
  }

  private var request: Request {
    Request(
      playbackKey: player.currentEntry?.nowPlayingPlaybackKey,
      artworkURL: player.currentEntry?.artworkURL
    )
  }

  var body: some View {
    Color.clear
      .task(id: request) {
        let request = request
        guard let playbackKey = request.playbackKey else { return }
        let artwork = await ArtworkImageCache.shared.image(for: request.artworkURL)
        guard self.request == request else { return }
        presentation.prepare(
          playbackKey: playbackKey,
          artwork: artwork,
          accent: AlbumArtworkLoader.extractAccent(from: artwork)
        )
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
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
    ]
    notificationTokens = names.map { name in
      center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
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
      guard let self, event.window === window else { return event }
      if event.type == .keyDown,
        event.keyCode == 53,
        self.presentation?.isPresented == true
      {
        if NSApp.sendAction(
          #selector(NSResponder.cancelOperation(_:)),
          to: nil,
          from: self
        ) {
          return nil
        }
        self.presentation?.dismiss()
        return nil
      }
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
                .lineLimit(2)
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
                HStack(spacing: 5) {
                  Text("From the album")
                    .foregroundStyle(.secondary)
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 22)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1) }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusEffectDisabled()
            .help("Back to Browsing")
            .accessibilityLabel("Back to Browsing")
            .opacity(presentation.isPointerInsidePresentation ? 0.72 : 0)
            .scaleEffect(presentation.isPointerInsidePresentation ? 1 : 0.94)
            .offset(y: -26)
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
        ArtworkImage(url: entry.artworkURL, cornerRadius: 16)
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
    let maximumCoverSize: CGFloat = 550
    let topClearance: CGFloat = 18
    let bottomClearance: CGFloat = 82
    let reservedVerticalSpace: CGFloat = 210
    let verticalGrowthFactor: CGFloat = 0.68
    let widthLimitedMaximum = min(maximumCoverSize, max(minimumCoverSize, size.width * 0.60))
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
  @State private var isUpdating = false
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
          .disabled(isUpdating)
          .onHover { isHovering in
            if isHovering { hoveredRating = value }
          }
          .help("Rate this album \(value) out of 5")
          .accessibilityLabel("Rate album \(value) out of 5")
        }
      }
      .opacity(isUpdating ? 0.78 : 1)
      .animation(.easeInOut(duration: 0.30), value: albumID)
      .animation(.easeInOut(duration: 0.18), value: isUpdating)
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
      isUpdating = false
      errorMessage = nil
    }
  }

  private var displayedRating: Int {
    hoveredRating ?? max(0, min(rating ?? 0, 5))
  }

  @MainActor
  private func updateRating(_ newRating: Int) async {
    guard !isUpdating, let client = session.client else { return }
    let requestedAlbumID = albumID
    let previousRating = rating
    isUpdating = true
    errorMessage = nil
    session.rememberRating(newRating, forAlbumID: requestedAlbumID)
    do {
      try await client.setRating(id: requestedAlbumID, rating: newRating)
      if albumID == requestedAlbumID { confirmedRating = newRating }
    } catch {
      session.rememberRating(previousRating, forAlbumID: requestedAlbumID)
      if albumID == requestedAlbumID { errorMessage = "Could not update rating" }
    }
    if albumID == requestedAlbumID { isUpdating = false }
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

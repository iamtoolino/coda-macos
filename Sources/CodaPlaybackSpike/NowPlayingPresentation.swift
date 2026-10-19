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

struct NowPlayingPreparedTheme: Identifiable {
  let id = UUID()
  let playbackKey: String
  let artwork: NSImage?
  let accent: ArtworkColor

  var artworkBackgroundTheme: ArtworkBackgroundTheme {
    ArtworkBackgroundTheme(id: id, artwork: artwork, accent: accent)
  }
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
  static let userDismissalCountKey = "coda-now-playing-user-dismissals"
  /// The dismiss hint teaches the way out until the user has left Now Playing this often.
  static let dismissHintUserDismissalLimit = 3

  static func dismissHintIsDue(userDismissals: Int) -> Bool {
    userDismissals < dismissHintUserDismissalLimit
  }

  @Published private(set) var handoffRevealRequest: UUID?
  @Published private(set) var isPresented = false
  @Published private(set) var phase = NowPlayingPresentationPhase.hidden
  @Published private(set) var preparedTheme: NowPlayingPreparedTheme?
  @Published private(set) var showsDismissHint = false
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
  private var dismissHintTask: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    automaticallyPresents = defaults.object(forKey: Self.automaticallyPresentsKey) as? Bool ?? true
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

  func clearPreparedTheme() {
    guard preparedTheme != nil else { return }
    preparedTheme = nil
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
    if isPlaying { cancelHandoffReveal() }

    if playbackKey == nil, preparedTheme != nil {
      self.preparedTheme = nil
    }

    guard hasEstablishedConnection, playbackKey != nil else {
      dismiss(restartsTimer: false, isUserDismissal: false)
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
    scheduleDismissHint()
  }

  private func scheduleDismissHint() {
    dismissHintTask?.cancel()
    guard Self.dismissHintIsDue(
      userDismissals: defaults.integer(forKey: Self.userDismissalCountKey)
    ) else { return }
    dismissHintTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(
          for: .milliseconds(Int64(NowPlayingPresentationMotion.duration * 1_000) + 400)
        )
        guard let self, self.phase == .visible else { return }
        withAnimation(.easeOut(duration: 0.35)) { self.showsDismissHint = true }
        try await Task.sleep(for: .seconds(4))
        withAnimation(.easeIn(duration: 0.5)) { self.showsDismissHint = false }
      } catch {}
    }
  }

  private func hideDismissHint() {
    dismissHintTask?.cancel()
    dismissHintTask = nil
    showsDismissHint = false
  }

  @discardableResult
  func beginHandoffReveal() -> Bool {
    guard isPresented, !isPlaying else { return false }
    handoffRevealRequest = UUID()
    return true
  }

  func completeHandoffReveal(_ request: UUID) {
    guard handoffRevealRequest == request else { return }
    dismiss(isUserDismissal: false)
  }

  func cancelHandoffReveal() {
    guard handoffRevealRequest != nil else { return }
    handoffRevealRequest = nil
  }

  func dismiss(restartsTimer: Bool = true, isUserDismissal: Bool = true) {
    cancelHandoffReveal()
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
    hideDismissHint()
    if isUserDismissal {
      defaults.set(
        defaults.integer(forKey: Self.userDismissalCountKey) + 1,
        forKey: Self.userDismissalCountKey
      )
    }
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
    guard automaticallyPresents,
      !isPresented,
      hasEstablishedConnection,
      playbackKey != nil,
      isPlaying
    else {
      cancelAutomaticPresentation()
      return
    }
    cancelAutomaticPresentationRetry()

    let delay = delay ?? (
      isApplicationActive == false
        ? NowPlayingAutomaticPresentationTiming.inactiveDelayCap
        : NowPlayingAutomaticPresentationTiming.activeDelay
    )
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: delay)
    let previousDeadline = automaticPresentationDeadline
    automaticPresentationDeadline = deadline
    // Interaction only pushes the deadline later; the running task re-sleeps until it,
    // so frequent scroll and drag events do not recreate the task.
    if inactivityTask != nil, let previousDeadline, previousDeadline <= deadline { return }

    inactivityTask?.cancel()
    inactivityTask = Task { @MainActor [weak self] in
      while true {
        guard let deadline = self?.automaticPresentationDeadline else { return }
        if clock.now < deadline {
          do {
            try await clock.sleep(until: deadline)
          } catch {
            return
          }
          continue
        }
        guard let self else { return }
        self.inactivityTask = nil
        self.automaticPresentationDeadline = nil
        guard self.automaticallyPresents,
          !self.isPresented,
          self.phase == .hidden,
          self.hasEstablishedConnection,
          self.playbackKey != nil,
          self.isPlaying
        else { return }
        self.present(automatically: true)
        return
      }
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
    cancelAutomaticPresentationRetry()
  }

  private func cancelAutomaticPresentationRetry() {
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
              .onTapGesture { presentation.dismiss() }
              // Like the full-screen video hint: over the cover's top edge, where there is
              // always room; it passes clicks through to the cover.
              .overlay(alignment: .top) {
                if presentation.showsDismissHint {
                  dismissHint
                    .padding(.top, 14)
                    .transition(
                      reduceMotion
                        ? .opacity : .opacity.combined(with: .offset(y: -6))
                    )
                }
              }

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
                ArtistCreditView(credit: entry.artistCredit, openArtist: showArtist)
                  .font(.title3.weight(.medium))
                  .foregroundStyle(presentationAccent)
                  .tint(presentationAccent)
                  .animation(.easeInOut(duration: 0.85), value: preparedThemeID)
                  .lineLimit(1)
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
                isLoaded: album?.id == albumID,
                fallbackRating: album?.id == albumID ? album?.userRating : nil,
                accent: presentationAccent
              )
              .animation(.easeInOut(duration: 0.85), value: preparedThemeID)
              .padding(.top, 18)
            }
          }
          .frame(maxWidth: .infinity)

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
          guard let albumID = entry.albumID else {
            album = nil
            return
          }
          // Usually already cached by the queue's album header for the same album.
          album = session.cachedAlbumMetadata(id: albumID)
          guard album == nil else { return }
          let loadedAlbum = await session.albumMetadata(id: albumID)
          guard !Task.isCancelled, player.currentEntry?.albumID == albumID else { return }
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

  private var dismissHint: some View {
    Label("Click the cover or press Esc to go back", systemImage: "chevron.down")
      .font(.callout)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .glassEffect(.regular, in: Capsule())
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var preparedArtworkIdentity: ObjectIdentifier? {
    presentation.preparedTheme?.artwork.map(ObjectIdentifier.init)
  }

  private var presentationAccent: Color {
    presentation.preparedTheme?.accent.color ?? ArtworkColor.fallback.color
  }

  private var preparedThemeID: UUID? {
    presentation.preparedTheme?.id
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let albumID: String
  let isLoaded: Bool
  let fallbackRating: Int?
  let accent: Color

  @State private var hoveredRating: Int?
  @State private var presentedRating = 0
  @State private var starsVisible = false
  @State private var animatesFillChanges = false

  private struct RatingPresentationRequest: Hashable {
    let albumID: String
    let sessionID: UUID?
    let loadedRating: Int?
  }

  private var presentationRequest: RatingPresentationRequest {
    RatingPresentationRequest(
      albumID: albumID,
      sessionID: session.activeSessionID,
      loadedRating: isLoaded ? max(0, min(rating ?? 0, 5)) : nil
    )
  }

  private var rating: Int? {
    session.rating(forAlbumID: albumID, fallback: fallbackRating)
  }

  var body: some View {
    VStack(spacing: 7) {
      Text("Album rating")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        ForEach(1...5, id: \.self) { value in
          Button {
            guard isLoaded && starsVisible else { return }
            Task {
              await session.updateAlbumRating(
                value,
                forAlbumID: albumID,
                fallback: fallbackRating
              )
            }
          } label: {
            ZStack {
              Image(systemName: "star.fill")
                .animation(
                  animatesFillChanges && !reduceMotion && hoveredRating == nil
                    ? .easeInOut(duration: 0.18) : nil
                ) { content in
                  content.opacity(value <= displayedRating ? 1 : 0)
                }
              Image(systemName: "star")
            }
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(accent)
            .contentShape(Rectangle())
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
      .animation(.easeInOut(duration: 0.18), value: session.isUpdatingAlbumRating)
      .onHover { isHovering in
        if !isHovering { hoveredRating = nil }
      }
      .opacity(starsVisible ? 1 : 0)
      .animation(nil, value: starsVisible)
      .allowsHitTesting(isLoaded && starsVisible)
      .accessibilityHidden(!isLoaded || !starsVisible)
    }
    .task(id: presentationRequest) {
      hoveredRating = nil
      if let loadedRating = presentationRequest.loadedRating {
        animatesFillChanges = starsVisible
        presentedRating = loadedRating
        starsVisible = true
        return
      }

      // Briefly retain the outgoing rating. New data cancels this timeout;
      // a slow or failed request must not leave another album's rating on screen.
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      starsVisible = false
    }
  }

  private var displayedRating: Int {
    hoveredRating ?? presentedRating
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

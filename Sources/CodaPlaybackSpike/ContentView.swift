import AppKit
import SwiftUI

private enum CodaWindowLayout {
  static let mainContentTopLift: CGFloat = 20
}

struct ContentView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var playlistSaver: QueuePlaylistSaveCoordinator
  @State private var isDockVolumeExpanded = false

  var body: some View {
    ZStack {
      AppArtworkBackground()
      PlaybackWindowVisibilityObserver()
        .frame(width: 0, height: 0)

      GeometryReader { geometry in
        let contentWidth = max(0, geometry.size.width - 20)
        let contentHeight = max(0, geometry.size.height - 20)
        let queueWidth = min(330, max(285, geometry.size.width * 0.22))

        HStack(alignment: .top, spacing: 10) {
          ZStack(alignment: .bottom) {
            NavigationStack(path: $session.path) {
              RootContentView()
                .id(session.rootToken)
                .navigationDestination(for: LibraryRoute.self) { route in
                  RouteContentView(route: route)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)

            if session.hasEstablishedConnection {
              HStack(spacing: 0) {
                Color.clear
                  .frame(width: PlaybackDockMetrics.volumeExpansionWidth)
                  .allowsHitTesting(false)

                CompactPlaybackDockHost(
                  isVolumeExpanded: $isDockVolumeExpanded
                )
                  .frame(
                    width: PlaybackDockMetrics.width(
                      isVolumeExpanded: isDockVolumeExpanded
                    ),
                    height: 64
                  )

                Spacer(minLength: 0)
                  .allowsHitTesting(false)
              }
              .frame(
                width: PlaybackDockMetrics.anchoredContainerWidth,
                height: 64
              )
            }
          }
          .frame(maxWidth: .infinity)
          .frame(height: contentHeight + CodaWindowLayout.mainContentTopLift)
          .offset(y: -CodaWindowLayout.mainContentTopLift)

          if session.hasEstablishedConnection {
            QueuePanel()
              .frame(width: queueWidth)
              .frame(maxHeight: .infinity, alignment: .top)
              .floatingPanel(adaptsWhenInactive: true)
          }
        }
        .frame(
          width: contentWidth,
          height: contentHeight,
          alignment: .topLeading
        )
        .padding(10)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        ForEach(SidebarDestination.allCases) { destination in
          TitlebarNavigationButton(destination: destination)
            .opacity(session.hasEstablishedConnection ? 1 : 0)
            .disabled(!session.hasEstablishedConnection)
            .accessibilityHidden(!session.hasEstablishedConnection)
        }
      }
    }
    .toolbar(removing: .title)
    .sheet(isPresented: $playlistSaver.isPresented) {
      QueuePlaylistSaveSheet()
        .environmentObject(playlistSaver)
    }
    .onAppear {
      session.startAutomaticConnection()
    }
    .onChange(of: session.path) { _, path in
      if path.isEmpty {
        artworkTreatments.restorePlaybackArtwork()
      }
    }
    .onChange(of: session.selectedRoot) {
      artworkTreatments.restorePlaybackArtwork()
    }
    .onChange(of: player.currentEntry?.id) { _, currentEntryID in
      if currentEntryID == nil {
        Task {
          try? await Task.sleep(for: .milliseconds(220))
          guard player.currentEntry == nil else { return }
          isDockVolumeExpanded = false
        }
      }
    }
  }
}

private struct PlaybackWindowVisibilityObserver: NSViewRepresentable {
  @EnvironmentObject private var player: PlayerController

  func makeNSView(context: Context) -> PlaybackWindowVisibilityView {
    let view = PlaybackWindowVisibilityView()
    view.onVisibilityChange = player.setPlaybackWindowVisible
    return view
  }

  func updateNSView(_ nsView: PlaybackWindowVisibilityView, context: Context) {
    nsView.onVisibilityChange = player.setPlaybackWindowVisible
    nsView.reportVisibility()
  }

  static func dismantleNSView(_ nsView: PlaybackWindowVisibilityView, coordinator: ()) {
    nsView.onVisibilityChange?(false)
    nsView.stopObserving()
  }
}

@MainActor
private final class PlaybackWindowVisibilityView: NSView {
  var onVisibilityChange: ((Bool) -> Void)?

  private weak var observedWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard observedWindow !== window else {
      reportVisibility()
      return
    }
    stopObserving()
    observedWindow = window
    startObserving()
    reportVisibility()
  }

  func reportVisibility() {
    guard let window = observedWindow else {
      onVisibilityChange?(false)
      return
    }
    onVisibilityChange?(
      !window.isMiniaturized && window.occlusionState.contains(.visible)
    )
  }

  func stopObserving() {
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
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification,
    ]
    notificationTokens = names.map { name in
      center.addObserver(
        forName: name,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.reportVisibility()
        }
      }
    }
  }
}

private struct CompactPlaybackDockHost: NSViewRepresentable {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @Binding var isVolumeExpanded: Bool

  func makeNSView(context: Context) -> PassthroughDockHostingView {
    let view = PassthroughDockHostingView(rootView: rootView)
    view.dockWidth = dockWidth
    view.hasActiveEntry = player.currentEntry != nil
    return view
  }

  func updateNSView(_ nsView: PassthroughDockHostingView, context: Context) {
    nsView.dockWidth = dockWidth
    nsView.hasActiveEntry = player.currentEntry != nil
  }

  private var dockWidth: CGFloat {
    PlaybackDockMetrics.width(
      isVolumeExpanded: isVolumeExpanded
    )
  }

  private var rootView: CompactPlaybackDockHostingRoot {
    CompactPlaybackDockHostingRoot(
      session: session,
      player: player,
      artworkTreatments: artworkTreatments,
      isVolumeExpanded: $isVolumeExpanded
    )
  }
}

private struct CompactPlaybackDockHostingRoot: View {
  @ObservedObject var session: AppSession
  @ObservedObject var player: PlayerController
  @ObservedObject var artworkTreatments: ArtworkTreatmentSettings
  @Binding var isVolumeExpanded: Bool

  var body: some View {
    Group {
      if player.currentEntry != nil {
        CompactPlaybackDock(
          isVolumeExpanded: $isVolumeExpanded
        )
        .environmentObject(session)
        .environmentObject(player)
        .environmentObject(artworkTreatments)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(
          .opacity.combined(
            with: .scale(scale: 0.97, anchor: .bottom)
          )
        )
      }
    }
    .animation(.easeInOut(duration: 0.2), value: player.currentEntry?.id)
  }
}

private final class PassthroughDockHostingView: NSHostingView<CompactPlaybackDockHostingRoot> {
  var dockWidth: CGFloat = PlaybackDockMetrics.collapsedWidth
  var hasActiveEntry = false

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard hasActiveEntry else { return nil }
    let dockHeight: CGFloat = 52
    let dockY = isFlipped ? 0 : bounds.height - dockHeight
    let dockRect = NSRect(
      x: (bounds.width - dockWidth) / 2,
      y: dockY,
      width: dockWidth,
      height: dockHeight
    )
    guard dockRect.contains(point) else { return nil }
    return super.hitTest(point)
  }
}

private enum PlaybackDockMetrics {
  static let collapsedWidth: CGFloat = 431
  static let volumeExpansionWidth: CGFloat = 79
  static let anchoredContainerWidth = collapsedWidth + (volumeExpansionWidth * 2)

  static func width(isVolumeExpanded: Bool) -> CGFloat {
    collapsedWidth
      + (isVolumeExpanded ? volumeExpansionWidth : 0)
  }
}

private struct TitlebarNavigationButton: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @State private var isHovering = false
  let destination: SidebarDestination

  var body: some View {
    Button {
      session.selectRoot(destination)
    } label: {
      Image(systemName: destination.systemImage)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .background {
          if isHovering {
            Circle()
              .fill(artworkTreatments.accent.color.opacity(0.18))
          }
        }
        .foregroundStyle(isHovering ? .primary : .secondary)
    }
    .buttonStyle(.plain)
    .focusable(false)
    .focusEffectDisabled()
    .onHover { isHovering = $0 }
    .help(destination.title)
    .accessibilityLabel(destination.title)
  }
}

private struct CompactPlaybackDock: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @StateObject private var artworkLoader = AlbumArtworkLoader()
  @State private var seekPreviewPosition: Double?
  @Binding var isVolumeExpanded: Bool

  var body: some View {
    HStack(spacing: 10) {
      PlaybackTransportControls()
      playbackSectionDivider
      PlaybackProgressControl(
        timeline: player.timeline,
        previewPosition: $seekPreviewPosition
      )
      playbackSectionDivider
      PlaybackVolumeControl(isExpanded: $isVolumeExpanded)
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .frame(
      width: PlaybackDockMetrics.width(
        isVolumeExpanded: isVolumeExpanded
      ),
      height: 52
    )
    .floatingPanel(capsule: true)
    .fixedSize(horizontal: true, vertical: true)
    .contentShape(.interaction, Capsule())
    .onChange(of: player.currentEntry?.id) {
      seekPreviewPosition = nil
    }
    .task(id: player.currentEntry?.artworkURL) {
      let entry = player.currentEntry
      artworkTreatments.promoteDisplayedArtworkToPlayback(ifIdentity: entry?.albumID)
      await artworkLoader.load(url: entry?.artworkURL)
      guard player.currentEntry?.artworkURL == entry?.artworkURL else { return }
      if let image = artworkLoader.image {
        let displayedAlbumID = session.path.last?.displayedAlbumID
        artworkTreatments.rememberPlaybackArtwork(
          image,
          accent: artworkLoader.accent,
          identity: entry?.albumID,
          displaysImmediately: displayedAlbumID == nil || displayedAlbumID == entry?.albumID
        )
      }
    }
  }

  private var playbackSectionDivider: some View {
    Divider()
      .frame(width: 1, height: 24)
      .accessibilityHidden(true)
  }
}

private struct PlaybackProgressControl: View {
  @EnvironmentObject private var player: PlayerController
  @ObservedObject var timeline: PlaybackTimeline
  @Binding var previewPosition: Double?

  var body: some View {
    HStack(spacing: 10) {
      Text(elapsedLabel)
        .frame(width: 38, alignment: .trailing)
      PlaybackSeekBar(
        position: timeline.snapshot.position,
        duration: timeline.snapshot.duration,
        previewPosition: $previewPosition,
        seekAction: player.seek
      )
      .frame(width: 145)
      Text(durationLabel)
        .frame(width: 38, alignment: .leading)
    }
  }

  private var elapsedLabel: String {
    formatDuration(Int(previewPosition ?? timeline.snapshot.position))
  }

  private var durationLabel: String {
    formatDuration(Int(timeline.snapshot.duration))
  }
}

private struct PlaybackTransportControls: View {
  @EnvironmentObject private var player: PlayerController

  var body: some View {
    HStack(spacing: 5) {
      PlaybackTransportButton(
        title: "Previous",
        systemImage: "backward.fill",
        isEnabled: player.canGoPrevious
      ) {
        player.previous()
      }
      PlaybackTransportButton(
        title: player.isPlaying ? "Pause" : "Play",
        systemImage: player.isPlaying ? "pause.fill" : "play.fill",
        isEnabled: player.currentEntry != nil,
        helpText: playbackHelp
      ) {
        player.togglePlayback()
      }
      PlaybackTransportButton(
        title: "Next",
        systemImage: "forward.fill",
        isEnabled: player.canGoNext
      ) {
        player.next()
      }
    }
  }

  private var playbackHelp: String {
    let action = player.isPlaying ? "Pause" : "Play"
    guard let entry = player.currentEntry else { return action }
    return "\(action) — \(entry.title) · \(entry.artist)"
  }
}

private struct PlaybackTransportButton: View {
  let title: String
  let systemImage: String
  let isEnabled: Bool
  var helpText: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.primary)
        .frame(width: 27, height: 27)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .focusEffectDisabled()
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.35)
    .help(helpText ?? title)
    .accessibilityLabel(title)
  }
}

private struct PlaybackVolumeControl: View {
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @Binding var isExpanded: Bool
  @State private var collapseTask: Task<Void, Never>?

  var body: some View {
    HStack(spacing: isExpanded ? 7 : 0) {
      Button {
        player.toggleMute()
      } label: {
        Image(systemName: volumeSystemImage)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.primary)
          .frame(width: 27, height: 27)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .focusable(false)
      .focusEffectDisabled()
      .help(player.isEffectivelyMuted ? "Unmute" : "Mute")
      .accessibilityLabel(player.isEffectivelyMuted ? "Unmute" : "Mute")

      if isExpanded {
        Slider(value: volumeBinding, in: 0...1)
          .controlSize(.mini)
          .tint(artworkTreatments.accent.color)
          .frame(width: 72)
          .transition(
            .asymmetric(
              insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .leading)),
              removal: .opacity
            )
          )
          .help("Volume \(Int((player.audibleVolume * 100).rounded())) percent")
          .accessibilityLabel("Volume")
          .accessibilityValue("\(Int((player.audibleVolume * 100).rounded())) percent")
      }
    }
    .onHover(perform: updateHover)
    .onDisappear {
      collapseTask?.cancel()
    }
  }

  private var volumeBinding: Binding<Double> {
    Binding(
      get: { player.audibleVolume },
      set: { player.setVolume($0) }
    )
  }

  private var volumeSystemImage: String {
    if player.isEffectivelyMuted { return "speaker.slash.fill" }
    if player.volume < 0.34 { return "speaker.wave.1.fill" }
    if player.volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
  }

  private func updateHover(_ isHovering: Bool) {
    collapseTask?.cancel()
    if isHovering {
      withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
        isExpanded = true
      }
    } else {
      collapseTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: 0.16)) {
          isExpanded = false
        }
      }
    }
  }
}

private struct PlaybackSeekBar: View {
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let position: Double
  let duration: Double
  @Binding var previewPosition: Double?
  let seekAction: (Double) -> Void
  @State private var isHovering = false

  var body: some View {
    GeometryReader { geometry in
      let width = max(geometry.size.width, 1)
      let progress = min(max(displayedPosition / max(duration, 1), 0), 1)

      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.24))
          .frame(height: 3)

        Capsule()
          .fill(artworkTreatments.accent.color)
          .frame(width: width * progress, height: 3)

        if isHovering || previewPosition != nil {
          Circle()
            .fill(artworkTreatments.accent.color)
            .frame(width: 8, height: 8)
            .position(
              x: min(max(width * progress, 4), width - 4),
              y: geometry.size.height / 2
            )
        }
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard duration > 0 else { return }
            previewPosition = seekPosition(at: value.location.x, width: width)
          }
          .onEnded { value in
            guard duration > 0 else { return }
            let target = seekPosition(at: value.location.x, width: width)
            previewPosition = nil
            seekAction(target)
          }
      )
    }
    .frame(height: 18)
    .opacity(duration > 0 ? 1 : 0.35)
    .onHover { isHovering = $0 }
    .help(
      "\(formatDuration(Int(displayedPosition))) of "
        + formatDuration(Int(duration))
    )
    .accessibilityElement()
    .accessibilityLabel("Playback position")
    .accessibilityValue(
      "\(formatDuration(Int(displayedPosition))) of "
        + formatDuration(Int(duration))
    )
    .accessibilityAdjustableAction { direction in
      guard duration > 0 else { return }
      let step = max(5, duration / 20)
      switch direction {
      case .increment:
        seekAction(position + step)
      case .decrement:
        seekAction(position - step)
      @unknown default:
        break
      }
    }
  }

  private var displayedPosition: Double {
    previewPosition ?? position
  }

  private func seekPosition(at x: CGFloat, width: CGFloat) -> Double {
    let fraction = min(max(x / max(width, 1), 0), 1)
    return duration * fraction
  }
}

private struct RootContentView: View {
  @EnvironmentObject private var session: AppSession

  var body: some View {
    Group {
      if session.isRestoringConnection {
        NavidromeConnectionView()
      } else if !session.hasEstablishedConnection {
        NavidromeLoginView()
      } else {
        switch session.selectedRoot {
        case .home:
          HomeView(resetToken: session.rootToken)
        case .search:
          SearchView(resetToken: session.rootToken)
        case .artists:
          ArtistsView(kind: .alphabetical, resetToken: session.rootToken)
        case .albums:
          AlbumsView(kind: .recentlyAdded, resetToken: session.rootToken)
        }
      }
    }
    .safeAreaPadding(.top, 14)
  }
}

private struct RouteContentView: View {
  let route: LibraryRoute

  var body: some View {
    Group {
      switch route {
      case .artistsCollection(let kind):
        ArtistsView(kind: kind, resetToken: nil)
      case .albumCollection(let kind):
        AlbumsView(kind: kind, resetToken: nil)
      case .artist(let id):
        ArtistDetailView(artistID: id)
      case .album(let id):
        AlbumDetailView(albumID: id)
      case .albumRating(let id):
        AlbumDetailView(albumID: id, highlightsRatingOnAppear: true)
      case .playlist(let id):
        PlaylistDetailView(playlistID: id)
      }
    }
    .safeAreaPadding(.top, 14)
  }
}

private struct NavidromeConnectionView: View {
  @EnvironmentObject private var session: AppSession

  var body: some View {
    VStack(spacing: 14) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 72, height: 72)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 7)

      ProgressView()
        .controlSize(.small)

      Text(connectionLabel)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .transition(.opacity)
    .accessibilityElement(children: .combine)
  }

  private var connectionLabel: String {
    guard let host = session.configuration?.serverURL.host, !host.isEmpty else {
      return "Connecting to Navidrome…"
    }
    return "Connecting to \(host)…"
  }
}

private struct NavidromeLoginView: View {
  @EnvironmentObject private var session: AppSession
  @State private var serverURL = "https://"
  @State private var username = ""
  @State private var password = ""
  @State private var loadedSavedLogin = false
  @FocusState private var focusedField: LoginField?

  var body: some View {
    VStack(spacing: 22) {
      VStack(spacing: 10) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 92, height: 92)
          .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

        Text("Welcome to Coda")
          .font(.system(size: 32, weight: .bold, design: .rounded))
        Text("Connect your Navidrome server to begin.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 14) {
        loginField(
          title: "Server",
          systemImage: "network",
          prompt: "https://music.example.com",
          text: $serverURL,
          field: .server
        )

        loginField(
          title: "Username",
          systemImage: "person",
          prompt: "Username",
          text: $username,
          field: .username
        )

        HStack(spacing: 12) {
          Image(systemName: "lock")
            .frame(width: 18)
            .foregroundStyle(.secondary)
          SecureField("Password", text: $password)
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .password)
            .onSubmit(connect)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

        if case .failed(let message) = session.connectionState {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }

        Button(action: connect) {
          HStack(spacing: 8) {
            if session.connectionState == .connecting {
              ProgressView()
                .controlSize(.small)
            }
            Text(session.connectionState == .connecting ? "Connecting…" : "Connect")
              .fontWeight(.semibold)
          }
          .frame(maxWidth: .infinity)
          .frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canConnect || session.connectionState == .connecting)

        #if DEBUG
          Label(
            "Local debug builds keep this login in your private Application Support folder.",
            systemImage: "hammer.fill"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        #else
          Label("Your login is stored in your macOS login Keychain.", systemImage: "key.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        #endif
      }
      .padding(20)
      .frame(width: 430)
      .floatingPanel()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      guard !loadedSavedLogin else { return }
      loadedSavedLogin = true
      guard let login = await session.savedLogin() else {
        focusedField = .server
        return
      }
      serverURL = login.serverURL
      username = login.username
      password = login.password
    }
    .onExitCommand {
      focusedField = nil
    }
  }

  private enum LoginField: Hashable {
    case server
    case username
    case password
  }

  private var canConnect: Bool {
    !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !password.isEmpty
  }

  private func loginField(
    title: String,
    systemImage: String,
    prompt: String,
    text: Binding<String>,
    field: LoginField
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .frame(width: 18)
        .foregroundStyle(.secondary)
      TextField(prompt, text: text)
        .textFieldStyle(.plain)
        .focused($focusedField, equals: field)
        .onSubmit {
          switch field {
          case .server: focusedField = .username
          case .username: focusedField = .password
          case .password: connect()
          }
        }
    }
    .accessibilityLabel(title)
    .padding(.horizontal, 14)
    .frame(height: 44)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
  }

  private func connect() {
    guard canConnect, session.connectionState != .connecting else { return }
    focusedField = nil
    Task {
      await session.logIn(server: serverURL, username: username, password: password)
    }
  }
}

struct ArtworkImage: View {
  let url: URL?
  var cornerRadius: CGFloat = 8
  @State private var image: NSImage?
  @State private var failed = false

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.secondary.opacity(0.12))
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else if failed || url == nil {
        Image(systemName: "music.note")
          .font(.title2)
          .foregroundStyle(.tertiary)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .task(id: url) {
      image = nil
      failed = false
      guard let url else { return }
      image = await ArtworkImageCache.shared.image(for: url)
      failed = image == nil
    }
  }
}

private let queueDropCoordinateSpace = "CodaQueueDropCoordinateSpace"

private struct QueueInsertionTarget: Equatable {
  let beforeEntryID: UUID?
  let lineY: CGFloat
}

private struct QueueDropGeometryMeasurement: Equatable {
  let generation: Int
  let frame: CGRect
}

private struct QueuePanel: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @State private var selectedEntryIDs: [UUID]?
  @State private var selectionAnchorEntryID: UUID?
  @State private var groups: [QueueGroup] = []
  @State private var fullyVisibleGroupIDs: Set<UUID> = []
  @State private var visibleEntryIDs: Set<UUID> = []
  @State private var groupHeights: [UUID: CGFloat] = [:]
  @State private var groupFrames: [UUID: CGRect] = [:]
  @State private var entryFrames: [UUID: CGRect] = [:]
  @State private var dropGeometryGeneration = 0
  @State private var activeReorderItem: QueueReorderDragItem?
  @State private var insertionTarget: QueueInsertionTarget?
  @State private var isDropTargeted = false
  @State private var isAddingDroppedItems = false
  @State private var viewportHeight: CGFloat = 0
  @FocusState private var queueHasFocus: Bool

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        HStack {
          HStack {
            Text("Queue")
              .font(.headline)
            Spacer()
          }
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
          .onTapGesture {
            clearSelection()
            queueHasFocus = true
          }
          .accessibilityElement()
          .accessibilityLabel("Deselect Queue Selection")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction {
            clearSelection()
            queueHasFocus = true
          }
          if shouldShowReturnToPlaying {
            Button("Return to Playing Track", systemImage: "scope") {
              scrollToPlayingTrack(proxy)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Return to Playing Track")
          }
          Button("Clear Queue", systemImage: "trash", role: .destructive) {
            clearSelection()
            player.clear()
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .disabled(player.queue.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)

        if player.queue.isEmpty {
          ContentUnavailableView(
            "Queue Is Empty",
            systemImage: "music.note.list",
            description: Text("Play something, or drag an album, disc, or artist here.")
          )
        } else {
          ScrollView {
            ZStack(alignment: .top) {
              Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
                .frame(minHeight: viewportHeight)
                .onTapGesture { clearSelection() }

              LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                  QueueAlbumBlock(
                    group: group,
                    currentIndex: player.currentIndex,
                    isPlaying: player.isPlaying,
                    selectedEntryIDs: selectedEntryIDs,
                    selectAction: select,
                    trackSelectAction: selectTrack,
                    deleteAction: remove,
                    playAction: player.play,
                    removeEntryAction: player.remove,
                    geometryGeneration: dropGeometryGeneration,
                    groupFrameAction: { generation, frame in
                      guard generation == dropGeometryGeneration else { return }
                      groupFrames[group.id] = frame
                    },
                    entryFrameAction: { entryID, generation, frame in
                      guard generation == dropGeometryGeneration else { return }
                      entryFrames[entryID] = frame
                    },
                    dragStateAction: updateDragState,
                    visibilityAction: updateEntryVisibility
                  )
                  .id(group.id)
                  .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                  } action: { height in
                    groupHeights[group.id] = height
                  }
                  .onScrollVisibilityChange(threshold: 0.98) { isVisible in
                    if isVisible {
                      fullyVisibleGroupIDs.insert(group.id)
                    } else {
                      fullyVisibleGroupIDs.remove(group.id)
                    }
                  }
                }
              }
              .padding(12)
            }
          }
          .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
          } action: { height in
            viewportHeight = height
          }
        }
      }
      .focusable()
      .focused($queueHasFocus)
      .focusEffectDisabled()
      .onDeleteCommand(perform: removeSelection)
      .onKeyPress(.return) {
        guard let selectedEntryIDs,
          selectedEntryIDs.count == 1,
          let entryID = selectedEntryIDs.first,
          let index = player.queue.firstIndex(where: { $0.id == entryID })
        else { return .ignored }
        player.play(index: index)
        return .handled
      }
      .onKeyPress(keys: [.delete, .deleteForward]) { _ in
        guard selectedEntryIDs != nil else { return .ignored }
        removeSelection()
        return .handled
      }
      .onExitCommand { clearSelection() }
      .onChange(of: player.queue.map(\.id)) { previousIDs, currentIDs in
        groups = queueGroups(player.queue)
        reconcileSelection()
        refreshDropGeometry()
        if previousIDs.isEmpty, !currentIDs.isEmpty {
          Task { @MainActor in
            // Queue restoration publishes the entries before PlayerController
            // publishes its restored current index. Wait for both that update and
            // the derived album groups to enter the scroll view.
            await Task.yield()
            groups = queueGroups(player.queue)
            await Task.yield()
            scrollToPlayingTrack(proxy, animated: false)
          }
        }
      }
      .onChange(of: player.currentEntry?.id) { oldEntryID, newEntryID in
        followCurrentAlbum(from: oldEntryID, to: newEntryID, proxy: proxy)
      }
      .task {
        groups = queueGroups(player.queue)
        await Task.yield()
        if player.currentEntry != nil, !shouldShowReturnToPlaying {
          return
        }
        scrollToPlayingTrack(proxy, animated: false)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .coordinateSpace(.named(queueDropCoordinateSpace))
      .contentShape(Rectangle())
      .overlay(alignment: .top) {
        ZStack(alignment: .top) {
          RoundedRectangle(cornerRadius: FloatingPanelStyle.cornerRadius, style: .continuous)
            .strokeBorder(
              artworkTreatments.accent.color.opacity(isDropTargeted ? 0.92 : 0),
              lineWidth: 2
            )
            .padding(1)

          if let insertionTarget {
            Rectangle()
              .fill(artworkTreatments.accent.color)
              .frame(height: 2)
              .padding(.horizontal, 18)
              .offset(y: insertionTarget.lineY - 1)
          }

          if isAddingDroppedItems {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Adding to Queue…")
                .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 5)
          }
        }
        .allowsHitTesting(false)
      }
      .animation(.easeOut(duration: 0.16), value: isDropTargeted)
      .dropDestination(for: QueueDropItem.self) { items, dropSession in
        handleDrop(items, at: dropSession.location)
      }
      .onDropSessionUpdated(updateDropSession)
      .dropConfiguration { _ in
        DropConfiguration(operation: activeReorderItem == nil ? .copy : .move)
      }
    }
  }

  private var shouldShowReturnToPlaying: Bool {
    guard let currentID = player.currentEntry?.id else { return false }
    return !visibleEntryIDs.contains(currentID)
  }

  private func select(_ entryIDs: [UUID]) {
    selectedEntryIDs = selectedEntryIDs == entryIDs ? nil : entryIDs
    selectionAnchorEntryID = nil
    queueHasFocus = true
  }

  private func selectTrack(_ entryID: UUID, modifiers: TrackSelectionModifiers) {
    let selection = updatedTrackSelection(
      current: selectedEntryIDs ?? [],
      anchor: selectionAnchorEntryID,
      clicked: entryID,
      ordered: player.queue.map(\.id),
      modifiers: modifiers
    )
    selectedEntryIDs = selection.ids.isEmpty ? nil : selection.ids
    selectionAnchorEntryID = selection.anchor
    queueHasFocus = true
  }

  private func remove(_ entryIDs: [UUID]) {
    player.remove(entryIDs: entryIDs)
    if let selectedEntryIDs {
      let removed = Set(entryIDs)
      let remainingSelection = selectedEntryIDs.filter { !removed.contains($0) }
      self.selectedEntryIDs = remainingSelection.isEmpty ? nil : remainingSelection
    }
    if let selectionAnchorEntryID, entryIDs.contains(selectionAnchorEntryID) {
      self.selectionAnchorEntryID = nil
    }
  }

  private func removeSelection() {
    guard let selectedEntryIDs else { return }
    player.remove(entryIDs: selectedEntryIDs)
    clearSelection()
  }

  private func clearSelection() {
    selectedEntryIDs = nil
    selectionAnchorEntryID = nil
  }

  private func move(_ item: QueueReorderDragItem, before targetID: UUID?) -> Bool {
    player.move(entryIDs: item.entryIDs, before: targetID)
  }

  private func updateDragState(_ item: QueueReorderDragItem, _ isActive: Bool) {
    if isActive {
      if activeReorderItem != item {
        refreshDropGeometry()
      }
      activeReorderItem = item
    } else if activeReorderItem == item {
      clearDropState()
    }
  }

  private func updateDropSession(_ dropSession: DropSession) {
    guard dropSession.phase == .entering || dropSession.phase == .active else {
      isDropTargeted = false
      insertionTarget = nil
      return
    }

    isDropTargeted = true
    insertionTarget = calculateTrackInsertionTarget(at: dropSession.location)
  }

  private func handleDrop(_ items: [QueueDropItem], at location: CGPoint) {
    guard let firstItem = items.first else {
      clearDropState()
      return
    }

    switch firstItem {
    case .reorder(let item):
      if let target = calculateTrackInsertionTarget(at: location) {
        _ = move(item, before: target.beforeEntryID)
      }
      clearDropState()

    case .library:
      guard !isAddingDroppedItems else { return }
      let libraryItems = items.compactMap { item -> LibraryQueueDragItem? in
        guard case .library(let libraryItem) = item else { return nil }
        return libraryItem
      }
      guard !libraryItems.isEmpty else {
        clearDropState()
        return
      }
      let target = calculateTrackInsertionTarget(at: location)
        ?? fallbackInsertionTarget
      isAddingDroppedItems = true
      clearDropVisuals()
      Task {
        await session.insert(
          libraryItems: libraryItems,
          before: target.beforeEntryID,
          into: player
        )
        isAddingDroppedItems = false
      }
    }
  }

  private func calculateTrackInsertionTarget(at location: CGPoint) -> QueueInsertionTarget? {
    guard !player.queue.isEmpty else { return fallbackInsertionTarget }
    let measuredEntries = player.queue.compactMap { entry -> (QueueEntry, CGRect)? in
      guard let frame = entryFrames[entry.id] else { return nil }
      return (entry, frame)
    }.sorted { $0.1.midY < $1.1.midY }
    guard let last = measuredEntries.last else { return nil }
    if let next = measuredEntries.first(where: { location.y < $0.1.midY }) {
      return QueueInsertionTarget(
        beforeEntryID: next.0.id,
        lineY: insertionLineY(before: next.0, fallback: next.1.minY)
      )
    }
    let lastIndex = player.queue.firstIndex(where: { $0.id == last.0.id })
    let nextID = lastIndex.flatMap { index in
      player.queue.indices.contains(index + 1) ? player.queue[index + 1].id : nil
    }
    return QueueInsertionTarget(beforeEntryID: nextID, lineY: last.1.maxY)
  }

  private func insertionLineY(before entry: QueueEntry, fallback: CGFloat) -> CGFloat {
    guard let group = groups.first(where: { $0.entryIDs.first == entry.id }),
      let groupFrame = groupFrames[group.id]
    else { return fallback }
    return groupFrame.minY
  }

  private var fallbackInsertionTarget: QueueInsertionTarget {
    let measuredBottom = entryFrames.values.map(\.maxY).max()
      ?? groupFrames.values.map(\.maxY).max()
      ?? 44
    return QueueInsertionTarget(beforeEntryID: nil, lineY: measuredBottom)
  }

  private func clearDropVisuals() {
    isDropTargeted = false
    insertionTarget = nil
  }

  private func clearDropState() {
    activeReorderItem = nil
    clearDropVisuals()
  }

  private func refreshDropGeometry() {
    entryFrames.removeAll(keepingCapacity: true)
    groupFrames.removeAll(keepingCapacity: true)
    dropGeometryGeneration &+= 1
    insertionTarget = nil

    let entryIDs = Set(player.queue.map(\.id))
    if let activeReorderItem,
      !Set(activeReorderItem.entryIDs).isSubset(of: entryIDs)
    {
      clearDropState()
    }
  }

  private func reconcileSelection() {
    guard let selectedEntryIDs else { return }
    let queueIDs = Set(player.queue.map(\.id))
    let remainingSelection = selectedEntryIDs.filter(queueIDs.contains)
    self.selectedEntryIDs = remainingSelection.isEmpty ? nil : remainingSelection
    if let selectionAnchorEntryID, !queueIDs.contains(selectionAnchorEntryID) {
      self.selectionAnchorEntryID = nil
    }
  }

  private func updateEntryVisibility(_ entryID: UUID, _ isVisible: Bool) {
    if isVisible {
      visibleEntryIDs.insert(entryID)
    } else {
      visibleEntryIDs.remove(entryID)
    }
  }

  private func followCurrentAlbum(
    from oldEntryID: UUID?,
    to newEntryID: UUID?,
    proxy: ScrollViewProxy
  ) {
    guard let newEntryID,
      let newGroup = groups.first(where: { $0.entryIDs.contains(newEntryID) })
    else { return }
    let oldGroup = oldEntryID.flatMap { oldID in
      groups.first(where: { $0.entryIDs.contains(oldID) })
    }
    guard oldGroup?.id != newGroup.id,
      !fullyVisibleGroupIDs.contains(newGroup.id)
    else { return }

    let isOversized = (groupHeights[newGroup.id] ?? 0) > max(0, viewportHeight - 24)
    let movingForward = (oldGroup?.startIndex ?? -1) < newGroup.startIndex
    let anchor: UnitPoint = isOversized ? .top : (movingForward ? .bottom : .top)
    withAnimation(.easeInOut(duration: 0.28)) {
      proxy.scrollTo(newGroup.id, anchor: anchor)
    }
  }

  private func scrollToPlayingTrack(_ proxy: ScrollViewProxy, animated: Bool = true) {
    guard let currentID = player.currentEntry?.id,
      let currentGroup = groups.first(where: { $0.entryIDs.contains(currentID) })
    else { return }
    let action = { proxy.scrollTo(currentGroup.id, anchor: .center) }
    if animated {
      withAnimation(.easeInOut(duration: 0.25), action)
    } else {
      action()
    }
  }
}

private struct QueueAlbumBlock: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @State private var album: RemoteAlbum?
  let group: QueueGroup
  let currentIndex: Int?
  let isPlaying: Bool
  let selectedEntryIDs: [UUID]?
  let selectAction: ([UUID]) -> Void
  let trackSelectAction: (UUID, TrackSelectionModifiers) -> Void
  let deleteAction: ([UUID]) -> Void
  let playAction: (Int) -> Void
  let removeEntryAction: (UUID) -> Void
  let geometryGeneration: Int
  let groupFrameAction: (Int, CGRect) -> Void
  let entryFrameAction: (UUID, Int, CGRect) -> Void
  let dragStateAction: (QueueReorderDragItem, Bool) -> Void
  let visibilityAction: (UUID, Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      QueueAlbumHeader(
        group: group,
        album: album,
        isSelected: selectedEntryIDs == group.entryIDs,
        selectAction: { selectAction(group.entryIDs) },
        deleteAction: { deleteAction(group.entryIDs) },
        dragStateAction: dragStateAction
      )
      ForEach(Array(group.entries.enumerated()), id: \.element.id) { offset, entry in
        if group.beginsDiscSection(at: offset) {
          let discEntryIDs = group.discEntryIDs(at: offset)
          QueueDiscHeader(
            number: group.discNumber(at: offset),
            subtitle: group.discSubtitle(at: offset),
            durationSeconds: group.discDuration(at: offset),
            isSelected: selectedEntryIDs == discEntryIDs,
            selectAction: { selectAction(discEntryIDs) },
            deleteAction: { deleteAction(discEntryIDs) }
          )
          .padding(.top, offset == 0 ? 3 : 7)
          .padding(.horizontal, 2)
        }
        QueueTrackRow(
          entry: entry,
          album: album,
          isCurrent: currentIndex == group.startIndex + offset,
          isPlaying: isPlaying,
          isTrackSelected: selectedEntryIDs?.contains(entry.id) == true,
          isCollectionSelected: group.showsDiscHeadings
            && selectedEntryIDs == group.discEntryIDs(at: offset),
          dragEntryIDs: selectedEntryIDs?.contains(entry.id) == true
            ? selectedEntryIDs ?? [entry.id] : [entry.id],
          selectAction: { modifiers in
            trackSelectAction(entry.id, modifiers)
          },
          playAction: { playAction(group.startIndex + offset) },
          removeAction: { removeEntryAction(entry.id) },
          geometryGeneration: geometryGeneration,
          frameAction: { generation, frame in
            entryFrameAction(entry.id, generation, frame)
          },
          dragStateAction: dragStateAction,
          visibilityAction: visibilityAction
        )
        .id(entry.id)
      }
    }
    .padding(6)
    .contentShape(Rectangle())
    .onGeometryChange(for: QueueDropGeometryMeasurement.self) { geometry in
      QueueDropGeometryMeasurement(
        generation: geometryGeneration,
        frame: geometry.frame(in: .named(queueDropCoordinateSpace))
      )
    } action: { measurement in
      groupFrameAction(measurement.generation, measurement.frame)
    }
    .background {
      if selectedEntryIDs == group.entryIDs {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(artworkTreatments.accent.color.opacity(0.12))
      }
    }
    .overlay {
      if selectedEntryIDs == group.entryIDs {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(artworkTreatments.accent.color.opacity(0.42), lineWidth: 1)
          .allowsHitTesting(false)
        }
    }
    .task(id: albumID) {
      await loadAlbum()
    }
  }

  private var albumID: String? {
    group.entries.first?.albumID?.nonEmpty
  }

  @MainActor
  private func loadAlbum() async {
    guard let albumID, let client = session.client else {
      album = nil
      return
    }
    do {
      let loadedAlbum = try await client.album(id: albumID).album
      guard self.albumID == albumID else { return }
      album = loadedAlbum
    } catch {
      // Queue controls remain available if optional context-menu metadata cannot load.
      album = nil
    }
  }
}

private struct QueueAlbumHeader: View {
  let group: QueueGroup
  let album: RemoteAlbum?
  let isSelected: Bool
  let selectAction: () -> Void
  let deleteAction: () -> Void
  let dragStateAction: (QueueReorderDragItem, Bool) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: selectAction) {
        HStack(spacing: 10) {
          ArtworkImage(url: group.entries.first?.artworkURL, cornerRadius: 6)
            .frame(width: 48, height: 48)
          VStack(alignment: .leading, spacing: 2) {
            Text(group.albumTitle)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
            Text(group.artist)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Text(group.detail)
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isSelected {
        Button("Remove Album from Queue", systemImage: "trash", role: .destructive) {
          deleteAction()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Remove Album from Queue")
      }
    }
    .draggable(QueueDropItem.reorder(.albumBlock(group.entryIDs)))
    .dragConfiguration(.init(allowMove: true))
    .onDragSessionUpdated { dragSession in
      let item = QueueReorderDragItem.albumBlock(group.entryIDs)
      dragStateAction(item, dragSession.phase == .initial || dragSession.phase == .active)
    }
    .contextMenu {
      QueueItemContextMenu(
        albumID: albumID,
        album: album,
        removalTitle: "Remove Album from Queue",
        deleteAction: deleteAction
      )
    }
  }

  private var albumID: String? {
    group.entries.first?.albumID?.nonEmpty
  }
}

private struct QueueItemContextMenu: View {
  @EnvironmentObject private var session: AppSession
  let albumID: String?
  let album: RemoteAlbum?
  let removalTitle: String
  let deleteAction: () -> Void

  var body: some View {
    if let albumID {
      Button("Show Album", systemImage: "square.stack") {
        session.open(.album(albumID))
      }

      if let artistID = album?.artistId {
        Button("Show Artist", systemImage: "person") {
          session.open(.artist(artistID))
        }
      }

      Divider()

      Button(ratingMenuTitle) {
        session.open(.albumRating(albumID))
      }

      Divider()
    }

    Button(role: .destructive, action: deleteAction) {
      Label(removalTitle, systemImage: "trash")
    }
  }

  private var ratingMenuTitle: String {
    guard let albumID else { return "Rate Album…" }
    return session.rating(forAlbumID: albumID, fallback: album?.userRating)
      .map(starLabel) ?? "Rate Album…"
  }

  private func starLabel(for rating: Int) -> String {
    String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating)
  }
}

private struct QueueDiscHeader: View {
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let number: Int
  let subtitle: String?
  let durationSeconds: Int
  let isSelected: Bool
  let selectAction: () -> Void
  let deleteAction: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button(action: selectAction) {
        DiscSectionHeading(
          number: number,
          subtitle: subtitle,
          durationSeconds: durationSeconds,
          compact: true
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isSelected {
        Button("Remove Disc from Queue", systemImage: "trash", role: .destructive) {
          deleteAction()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Remove Disc \(number) from Queue")
      }
    }
    .padding(.horizontal, 5)
    .padding(.vertical, 4)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(artworkTreatments.accent.color.opacity(0.14))
      }
    }
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(artworkTreatments.accent.color.opacity(0.42), lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
    .contextMenu {
      Button("Remove Disc from Queue", role: .destructive, action: deleteAction)
    }
  }
}

private struct QueueTrackRow: View {
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let entry: QueueEntry
  let album: RemoteAlbum?
  let isCurrent: Bool
  let isPlaying: Bool
  let isTrackSelected: Bool
  let isCollectionSelected: Bool
  let dragEntryIDs: [UUID]
  let selectAction: (TrackSelectionModifiers) -> Void
  let playAction: () -> Void
  let removeAction: () -> Void
  let geometryGeneration: Int
  let frameAction: (Int, CGRect) -> Void
  let dragStateAction: (QueueReorderDragItem, Bool) -> Void
  let visibilityAction: (UUID, Bool) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if isCurrent {
          Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
        } else {
          Text(trackLabel(entry))
            .monospacedDigit()
        }
      }
      .font(.caption)
      .foregroundStyle(
        isCurrent ? artworkTreatments.accent.color : Color.secondary
      )
      .frame(width: 24, alignment: .trailing)

      Text(entry.title)
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(
          isCurrent ? artworkTreatments.accent.color : Color.primary
        )
      Spacer(minLength: 4)
      Text(formatDuration(entry.durationSeconds))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .padding(.vertical, 3)
    .background {
      if isTrackSelected {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.primary.opacity(0.075))
      } else if isCollectionSelected {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(artworkTreatments.accent.color.opacity(0.14))
      }
    }
    .onTapGesture {
      selectAction(currentTrackSelectionModifiers())
    }
    .simultaneousGesture(
      TapGesture(count: 2)
        .onEnded(playAction)
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { selectAction([]) }
    .accessibilityAction(named: "Play", playAction)
    .draggable(QueueDropItem.reorder(.tracks(dragEntryIDs)))
    .dragConfiguration(.init(allowMove: true))
    .onDragSessionUpdated { dragSession in
      let item = QueueReorderDragItem.tracks(dragEntryIDs)
      dragStateAction(item, dragSession.phase == .initial || dragSession.phase == .active)
    }
    .onGeometryChange(for: QueueDropGeometryMeasurement.self) { geometry in
      QueueDropGeometryMeasurement(
        generation: geometryGeneration,
        frame: geometry.frame(in: .named(queueDropCoordinateSpace))
      )
    } action: { measurement in
      frameAction(measurement.generation, measurement.frame)
    }
    .onScrollVisibilityChange(threshold: 0.55) { isVisible in
      visibilityAction(entry.id, isVisible)
    }
    .contextMenu {
      QueueItemContextMenu(
        albumID: entry.albumID?.nonEmpty,
        album: album,
        removalTitle: "Remove Track from Queue",
        deleteAction: removeAction
      )
    }
  }
}

struct QueueGroup: Identifiable {
  let id: UUID
  let startIndex: Int
  let entries: [QueueEntry]

  var entryIDs: [UUID] { entries.map(\.id) }
  var albumTitle: String { entries.first?.album.nonEmpty ?? "Unknown Album" }
  var artist: String { entries.first?.artist.nonEmpty ?? "Unknown Artist" }

  var showsDiscHeadings: Bool {
    Set(entries.map(normalizedDiscNumber)).count > 1
      || entries.contains { $0.discSubtitle?.nonEmpty != nil }
  }

  var detail: String {
    let year = entries.first?.year.map(String.init)
    let duration = formatCollectionDuration(entries.reduce(0) { $0 + $1.durationSeconds })
    return [year, duration].compactMap { $0 }.joined(separator: " · ")
  }

  func beginsDiscSection(at offset: Int) -> Bool {
    guard showsDiscHeadings, entries.indices.contains(offset) else { return false }
    guard offset > 0 else { return true }
    return normalizedDiscNumber(entries[offset - 1]) != normalizedDiscNumber(entries[offset])
  }

  func discNumber(at offset: Int) -> Int {
    guard entries.indices.contains(offset) else { return 1 }
    return normalizedDiscNumber(entries[offset])
  }

  func discSubtitle(at offset: Int) -> String? {
    let number = discNumber(at: offset)
    return entries.first {
      normalizedDiscNumber($0) == number && $0.discSubtitle?.nonEmpty != nil
    }?.discSubtitle
  }

  func discDuration(at offset: Int) -> Int {
    let number = discNumber(at: offset)
    return entries.filter { normalizedDiscNumber($0) == number }
      .reduce(0) { $0 + $1.durationSeconds }
  }

  func discEntryIDs(at offset: Int) -> [UUID] {
    let number = discNumber(at: offset)
    return entries.filter { normalizedDiscNumber($0) == number }.map(\.id)
  }

  private func normalizedDiscNumber(_ entry: QueueEntry) -> Int {
    max(1, entry.discNumber ?? 1)
  }
}

func queueGroups(_ entries: [QueueEntry]) -> [QueueGroup] {
  var result: [QueueGroup] = []
  var currentEntries: [QueueEntry] = []
  var currentKey = ""
  var startIndex = 0

  func appendCurrentGroup() {
    guard let firstEntry = currentEntries.first else { return }
    result.append(
      QueueGroup(id: firstEntry.id, startIndex: startIndex, entries: currentEntries)
    )
  }

  for (index, entry) in entries.enumerated() {
    let key = entry.queueGroupID.map { "group:\($0.uuidString)" }
      ?? entry.albumID.map { "album:\($0)" }
      ?? "metadata:\(entry.artist.lowercased())|\(entry.album.lowercased())"
    if !currentEntries.isEmpty, key != currentKey {
      appendCurrentGroup()
      currentEntries = []
      startIndex = index
    }
    currentKey = key
    currentEntries.append(entry)
  }

  if !currentEntries.isEmpty {
    appendCurrentGroup()
  }
  return result
}

func trackLabel(_ entry: QueueEntry) -> String {
  guard let track = entry.trackNumber else { return "–" }
  return String(track)
}

func formatDuration(_ seconds: Int) -> String {
  let clampedSeconds = max(0, seconds)
  return String(format: "%d:%02d", clampedSeconds / 60, clampedSeconds % 60)
}

func formatCollectionDuration(_ seconds: Int) -> String {
  guard seconds > 0 else { return "" }
  let hours = seconds / 3_600
  let minutes = (seconds % 3_600) / 60
  if hours > 0 { return "\(hours)h \(minutes)m" }
  return "\(minutes)m"
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

import AppKit
import SwiftUI

private enum CodaWindowLayout {
  static let mainContentTopLift: CGFloat = 20
  static let titlebarFadeStart: CGFloat = 8
  static let titlebarFadeHeight: CGFloat = 44
  static let minimumWidth = PlaybackDockMetrics.collapsedWidth + 40
  static let minimumHeight: CGFloat = 580
}

struct ContentView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var queueHandoff: QueueHandoffCoordinator
  @EnvironmentObject private var playlistSaver: QueuePlaylistSaveCoordinator
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  @StateObject private var volumePresentation = PlaybackVolumePresentationState()
  private var isRevealingContinueOffer: Bool {
    nowPlayingPresentation.handoffRevealRequest != nil
  }

  var body: some View {
    ZStack {
      AppArtworkBackground()
      PlaybackWindowVisibilityObserver()
        .frame(width: 0, height: 0)
      NowPlayingActivityObserver()
        .frame(width: 0, height: 0)
      QueueSelectionReconciler()
        .frame(width: 0, height: 0)

      GeometryReader { geometry in
        let contentWidth = max(0, geometry.size.width - 20)
        let contentHeight = max(0, geometry.size.height - 20)
        let queueWidth = codaQueueWidth(windowWidth: geometry.size.width)
        let queueIsVisible = codaQueueIsVisible(
          windowWidth: geometry.size.width,
          hasEstablishedConnection: session.hasEstablishedConnection
        )

        ZStack {
          HStack(alignment: .top, spacing: 10) {
            NavigationStack(path: $session.path) {
                RootContentView()
                  .id(session.rootToken)
                  .transition(.opacity)
                  .navigationDestination(for: LibraryRoute.self) { route in
                    RouteContentView(route: route)
                  }
            }
            // Library content dissolves under the titlebar instead of meeting a hard edge.
            // The native scroll edge effect does not reach this lifted, custom-laid-out
            // column, so a window-anchored mask fades the titlebar band instead.
            .mask {
              GeometryReader { proxy in
                let windowTop = -proxy.frame(in: .global).minY
                VStack(spacing: 0) {
                  Color.clear.frame(height: max(0, windowTop + CodaWindowLayout.titlebarFadeStart))
                  LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: CodaWindowLayout.titlebarFadeHeight)
                  Color.black
                }
              }
            }
            .animation(.easeOut(duration: 0.14), value: session.rootToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .allowsHitTesting(
              nowPlayingPresentation.phase.browsingIsInteractive
            )
            .accessibilityHidden(
              !nowPlayingPresentation.phase.browsingIsInteractive
            )
            .frame(minWidth: PlaybackDockMetrics.collapsedWidth)
            .frame(height: contentHeight + CodaWindowLayout.mainContentTopLift)
            .offset(y: -CodaWindowLayout.mainContentTopLift)

            if queueIsVisible {
              Color.clear
                .frame(width: queueWidth)
                .allowsHitTesting(false)
            }
          }
          .frame(
            width: contentWidth,
            height: contentHeight,
            alignment: .topLeading
          )
          .padding(10)

          ZStack {
            NowPlayingArtworkBackground()
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture { nowPlayingPresentation.dismiss() }
          }
          .ignoresSafeArea(.container, edges: .top)
          .opacity(nowPlayingPresentation.isPresented ? 1 : 0)
          .allowsHitTesting(
            nowPlayingPresentation.phase.presentationIsInteractive
          )
          .accessibilityHidden(true)
          .animation(
            .easeInOut(duration: NowPlayingPresentationMotion.duration),
            value: nowPlayingPresentation.isPresented
          )

          HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottom) {
              NowPlayingPresentationView()
                .opacity(nowPlayingPresentation.isPresented ? 1 : 0)
                .offset(
                  y: nowPlayingPresentation.isPresented
                    ? 0 : NowPlayingPresentationMotion.verticalOffset
                )
                .allowsHitTesting(
                  nowPlayingPresentation.phase.presentationIsInteractive
                )
                .accessibilityHidden(
                  !nowPlayingPresentation.phase.presentationIsInteractive
                )
                .animation(
                  .easeInOut(duration: NowPlayingPresentationMotion.duration),
                  value: nowPlayingPresentation.isPresented
                )

              Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
                .allowsHitTesting(nowPlayingPresentation.phase.isTransitioning)

              if session.hasEstablishedConnection {
                if player.currentEntry != nil {
                  PlaybackVolumePanel()
                    .frame(
                      width: PlaybackDockMetrics.volumePanelWidth,
                      height: PlaybackDockMetrics.volumePanelHeight
                    )
                    .offset(x: PlaybackDockMetrics.volumePanelHorizontalOffset)
                    .padding(.bottom, PlaybackDockMetrics.volumePanelBottomInset)
                    .onHover { isInside in
                      volumePresentation.updateHover(.panel, isInside: isInside)
                    }
                    .opacity(volumePresentation.isPresented ? 1 : 0)
                    .scaleEffect(
                      x: 1,
                      y: volumePresentation.isPresented ? 1 : 0.82,
                      anchor: .bottom
                    )
                    .allowsHitTesting(volumePresentation.isPresented)
                    .accessibilityHidden(!volumePresentation.isPresented)
                    .animation(
                      .easeOut(duration: 0.16),
                      value: volumePresentation.isPresented
                    )
                }

                CompactPlaybackDockHost(volumePresentation: volumePresentation)
                  .frame(
                    width: PlaybackDockMetrics.collapsedWidth,
                    height: 64
                  )
              }
            }
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight + CodaWindowLayout.mainContentTopLift)
            .offset(y: -CodaWindowLayout.mainContentTopLift)

            if queueIsVisible {
              QueuePanel()
                .frame(width: queueWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .floatingPanel(
                  surface: .tint,
                  accent: nowPlayingPresentation
                    .resolvedAccent(artworkTreatments.accent).color
                )
            }
          }
          .frame(
            width: contentWidth,
            height: contentHeight,
            alignment: .topLeading
          )
          .padding(10)

          if session.hasEstablishedConnection && !queueIsVisible {
            CompactQueuePeek(queueWidth: queueWidth)
              .padding(.vertical, 10)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
          }
        }
      }
    }
    .frame(
      minWidth: CodaWindowLayout.minimumWidth,
      minHeight: CodaWindowLayout.minimumHeight
    )
    .toolbar {
      if session.hasEstablishedConnection {
        ToolbarItemGroup(placement: .navigation) {
          ForEach(SidebarDestination.allCases) { destination in
            TitlebarNavigationButton(destination: destination)
          }
        }
        .sharedBackgroundVisibility(.automatic)
      } else {
        ToolbarItemGroup(placement: .navigation) {
          ForEach(SidebarDestination.allCases) { destination in
            TitlebarNavigationButton(destination: destination)
              .opacity(0)
              .disabled(true)
              .accessibilityHidden(true)
          }
        }
        .sharedBackgroundVisibility(.hidden)
      }
    }
    .toolbar(removing: .title)
    .focusEffectDisabled()
    .sheet(isPresented: $playlistSaver.isPresented) {
      QueuePlaylistSaveSheet()
        .environmentObject(playlistSaver)
    }
    .alert(
      "Could Not Update Rating",
      isPresented: Binding(
        get: { session.albumRatingErrorMessage != nil },
        set: { if !$0 { session.dismissAlbumRatingError() } }
      )
    ) {
      Button("OK", role: .cancel) { session.dismissAlbumRatingError() }
    } message: {
      Text(session.albumRatingErrorMessage ?? "The server rejected the rating.")
    }
    .onAppear {
      session.startAutomaticConnection()
      applyArtworkDisplayContext()
    }
    .onChange(of: session.path) { handleNavigationChange() }
    .onChange(of: session.selectedRoot) { handleNavigationChange() }
    .onChange(of: session.hasEstablishedConnection) {
      applyArtworkDisplayContext()
    }
    .onChange(of: session.activeSessionID) { _, activeSessionID in
      playlistSaver.sessionDidChange(to: activeSessionID)
    }
    .onChange(of: player.currentEntry?.id) {
      applyArtworkDisplayContext()
      volumePresentation.dismiss()
    }
    .onChange(of: queueHandoff.continueQueueIdentity) {
      revealContinueOfferIfNeeded()
    }
  }

  private func handleNavigationChange() {
    if !isRevealingContinueOffer || session.selectedRoot != .home || !session.path.isEmpty {
      nowPlayingPresentation.dismiss()
    }
    applyArtworkDisplayContext()
  }

  private func revealContinueOfferIfNeeded() {
    guard queueHandoff.continueQueue != nil else {
      nowPlayingPresentation.cancelHandoffReveal()
      return
    }
    guard !player.isPlaying, nowPlayingPresentation.beginHandoffReveal() else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      session.selectRoot(.home)
    }
  }

  private func applyArtworkDisplayContext() {
    artworkTreatments.applyDisplayContext(
      .resolve(
        hasEstablishedConnection: session.hasEstablishedConnection,
        displayedAlbumID: session.path.last?.displayedAlbumID,
        playbackIdentity: player.currentEntry?.artworkThemeIdentity
      )
    )
  }
}

private struct CompactQueuePeek: View {
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pointerIsInside = false
  @State private var edgeIsDropTargeted = false
  @State private var queueIsDropTargeted = false
  @EnvironmentObject private var queueSelection: QueueSelectionModel

  let queueWidth: CGFloat

  private var isInteracting: Bool {
    pointerIsInside || edgeIsDropTargeted || queueIsDropTargeted
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      if queueSelection.isCompactQueuePresented {
        QueuePanel(onDropTargetChanged: { queueIsDropTargeted = $0 })
          .frame(width: queueWidth)
          .frame(maxHeight: .infinity)
          .floatingPanel(
            surface: .material,
            accent: nowPlayingPresentation
              .resolvedAccent(artworkTreatments.accent).color
          )
          .padding(.trailing, 10)
          .transition(reduceMotion ? .opacity : .move(edge: .trailing))
      } else {
        Button {
          queueSelection.isCompactQueuePresented = true
        } label: {
          Color.clear
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show queue")
        .help("Show queue")
        .onDrop(of: [.codaQueueDropItem], isTargeted: $edgeIsDropTargeted) { _ in
          // The edge reveals the queue; only the queue itself accepts the drop.
          false
        }
        .onDisappear { edgeIsDropTargeted = false }
      }
    }
    .frame(width: queueSelection.isCompactQueuePresented ? queueWidth + 10 : 20)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    .onHover { pointerIsInside = $0 }
    .task(id: isInteracting) {
      do {
        try await Task.sleep(for: .milliseconds(isInteracting ? 120 : 300))
        guard !Task.isCancelled else { return }
        queueSelection.isCompactQueuePresented = isInteracting
      } catch {}
    }
    .onDisappear { queueSelection.isCompactQueuePresented = false }
    .onExitCommand { queueSelection.isCompactQueuePresented = false }
    .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.20), value: queueSelection.isCompactQueuePresented)
  }
}

func codaQueueIsVisible(
  windowWidth: CGFloat,
  hasEstablishedConnection: Bool,
  compactQueueIsPresented: Bool = false
) -> Bool {
  let contentWidth = max(0, windowWidth - 20)
  let queueWidth = codaQueueWidth(windowWidth: windowWidth)
  return hasEstablishedConnection
    && (compactQueueIsPresented
      || contentWidth - queueWidth - 10 >= PlaybackDockMetrics.minimumMainContentWidth)
}

func codaQueueWidth(windowWidth: CGFloat) -> CGFloat {
  min(330, max(285, windowWidth * 0.22))
}

/// Keeps the queue selection valid without making the root view depend on selection changes.
private struct QueueSelectionReconciler: View {
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var queueSelection: QueueSelectionModel

  var body: some View {
    Color.clear
      .onChange(of: player.queueRevision) {
        queueSelection.reconcile(with: player.queueEntryIDs)
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
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  @ObservedObject var volumePresentation: PlaybackVolumePresentationState

  func makeNSView(context: Context) -> PassthroughDockHostingView {
    let view = PassthroughDockHostingView(rootView: rootView)
    view.hasActiveEntry = player.currentEntry != nil
    return view
  }

  func updateNSView(_ nsView: PassthroughDockHostingView, context: Context) {
    nsView.hasActiveEntry = player.currentEntry != nil
  }

  private var rootView: CompactPlaybackDockHostingRoot {
    CompactPlaybackDockHostingRoot(
      session: session,
      player: player,
      artworkTreatments: artworkTreatments,
      nowPlayingPresentation: nowPlayingPresentation,
      volumePresentation: volumePresentation
    )
  }
}

private struct CompactPlaybackDockHostingRoot: View {
  @ObservedObject var session: AppSession
  @ObservedObject var player: PlayerController
  @ObservedObject var artworkTreatments: ArtworkTreatmentSettings
  @ObservedObject var nowPlayingPresentation: NowPlayingPresentationController
  @ObservedObject var volumePresentation: PlaybackVolumePresentationState

  var body: some View {
    Group {
      if player.currentEntry != nil {
        CompactPlaybackDock()
        .environmentObject(session)
        .environmentObject(player)
        .environmentObject(artworkTreatments)
        .environmentObject(nowPlayingPresentation)
        .environmentObject(volumePresentation)
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

  private var dockWidth: CGFloat {
    PlaybackDockMetrics.collapsedWidth
  }
}

private enum PlaybackDockMetrics {
  static let collapsedWidth: CGFloat = 431
  static let horizontalPadding: CGFloat = 14
  static let controlButtonWidth: CGFloat = 27
  static let progressWidth: CGFloat = 241
  static let minimumMainContentWidth = collapsedWidth + 20
  static let volumePanelWidth: CGFloat = 32
  static let volumePanelHeight: CGFloat = 96
  static let volumePanelBottomInset: CGFloat = 64
  static let volumePanelHorizontalOffset =
    collapsedWidth / 2 - horizontalPadding - controlButtonWidth / 2
}

@MainActor
private final class PlaybackVolumePresentationState: ObservableObject {
  enum HoverTarget: Hashable {
    case button
    case panel
  }

  @Published private(set) var isPresented = false
  private var hoveredTargets: Set<HoverTarget> = []
  private var hideTask: Task<Void, Never>?

  func updateHover(_ target: HoverTarget, isInside: Bool) {
    if isInside {
      hoveredTargets.insert(target)
      hideTask?.cancel()
      guard !isPresented else { return }
      isPresented = true
      return
    }

    hoveredTargets.remove(target)
    hideTask?.cancel()
    hideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(140))
      guard let self, !Task.isCancelled, hoveredTargets.isEmpty else { return }
      isPresented = false
    }
  }

  func dismiss() {
    hideTask?.cancel()
    hideTask = nil
    hoveredTargets.removeAll()
    isPresented = false
  }
}

private struct TitlebarNavigationButton: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  @State private var isHovering = false
  let destination: SidebarDestination

  var body: some View {
    Button {
      nowPlayingPresentation.dismiss()
      session.selectRoot(destination)
    } label: {
      Image(systemName: destination.systemImage)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .background {
          if isHovering {
            Circle()
              .fill(interfaceAccent.opacity(0.18))
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

  private var interfaceAccent: Color {
    nowPlayingPresentation.resolvedAccent(artworkTreatments.accent).color
  }
}

private struct CompactPlaybackDock: View {
  @EnvironmentObject private var player: PlayerController
  @State private var seekPreviewPosition: Double?

  var body: some View {
    HStack(spacing: 10) {
      PlaybackTransportControls()
      playbackSectionDivider
      PlaybackProgressControl(
        timeline: player.timeline,
        previewPosition: $seekPreviewPosition
      )
      playbackSectionDivider
      PlaybackVolumeControl()
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.secondary)
    .padding(.horizontal, PlaybackDockMetrics.horizontalPadding)
    .frame(
      width: PlaybackDockMetrics.collapsedWidth,
      height: 44
    )
    .floatingPanel(capsule: true)
    .fixedSize(horizontal: true, vertical: true)
    .contentShape(.interaction, Capsule())
    .onChange(of: player.currentEntry?.id) {
      seekPreviewPosition = nil
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
    Group {
      if let errorMessage = player.errorMessage {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("Playback failed · Press Play to retry")
            .lineLimit(1)
        }
        .help(errorMessage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback failed")
        .accessibilityHint("Press Play to retry. \(errorMessage)")
      } else {
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
    }
    .frame(width: PlaybackDockMetrics.progressWidth)
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
  @EnvironmentObject private var volumePresentation: PlaybackVolumePresentationState

  var body: some View {
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
    .accessibilityValue("\(Int((player.audibleVolume * 100).rounded())) percent")
    .onHover { isInside in
      volumePresentation.updateHover(.button, isInside: isInside)
    }
  }

  private var volumeSystemImage: String {
    if player.isEffectivelyMuted { return "speaker.slash.fill" }
    if player.volume < 0.34 { return "speaker.wave.1.fill" }
    if player.volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
  }
}

private struct PlaybackVolumePanel: View {
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController

  var body: some View {
    VerticalVolumeSlider(
      value: Binding(
        get: { player.audibleVolume },
        set: { player.setVolume($0) }
      ),
      accent: interfaceAccent
    )
    .frame(width: 22, height: 72)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .floatingPanel(capsule: true)
    .animation(
      .easeInOut(duration: NowPlayingPresentationMotion.duration),
      value: nowPlayingPresentation.isPresented
    )
  }

  private var interfaceAccent: Color {
    nowPlayingPresentation.resolvedAccent(artworkTreatments.accent).color
  }
}

private struct VerticalVolumeSlider: View {
  @Binding var value: Double
  let accent: Color

  var body: some View {
    GeometryReader { geometry in
      let height = max(geometry.size.height, 1)
      let clampedValue = min(max(value, 0), 1)
      let thumbDiameter: CGFloat = 10
      let travel = max(height - thumbDiameter, 1)

      ZStack(alignment: .bottom) {
        Capsule()
          .fill(Color.secondary.opacity(0.28))
          .frame(width: 4, height: travel)

        Capsule()
          .fill(accent)
          .frame(width: 4, height: travel * clampedValue)

        Circle()
          .fill(Color.primary)
          .overlay {
            Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5)
          }
          .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
          .frame(width: thumbDiameter, height: thumbDiameter)
          .offset(y: -travel * clampedValue)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            value = min(max(1 - gesture.location.y / height, 0), 1)
          }
      )
    }
    .help("Volume \(Int((value * 100).rounded())) percent")
    .accessibilityElement()
    .accessibilityLabel("Volume")
    .accessibilityValue("\(Int((value * 100).rounded())) percent")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        value = min(value + 0.05, 1)
      case .decrement:
        value = max(value - 0.05, 0)
      @unknown default:
        break
      }
    }
  }
}

private struct PlaybackSeekBar: View {
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
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
          .fill(activeAccent)
          .frame(width: width * progress, height: 3)

        if isHovering || previewPosition != nil {
          Circle()
            .fill(activeAccent)
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
    .animation(
      .easeInOut(duration: NowPlayingPresentationMotion.duration),
      value: nowPlayingPresentation.isPresented
    )
  }

  private var activeAccent: Color {
    nowPlayingPresentation.resolvedAccent(artworkTreatments.accent).color
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

        Divider()

        VStack(alignment: .leading, spacing: 3) {
          Text("A larger Navidrome artwork cache can make browsing in Coda smoother.")
            .foregroundStyle(.secondary)
          Link(
            "View setup instructions",
            destination: URL(
              string:
                "https://github.com/iamtoolino/coda-macos/blob/main/docs/artwork-performance.md"
            )!
          )
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(20)
      .frame(width: 430)
      .floatingPanel()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tint(ArtworkColor.brandAction.color)
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
  var showsBorder = false
  @ObservedObject private var cache = ArtworkImageCache.shared
  @State private var image: NSImage?

  private struct Request: Hashable {
    let url: URL?
    let cacheGeneration: Int
  }

  private var request: Request {
    Request(url: url, cacheGeneration: cache.generation)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.secondary.opacity(0.12)
        if let image {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        } else {
          ProgressView()
            .controlSize(.small)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      if showsBorder {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(.white.opacity(0.10), lineWidth: 0.7)
      }
    }
    .task(id: request) {
      let request = request
      image = nil
      let loadedImage = await cache.image(for: request.url)
      guard self.request == request else { return }
      image = loadedImage
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

  /// Rows only report frames while a drop or reorder is active (`generation` is non-nil),
  /// so ordinary scrolling does not stream geometry updates into the queue.
  init(generation: Int?, geometry: GeometryProxy) {
    self.generation = generation ?? -1
    frame = generation == nil ? .zero : geometry.frame(in: .named(queueDropCoordinateSpace))
  }
}

/// Queue geometry that actions read but rendering does not depend on, so row visibility and
/// frame updates while scrolling do not invalidate the whole queue panel.
private final class QueueGeometryStore {
  var visibleEntryIDs: Set<UUID> = []
  var groupFrames: [UUID: CGRect] = [:]
  var entryFrames: [UUID: CGRect] = [:]
}

private struct QueueAlbumScrollTarget: Hashable {
  let id: UUID
}

private struct QueuePanel: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var queueSelection: QueueSelectionModel
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  var onDropTargetChanged: ((Bool) -> Void)? = nil
  @State private var groups: [QueueGroup] = []
  @State private var groupedQueueRevision: Int?
  @State private var geometry = QueueGeometryStore()
  @State private var currentEntryIsVisible = false
  @State private var dropGeometryGeneration = 0
  @State private var activeReorderItem: QueueReorderDragItem?
  @State private var insertionTarget: QueueInsertionTarget?
  @State private var isDropTargeted = false
  @State private var isAddingDroppedItems = false
  @State private var viewportHeight: CGFloat = 0
  @FocusState private var queueHasFocus: Bool

  private var interfaceAccent: Color {
    nowPlayingPresentation.resolvedAccent(artworkTreatments.accent).color
  }

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
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
                .onTapGesture {
                  clearSelection()
                  queueHasFocus = true
                }
                .contextMenu {
                  Button("Clear Queue", systemImage: "trash", role: .destructive) {
                    clearSelection()
                    player.clear()
                  }
                }

              let selectedEntryIDSet = Set(selectedEntryIDs ?? [])
              let geometryGeneration = tracksDropGeometry ? dropGeometryGeneration : nil
              LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                  QueueAlbumBlock(
                    group: group,
                    currentIndex: player.currentIndex,
                    isPlaying: player.isPlaying,
                    selectedEntryIDs: selectedEntryIDs,
                    selectedEntryIDSet: selectedEntryIDSet,
                    selectAction: select,
                    trackSelectAction: selectTrack,
                    deleteAction: remove,
                    playAction: player.play,
                    removeEntryAction: player.remove,
                    geometryGeneration: geometryGeneration,
                    groupFrameAction: { generation, frame in
                      guard generation == dropGeometryGeneration else { return }
                      geometry.groupFrames[group.id] = frame
                    },
                    entryFrameAction: { entryID, generation, frame in
                      guard generation == dropGeometryGeneration else { return }
                      geometry.entryFrames[entryID] = frame
                    },
                    dragStateAction: updateDragState,
                    visibilityAction: updateEntryVisibility
                  )
                  .id(QueueAlbumScrollTarget(id: group.id))
                }
              }
              .padding(12)
              // Room for the floating Remove and Return to Playing buttons.
              .padding(.bottom, 40)
            }
            // Overlay scrollers keep the duration column fixed with "always show scroll bars".
            .background(NativeScrollIndicators(visibility: .transient))
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
          let index = player.queueEntryIDs.firstIndex(of: entryID)
        else { return .ignored }
        player.play(index: index)
        return .handled
      }
      .onKeyPress(keys: [.delete, .deleteForward]) { _ in
        guard selectedEntryIDs != nil else { return .ignored }
        removeSelection()
        return .handled
      }
      .onExitCommand {
        if selectedEntryIDs != nil {
          clearSelection()
        } else if nowPlayingPresentation.isPresented {
          nowPlayingPresentation.dismiss()
        }
      }
      .onChange(of: player.queueRevision) {
        let wasEmpty = groups.isEmpty
        refreshGroups()
        refreshDropGeometry()
        if wasEmpty, !player.queue.isEmpty {
          Task { @MainActor in
            // Queue restoration publishes the entries before PlayerController
            // publishes its restored current index. Wait for both that update and
            // the derived album groups to enter the scroll view.
            await Task.yield()
            refreshGroups()
            await Task.yield()
            revealCurrentPlayback(proxy, animated: false)
          }
        }
      }
      .onChange(of: player.queueTopScrollRequest) { _, request in
        clearSelection()
        Task { @MainActor in
          await Task.yield()
          guard request == player.queueTopScrollRequest,
            let firstEntryID = player.queue.first?.id
          else { return }
          refreshGroups()
          await Task.yield()
          guard request == player.queueTopScrollRequest else { return }
          proxy.scrollTo(QueueAlbumScrollTarget(id: firstEntryID), anchor: .top)
        }
      }
      .onChange(of: player.queueCurrentScrollRequest) { _, request in
        clearSelection()
        Task { @MainActor in
          await Task.yield()
          guard request == player.queueCurrentScrollRequest else { return }
          refreshGroups()
          await Task.yield()
          guard request == player.queueCurrentScrollRequest else { return }
          revealCurrentPlayback(proxy, animated: false)
        }
      }
      .onChange(of: player.currentEntry?.id) { oldEntryID, newEntryID in
        updateCurrentEntryVisibility()
        guard newEntryID != nil else { return }
        revealCurrentPlayback(proxy, from: oldEntryID)
      }
      .task {
        refreshGroups()
        await Task.yield()
        revealCurrentPlayback(proxy, animated: false)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .coordinateSpace(.named(queueDropCoordinateSpace))
      .contentShape(Rectangle())
      .help(queueDurationHelp)
      .overlay(alignment: .top) {
        ZStack(alignment: .top) {
          RoundedRectangle(cornerRadius: FloatingPanelStyle.cornerRadius, style: .continuous)
            .strokeBorder(
              interfaceAccent.opacity(isDropTargeted ? 0.92 : 0),
              lineWidth: 2
            )
            .padding(1)

          if let insertionTarget {
            Rectangle()
              .fill(interfaceAccent)
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
      .overlay(alignment: .bottomTrailing) {
        // One glass container, so the buttons morph together as they appear and disappear.
        GlassEffectContainer(spacing: 7) {
        HStack(spacing: 7) {
          if shouldShowReturnToPlaying {
            Button("Return to Playing Track", systemImage: "scope") {
              revealCurrentPlayback(proxy)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .padding(5)
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Return to Playing Track")
            .transition(.opacity)
          }

          if selectedEntryIDs?.isEmpty == false {
            // Deselect sits next to Remove, since Esc alone is easy to miss.
            HStack(spacing: 0) {
              Button("Deselect All", systemImage: "xmark") {
                clearSelection()
              }
              .help("Deselect All (Esc)")
              Divider()
                .frame(height: 16)
              Button(selectionRemovalHelp, systemImage: "trash", role: .destructive) {
                removeSelection()
              }
              .help("\(selectionRemovalHelp) (⌫)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(QueueCapsuleSegmentStyle())
            .glassEffect(.regular.interactive(), in: Capsule())
            .transition(.opacity)
          }
        }
        }
        .padding(.bottom, 12)
        .padding(.trailing, 16)
      }
      .animation(.easeOut(duration: 0.14), value: shouldShowReturnToPlaying)
      .animation(.easeOut(duration: 0.14), value: selectedEntryIDs?.isEmpty == false)
      .animation(.easeOut(duration: 0.16), value: isDropTargeted)
      .dropDestination(for: QueueDropItem.self) { items, dropSession in
        handleDrop(items, at: dropSession.location)
      }
      .onDropSessionUpdated(updateDropSession)
      .onChange(of: isDropTargeted) { _, targeted in
        onDropTargetChanged?(targeted)
      }
      .onDisappear { onDropTargetChanged?(false) }
      .dropConfiguration { _ in
        DropConfiguration(operation: activeReorderItem == nil ? .copy : .move)
      }
    }
  }

  private var shouldShowReturnToPlaying: Bool {
    player.currentEntry != nil && !currentEntryIsVisible
  }

  private var tracksDropGeometry: Bool {
    activeReorderItem != nil || isDropTargeted
  }

  private func refreshGroups() {
    guard groupedQueueRevision != player.queueRevision else { return }
    groups = queueGroups(player.queue)
    groupedQueueRevision = player.queueRevision
  }

  private var selectedEntryIDs: [UUID]? {
    queueSelection.selectedEntryIDs
  }

  private var queueDurationHelp: String {
    let trackCount = player.queue.count
    let duration = formatCollectionDuration(player.queueDurationSeconds)
    let count = "\(trackCount) \(trackCount == 1 ? "track" : "tracks")"
    let summary = duration.isEmpty ? count : "\(count) · \(duration)"
    return "Queue: \(summary)"
  }

  private var selectionRemovalHelp: String {
    let count = selectedEntryIDs?.count ?? 0
    return count == 1 ? "Remove Track" : "Remove \(countLabel(count, "Track"))"
  }

  private func select(_ entryIDs: [UUID], modifiers: TrackSelectionModifiers) {
    queueSelection.select(
      entryIDs,
      orderedBy: player.queueEntryIDs,
      modifiers: modifiers
    )
    queueHasFocus = true
  }

  private func selectTrack(_ entryID: UUID, modifiers: TrackSelectionModifiers) {
    select([entryID], modifiers: modifiers)
  }

  private func remove(_ entryIDs: [UUID]) {
    player.remove(entryIDs: entryIDs)
    queueSelection.remove(entryIDs)
  }

  private func removeSelection() {
    guard let selectedEntryIDs else { return }
    player.remove(entryIDs: selectedEntryIDs)
    clearSelection()
  }

  private func clearSelection() {
    queueSelection.clear()
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

    if dropSession.phase == .entering, activeReorderItem == nil {
      refreshDropGeometry()
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
    let measuredEntries = visibleQueueDropMeasurements(
      entries: player.queue,
      frames: geometry.entryFrames,
      visibleEntryIDs: geometry.visibleEntryIDs
    )
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
      let groupFrame = geometry.groupFrames[group.id]
    else { return fallback }
    return groupFrame.minY
  }

  private var fallbackInsertionTarget: QueueInsertionTarget {
    let measuredBottom = geometry.entryFrames.values.map(\.maxY).max()
      ?? geometry.groupFrames.values.map(\.maxY).max()
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
    geometry.entryFrames.removeAll(keepingCapacity: true)
    geometry.groupFrames.removeAll(keepingCapacity: true)
    dropGeometryGeneration &+= 1
    insertionTarget = nil

    let entryIDs = Set(player.queueEntryIDs)
    if let activeReorderItem,
      !Set(activeReorderItem.entryIDs).isSubset(of: entryIDs)
    {
      clearDropState()
    }
  }

  private func updateEntryVisibility(_ entryID: UUID, _ isVisible: Bool) {
    if isVisible {
      geometry.visibleEntryIDs.insert(entryID)
    } else {
      geometry.visibleEntryIDs.remove(entryID)
      geometry.entryFrames[entryID] = nil
    }
    if entryID == player.currentEntry?.id {
      updateCurrentEntryVisibility()
    }
  }

  private func updateCurrentEntryVisibility() {
    let isVisible = player.currentEntry.map { geometry.visibleEntryIDs.contains($0.id) } ?? false
    if currentEntryIsVisible != isVisible {
      currentEntryIsVisible = isVisible
    }
  }

  private func revealCurrentPlayback(
    _ proxy: ScrollViewProxy,
    from oldEntryID: UUID? = nil,
    animated: Bool = true
  ) {
    guard let currentID = player.currentEntry?.id,
      let currentGroup = groups.first(where: { $0.entryIDs.contains(currentID) })
    else { return }

    let targetIsBelow = queueRevealTargetIsBelow(
      oldEntryID: oldEntryID,
      currentEntryID: currentID
    )
    let oldGroupID = oldEntryID.flatMap { oldID in
      groups.first(where: { $0.entryIDs.contains(oldID) })?.id
    }
    let currentOffset = currentGroup.entryIDs.firstIndex(of: currentID) ?? 0
    let discHeaderOffsets = currentGroup.entries.indices.filter {
      currentGroup.beginsDiscSection(at: $0)
    }
    guard let action = queueTrackBasedRevealAction(
      trackCount: currentGroup.entries.count,
      currentOffset: currentOffset,
      discHeaderOffsets: discHeaderOffsets,
      isAutomatic: oldEntryID != nil,
      automaticWithinSameAlbum: oldEntryID != nil && oldGroupID == currentGroup.id,
      previousTrackIsVisible: oldEntryID.map(geometry.visibleEntryIDs.contains) ?? true,
      albumTracksAreFullyVisible: currentGroup.entryIDs.allSatisfy(
        geometry.visibleEntryIDs.contains),
      currentTrackIsVisible: geometry.visibleEntryIDs.contains(currentID),
      targetIsBelow: targetIsBelow
    ) else { return }

    let scroll = {
      let target = QueueAlbumScrollTarget(id: currentGroup.id)
      switch action {
      case .top:
        proxy.scrollTo(target, anchor: .top)
      case .bottom:
        proxy.scrollTo(target, anchor: .bottom)
      case .position(let anchorY):
        proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: anchorY))
      }
    }
    if animated {
      withAnimation(.easeInOut(duration: 0.28), scroll)
    } else {
      scroll()
    }
  }

  private func queueRevealTargetIsBelow(
    oldEntryID: UUID?,
    currentEntryID: UUID
  ) -> Bool {
    let queueIDs = player.queueEntryIDs
    guard let currentIndex = queueIDs.firstIndex(of: currentEntryID) else { return false }
    if let oldEntryID,
      let oldIndex = queueIDs.firstIndex(of: oldEntryID)
    {
      return currentIndex >= oldIndex
    }
    let visibleIndices = geometry.visibleEntryIDs.compactMap { queueIDs.firstIndex(of: $0) }
    guard let firstVisible = visibleIndices.min() else { return currentIndex > 0 }
    return currentIndex >= firstVisible
  }

}

func visibleQueueDropMeasurements(
  entries: [QueueEntry],
  frames: [UUID: CGRect],
  visibleEntryIDs: Set<UUID>
) -> [(QueueEntry, CGRect)] {
  entries.compactMap { entry in
    guard visibleEntryIDs.contains(entry.id),
      let frame = frames[entry.id]
    else { return nil }
    return (entry, frame)
  }
  .sorted { $0.1.midY < $1.1.midY }
}

enum QueueTrackBasedRevealAction: Equatable {
  case top
  case bottom
  case position(CGFloat)
}

func queueTrackBasedRevealAction(
  trackCount: Int,
  currentOffset: Int,
  discHeaderOffsets: [Int],
  isAutomatic: Bool,
  automaticWithinSameAlbum: Bool,
  previousTrackIsVisible: Bool,
  albumTracksAreFullyVisible: Bool,
  currentTrackIsVisible: Bool,
  targetIsBelow: Bool
) -> QueueTrackBasedRevealAction? {
  let fittingTrackLimit = 16
  if isAutomatic, !previousTrackIsVisible { return nil }

  if trackCount <= fittingTrackLimit {
    guard !albumTracksAreFullyVisible else { return nil }
    if automaticWithinSameAlbum, currentTrackIsVisible { return nil }
    return targetIsBelow ? .bottom : .top
  }

  if currentOffset == 0 || (isAutomatic && !automaticWithinSameAlbum) {
    return .top
  }
  if isAutomatic, currentTrackIsVisible { return nil }

  let albumHeaderRows: CGFloat = 2
  let visibleRows = albumHeaderRows + CGFloat(fittingTrackLimit)
  let forwardContextRows: CGFloat = 5
  let discHeadersBeforeCurrent = discHeaderOffsets.filter { $0 <= currentOffset }.count
  let totalRows = albumHeaderRows + CGFloat(trackCount + discHeaderOffsets.count)
  let currentBottom =
    albumHeaderRows + CGFloat(currentOffset + 1 + discHeadersBeforeCurrent)
  let scrollableRows = max(1, totalRows - visibleRows)
  let desiredOffset = currentBottom + forwardContextRows - visibleRows
  let anchorY = min(1, max(0, desiredOffset / scrollableRows))
  return .position(anchorY)
}

private struct QueueAlbumBlock: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  @State private var album: RemoteAlbum?
  let group: QueueGroup
  let currentIndex: Int?
  let isPlaying: Bool
  let selectedEntryIDs: [UUID]?
  let selectedEntryIDSet: Set<UUID>
  let selectAction: ([UUID], TrackSelectionModifiers) -> Void
  let trackSelectAction: (UUID, TrackSelectionModifiers) -> Void
  let deleteAction: ([UUID]) -> Void
  let playAction: (Int) -> Void
  let removeEntryAction: (UUID) -> Void
  let geometryGeneration: Int?
  let groupFrameAction: (Int, CGRect) -> Void
  let entryFrameAction: (UUID, Int, CGRect) -> Void
  let dragStateAction: (QueueReorderDragItem, Bool) -> Void
  let visibilityAction: (UUID, Bool) -> Void
  @Environment(\.appearsActive) private var appearsActive

  private var interfaceAccent: Color {
    nowPlayingPresentation.resolvedAccent(artworkTreatments.accent).color
  }

  var body: some View {
    let selectedDiscSections = Set(group.discSections.indices.filter {
      group.discSections[$0].entryIDs.allSatisfy(selectedEntryIDSet.contains)
    })
    let isGroupSelected = group.entryIDs.allSatisfy(selectedEntryIDSet.contains)
    // A selected album is filled once as a block; standalone tracks fill their own row.
    let fillsBlock = isGroupSelected && !group.isStandalone
    VStack(alignment: .leading, spacing: 5) {
      if !group.isStandalone {
        QueueAlbumHeader(
          group: group,
          album: album,
          dragEntryIDs: queueCollectionDragIDs(
            collection: group.entryIDs,
            selected: selectedEntryIDs ?? []
          ),
          selectAction: { modifiers in selectAction(group.entryIDs, modifiers) },
          deleteAction: { deleteAction(group.entryIDs) },
          dragStateAction: dragStateAction
        )
      }
      ForEach(Array(group.entries.enumerated()), id: \.element.id) { offset, entry in
        if !group.isStandalone, group.beginsDiscSection(at: offset) {
          let discEntryIDs = group.discEntryIDs(at: offset)
          QueueDiscHeader(
            number: group.discNumber(at: offset),
            subtitle: group.discSubtitle(at: offset),
            durationSeconds: group.discDuration(at: offset),
            isSelected: !fillsBlock
              && (group.discSectionIndex(at: offset).map(selectedDiscSections.contains) ?? false),
            selectAction: { modifiers in selectAction(discEntryIDs, modifiers) },
            deleteAction: { deleteAction(discEntryIDs) }
          )
          .padding(.top, offset == 0 ? 3 : 7)
          .padding(.horizontal, 2)
        }
        QueueTrackRow(
          entry: entry,
          album: album,
          isStandalone: group.isStandalone,
          isCurrent: currentIndex == group.startIndex + offset,
          isPlaying: isPlaying,
          isTrackSelected: !fillsBlock && selectedEntryIDSet.contains(entry.id),
          isCollectionSelected: !fillsBlock && group.showsDiscHeadings
            && (group.discSectionIndex(at: offset).map(selectedDiscSections.contains) ?? false),
          dragEntryIDs: selectedEntryIDSet.contains(entry.id)
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
    .padding(.horizontal, 6)
    // Consecutive standalone tracks sit closer together than album blocks.
    .padding(.vertical, group.isStandalone ? 3 : 6)
    .contentShape(Rectangle())
    .onGeometryChange(for: QueueDropGeometryMeasurement.self) { geometry in
      QueueDropGeometryMeasurement(generation: geometryGeneration, geometry: geometry)
    } action: { measurement in
      groupFrameAction(measurement.generation, measurement.frame)
    }
    .background {
      if fillsBlock {
        QueueSelectionBackground(accent: interfaceAccent, appearsActive: appearsActive, cornerRadius: 9)
      }
    }
    .task(id: albumID) {
      await loadAlbum()
    }
  }

  private var albumID: String? {
    group.albumID
  }

  @MainActor
  private func loadAlbum() async {
    guard let albumID else {
      album = nil
      return
    }
    // Queue controls remain available if optional context-menu metadata cannot load.
    let loadedAlbum = await session.albumMetadata(id: albumID)
    guard self.albumID == albumID else { return }
    album = loadedAlbum
  }
}

private struct QueueAlbumHeader: View {
  let group: QueueGroup
  let album: RemoteAlbum?
  let dragEntryIDs: [UUID]
  let selectAction: (TrackSelectionModifiers) -> Void
  let deleteAction: () -> Void
  let dragStateAction: (QueueReorderDragItem, Bool) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button {
        selectAction(currentTrackSelectionModifiers())
      } label: {
        TrackListAlbumLabel(
          artworkURL: group.entries.first?.artworkURL,
          title: group.albumTitle,
          artist: album?.artistName ?? group.artist,
          detail: group.detail,
          compact: true
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(NoPressEffectButtonStyle())
    }
    .accessibilityAction { selectAction([]) }
    .draggable(QueueDropItem.reorder(.albumBlock(dragEntryIDs)))
    .dragConfiguration(.codaInternal(allowMove: true))
    .onDragSessionUpdated { dragSession in
      let item = QueueReorderDragItem.albumBlock(dragEntryIDs)
      dragStateAction(item, dragSession.phase == .initial || dragSession.phase == .active)
    }
    .contextMenu {
      QueueItemContextMenu(
        albumID: albumID,
        album: album,
        removalTitle: "Remove Album from Queue",
        deleteAction: deleteAction,
        artistCredit: album?.artistCredit ?? ArtistCredit(
          name: group.artist, artists: group.entries.first?.albumArtists ?? []
        )
      )
    }
  }

  private var albumID: String? {
    group.albumID
  }
}

private struct QueueCapsuleSegmentStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: 34, height: 34)
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.6 : 1)
  }
}

private struct NoPressEffectButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

private struct QueueItemContextMenu: View {
  @EnvironmentObject private var session: AppSession
  let albumID: String?
  let album: RemoteAlbum?
  let removalTitle: String
  let deleteAction: () -> Void
  var artistCredit: ArtistCredit? = nil

  var body: some View {
    if let albumID {
      Button("Show Album", systemImage: "square.stack") {
        session.open(.album(albumID))
      }

      if let artist = (artistCredit ?? album?.artistCredit)?.artists.first {
        Button("Show Artist", systemImage: "person") {
          session.open(.artist(artist.id))
        }
      }

      Divider()
    }

    Button(role: .destructive, action: deleteAction) {
      Label(removalTitle, systemImage: "trash")
    }
  }
}

private struct QueueDiscHeader: View {
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  let number: Int
  let subtitle: String?
  let durationSeconds: Int
  let isSelected: Bool
  @Environment(\.appearsActive) private var appearsActive
  let selectAction: (TrackSelectionModifiers) -> Void
  let deleteAction: () -> Void

  private var interfaceAccent: Color {
    nowPlayingPresentation.resolvedAccent(artworkTreatments.accent).color
  }

  var body: some View {
    HStack(spacing: 6) {
      Button {
        selectAction(currentTrackSelectionModifiers())
      } label: {
        DiscSectionHeading(
          number: number,
          subtitle: subtitle,
          durationSeconds: durationSeconds,
          compact: true
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(NoPressEffectButtonStyle())
      .accessibilityAction { selectAction([]) }
    }
    .padding(.horizontal, 5)
    .padding(.vertical, 4)
    .background {
      if isSelected {
        QueueSelectionBackground(accent: interfaceAccent, appearsActive: appearsActive, cornerRadius: 9)
          // Reach the album block's edges, so every selection shares one extent and radius.
          .padding(.horizontal, -8)
      }
    }
    .contextMenu {
      Button("Remove Disc from Queue", role: .destructive, action: deleteAction)
    }
  }
}

private struct QueueTrackRow: View {
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  let entry: QueueEntry
  let album: RemoteAlbum?
  let isStandalone: Bool
  let isCurrent: Bool
  let isPlaying: Bool
  let isTrackSelected: Bool
  let isCollectionSelected: Bool
  let dragEntryIDs: [UUID]
  @Environment(\.appearsActive) private var appearsActive
  let selectAction: (TrackSelectionModifiers) -> Void
  let playAction: () -> Void
  let removeAction: () -> Void
  let geometryGeneration: Int?
  let frameAction: (Int, CGRect) -> Void
  let dragStateAction: (QueueReorderDragItem, Bool) -> Void
  let visibilityAction: (UUID, Bool) -> Void

  private var activeAccent: Color {
    nowPlayingPresentation.resolvedAccent(artworkTreatments.accent).color
  }

  var body: some View {
    Group {
      if isStandalone {
        TrackListStandaloneLabel(
          artworkURL: entry.artworkURL,
          title: entry.title,
          artist: entry.artist,
          durationSeconds: entry.durationSeconds,
          isCurrent: isCurrent,
          isPlaying: isPlaying,
          accent: activeAccent,
          compact: true
        )
      } else {
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
            isCurrent ? activeAccent : Color.secondary
          )
          .frame(width: 24, alignment: .trailing)

          TrackRowLabel(
            title: entry.title,
            artist: entry.artist,
            isCompilation: album?.isCompilation ?? entry.isCompilation ?? false,
            titleColor: isCurrent ? activeAccent : .primary,
            titleFont: .callout,
            artistFont: .caption2
          )
          Spacer(minLength: 4)
          Text(formatDuration(entry.durationSeconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
    .contentShape(Rectangle())
    .padding(.vertical, 3)
    .background {
      if isTrackSelected || isCollectionSelected {
        QueueSelectionBackground(accent: activeAccent, appearsActive: appearsActive, cornerRadius: 9)
          // Reach the album block's edges, so every selection shares one extent and radius.
          .padding(.horizontal, -6)
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
    .animation(
      .easeInOut(duration: NowPlayingPresentationMotion.duration),
      value: nowPlayingPresentation.isPresented
    )
    .draggable(QueueDropItem.reorder(.tracks(dragEntryIDs)))
    .dragConfiguration(.codaInternal(allowMove: true))
    .onDragSessionUpdated { dragSession in
      let item = QueueReorderDragItem.tracks(dragEntryIDs)
      dragStateAction(item, dragSession.phase == .initial || dragSession.phase == .active)
    }
    .onGeometryChange(for: QueueDropGeometryMeasurement.self) { geometry in
      QueueDropGeometryMeasurement(generation: geometryGeneration, geometry: geometry)
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
        deleteAction: removeAction,
        artistCredit: entry.artistCredit
      )
    }
  }
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

/// The queue's one selection style, drawn once per selected item: an accent fill and outline
/// while the window is key, neutral grey otherwise.
struct QueueSelectionBackground: View {
  let accent: Color
  let appearsActive: Bool
  let cornerRadius: CGFloat

  var body: some View {
    let tint = appearsActive ? accent : Color.secondary
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(tint.opacity(appearsActive ? 0.15 : 0.10))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(tint.opacity(0.42), lineWidth: 1)
      }
      .allowsHitTesting(false)
  }
}

/// "1 album", "3 albums".
func countLabel(_ count: Int, _ singular: String, plural: String? = nil) -> String {
  "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
}

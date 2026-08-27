import AppKit
import Combine
import Foundation

struct PlaybackArtworkPreparationRequest: Equatable {
  let standardIdentity: String?
  let playbackKey: String?
  let standardArtworkURL: URL?
  let nowPlayingArtworkURL: URL?
  let cacheGeneration: Int

  init(current: QueueEntry?, cacheGeneration: Int) {
    standardIdentity = current?.artworkThemeIdentity
    playbackKey = current?.nowPlayingPlaybackKey
    standardArtworkURL = current?.artworkURL
    nowPlayingArtworkURL = current?.nowPlayingArtworkURL ?? current?.artworkURL
    self.cacheGeneration = cacheGeneration
  }
}

struct PlaybackArtworkPrefetchRequest: Equatable {
  let currentArtworkURL: URL?
  let nextArtworkURL: URL?
  let cacheGeneration: Int

  init(current: QueueEntry?, next: QueueEntry?, cacheGeneration: Int) {
    currentArtworkURL = current?.nowPlayingArtworkURL ?? current?.artworkURL
    nextArtworkURL = next?.nowPlayingArtworkURL ?? next?.artworkURL
    self.cacheGeneration = cacheGeneration
  }
}

@MainActor
final class PlaybackArtworkCoordinator: ObservableObject {
  typealias ImageLoader = @MainActor (URL?) async -> NSImage

  private let session: AppSession
  private let player: PlayerController
  private let treatments: ArtworkTreatmentSettings
  private let presentation: NowPlayingPresentationController
  private let imageLoader: ImageLoader
  private var standardTask: Task<Void, Never>?
  private var nowPlayingTask: Task<Void, Never>?
  private var prefetchTask: Task<Void, Never>?
  private var currentRequest: PlaybackArtworkPreparationRequest?
  private var cancellables: Set<AnyCancellable> = []

  init(
    session: AppSession,
    player: PlayerController,
    treatments: ArtworkTreatmentSettings,
    presentation: NowPlayingPresentationController,
    imageLoader: @escaping ImageLoader = { url in
      await ArtworkImageCache.shared.image(for: url)
    }
  ) {
    self.session = session
    self.player = player
    self.treatments = treatments
    self.presentation = presentation
    self.imageLoader = imageLoader

    Publishers.CombineLatest(
      player.$artworkQueueContext,
      ArtworkImageCache.shared.$generation
    )
    .map { context, generation in
      return PlaybackArtworkPreparationRequest(
        current: context.current,
        cacheGeneration: generation
      )
    }
    .removeDuplicates()
    .sink { @MainActor [weak self] request in
      self?.prepare(request)
    }
    .store(in: &cancellables)

    Publishers.CombineLatest(
      player.$artworkQueueContext,
      ArtworkImageCache.shared.$generation
    )
    .map { context, generation in
      PlaybackArtworkPrefetchRequest(
        current: context.current,
        next: context.next,
        cacheGeneration: generation
      )
    }
    .removeDuplicates()
    .sink { @MainActor [weak self] request in
      self?.prefetch(request)
    }
    .store(in: &cancellables)
  }

  private func prepare(_ request: PlaybackArtworkPreparationRequest) {
    currentRequest = request
    standardTask?.cancel()
    nowPlayingTask?.cancel()

    guard let standardIdentity = request.standardIdentity,
      let playbackKey = request.playbackKey
    else {
      presentation.clearPreparedTheme()
      applyDisplayContext()
      return
    }

    treatments.promoteDisplayedArtworkToPlayback(ifIdentity: standardIdentity)
    applyDisplayContext()

    standardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let image = await self.imageLoader(request.standardArtworkURL)
      guard !Task.isCancelled, self.currentRequest == request else { return }
      self.treatments.rememberPlaybackArtwork(
        image,
        accent: AlbumArtworkLoader.extractAccent(from: image),
        identity: standardIdentity
      )
      self.applyDisplayContext()
    }

    nowPlayingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let image = await self.imageLoader(request.nowPlayingArtworkURL)
      guard !Task.isCancelled, self.currentRequest == request else { return }
      self.presentation.prepare(
        playbackKey: playbackKey,
        artwork: image,
        accent: AlbumArtworkLoader.extractAccent(from: image)
      )
    }
  }

  private func prefetch(_ request: PlaybackArtworkPrefetchRequest) {
    prefetchTask?.cancel()
    guard let nextURL = request.nextArtworkURL,
      nextURL != request.currentArtworkURL
    else { return }

    prefetchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      _ = await self.imageLoader(nextURL)
    }
  }

  private func applyDisplayContext() {
    treatments.applyDisplayContext(
      .resolve(
        hasEstablishedConnection: session.hasEstablishedConnection,
        displayedAlbumID: session.path.last?.displayedAlbumID,
        playbackIdentity: player.currentEntry?.artworkThemeIdentity
      )
    )
  }
}

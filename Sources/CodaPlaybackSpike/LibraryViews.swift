import AppKit
import SwiftUI

private let floatingPlaybackDockScrollClearance: CGFloat = 78

private struct HomeData {
  let newest: [RemoteAlbum]
  let recentReleases: [RemoteAlbum]
  let recentArtists: [RemoteArtist]
  let recentlyPlayed: [RemoteAlbum]
  let playlists: [RemotePlaylist]
  let playQueue: RemotePlayQueue?
}

struct HomeView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var queueHandoff: QueueHandoffCoordinator
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let resetToken: UUID?

  @StateObject private var artworkLoader = AlbumArtworkLoader()
  @State private var data: HomeData?
  @State private var isLoading = false
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        if isLoading, data == nil {
          LibraryLoadingView(label: "Loading Home…")
        } else if let errorMessage, data == nil {
          LibraryErrorView(title: "Could Not Load Home", message: errorMessage) {
            Task { await load() }
          }
        }

        if let queue = offeredContinueQueue {
          ContinuePlayingCard(queue: queue) {
            session.markPlayQueueHandled(queue)
            session.play(
              songs: queue.songs,
              startAt: queue.resolvedCurrentIndex,
              positionMilliseconds: queue.position ?? 0,
              with: player
            )
          }
        }

        if let artists = data?.recentArtists, !artists.isEmpty {
          ArtistShelf(title: "Recently Added Artists", artists: artists) {
            session.open(.artistsCollection(.recentlyAdded))
          }
        }

        if let albums = data?.newest {
          AlbumShelf(title: "Recently Added Albums", albums: albums) {
            session.open(.albumCollection(.recentlyAdded))
          }
        }

        if let albums = data?.recentReleases, !albums.isEmpty {
          AlbumShelf(title: "Recent Releases", albums: albums) {
            session.open(.albumCollection(.recentReleases))
          }
        }

        if let albums = data?.recentlyPlayed, !albums.isEmpty {
          AlbumShelf(title: "Recently Played", albums: albums) {
            session.open(.albumCollection(.recentlyPlayed))
          }
        }

        if let playlists = data?.playlists, !playlists.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            SectionHeading(title: "Playlists")
            ForEach(playlists) { playlist in
              PlaylistHomeRow(playlist: playlist)
            }
          }
        }

        if let errorMessage, data != nil {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, 22)
        }
      }
      .padding(.vertical, 20)
      .padding(.bottom, floatingPlaybackDockScrollClearance)
      .background(TransientScrollIndicators())
    }
    .navigationTitle("Home")
    .focusedSceneValue(
      \.codaRefreshAction,
      CodaRefreshAction { Task { await load() } }
    )
    .task(id: resetToken) {
      await load()
    }
    .onAppear {
      artworkTreatments.restorePlaybackArtwork()
    }
  }

  @MainActor
  private func load() async {
    guard let client = session.client else { return }
    isLoading = true
    errorMessage = nil
    do {
      async let newestTask = client.albums(.recentlyAdded, size: 24)
      async let releasesTask = client.albums(.recentReleases, size: 24)
      async let artistsTask = client.artists()
      async let recentTask = client.albums(.recentlyPlayed, size: 20)
      async let playlistsTask = client.playlists()
      async let queueTask = client.playQueue()

      let savedQueue = try await queueTask
      queueHandoff.observeRemoteQueue(savedQueue)
      autoRestoreIfNeeded(savedQueue)
      let newest = try await newestTask
      let artists = try await artistsTask
      let loadedData = HomeData(
        newest: newest,
        recentReleases: try await releasesTask,
        recentArtists: recentArtists(newestAlbums: newest, artists: artists),
        recentlyPlayed: try await recentTask,
        playlists: try await playlistsTask,
        playQueue: savedQueue
      )
      data = loadedData
      if player.currentEntry == nil, !artworkTreatments.hasPlaybackArtwork {
        let queue = loadedData.playQueue
        let currentQueueIndex = queue?.resolvedCurrentIndex ?? 0
        let queueSong = queue?.songs[safe: currentQueueIndex]
        let queueCoverID = queueSong?.albumArtworkID
        let recentAlbum = loadedData.recentlyPlayed.first
        let recentCoverID = recentAlbum?.coverArt ?? recentAlbum?.id
        let newestAlbum = loadedData.newest.first
        let newestCoverID = newestAlbum?.coverArt ?? newestAlbum?.id
        let homeCoverID = queueCoverID ?? recentCoverID ?? newestCoverID
        await artworkLoader.load(url: session.artworkURL(id: homeCoverID, size: 900))
        if player.currentEntry == nil, !artworkTreatments.hasPlaybackArtwork,
          let image = artworkLoader.image
        {
          artworkTreatments.rememberPlaybackArtwork(
            image,
            accent: artworkLoader.accent,
            identity: queueSong?.albumId ?? recentAlbum?.id ?? newestAlbum?.id
          )
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  private var offeredContinueQueue: RemotePlayQueue? {
    guard let queue = queueHandoff.remoteQueue,
      !queue.songs.isEmpty,
      !queue.wasWrittenByThisCoda,
      !player.isPlaying,
      !session.hasHandledPlayQueue(queue)
    else { return nil }
    return queue
  }

  private func autoRestoreIfNeeded(_ queue: RemotePlayQueue?) {
    guard let queue,
      queue.wasWrittenByThisCoda,
      !queue.songs.isEmpty,
      player.queue.isEmpty,
      !session.hasHandledPlayQueue(queue)
    else { return }

    session.markPlayQueueHandled(queue)
    session.restore(
      songs: queue.songs,
      startAt: queue.resolvedCurrentIndex,
      positionMilliseconds: queue.position ?? 0,
      with: player
    )
  }
}

struct SearchView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let resetToken: UUID?

  @FocusState private var searchFieldIsFocused: Bool
  @State private var query = ""
  @State private var results = LibrarySearchResults.empty
  @State private var completedQuery: String?
  @State private var isSearching = false
  @State private var loadingSongID: String?
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        searchField

        if normalizedQuery.count < 2 {
          searchPlaceholder(
            title: "Search your library",
            message: "Find artists, albums, and songs."
          )
        } else if completedQuery == normalizedQuery, results.isEmpty, errorMessage == nil {
          searchPlaceholder(
            title: "No results for “\(normalizedQuery)”",
            message: "Try a different artist, album, or song title."
          )
        } else {
          if !results.artists.isEmpty {
            ArtistShelf(title: "Artists", artists: results.artists, onMore: nil)
          }

          if !results.albums.isEmpty {
            AlbumShelf(title: "Albums", albums: results.albums, onMore: nil)
          }

          if !results.songs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
              SectionHeading(title: "Songs")
                .padding(.bottom, 4)
              ForEach(results.songs) { song in
                SearchSongRow(song: song, isLoading: loadingSongID == song.id) {
                  Task { await play(song) }
                }
                Divider()
                  .padding(.horizontal, 22)
                  .opacity(0.14)
              }
            }
          }
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, 22)
        }
      }
      .padding(.vertical, 20)
      .padding(.bottom, floatingPlaybackDockScrollClearance)
    }
    .navigationTitle("Search")
    .focusedSceneValue(
      \.codaRefreshAction,
      CodaRefreshAction { Task { await performSearch(for: query) } }
    )
    .task(id: query) {
      await performSearch(for: query)
    }
    .task(id: resetToken) {
      await Task.yield()
      searchFieldIsFocused = true
    }
    .onAppear {
      artworkTreatments.restorePlaybackArtwork()
      searchFieldIsFocused = true
    }
    .onExitCommand {
      if query.isEmpty {
        session.selectRoot(.home)
      } else {
        query = ""
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Artists, albums, and songs", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFieldIsFocused)
        .submitLabel(.search)

      if isSearching {
        ProgressView()
          .controlSize(.small)
      } else if !query.isEmpty {
        Button("Clear Search", systemImage: "xmark.circle.fill") {
          query = ""
          searchFieldIsFocused = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .font(.body)
    .padding(.horizontal, 13)
    .frame(maxWidth: 520)
    .frame(height: 38)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
    }
    .padding(.horizontal, 22)
  }

  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @MainActor
  private func performSearch(for rawQuery: String) async {
    let requestedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    isSearching = false
    errorMessage = nil

    guard requestedQuery.count >= 2 else {
      results = .empty
      completedQuery = nil
      return
    }

    do {
      try await Task.sleep(for: .milliseconds(250))
      try Task.checkCancellation()
      guard requestedQuery == normalizedQuery, let client = session.client else { return }
      isSearching = true
      let loadedResults = try await client.search(requestedQuery)
      try Task.checkCancellation()
      guard requestedQuery == normalizedQuery else { return }
      results = loadedResults
      completedQuery = requestedQuery
      isSearching = false
    } catch is CancellationError {
      if requestedQuery == normalizedQuery {
        isSearching = false
      }
    } catch {
      guard requestedQuery == normalizedQuery else { return }
      isSearching = false
      completedQuery = requestedQuery
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func play(_ song: RemoteSong) async {
    guard loadingSongID == nil, let client = session.client else { return }
    loadingSongID = song.id
    defer { loadingSongID = nil }

    do {
      if let albumID = song.albumId, !albumID.isEmpty {
        let page = try await client.album(id: albumID)
        let index = page.songs.firstIndex(where: { $0.id == song.id }) ?? 0
        session.play(songs: page.songs, startAt: index, with: player)
      } else {
        session.play(songs: [song], with: player)
      }
    } catch {
      errorMessage = "Could not play \(song.title): \(error.localizedDescription)"
    }
  }

  private func searchPlaceholder(title: String, message: String) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: "magnifyingglass")
    } description: {
      Text(message)
    }
    .frame(maxWidth: .infinity, minHeight: 360)
  }
}

private struct ArtistsLoadRequest: Hashable {
  let kind: ArtistCollectionKind
  let resetToken: UUID?
}

struct ArtistsView: View {
  @EnvironmentObject private var session: AppSession
  let resetToken: UUID?

  @State private var selectedKind: ArtistCollectionKind
  @State private var artists: [RemoteArtist]?
  @State private var isLoading = false
  @State private var errorMessage: String?

  init(kind: ArtistCollectionKind, resetToken: UUID?) {
    self.resetToken = resetToken
    _selectedKind = State(initialValue: kind)
  }

  var body: some View {
    Group {
      if isLoading, artists == nil {
        LibraryLoadingView(label: "Loading Artists…")
      } else if let errorMessage, artists == nil {
        LibraryErrorView(title: "Could Not Load Artists", message: errorMessage) {
          Task { await load(selectedKind) }
        }
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(selectedKind.title)
                .font(.title2.bold())
              Spacer(minLength: 12)
              artistOrderMenu
            }

            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 145, maximum: 190), spacing: 18)],
              alignment: .leading,
              spacing: 22
            ) {
              ForEach(artists ?? []) { artist in
                ArtistCard(artist: artist)
              }
            }
          }
          .padding(.horizontal, 22)
          .padding(.top, 18)
          .padding(.bottom, 22)
          .padding(.bottom, floatingPlaybackDockScrollClearance)
        }
      }
    }
    .navigationTitle(selectedKind.title)
    .focusedSceneValue(
      \.codaRefreshAction,
      CodaRefreshAction { Task { await load(selectedKind) } }
    )
    .task(id: ArtistsLoadRequest(kind: selectedKind, resetToken: resetToken)) {
      await load(selectedKind)
    }
  }

  private var artistOrderMenu: some View {
    Menu {
      ForEach(ArtistCollectionKind.allCases, id: \.self) { kind in
        Button {
          selectedKind = kind
        } label: {
          if selectedKind == kind {
            Label(kind.title, systemImage: "checkmark")
          } else {
            Text(kind.title)
          }
        }
      }
    } label: {
      Image(systemName: "line.3.horizontal.decrease")
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Sort Artists — \(selectedKind.title)")
    .accessibilityLabel("Artist order: \(selectedKind.title)")
  }

  @MainActor
  private func load(_ requestedKind: ArtistCollectionKind) async {
    guard let client = session.client else { return }
    isLoading = true
    artists = nil
    errorMessage = nil
    do {
      let loadedArtists: [RemoteArtist]
      switch requestedKind {
      case .recentlyAdded:
        async let albumsTask = client.allAlbums(.recentlyAdded)
        async let artistsTask = client.artists()
        loadedArtists = recentArtists(
          newestAlbums: try await albumsTask,
          artists: try await artistsTask,
          limit: nil
        )
      case .alphabetical:
        loadedArtists = try await client.artists().sorted {
          $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
      }
      try Task.checkCancellation()
      guard selectedKind == requestedKind else { return }
      artists = loadedArtists
    } catch is CancellationError {
      return
    } catch {
      guard selectedKind == requestedKind else { return }
      errorMessage = error.localizedDescription
    }
    if selectedKind == requestedKind {
      isLoading = false
    }
  }
}

private struct AlbumsLoadRequest: Hashable {
  let kind: AlbumCollectionKind
  let resetToken: UUID?
}

struct AlbumsView: View {
  @EnvironmentObject private var session: AppSession
  let resetToken: UUID?

  @State private var selectedKind: AlbumCollectionKind
  @State private var albums: [RemoteAlbum]?
  @State private var isLoading = false
  @State private var errorMessage: String?

  init(kind: AlbumCollectionKind, resetToken: UUID?) {
    self.resetToken = resetToken
    _selectedKind = State(initialValue: kind)
  }

  var body: some View {
    Group {
      if isLoading, albums == nil {
        LibraryLoadingView(label: "Loading Albums…")
      } else if let errorMessage, albums == nil {
        LibraryErrorView(title: "Could Not Load Albums", message: errorMessage) {
          Task { await load(selectedKind) }
        }
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(selectedKind.title)
                .font(.title2.bold())
              Spacer(minLength: 12)
              albumOrderMenu
            }

            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 145, maximum: 200), spacing: 18)],
              alignment: .leading,
              spacing: 22
            ) {
              ForEach(albums ?? []) { album in
                AlbumCard(album: album)
              }
            }
          }
          .padding(.horizontal, 22)
          .padding(.top, 18)
          .padding(.bottom, 22)
          .padding(.bottom, floatingPlaybackDockScrollClearance)
        }
      }
    }
    .navigationTitle(selectedKind.title)
    .focusedSceneValue(
      \.codaRefreshAction,
      CodaRefreshAction { Task { await load(selectedKind) } }
    )
    .task(id: AlbumsLoadRequest(kind: selectedKind, resetToken: resetToken)) {
      await load(selectedKind)
    }
  }

  private var albumOrderMenu: some View {
    Menu {
      ForEach(AlbumCollectionKind.allCases, id: \.self) { kind in
        Button {
          selectedKind = kind
        } label: {
          if selectedKind == kind {
            Label(kind.title, systemImage: "checkmark")
          } else {
            Text(kind.title)
          }
        }
      }
    } label: {
      Image(systemName: "line.3.horizontal.decrease")
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Sort Albums — \(selectedKind.title)")
    .accessibilityLabel("Album order: \(selectedKind.title)")
  }

  @MainActor
  private func load(_ requestedKind: AlbumCollectionKind) async {
    guard let client = session.client else { return }
    isLoading = true
    albums = nil
    errorMessage = nil
    do {
      let loadedAlbums = try await client.allAlbums(requestedKind)
      try Task.checkCancellation()
      guard selectedKind == requestedKind else { return }
      albums = loadedAlbums
    } catch is CancellationError {
      return
    } catch {
      guard selectedKind == requestedKind else { return }
      errorMessage = error.localizedDescription
    }
    if selectedKind == requestedKind {
      isLoading = false
    }
  }
}

struct ArtistDetailView: View {
  @EnvironmentObject private var session: AppSession
  let artistID: String

  @State private var page: ArtistPage?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let page {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 20) {
              ArtworkImage(
                url: session.artworkURL(id: page.artist.coverArt, size: 500), cornerRadius: 12
              )
              .frame(width: 150, height: 150)
              .draggable(QueueDropItem.library(.artist(page.artist.id)))
              .help("Drag artist discography to queue")
              VStack(alignment: .leading, spacing: 7) {
                Text(page.artist.name)
                  .font(.system(size: 32, weight: .bold))
                Text("\(page.albums.count) albums")
                  .foregroundStyle(.secondary)
                if let genre = page.artist.genre, !genre.isEmpty {
                  Text(genre)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            Text("Discography")
              .font(.title2.bold())
              .padding(.horizontal, 22)

            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 145, maximum: 200), spacing: 18)],
              alignment: .leading,
              spacing: 22
            ) {
              ForEach(page.albums) { album in
                AlbumCard(album: album, showsArtist: false)
              }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
          }
          .padding(.bottom, floatingPlaybackDockScrollClearance)
        }
      } else if let errorMessage {
        LibraryErrorView(title: "Could Not Load Artist", message: errorMessage) {
          Task { await load() }
        }
      } else {
        LibraryLoadingView(label: "Loading Artist…")
      }
    }
    .navigationTitle(page?.artist.name ?? "Artist")
    .focusedSceneValue(
      \.codaRefreshAction,
      CodaRefreshAction { Task { await load() } }
    )
    .task(id: artistID) {
      await load()
    }
  }

  @MainActor
  private func load() async {
    guard let client = session.client else { return }
    errorMessage = nil
    do {
      page = try await client.artist(id: artistID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct AlbumDetailView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let albumID: String
  let highlightsRatingOnAppear: Bool

  @StateObject private var artworkLoader = AlbumArtworkLoader()
  @State private var page: AlbumPage?
  @State private var errorMessage: String?
  @State private var isUpdatingRating = false
  @State private var ratingErrorMessage: String?
  @State private var ratingHighlightTrigger = 0
  @State private var selectedSongID: String?
  @FocusState private var trackListHasFocus: Bool

  init(albumID: String, highlightsRatingOnAppear: Bool = false) {
    self.albumID = albumID
    self.highlightsRatingOnAppear = highlightsRatingOnAppear
  }

  var body: some View {
    Group {
      if let page {
        GeometryReader { geometry in
          ScrollView {
            ZStack(alignment: .topLeading) {
              Color.clear
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture {
                  selectedSongID = nil
                  trackListHasFocus = true
                }

              LazyVStack(alignment: .leading, spacing: 0) {
                albumDetailHeader(page: page)
                ForEach(page.discSections) { section in
                  if page.showsDiscHeadings {
                    DiscSectionHeading(
                      number: section.number,
                      subtitle: section.subtitle,
                      durationSeconds: section.durationSeconds
                    )
                    .padding(.horizontal, geometry.size.width >= 760 ? 11 : 22)
                    .padding(.top, section.number == page.discSections.first?.number ? 12 : 18)
                    .padding(.bottom, 5)
                    .draggable(
                      QueueDropItem.library(
                        .albumDisc(
                          page.album.id,
                          discNumber: section.number
                        )
                      )
                    ) {
                      LibraryDragPreview(
                        title: "\(page.album.name) Disc \(section.number)",
                        detail: formatDuration(section.durationSeconds)
                      )
                    }
                    .contextMenu {
                      Button("Add Disc to Queue", systemImage: "text.badge.plus") {
                        session.append(songs: section.songs, to: player)
                      }
                    }
                    .help("Drag Disc \(section.number) to the queue")
                  }

                  ForEach(section.songs) { song in
                    SongRow(
                      song: song,
                      isPlaying: player.currentEntry?.sourceID == song.id,
                      horizontalPadding: geometry.size.width >= 760 ? 11 : 22,
                      isSelected: selectedSongID == song.id,
                      selectionAction: {
                        selectedSongID = song.id
                        trackListHasFocus = true
                      }
                    ) {
                      play(song, from: page)
                    }
                    Divider()
                      .padding(.horizontal, 22)
                      .opacity(0.14)
                  }
                }
              }
              .padding(.bottom, 22)
              .padding(.bottom, floatingPlaybackDockScrollClearance)
            }
            .background(TransientScrollIndicators())
          }
          .contentMargins(
            .top,
            geometry.size.width >= 760 ? -60 : 0,
            for: .scrollContent
          )
        }
      } else if let errorMessage {
        LibraryErrorView(title: "Could Not Load Album", message: errorMessage) {
          Task { await load() }
        }
      } else {
        LibraryLoadingView(label: "Loading Album…")
      }
    }
    .focusable()
    .focused($trackListHasFocus)
    .focusEffectDisabled()
    .onKeyPress(.return) {
      guard let page,
        let selectedSongID,
        let song = page.songs.first(where: { $0.id == selectedSongID })
      else { return .ignored }
      play(song, from: page)
      return .handled
    }
    .onExitCommand { selectedSongID = nil }
    .navigationTitle(page?.album.name ?? "Album")
    .focusedSceneValue(
      \.codaRefreshAction,
      CodaRefreshAction { Task { await load() } }
    )
    .task(id: albumID) {
      selectedSongID = nil
      await load()
      if highlightsRatingOnAppear, !Task.isCancelled {
        await highlightRating()
      }
    }
    .onAppear {
      applyLoadedArtwork()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
    ) { notification in
      guard let window = notification.object as? NSWindow,
        window === NSApp.keyWindow,
        window.title != "Coda Status"
      else { return }
      applyLoadedArtwork()
    }
    .onChange(of: session.albumRatingPrompt) { _, prompt in
      guard prompt?.albumID == albumID else { return }
      Task { await highlightRating() }
    }
    .alert(
      "Could Not Update Rating",
      isPresented: Binding(
        get: { ratingErrorMessage != nil },
        set: { if !$0 { ratingErrorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(ratingErrorMessage ?? "The server rejected the rating.")
    }
  }

  private func albumDetailHeader(page: AlbumPage) -> some View {
    let artworkURL = session.artworkURL(id: page.album.coverArt ?? page.album.id, size: 700)
    return AlbumMockupHero(
      image: artworkLoader.image,
      fallbackURL: artworkURL,
      title: page.album.name,
      artist: page.album.artistName,
      metadata: albumMetadata(page),
      rating: session.rating(for: page.album),
      ratingIsUpdating: isUpdatingRating,
      ratingHighlightTrigger: ratingHighlightTrigger,
      ratingAction: { rating in
        Task { await updateRating(rating, albumID: page.album.id) }
      },
      artistAction: page.album.artistId.map { artistID in
        { session.open(.artist(artistID)) }
      },
      playAction: {
        artworkTreatments.promoteDisplayedArtworkToPlayback(ifIdentity: page.album.id)
        session.play(songs: page.songs, with: player)
      },
      queueAction: { session.append(songs: page.songs, to: player) },
      queueDragItem: .album(page.album.id)
    )
  }

  private func play(_ song: RemoteSong, from page: AlbumPage) {
    artworkTreatments.promoteDisplayedArtworkToPlayback(ifIdentity: page.album.id)
    let index = page.songs.firstIndex(where: { $0.id == song.id }) ?? 0
    session.play(songs: page.songs, startAt: index, with: player)
  }

  @MainActor
  private func highlightRating() async {
    try? await Task.sleep(for: .milliseconds(220))
    guard !Task.isCancelled else { return }
    ratingHighlightTrigger &+= 1
  }

  @MainActor
  private func updateRating(_ rating: Int, albumID: String) async {
    guard !isUpdatingRating, let client = session.client, let currentPage = page,
      currentPage.album.id == albumID
    else { return }

    let previousRating = session.rating(for: currentPage.album)
    var updatedAlbum = currentPage.album
    updatedAlbum.userRating = rating
    page = AlbumPage(album: updatedAlbum, songs: currentPage.songs)
    session.rememberRating(rating, forAlbumID: albumID)
    isUpdatingRating = true

    do {
      try await client.setRating(id: albumID, rating: rating)
    } catch {
      if let latestPage = page, latestPage.album.id == albumID,
        latestPage.album.userRating == rating
      {
        var restoredAlbum = latestPage.album
        restoredAlbum.userRating = previousRating
        page = AlbumPage(album: restoredAlbum, songs: latestPage.songs)
        session.rememberRating(previousRating, forAlbumID: albumID)
      }
      ratingErrorMessage = error.localizedDescription
    }

    if page?.album.id == albumID {
      isUpdatingRating = false
    }
  }

  @MainActor
  private func load() async {
    guard let client = session.client else { return }
    errorMessage = nil
    do {
      let loadedPage = try await client.album(id: albumID)
      page = loadedPage
      await artworkLoader.load(
        url: session.artworkURL(id: loadedPage.album.coverArt ?? loadedPage.album.id, size: 700)
      )
      if !Task.isCancelled {
        applyLoadedArtwork()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func applyLoadedArtwork() {
    guard let album = page?.album, let image = artworkLoader.image else { return }
    if player.currentEntry?.albumID == album.id {
      artworkTreatments.rememberPlaybackArtwork(
        image,
        accent: artworkLoader.accent,
        identity: album.id
      )
    } else {
      artworkTreatments.displayArtwork(
        image,
        accent: artworkLoader.accent,
        identity: album.id
      )
    }
  }
}

struct PlaylistDetailView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  let playlistID: String

  @State private var playlist: RemotePlaylist?
  @State private var errorMessage: String?
  @State private var selectedSongIndex: Int?
  @FocusState private var trackListHasFocus: Bool

  var body: some View {
    Group {
      if let playlist {
        GeometryReader { geometry in
          ScrollView {
            ZStack(alignment: .topLeading) {
              Color.clear
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture {
                  selectedSongIndex = nil
                  trackListHasFocus = true
                }

              LazyVStack(alignment: .leading, spacing: 20) {
                HStack {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(playlist.name)
                      .font(.system(size: 30, weight: .bold))
                    Text(
                      "\(playlist.songs.count) tracks · \(formatCollectionDuration(playlist.duration ?? playlist.songs.compactMap(\.duration).reduce(0, +)))"
                    )
                    .foregroundStyle(.secondary)
                  }
                  Spacer()
                  CollectionPlaybackControls(
                    collectionKind: "playlist",
                    playAction: {
                      session.play(songs: playlist.songs, with: player)
                    },
                    queueAction: {
                      session.append(songs: playlist.songs, to: player)
                    }
                  )
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                ForEach(playlistGroups(playlist.songs)) { group in
                  VStack(alignment: .leading, spacing: 5) {
                    PlaylistAlbumHeader(group: group)
                    ForEach(group.songs, id: \.index) { indexed in
                      SongRow(
                        song: indexed.song,
                        isPlaying: player.currentEntry?.sourceID == indexed.song.id,
                        isSelected: selectedSongIndex == indexed.index,
                        selectionAction: {
                          selectedSongIndex = indexed.index
                          trackListHasFocus = true
                        }
                      ) {
                        session.play(
                          songs: playlist.songs,
                          startAt: indexed.index,
                          with: player
                        )
                      }
                    }
                  }
                }
              }
              .padding(.bottom, 22)
              .padding(.bottom, floatingPlaybackDockScrollClearance)
            }
            .background(TransientScrollIndicators())
          }
        }
      } else if let errorMessage {
        LibraryErrorView(title: "Could Not Load Playlist", message: errorMessage) {
          Task { await load() }
        }
      } else {
        LibraryLoadingView(label: "Loading Playlist…")
      }
    }
    .focusable()
    .focused($trackListHasFocus)
    .focusEffectDisabled()
    .onKeyPress(.return) {
      guard let playlist,
        let selectedSongIndex,
        playlist.songs.indices.contains(selectedSongIndex)
      else { return .ignored }
      session.play(songs: playlist.songs, startAt: selectedSongIndex, with: player)
      return .handled
    }
    .onExitCommand {
      selectedSongIndex = nil
    }
    .navigationTitle(playlist?.name ?? "Playlist")
    .focusedSceneValue(
      \.codaRefreshAction,
      CodaRefreshAction { Task { await load() } }
    )
    .task(id: playlistID) {
      selectedSongIndex = nil
      await load()
    }
  }

  @MainActor
  private func load() async {
    guard let client = session.client else { return }
    errorMessage = nil
    do {
      playlist = try await client.playlist(id: playlistID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct SectionHeading: View {
  let title: String
  var action: (() -> Void)?

  var body: some View {
    Button {
      action?()
    } label: {
      HStack {
        Text(title)
          .font(.title2.bold())
        Spacer()
        if action != nil {
          Image(systemName: "chevron.right")
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .padding(.horizontal, 22)
  }
}

private struct AlbumShelf: View {
  let title: String
  let albums: [RemoteAlbum]
  let onMore: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeading(title: title, action: onMore)
      PagedHorizontalShelf(items: albums, itemWidth: 154) { album in
        AlbumCard(album: album)
          .frame(width: 154)
      }
    }
  }
}

private struct PagedHorizontalShelf<Item: Identifiable, Card: View>: View
where Item.ID: Hashable {
  let items: [Item]
  let itemWidth: CGFloat
  @ViewBuilder let card: (Item) -> Card

  @State private var leadingItemID: Item.ID?
  @State private var viewportWidth: CGFloat = 0
  @State private var isHovering = false

  private let spacing: CGFloat = 16
  private let horizontalPadding: CGFloat = 22

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(alignment: .top, spacing: spacing) {
        ForEach(items) { item in
          card(item)
            .id(item.id)
        }
      }
      .scrollTargetLayout()
      .padding(.horizontal, horizontalPadding)
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollPosition(id: $leadingItemID, anchor: .leading)
    .background {
      GeometryReader { geometry in
        Color.clear
          .onAppear {
            viewportWidth = geometry.size.width
          }
          .onChange(of: geometry.size.width) { _, width in
            viewportWidth = width
          }
      }
    }
    .overlay(alignment: .leading) {
      pagingButton(direction: -1)
        .padding(.leading, 7)
    }
    .overlay(alignment: .trailing) {
      pagingButton(direction: 1)
        .padding(.trailing, 7)
    }
    .onHover { isHovering = $0 }
  }

  private func pagingButton(direction: Int) -> some View {
    Button {
      page(direction: direction)
    } label: {
      Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 30, height: 30)
        .background(.ultraThinMaterial, in: Circle())
        .overlay {
          Circle()
            .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }
    .buttonStyle(.plain)
    .focusable(false)
    .opacity(isHovering && canPage(direction: direction) ? 1 : 0)
    .allowsHitTesting(isHovering && canPage(direction: direction))
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .help(direction < 0 ? "Previous" : "Next")
  }

  private func canPage(direction: Int) -> Bool {
    guard items.count > 1 else { return false }
    let index = currentIndex
    return direction < 0 ? index > 0 : index < items.count - 1
  }

  private var currentIndex: Int {
    guard let leadingItemID,
      let index = items.firstIndex(where: { $0.id == leadingItemID })
    else { return 0 }
    return index
  }

  private func page(direction: Int) {
    guard !items.isEmpty else { return }
    let usableWidth = max(itemWidth, viewportWidth - (horizontalPadding * 2))
    let pageSize = max(1, Int(usableWidth / (itemWidth + spacing)))
    let targetIndex = min(
      max(currentIndex + (direction * pageSize), 0),
      items.count - 1
    )
    withAnimation(.snappy(duration: 0.28)) {
      leadingItemID = items[targetIndex].id
    }
  }
}

private struct ArtistShelf: View {
  let title: String
  let artists: [RemoteArtist]
  let onMore: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeading(title: title, action: onMore)
      PagedHorizontalShelf(items: artists, itemWidth: 140) { artist in
        ArtistCard(artist: artist)
          .frame(width: 140)
      }
    }
  }
}

private struct AlbumCard: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let album: RemoteAlbum
  var showsArtist = true

  var body: some View {
    Button {
      session.open(.album(album.id))
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        ZStack(alignment: .topTrailing) {
          ArtworkImage(
            url: session.artworkURL(id: album.coverArt ?? album.id, size: 500), cornerRadius: 9
          )
          .aspectRatio(1, contentMode: .fit)

          if let rating = visibleRating, artworkTreatments.showsAlbumRatingLabels {
            artworkStamp(rating)
          }
        }
        .draggable(QueueDropItem.library(.album(album.id)))
        .help("Drag album to queue")
        Text(album.name)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        Text(cardSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var cardSubtitle: String {
    if showsArtist, !album.artistName.isEmpty {
      return album.artistName
    }
    return album.releaseYear.map(String.init) ?? ""
  }

  private var visibleRating: Int? {
    guard let rating = session.rating(for: album), (1...5).contains(rating) else { return nil }
    return rating
  }

  private func artworkStamp(_ rating: Int) -> some View {
    let size = AlbumRatingBadgeStyle.size
    return Text(rating.formatted())
      .font(
        .system(
          size: AlbumRatingBadgeStyle.fontSize,
          weight: AlbumRatingBadgeStyle.fontWeight,
          design: .rounded
        )
      )
      .monospacedDigit()
      .foregroundStyle(artworkTreatments.accent.contrastingColor)
      .frame(width: size, height: size)
      .background(
        artworkTreatments.accent.color.opacity(AlbumRatingBadgeStyle.opacity),
        in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
          .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
      }
      .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
      .padding(AlbumRatingBadgeStyle.cornerInset)
  }
}

private struct ArtistCard: View {
  @EnvironmentObject private var session: AppSession
  let artist: RemoteArtist

  var body: some View {
    Button {
      session.open(.artist(artist.id))
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        ArtworkImage(url: session.artworkURL(id: artist.coverArt, size: 500), cornerRadius: 9)
          .aspectRatio(1, contentMode: .fit)
          .draggable(QueueDropItem.library(.artist(artist.id)))
          .help("Drag artist discography to queue")
        Text(artist.name)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        if let count = artist.albumCount {
          Text("\(count) albums")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct PlaylistHomeRow: View {
  @EnvironmentObject private var session: AppSession
  let playlist: RemotePlaylist

  var body: some View {
    Button {
      session.open(.playlist(playlist.id))
    } label: {
      HStack(spacing: 12) {
        ArtworkImage(url: session.artworkURL(id: playlist.coverArt, size: 240), cornerRadius: 7)
          .frame(width: 48, height: 48)
        VStack(alignment: .leading, spacing: 2) {
          Text(playlist.name)
            .font(.headline)
          Text("\(playlist.songCount ?? 0) tracks")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 22)
      .padding(.vertical, 5)
    }
    .buttonStyle(.plain)
  }
}

private struct ContinuePlayingCard: View {
  @EnvironmentObject private var session: AppSession
  let queue: RemotePlayQueue
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      let currentSong = queue.songs[safe: queue.resolvedCurrentIndex]
      HStack(spacing: 14) {
        ArtworkImage(
          url: session.artworkURL(
            id: currentSong?.albumArtworkID,
            size: 700
          ),
          cornerRadius: 9
        )
        .frame(width: 76, height: 76)
        VStack(alignment: .leading, spacing: 4) {
          Text(
            queue.changedBy?.isEmpty == false
              ? "Continue from \(queue.changedBy!)" : "Continue Playing"
          )
          .font(.headline)
          Text(currentSong?.title ?? "Saved Queue")
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text("\(queue.songs.count) tracks")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        Image(systemName: "play.circle.fill")
          .font(.system(size: 34))
      }
      .padding(14)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 22)
  }
}

private struct SongRow: View {
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let song: RemoteSong
  let isPlaying: Bool
  var horizontalPadding: CGFloat = 22
  var isSelected = false
  var selectionAction: (() -> Void)?
  let action: () -> Void

  var body: some View {
    interactiveRow
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        if let selectionAction {
          selectionAction()
        } else {
          action()
        }
      }
      .accessibilityAction(named: "Play") { action() }
      .draggable(QueueDropItem.library(.song(song.id))) {
        LibraryDragPreview(
          title: song.title,
          detail: formatDuration(song.duration ?? 0)
        )
      }
      .help(selectionAction == nil ? "Drag track to queue" : "Double-click to play · Drag to queue")
  }

  @ViewBuilder
  private var interactiveRow: some View {
    if let selectionAction {
      rowContent
        .onTapGesture(perform: selectionAction)
        .simultaneousGesture(
          TapGesture(count: 2)
            .onEnded { action() }
        )
    } else {
      rowContent
        .onTapGesture(perform: action)
    }
  }

  private var rowContent: some View {
    HStack(spacing: 12) {
      Group {
        if isPlaying {
          Image(systemName: "speaker.wave.2.fill")
        } else if let track = song.track {
          Text(String(track))
            .monospacedDigit()
        } else {
          Text("–")
        }
      }
      .font(.caption)
      .foregroundStyle(isPlaying ? artworkTreatments.accent.color : Color.secondary)
      .frame(width: 34, alignment: .trailing)
      Text(song.title)
        .foregroundStyle(isPlaying ? artworkTreatments.accent.color : Color.primary)
        .lineLimit(1)
      Spacer()
      Text(formatDuration(song.duration ?? 0))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, 7)
    .background {
      if isSelected {
        Rectangle()
          .fill(Color.primary.opacity(0.075))
      }
    }
  }
}

private struct LibraryDragPreview: View {
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 10) {
      Text(title)
        .lineLimit(1)
        .foregroundStyle(Color.white)
      Text(detail)
        .font(.caption.monospacedDigit())
        .foregroundStyle(Color.white.opacity(0.68))
    }
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(white: 0.14))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
    }
  }
}

struct DiscSectionHeading: View {
  let number: Int
  let subtitle: String?
  let durationSeconds: Int
  var compact = false

  var body: some View {
    HStack(spacing: compact ? 6 : 8) {
      Text("Disc \(number)")
        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
        .textCase(.uppercase)

      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(compact ? .caption2 : .caption)
          .lineLimit(1)
      }

      Rectangle()
        .fill(.separator.opacity(0.45))
        .frame(height: 0.5)

      if durationSeconds > 0 {
        Text(formatCollectionDuration(durationSeconds))
          .font((compact ? Font.caption2 : Font.caption).monospacedDigit())
      }
    }
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }
}

private struct SearchSongRow: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  let song: RemoteSong
  let isLoading: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        ArtworkImage(
          url: session.artworkURL(id: song.albumArtworkID, size: 240),
          cornerRadius: 7
        )
        .frame(width: 48, height: 48)

        VStack(alignment: .leading, spacing: 3) {
          Text(song.title)
            .font(.body.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(isPlaying ? artworkTreatments.accent.color : Color.primary)
          if !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 12)

        if isLoading {
          ProgressView()
            .controlSize(.small)
        }

        Text(formatDuration(song.duration ?? 0))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 22)
      .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
    .disabled(isLoading)
    .help("Play \(song.title) from \(song.albumName)")
  }

  private var isPlaying: Bool {
    player.currentEntry?.sourceID == song.id
  }

  private var subtitle: String {
    [song.artistName, song.albumName]
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
  }
}

private struct PlaylistAlbumHeader: View {
  @EnvironmentObject private var session: AppSession
  let group: PlaylistGroup

  var body: some View {
    HStack(spacing: 12) {
      ArtworkImage(
        url: session.artworkURL(
          id: group.songs.first?.song.albumArtworkID,
          size: 300
        ),
        cornerRadius: 8
      )
      .frame(width: 62, height: 62)
      VStack(alignment: .leading, spacing: 2) {
        Text(group.albumTitle)
          .font(.headline)
        Text(group.artist)
          .foregroundStyle(.secondary)
        Text(group.detail)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      Spacer()
    }
    .padding(.horizontal, 22)
    .padding(.top, 8)
  }
}

private struct LibraryLoadingView: View {
  let label: String

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(label)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct LibraryErrorView: View {
  let title: String
  let message: String
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Try Again", action: retry)
    }
  }
}

private struct IndexedSong: Identifiable {
  let index: Int
  let song: RemoteSong
  var id: String { "\(index):\(song.id)" }
}

private struct PlaylistGroup: Identifiable {
  let id: String
  let songs: [IndexedSong]

  var albumTitle: String { songs.first?.song.albumName.nonEmptyValue ?? "Unknown Album" }
  var artist: String { songs.first?.song.artistName.nonEmptyValue ?? "Unknown Artist" }
  var detail: String {
    let year = songs.first?.song.year.map(String.init)
    let duration = formatCollectionDuration(songs.compactMap { $0.song.duration }.reduce(0, +))
    return [year, duration.nonEmptyValue].compactMap { $0 }.joined(separator: " · ")
  }
}

private func playlistGroups(_ songs: [RemoteSong]) -> [PlaylistGroup] {
  var result: [PlaylistGroup] = []
  var current: [IndexedSong] = []
  var currentKey = ""

  for (index, song) in songs.enumerated() {
    let key = song.albumId ?? "\(song.artistName.lowercased())|\(song.albumName.lowercased())"
    if !current.isEmpty, key != currentKey {
      result.append(PlaylistGroup(id: "\(current[0].index):\(currentKey)", songs: current))
      current = []
    }
    currentKey = key
    current.append(IndexedSong(index: index, song: song))
  }
  if !current.isEmpty {
    result.append(PlaylistGroup(id: "\(current[0].index):\(currentKey)", songs: current))
  }
  return result
}

private func recentArtists(
  newestAlbums: [RemoteAlbum],
  artists: [RemoteArtist],
  limit: Int? = 20
) -> [RemoteArtist] {
  let byID = Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) })
  let byName = Dictionary(uniqueKeysWithValues: artists.map { ($0.name.lowercased(), $0) })
  var seen: Set<String> = []
  var result: [RemoteArtist] = []
  for album in newestAlbums {
    let artist = album.artistId.flatMap { byID[$0] } ?? byName[album.artistName.lowercased()]
    if let artist, seen.insert(artist.id).inserted {
      result.append(artist)
      if let limit, result.count == limit { break }
    }
  }
  return result
}

private func albumMetadata(_ page: AlbumPage) -> String {
  let year = page.album.releaseYear.map(String.init)
  let tracks = "\(page.songs.count) tracks"
  let duration = formatCollectionDuration(
    page.album.duration ?? page.songs.compactMap(\.duration).reduce(0, +))
  return [year, tracks, duration.nonEmptyValue].compactMap { $0 }.joined(separator: " · ")
}

extension String {
  fileprivate var nonEmptyValue: String? { isEmpty ? nil : self }
}

extension Collection {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

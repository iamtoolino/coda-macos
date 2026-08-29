import Combine
import Foundation

enum SidebarDestination: String, CaseIterable, Identifiable, Sendable {
  case home
  case search
  case artists
  case albums

  var id: Self { self }

  var title: String {
    switch self {
    case .home: "Home"
    case .search: "Search"
    case .artists: "Artists"
    case .albums: "Albums"
    }
  }

  var systemImage: String {
    switch self {
    case .home: "house"
    case .search: "magnifyingglass"
    case .artists: "person.2"
    case .albums: "square.stack"
    }
  }
}

enum LibraryRoute: Hashable, Sendable {
  case artistsCollection(ArtistCollectionKind)
  case albumCollection(AlbumCollectionKind)
  case artist(String)
  case album(String)
  case playlist(String)

  var displayedAlbumID: String? {
    switch self {
    case .album(let id): id
    default: nil
    }
  }
}

enum ConnectionState: Equatable, Sendable {
  case disconnected
  case connecting
  case connected(String)
  case failed(String)
}

enum ArtworkPurpose: Int, Sendable {
  case standard = 472
  case nowPlaying = 1_200
}

struct PreparedQueueSongs: Sendable {
  let songs: [RemoteSong]
  let canonicalArtworkIDsBySongID: [String: String]
}

struct SessionRequestContext: Sendable {
  let client: NavidromeClient
  let sessionID: UUID
}

@MainActor
final class AppSession: ObservableObject {
  @Published private(set) var client: NavidromeClient?
  @Published private(set) var configuration: NavidromeConfiguration?
  @Published private(set) var activeSessionID: UUID?
  @Published private(set) var connectionState: ConnectionState = .disconnected
  @Published private(set) var serverDetails: ServerDetails?
  @Published private(set) var handledPlayQueueIdentity: String?
  @Published var selectedRoot: SidebarDestination = .home
  @Published var path: [LibraryRoute] = []
  @Published private(set) var rootToken = UUID()
  @Published private var albumRatingOverrides: [String: Int] = [:]
  @Published private(set) var isUpdatingAlbumRating = false
  @Published private(set) var albumRatingErrorMessage: String?
  @Published private(set) var isSigningOut = false

  private var artworkURLs: [String: URL] = [:]
  private var automaticConnectionTask: Task<Void, Never>?
  private var connectionAttemptID: UUID?
  private var ratingUpdateSessionID: UUID?

  var hasEstablishedConnection: Bool {
    client != nil && activeSessionID != nil
  }

  var isRestoringConnection: Bool {
    connectionState == .connecting
      && configuration != nil
      && client != nil
      && activeSessionID == nil
  }

  init(loadCredentials: Bool = true) {
    guard loadCredentials else { return }
    do {
      guard let login = try CredentialStore.load() else { return }
      let configuration = try login.configuration
      self.configuration = configuration
      client = NavidromeClient(configuration: configuration)
      connectionState = .connecting
    } catch {
      connectionState = .failed(error.localizedDescription)
    }
  }

  func startAutomaticConnection() {
    guard activeSessionID == nil, automaticConnectionTask == nil, !isSigningOut else { return }
    guard let configuration else {
      connectionState = .disconnected
      return
    }
    connectionState = .connecting
    automaticConnectionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var lastError: Error?
      for attempt in 0..<3 {
        guard !Task.isCancelled else { break }
        do {
          try await self.establishConnection(
            configuration: configuration,
            preservingExistingClient: true
          )
          lastError = nil
          break
        } catch {
          lastError = error
        }
        guard attempt < 2 else { break }
        try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
      }
      if let lastError, !Task.isCancelled {
        self.handleConnectionFailure(lastError, configuration: configuration)
      }
      self.automaticConnectionTask = nil
    }
  }

  func connect() async {
    guard connectionState != .connecting, !isSigningOut else { return }
    let attemptID = UUID()
    connectionAttemptID = attemptID
    connectionState = .connecting
    do {
      guard let login = try await Self.loadStoredLogin() else {
        guard Self.requestMatchesCurrentGeneration(attemptID, current: connectionAttemptID)
        else { return }
        resetConnectionState(to: .disconnected)
        return
      }
      guard Self.requestMatchesCurrentGeneration(attemptID, current: connectionAttemptID)
      else { return }
      try await establishConnection(configuration: login.configuration, attemptID: attemptID)
    } catch is CancellationError {
      return
    } catch {
      guard Self.requestMatchesCurrentGeneration(attemptID, current: connectionAttemptID)
      else { return }
      handleConnectionFailure(error, configuration: configuration)
    }
  }

  func logIn(server: String, username: String, password: String) async {
    guard connectionState != .connecting, !isSigningOut else { return }
    let attemptID = UUID()
    connectionAttemptID = attemptID
    do {
      let configuration = try NavidromeConfiguration(
        server: server,
        username: username,
        password: password
      )
      let login = StoredLogin(configuration: configuration)
      try await establishConnection(
        configuration: configuration,
        loginToStore: login,
        attemptID: attemptID
      )
    } catch is CancellationError {
      return
    } catch {
      guard Self.requestMatchesCurrentGeneration(attemptID, current: connectionAttemptID)
      else { return }
      handleConnectionFailure(error, configuration: configuration)
    }
  }

  func savedLogin() async -> StoredLogin? {
    try? await Self.loadStoredLogin()
  }

  func signOut() async {
    guard !isSigningOut else { return }
    isSigningOut = true
    automaticConnectionTask?.cancel()
    automaticConnectionTask = nil
    resetConnectionState(to: .disconnected)
    defer { isSigningOut = false }
    do {
      try await Task.detached(priority: .userInitiated) {
        try CredentialStore.delete()
      }.value
    } catch {
      connectionState = .failed(error.localizedDescription)
    }
  }

  private static func loadStoredLogin() async throws -> StoredLogin? {
    try await Task.detached(priority: .userInitiated) {
      try CredentialStore.load()
    }.value
  }

  private func establishConnection(
    configuration: NavidromeConfiguration,
    preservingExistingClient: Bool = false,
    loginToStore: StoredLogin? = nil,
    attemptID requestedAttemptID: UUID? = nil
  ) async throws {
    let attemptID = requestedAttemptID ?? UUID()
    if requestedAttemptID != nil {
      guard Self.requestMatchesCurrentGeneration(attemptID, current: connectionAttemptID)
      else { throw CancellationError() }
    }
    prepareForConnection(
      configuration: configuration,
      preservingExistingClient: preservingExistingClient,
      attemptID: attemptID
    )
    let client = NavidromeClient(configuration: configuration)
    let serverDetails = try await client.ping()
    try Task.checkCancellation()
    guard Self.requestMatchesCurrentGeneration(attemptID, current: connectionAttemptID)
    else { throw CancellationError() }
    if let loginToStore {
      // Do not publish a connected session while Sign Out could race an older save.
      try await Task.detached(priority: .userInitiated) {
        try CredentialStore.save(loginToStore)
      }.value
      try Task.checkCancellation()
      guard Self.requestMatchesCurrentGeneration(attemptID, current: connectionAttemptID)
      else { throw CancellationError() }
    }
    self.client = client
    self.serverDetails = serverDetails
    activeSessionID = UUID()
    connectionAttemptID = nil
    artworkURLs.removeAll()
    connectionState = .connected(
      configuration.serverURL.host ?? configuration.serverURL.absoluteString)
    path.removeAll()
    rootToken = UUID()
  }

  private func prepareForConnection(
    configuration: NavidromeConfiguration,
    preservingExistingClient: Bool = false,
    attemptID: UUID
  ) {
    ArtworkImageCache.shared.resetMemory()
    activeSessionID = nil
    connectionAttemptID = attemptID
    handledPlayQueueIdentity = nil
    albumRatingOverrides.removeAll()
    isUpdatingAlbumRating = false
    albumRatingErrorMessage = nil
    ratingUpdateSessionID = nil
    if !preservingExistingClient {
      client = nil
    }
    self.configuration = configuration
    serverDetails = nil
    connectionState = .connecting
  }

  private func handleConnectionFailure(
    _ error: Error,
    configuration: NavidromeConfiguration? = nil
  ) {
    client = nil
    activeSessionID = nil
    connectionAttemptID = nil
    serverDetails = nil
    self.configuration = configuration
    isUpdatingAlbumRating = false
    albumRatingErrorMessage = nil
    ratingUpdateSessionID = nil
    connectionState = .failed(error.localizedDescription)
    path.removeAll()
  }

  private func resetConnectionState(to state: ConnectionState) {
    ArtworkImageCache.shared.resetMemory()
    client = nil
    configuration = nil
    activeSessionID = nil
    connectionAttemptID = nil
    serverDetails = nil
    handledPlayQueueIdentity = nil
    albumRatingOverrides.removeAll()
    isUpdatingAlbumRating = false
    albumRatingErrorMessage = nil
    ratingUpdateSessionID = nil
    artworkURLs.removeAll()
    connectionState = state
    selectedRoot = .home
    path.removeAll()
    rootToken = UUID()
  }

  static func requestMatchesCurrentGeneration(_ requested: UUID, current: UUID?) -> Bool {
    requested == current
  }

  func isCurrentSession(_ sessionID: UUID) -> Bool {
    Self.requestMatchesCurrentGeneration(sessionID, current: activeSessionID)
  }

  func sessionRequestContext() -> SessionRequestContext? {
    guard let client, let activeSessionID else { return nil }
    return SessionRequestContext(client: client, sessionID: activeSessionID)
  }

  func isCurrent(_ request: SessionRequestContext) -> Bool {
    isCurrentSession(request.sessionID)
  }

  func selectRoot(_ destination: SidebarDestination) {
    if selectedRoot == destination {
      if destination == .search {
        path.removeAll()
        rootToken = UUID()
        return
      }
      guard !path.isEmpty else { return }
      path.removeAll()
      return
    }
    selectedRoot = destination
    path.removeAll()
    rootToken = UUID()
  }

  func open(_ route: LibraryRoute) {
    if let displayedAlbumID = route.displayedAlbumID,
      path.last?.displayedAlbumID == displayedAlbumID
    {
      return
    }
    guard path.last != route else { return }
    path.append(route)
  }

  @discardableResult
  func goBack() -> Bool {
    guard !path.isEmpty else { return false }
    path.removeLast()
    return true
  }

  func rating(for album: RemoteAlbum) -> Int? {
    rating(forAlbumID: album.id, fallback: album.userRating)
  }

  func rating(forAlbumID albumID: String, fallback: Int? = nil) -> Int? {
    guard let override = albumRatingOverrides[albumID] else { return fallback }
    return override == 0 ? nil : override
  }

  func rememberRating(_ rating: Int?, forAlbumID albumID: String) {
    albumRatingOverrides[albumID] = rating ?? 0
  }

  func updateAlbumRating(_ rating: Int, forAlbumID albumID: String, fallback: Int?) async {
    guard let request = sessionRequestContext(), beginAlbumRatingUpdate() else { return }
    defer { finishAlbumRatingUpdate(for: request) }

    let previousRating = self.rating(forAlbumID: albumID, fallback: fallback)
    albumRatingErrorMessage = nil
    rememberRating(rating, forAlbumID: albumID)

    do {
      try await request.client.setRating(id: albumID, rating: rating)
      guard isCurrent(request) else { return }
    } catch {
      guard isCurrent(request) else { return }
      rememberRating(previousRating, forAlbumID: albumID)
      albumRatingErrorMessage = error.localizedDescription
    }
  }

  func dismissAlbumRatingError() {
    albumRatingErrorMessage = nil
  }

  func beginAlbumRatingUpdate() -> Bool {
    guard !isUpdatingAlbumRating else { return false }
    isUpdatingAlbumRating = true
    ratingUpdateSessionID = activeSessionID
    return true
  }

  func finishAlbumRatingUpdate() {
    isUpdatingAlbumRating = false
    ratingUpdateSessionID = nil
  }

  func finishAlbumRatingUpdate(for request: SessionRequestContext) {
    guard ratingUpdateSessionID == request.sessionID else { return }
    finishAlbumRatingUpdate()
  }

  func hasHandledPlayQueue(_ queue: RemotePlayQueue) -> Bool {
    handledPlayQueueIdentity == queue.handoffIdentity
  }

  func markPlayQueueHandled(_ queue: RemotePlayQueue) {
    handledPlayQueueIdentity = queue.handoffIdentity
  }

  func refreshArtwork(
    id: String?,
    purposes: [ArtworkPurpose] = [.standard]
  ) async {
    let urls = purposes.compactMap { artworkURL(id: id, purpose: $0) }
    await ArtworkImageCache.shared.invalidate(urls: urls)
  }

  func artworkURL(id: String?, purpose: ArtworkPurpose = .standard) -> URL? {
    guard let id, !id.isEmpty, let configuration else { return nil }
    let size = purpose.rawValue
    let key = "\(id):\(size)"
    if let cached = artworkURLs[key] { return cached }
    let salt = String(NavidromeConfiguration.md5("artwork:\(key)").prefix(12))
    let url = try? configuration.coverArtURL(id: id, size: size, salt: salt)
    artworkURLs[key] = url
    return url
  }

  static func resolvedAlbumArtworkID(
    for song: RemoteSong,
    canonicalAlbumArtworkID: String?,
    canonicalAlbumArtworkIDsBySongID: [String: String] = [:]
  ) -> String? {
    if let artworkID = canonicalAlbumArtworkIDsBySongID[song.id], !artworkID.isEmpty {
      return artworkID
    }
    if let canonicalAlbumArtworkID, !canonicalAlbumArtworkID.isEmpty {
      return canonicalAlbumArtworkID
    }
    return song.albumArtworkID
  }

  func queueEntries(
    for songs: [RemoteSong],
    canonicalAlbumArtworkID: String? = nil,
    canonicalAlbumArtworkIDsBySongID: [String: String] = [:]
  ) throws -> [QueueEntry] {
    guard let configuration else { throw CredentialStoreError.notConnected }
    var currentAlbumKey: String?
    var currentGroupID = UUID()
    return try songs.map { song in
      let albumKey = albumGroupingIdentity(
        albumID: song.albumId,
        artist: song.artistName,
        album: song.albumName
      )
      if currentAlbumKey != albumKey {
        currentAlbumKey = albumKey
        currentGroupID = UUID()
      }
      let streamURL = try configuration.originalStreamURL(songID: song.id)
      let artworkID = Self.resolvedAlbumArtworkID(
        for: song,
        canonicalAlbumArtworkID: canonicalAlbumArtworkID,
        canonicalAlbumArtworkIDsBySongID: canonicalAlbumArtworkIDsBySongID
      )
      return QueueEntry.remoteSong(
        song,
        streamURL: streamURL,
        artworkURL: artworkURL(id: artworkID),
        nowPlayingArtworkURL: artworkURL(id: artworkID, purpose: .nowPlaying),
        queueGroupID: currentGroupID
      )
    }
  }

  func play(
    songs: [RemoteSong],
    startAt index: Int = 0,
    positionMilliseconds: Int = 0,
    scrollQueueToCurrent: Bool = false,
    canonicalAlbumArtworkID: String? = nil,
    canonicalAlbumArtworkIDsBySongID: [String: String] = [:],
    with player: PlayerController
  ) {
    do {
      let entries = try queueEntries(
        for: songs,
        canonicalAlbumArtworkID: canonicalAlbumArtworkID,
        canonicalAlbumArtworkIDsBySongID: canonicalAlbumArtworkIDsBySongID
      )
      player.replaceQueue(
        entries,
        startAt: index,
        positionSeconds: Double(positionMilliseconds) / 1_000,
        scrollQueueToTop: !scrollQueueToCurrent,
        scrollQueueToCurrent: scrollQueueToCurrent
      )
    } catch {
      player.report(error: error)
    }
  }

  func restore(
    songs: [RemoteSong],
    startAt index: Int,
    positionMilliseconds: Int,
    with player: PlayerController
  ) {
    do {
      let entries = try queueEntries(for: songs)
      player.replaceQueue(
        entries,
        startAt: index,
        positionSeconds: Double(positionMilliseconds) / 1_000,
        startsPlaying: false,
        scrollQueueToCurrent: true
      )
    } catch {
      player.report(error: error)
    }
  }

  func append(
    songs: [RemoteSong],
    canonicalAlbumArtworkID: String? = nil,
    canonicalAlbumArtworkIDsBySongID: [String: String] = [:],
    to player: PlayerController
  ) {
    do {
      player.enqueue(
        try queueEntries(
          for: songs,
          canonicalAlbumArtworkID: canonicalAlbumArtworkID,
          canonicalAlbumArtworkIDsBySongID: canonicalAlbumArtworkIDsBySongID
        )
      )
    } catch {
      player.report(error: error)
    }
  }

  func append(libraryItems: [LibraryQueueDragItem], to player: PlayerController) async {
    await insert(libraryItems: libraryItems, before: nil, into: player)
  }

  func insert(
    libraryItems: [LibraryQueueDragItem],
    before entryID: UUID?,
    into player: PlayerController
  ) async {
    guard let client, let sessionID = activeSessionID, !libraryItems.isEmpty else { return }
    do {
      var songs: [RemoteSong] = []
      var canonicalArtworkIDsBySongID: [String: String] = [:]
      for item in libraryItems {
        switch item.kind {
        case .album:
          let page = try await client.album(id: item.id)
          let albumSongs = page.songs
          songs.append(contentsOf: albumSongs)
          rememberCanonicalArtwork(
            page.album.artworkID,
            for: albumSongs,
            in: &canonicalArtworkIDsBySongID
          )
        case .albumDisc:
          guard let discNumber = item.discNumber else { continue }
          let page = try await client.album(id: item.id)
          let discSongs = page.songs.filter { max(1, $0.discNumber ?? 1) == discNumber }
          songs.append(contentsOf: discSongs)
          rememberCanonicalArtwork(
            page.album.artworkID,
            for: discSongs,
            in: &canonicalArtworkIDsBySongID
          )
        case .artist:
          let artist = try await client.artist(id: item.id)
          let prepared = try await prepareQueueSongs(for: artist.albums, client: client)
          songs.append(contentsOf: prepared.songs)
          canonicalArtworkIDsBySongID.merge(
            prepared.canonicalArtworkIDsBySongID,
            uniquingKeysWith: { _, later in later }
          )
        case .playlist:
          songs.append(contentsOf: try await client.playlist(id: item.id).songs)
        case .song:
          let song = try await client.song(id: item.id)
          songs.append(song)
          rememberCanonicalArtwork(
            item.canonicalAlbumArtworkID,
            for: [song],
            in: &canonicalArtworkIDsBySongID
          )
        case .songs:
          let fetchedSongs = try await fetchSongs(ids: item.songIDs ?? [], client: client)
          songs.append(contentsOf: fetchedSongs)
          rememberCanonicalArtwork(
            item.canonicalAlbumArtworkID,
            for: fetchedSongs,
            in: &canonicalArtworkIDsBySongID
          )
        }
        guard isCurrentSession(sessionID) else { return }
      }
      guard isCurrentSession(sessionID) else { return }
      player.insert(
        try queueEntries(
          for: songs,
          canonicalAlbumArtworkIDsBySongID: canonicalArtworkIDsBySongID
        ),
        before: entryID
      )
    } catch {
      guard isCurrentSession(sessionID) else { return }
      player.report(error: error)
    }
  }

  func prepareQueueSongs(for albums: [RemoteAlbum]) async throws -> PreparedQueueSongs {
    guard let client, let sessionID = activeSessionID else {
      throw CredentialStoreError.notConnected
    }
    let prepared = try await prepareQueueSongs(for: albums, client: client)
    guard isCurrentSession(sessionID) else { throw CancellationError() }
    return prepared
  }

  private func prepareQueueSongs(
    for albums: [RemoteAlbum],
    client: NavidromeClient
  ) async throws -> PreparedQueueSongs {
    try await withThrowingTaskGroup(of: (Int, AlbumPage).self) { group in
      for (index, album) in albums.enumerated() {
        group.addTask {
          (index, try await client.album(id: album.id))
        }
      }

      var loadedAlbums: [(Int, AlbumPage)] = []
      for try await album in group {
        loadedAlbums.append(album)
      }
      var songs: [RemoteSong] = []
      var canonicalArtworkIDsBySongID: [String: String] = [:]
      for (_, page) in loadedAlbums.sorted(by: { $0.0 < $1.0 }) {
        songs.append(contentsOf: page.songs)
        rememberCanonicalArtwork(
          page.album.artworkID,
          for: page.songs,
          in: &canonicalArtworkIDsBySongID
        )
      }
      return PreparedQueueSongs(
        songs: songs,
        canonicalArtworkIDsBySongID: canonicalArtworkIDsBySongID
      )
    }
  }

  private func rememberCanonicalArtwork(
    _ artworkID: String?,
    for songs: [RemoteSong],
    in artworkIDsBySongID: inout [String: String]
  ) {
    guard let artworkID, !artworkID.isEmpty else { return }
    for song in songs {
      artworkIDsBySongID[song.id] = artworkID
    }
  }

  private func fetchSongs(ids: [String], client: NavidromeClient) async throws -> [RemoteSong] {
    try await withThrowingTaskGroup(of: (Int, RemoteSong).self) { group in
      for (index, id) in ids.enumerated() {
        group.addTask {
          (index, try await client.song(id: id))
        }
      }

      var songs: [(Int, RemoteSong)] = []
      for try await song in group {
        songs.append(song)
      }
      return songs.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }
}

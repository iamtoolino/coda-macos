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
  case standard = 500
  case nowPlaying = 1_200
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

  private var artworkURLs: [String: URL] = [:]
  private var automaticConnectionTask: Task<Void, Never>?

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
    guard activeSessionID == nil, automaticConnectionTask == nil else { return }
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
    guard connectionState != .connecting else { return }
    do {
      guard let login = try await Self.loadStoredLogin() else {
        resetConnectionState(to: .disconnected)
        return
      }
      try await establishConnection(configuration: login.configuration)
    } catch {
      handleConnectionFailure(error, configuration: configuration)
    }
  }

  func logIn(server: String, username: String, password: String) async {
    guard connectionState != .connecting else { return }
    do {
      let configuration = try NavidromeConfiguration(
        server: server,
        username: username,
        password: password
      )
      let login = StoredLogin(configuration: configuration)
      try await establishConnection(configuration: configuration, loginToStore: login)
    } catch {
      handleConnectionFailure(error, configuration: configuration)
    }
  }

  func savedLogin() async -> StoredLogin? {
    try? await Self.loadStoredLogin()
  }

  func signOut() async {
    automaticConnectionTask?.cancel()
    automaticConnectionTask = nil
    do {
      try await Task.detached(priority: .userInitiated) {
        try CredentialStore.delete()
      }.value
      resetConnectionState(to: .disconnected)
    } catch {
      resetConnectionState(to: .failed(error.localizedDescription))
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
    loginToStore: StoredLogin? = nil
  ) async throws {
    prepareForConnection(
      configuration: configuration,
      preservingExistingClient: preservingExistingClient
    )
    let client = NavidromeClient(configuration: configuration)
    let serverDetails = try await client.ping()
    try Task.checkCancellation()
    if let loginToStore {
      // Do not publish a connected session while Sign Out could race an older save.
      try await Task.detached(priority: .userInitiated) {
        try CredentialStore.save(loginToStore)
      }.value
      try Task.checkCancellation()
    }
    self.client = client
    self.serverDetails = serverDetails
    activeSessionID = UUID()
    artworkURLs.removeAll()
    connectionState = .connected(
      configuration.serverURL.host ?? configuration.serverURL.absoluteString)
    path.removeAll()
    rootToken = UUID()
  }

  private func prepareForConnection(
    configuration: NavidromeConfiguration,
    preservingExistingClient: Bool = false
  ) {
    ArtworkImageCache.shared.resetMemory()
    activeSessionID = nil
    handledPlayQueueIdentity = nil
    albumRatingOverrides.removeAll()
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
    serverDetails = nil
    self.configuration = configuration
    connectionState = .failed(error.localizedDescription)
    path.removeAll()
  }

  private func resetConnectionState(to state: ConnectionState) {
    ArtworkImageCache.shared.resetMemory()
    client = nil
    configuration = nil
    activeSessionID = nil
    serverDetails = nil
    handledPlayQueueIdentity = nil
    albumRatingOverrides.removeAll()
    artworkURLs.removeAll()
    connectionState = state
    selectedRoot = .home
    path.removeAll()
    rootToken = UUID()
  }

  func selectRoot(_ destination: SidebarDestination) {
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

  func beginAlbumRatingUpdate() -> Bool {
    guard !isUpdatingAlbumRating else { return false }
    isUpdatingAlbumRating = true
    return true
  }

  func finishAlbumRatingUpdate() {
    isUpdatingAlbumRating = false
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

  func queueEntries(for songs: [RemoteSong]) throws -> [QueueEntry] {
    guard let configuration else { throw CredentialStoreError.notConnected }
    var currentAlbumKey: String?
    var currentGroupID = UUID()
    return try songs.map { song in
      let albumKey = song.albumId ?? "\(song.artistName.lowercased())|\(song.albumName.lowercased())"
      if currentAlbumKey != albumKey {
        currentAlbumKey = albumKey
        currentGroupID = UUID()
      }
      let streamURL = try configuration.originalStreamURL(songID: song.id)
      return QueueEntry.remoteSong(
        song,
        streamURL: streamURL,
        artworkURL: artworkURL(id: song.albumArtworkID),
        nowPlayingArtworkURL: artworkURL(id: song.albumArtworkID, purpose: .nowPlaying),
        queueGroupID: currentGroupID
      )
    }
  }

  func play(
    songs: [RemoteSong],
    startAt index: Int = 0,
    positionMilliseconds: Int = 0,
    with player: PlayerController
  ) {
    do {
      let entries = try queueEntries(for: songs)
      player.replaceQueue(
        entries,
        startAt: index,
        positionSeconds: Double(positionMilliseconds) / 1_000,
        scrollQueueToTop: true
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
        startsPlaying: false
      )
    } catch {
      player.report(error: error)
    }
  }

  func append(songs: [RemoteSong], to player: PlayerController) {
    do {
      player.enqueue(try queueEntries(for: songs))
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
    guard let client, !libraryItems.isEmpty else { return }
    do {
      var songs: [RemoteSong] = []
      for item in libraryItems {
        switch item.kind {
        case .album:
          songs.append(contentsOf: try await client.album(id: item.id).songs)
        case .albumDisc:
          guard let discNumber = item.discNumber else { continue }
          let album = try await client.album(id: item.id)
          songs.append(
            contentsOf: album.songs.filter { max(1, $0.discNumber ?? 1) == discNumber }
          )
        case .artist:
          songs.append(contentsOf: try await songsForArtist(id: item.id, client: client))
        case .playlist:
          songs.append(contentsOf: try await client.playlist(id: item.id).songs)
        case .song:
          songs.append(try await client.song(id: item.id))
        case .songs:
          songs.append(
            contentsOf: try await fetchSongs(ids: item.songIDs ?? [], client: client)
          )
        }
      }
      player.insert(try queueEntries(for: songs), before: entryID)
    } catch {
      player.report(error: error)
    }
  }

  private func songsForArtist(id: String, client: NavidromeClient) async throws -> [RemoteSong] {
    let artist = try await client.artist(id: id)
    return try await withThrowingTaskGroup(of: (Int, [RemoteSong]).self) { group in
      for (index, album) in artist.albums.enumerated() {
        group.addTask {
          (index, try await client.album(id: album.id).songs)
        }
      }

      var albums: [(Int, [RemoteSong])] = []
      for try await album in group {
        albums.append(album)
      }
      return albums.sorted { $0.0 < $1.0 }.flatMap(\.1)
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

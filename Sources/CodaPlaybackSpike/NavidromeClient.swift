import CryptoKit
import Foundation
import SystemConfiguration

enum CodaURLSessions {
  static let api = makeEphemeralSession()
  static let artwork = makeEphemeralSession()

  private static func makeEphemeralSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }
}

struct NavidromeConfiguration: Sendable {
  static let clientName = makeClientName(deviceName: currentComputerName())

  let serverURL: URL
  let username: String
  let password: String

  init(server: String, username: String, password: String) throws {
    serverURL = try Self.normalizeServerURL(server)

    let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUsername.isEmpty else {
      throw NavidromeError.invalidConfiguration("Enter a username.")
    }
    guard !password.isEmpty else {
      throw NavidromeError.invalidConfiguration("Enter a password.")
    }

    self.username = trimmedUsername
    self.password = password
  }

  func endpointURL(
    _ endpoint: String,
    parameters: [URLQueryItem] = [],
    salt: String = Self.makeSalt()
  ) throws -> URL {
    let endpointURL = try restEndpointURL(endpoint)
    guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
      throw NavidromeError.invalidConfiguration("Could not construct the server URL.")
    }

    components.queryItems =
      [
        URLQueryItem(name: "u", value: username),
        URLQueryItem(name: "t", value: Self.md5(password + salt)),
        URLQueryItem(name: "s", value: salt),
        URLQueryItem(name: "v", value: "1.16.1"),
        URLQueryItem(name: "c", value: Self.clientName),
        URLQueryItem(name: "f", value: "json"),
      ] + parameters

    guard let url = components.url else {
      throw NavidromeError.invalidConfiguration("Could not construct the server URL.")
    }
    return url
  }

  func playQueueSaveRequest(
    songIDs: [String],
    currentIndex: Int,
    positionMilliseconds: Int64,
    salt: String = Self.makeSalt()
  ) throws -> URLRequest {
    var formItems = authenticationItems(salt: salt)
    formItems.append(contentsOf: songIDs.map { URLQueryItem(name: "id", value: $0) })
    if !songIDs.isEmpty {
      let boundedIndex = max(0, min(currentIndex, songIDs.count - 1))
      formItems.append(URLQueryItem(name: "current", value: songIDs[boundedIndex]))
      formItems.append(
        URLQueryItem(name: "position", value: String(max(0, positionMilliseconds))))
    }

    var formComponents = URLComponents()
    formComponents.queryItems = formItems

    var request = URLRequest(url: try restEndpointURL("savePlayQueue"))
    request.httpMethod = "POST"
    request.httpBody = Data((formComponents.percentEncodedQuery ?? "").utf8)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return request
  }

  func playlistMutationRequest(
    endpoint: String,
    parameters: [URLQueryItem],
    salt: String = Self.makeSalt()
  ) throws -> URLRequest {
    var formComponents = URLComponents()
    formComponents.queryItems = authenticationItems(salt: salt) + parameters

    var request = URLRequest(url: try restEndpointURL(endpoint))
    request.httpMethod = "POST"
    request.httpBody = Data((formComponents.percentEncodedQuery ?? "").utf8)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return request
  }

  func originalStreamURL(songID: String, salt: String = Self.makeSalt()) throws -> URL {
    let trimmedID = songID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else {
      throw NavidromeError.invalidConfiguration("The song ID is empty.")
    }
    return try endpointURL(
      "stream",
      parameters: [
        URLQueryItem(name: "id", value: trimmedID),
        URLQueryItem(name: "format", value: "raw"),
      ],
      salt: salt
    )
  }

  func coverArtURL(id: String, size: Int, salt: String = Self.makeSalt()) throws -> URL {
    try endpointURL(
      "getCoverArt",
      parameters: [
        URLQueryItem(name: "id", value: id),
        URLQueryItem(name: "size", value: String(size)),
      ],
      salt: salt
    )
  }

  func ratingURL(id: String, rating: Int, salt: String = Self.makeSalt()) throws -> URL {
    let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else {
      throw NavidromeError.invalidConfiguration("The rating item ID is empty.")
    }
    guard (0...5).contains(rating) else {
      throw NavidromeError.invalidConfiguration("Ratings must be between 0 and 5.")
    }
    return try endpointURL(
      "setRating",
      parameters: [
        URLQueryItem(name: "id", value: trimmedID),
        URLQueryItem(name: "rating", value: String(rating)),
      ],
      salt: salt
    )
  }

  func scrobbleURL(
    songID: String,
    submission: Bool,
    timeMilliseconds: Int64,
    salt: String = Self.makeSalt()
  ) throws -> URL {
    let trimmedID = songID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else {
      throw NavidromeError.invalidConfiguration("The scrobble song ID is empty.")
    }
    return try endpointURL(
      "scrobble",
      parameters: [
        URLQueryItem(name: "id", value: trimmedID),
        URLQueryItem(name: "submission", value: submission ? "true" : "false"),
        URLQueryItem(name: "time", value: String(max(0, timeMilliseconds))),
      ],
      salt: salt
    )
  }

  static func normalizeServerURL(_ value: String) throws -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NavidromeError.invalidConfiguration("Enter a server URL.")
    }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: candidate),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      components.host != nil
    else {
      throw NavidromeError.invalidConfiguration("Enter a valid HTTP or HTTPS server URL.")
    }
    guard components.query == nil, components.fragment == nil else {
      throw NavidromeError.invalidConfiguration(
        "The server URL cannot contain a query or fragment.")
    }

    components.scheme = scheme
    while components.path.count > 1, components.path.hasSuffix("/") {
      components.path.removeLast()
    }
    guard let url = components.url else {
      throw NavidromeError.invalidConfiguration("Enter a valid server URL.")
    }
    return url
  }

  static func md5(_ value: String) -> String {
    Insecure.MD5.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func makeClientName(deviceName: String?) -> String {
    let trimmedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return "Coda on \(trimmedName.isEmpty ? "Mac" : trimmedName)"
  }

  private func restEndpointURL(_ endpoint: String) throws -> URL {
    guard !endpoint.isEmpty, !endpoint.contains("/") else {
      throw NavidromeError.invalidConfiguration("Invalid API endpoint.")
    }
    return serverURL
      .appendingPathComponent("rest", isDirectory: true)
      .appendingPathComponent("\(endpoint).view", isDirectory: false)
  }

  private func authenticationItems(salt: String) -> [URLQueryItem] {
    [
      URLQueryItem(name: "u", value: username),
      URLQueryItem(name: "t", value: Self.md5(password + salt)),
      URLQueryItem(name: "s", value: salt),
      URLQueryItem(name: "v", value: "1.16.1"),
      URLQueryItem(name: "c", value: Self.clientName),
      URLQueryItem(name: "f", value: "json"),
    ]
  }

  private static func makeSalt() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
  }

  private static func currentComputerName() -> String? {
    SCDynamicStoreCopyComputerName(nil, nil) as String?
  }
}

struct NavidromeClient: Sendable {
  let configuration: NavidromeConfiguration
  private let session: URLSession

  init(configuration: NavidromeConfiguration, session: URLSession = CodaURLSessions.api) {
    self.configuration = configuration
    self.session = session
  }

  func ping() async throws -> ServerDetails {
    let response = try await checkedResponse(endpoint: "ping")
    return ServerDetails(
      software: response.type,
      version: response.serverVersion,
      apiVersion: response.version,
      supportsOpenSubsonic: response.openSubsonic
    )
  }

  func albums(
    _ kind: AlbumCollectionKind,
    size: Int = 40,
    offset: Int = 0
  ) async throws -> [RemoteAlbum] {
    var parameters = [
      URLQueryItem(name: "type", value: kind.apiValue),
      URLQueryItem(name: "size", value: String(max(1, min(size, 500)))),
      URLQueryItem(name: "offset", value: String(max(0, offset))),
    ]
    if kind == .recentReleases {
      parameters.append(URLQueryItem(name: "fromYear", value: "3000"))
      parameters.append(URLQueryItem(name: "toYear", value: "0"))
    }
    let response = try await checkedResponse(endpoint: "getAlbumList2", parameters: parameters)
    return response.albumList2?.album ?? []
  }

  func allAlbums(_ kind: AlbumCollectionKind) async throws -> [RemoteAlbum] {
    var result: [RemoteAlbum] = []
    var offset = 0
    while true {
      let page = try await albums(kind, size: 500, offset: offset)
      result.append(contentsOf: page)
      if page.count < 500 { break }
      offset += page.count
    }

    return result
  }

  func artists() async throws -> [RemoteArtist] {
    let response = try await checkedResponse(endpoint: "getArtists")
    return (response.artists?.index ?? [])
      .flatMap { $0.artist ?? [] }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func artist(id: String) async throws -> ArtistPage {
    let response = try await checkedResponse(
      endpoint: "getArtist",
      parameters: [URLQueryItem(name: "id", value: id)]
    )
    guard let detail = response.artist else {
      throw NavidromeError.server("The server did not return the artist.")
    }
    let albums = (detail.album ?? []).sorted {
      let left = $0.chronologicalReleaseKey
      let right = $1.chronologicalReleaseKey
      if left != right { return left < right }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    return ArtistPage(
      artist: detail.summary,
      albums: albums
    )
  }

  func album(id: String) async throws -> AlbumPage {
    let response = try await checkedResponse(
      endpoint: "getAlbum",
      parameters: [URLQueryItem(name: "id", value: id)]
    )
    guard let detail = response.album else {
      throw NavidromeError.server("The server did not return the album.")
    }
    let discSubtitles = Dictionary(
      (detail.discTitles ?? []).map {
        (max(1, $0.disc), $0.title.trimmingCharacters(in: .whitespacesAndNewlines))
      },
      uniquingKeysWith: { first, _ in first }
    )
    let songs = (detail.song ?? []).map { source in
      var song = source
      song.discSubtitle = discSubtitles[max(1, song.discNumber ?? 1)]
      return song
    }.sorted {
      let left = ($0.discNumber ?? 1, $0.track ?? Int.max, $0.title.lowercased())
      let right = ($1.discNumber ?? 1, $1.track ?? Int.max, $1.title.lowercased())
      return left < right
    }
    return AlbumPage(album: detail.summary, songs: songs)
  }

  func song(id: String) async throws -> RemoteSong {
    let response = try await checkedResponse(
      endpoint: "getSong",
      parameters: [URLQueryItem(name: "id", value: id)]
    )
    guard let song = response.song else {
      throw NavidromeError.server("The server did not return the song.")
    }
    return song
  }

  func playlists() async throws -> [RemotePlaylist] {
    let response = try await checkedResponse(endpoint: "getPlaylists")
    return response.playlists?.playlist ?? []
  }

  func playlist(id: String) async throws -> RemotePlaylist {
    let response = try await checkedResponse(
      endpoint: "getPlaylist",
      parameters: [URLQueryItem(name: "id", value: id)]
    )
    guard let playlist = response.playlist else {
      throw NavidromeError.server("The server did not return the playlist.")
    }
    return playlist
  }

  func createPlaylist(name: String, songIDs: [String]) async throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw NavidromeError.invalidConfiguration("Enter a playlist name.")
    }
    let request = try configuration.playlistMutationRequest(
      endpoint: "createPlaylist",
      parameters:
        [URLQueryItem(name: "name", value: trimmedName)]
        + songIDs.map { URLQueryItem(name: "songId", value: $0) }
    )
    _ = try await checkedResponse(request)
  }

  func replacePlaylist(id: String, existingSongCount: Int, songIDs: [String]) async throws {
    let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else {
      throw NavidromeError.invalidConfiguration("The playlist ID is empty.")
    }
    let removalItems = (0..<max(0, existingSongCount)).map {
      URLQueryItem(name: "songIndexToRemove", value: String($0))
    }
    let additionItems = songIDs.map { URLQueryItem(name: "songIdToAdd", value: $0) }
    let request = try configuration.playlistMutationRequest(
      endpoint: "updatePlaylist",
      parameters:
        [URLQueryItem(name: "playlistId", value: trimmedID)]
        + removalItems
        + additionItems
    )
    _ = try await checkedResponse(request)
  }

  func playQueue() async throws -> RemotePlayQueue? {
    try await checkedResponse(endpoint: "getPlayQueue").playQueue
  }

  func savePlayQueue(
    songIDs: [String],
    currentIndex: Int,
    positionMilliseconds: Int64
  ) async throws {
    let request = try configuration.playQueueSaveRequest(
      songIDs: songIDs,
      currentIndex: currentIndex,
      positionMilliseconds: positionMilliseconds
    )
    _ = try await checkedResponse(request)
  }

  func setRating(id: String, rating: Int) async throws {
    let request = URLRequest(url: try configuration.ratingURL(id: id, rating: rating))
    _ = try await checkedResponse(request)
  }

  func scrobble(
    songID: String,
    submission: Bool,
    timeMilliseconds: Int64
  ) async throws {
    let request = URLRequest(
      url: try configuration.scrobbleURL(
        songID: songID,
        submission: submission,
        timeMilliseconds: timeMilliseconds
      ))
    _ = try await checkedResponse(request)
  }

  func searchSongs(_ query: String, count: Int = 30) async throws -> [RemoteSong] {
    try await search(
      query,
      artistCount: 0,
      albumCount: 0,
      songCount: count
    ).songs
  }

  func search(
    _ query: String,
    artistCount: Int = 16,
    albumCount: Int = 24,
    songCount: Int = 40
  ) async throws -> LibrarySearchResults {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .empty }

    let response = try await checkedResponse(
      endpoint: "search3",
      parameters: [
        URLQueryItem(name: "query", value: trimmed),
        URLQueryItem(name: "artistCount", value: String(max(0, min(artistCount, 100)))),
        URLQueryItem(name: "albumCount", value: String(max(0, min(albumCount, 100)))),
        URLQueryItem(name: "songCount", value: String(max(0, min(songCount, 100)))),
      ]
    )
    let result = response.searchResult3
    return LibrarySearchResults(
      artists: (result?.artist ?? []).filter(\.isAlbumArtistSearchResult),
      albums: result?.album ?? [],
      songs: result?.song ?? []
    )
  }

  private func checkedResponse(
    endpoint: String,
    parameters: [URLQueryItem] = []
  ) async throws -> SubsonicResponse {
    let url = try configuration.endpointURL(endpoint, parameters: parameters)
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return try await checkedResponse(request)
  }

  private func checkedResponse(_ request: URLRequest) async throws -> SubsonicResponse {
    let response = try await response(for: request)
    guard response.status == "ok" else {
      throw NavidromeError.server(response.error?.message ?? "The server rejected the request.")
    }
    return response
  }

  private func response(for request: URLRequest) async throws -> SubsonicResponse {
    let (data, urlResponse) = try await session.data(for: request)
    guard let httpResponse = urlResponse as? HTTPURLResponse else {
      throw NavidromeError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw NavidromeError.httpStatus(httpResponse.statusCode)
    }

    do {
      return try JSONDecoder().decode(SubsonicEnvelope.self, from: data).response
    } catch {
      throw NavidromeError.decoding(error.localizedDescription)
    }
  }
}

enum NavidromeError: LocalizedError, Equatable {
  case invalidConfiguration(String)
  case httpStatus(Int)
  case invalidResponse
  case decoding(String)
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message), .decoding(let message), .server(let message):
      message
    case .httpStatus(let status):
      "The server returned HTTP \(status)."
    case .invalidResponse:
      "The server returned an invalid response."
    }
  }
}

private struct SubsonicEnvelope: Decodable {
  let response: SubsonicResponse

  enum CodingKeys: String, CodingKey {
    case response = "subsonic-response"
  }
}

private struct SubsonicResponse: Decodable {
  let status: String
  var version: String?
  var type: String?
  var serverVersion: String?
  var openSubsonic: Bool?
  var error: SubsonicAPIError?
  var albumList2: AlbumListResponse?
  var artists: ArtistIndexesResponse?
  var artist: ArtistDetailResponse?
  var album: AlbumDetailResponse?
  var song: RemoteSong?
  var playlists: PlaylistListResponse?
  var playlist: RemotePlaylist?
  var playQueue: RemotePlayQueue?
  var searchResult3: SongSearchResult?
}

private struct SubsonicAPIError: Decodable {
  var message: String?
}

private struct AlbumListResponse: Decodable {
  var album: [RemoteAlbum]?
}

private struct ArtistIndexesResponse: Decodable {
  var index: [ArtistIndexResponse]?
}

private struct ArtistIndexResponse: Decodable {
  var artist: [RemoteArtist]?
}

private struct ArtistDetailResponse: Decodable {
  let id: String
  let name: String
  var albumCount: Int?
  var coverArt: String?
  var artistImageUrl: String?
  var genre: String?
  var album: [RemoteAlbum]?

  var summary: RemoteArtist {
    RemoteArtist(
      id: id,
      name: name,
      albumCount: albumCount,
      coverArt: coverArt,
      artistImageUrl: artistImageUrl,
      genre: genre
    )
  }
}

private struct AlbumDetailResponse: Decodable {
  let id: String
  let name: String
  var artist: String?
  var artistId: String?
  var coverArt: String?
  var songCount: Int?
  var duration: Int?
  var created: String?
  var year: Int?
  var originalReleaseDate: ItemDate?
  var releaseDate: ItemDate?
  var playCount: Int?
  var userRating: Int?
  var discTitles: [RemoteDiscTitle]?
  var song: [RemoteSong]?

  var summary: RemoteAlbum {
    RemoteAlbum(
      id: id,
      name: name,
      artist: artist,
      artistId: artistId,
      coverArt: coverArt,
      songCount: songCount,
      duration: duration,
      created: created,
      year: year,
      originalReleaseDate: originalReleaseDate,
      releaseDate: releaseDate,
      playCount: playCount,
      userRating: userRating,
      discTitles: discTitles
    )
  }
}

private struct PlaylistListResponse: Decodable {
  var playlist: [RemotePlaylist]?
}

private struct SongSearchResult: Decodable {
  var artist: [RemoteArtist]?
  var album: [RemoteAlbum]?
  var song: [RemoteSong]?
}

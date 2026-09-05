import AppKit
import AudioToolbox
import Combine
import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Navidrome and models")
@MainActor
struct NavidromeTests {
  @Test("stale session generations are rejected")
  func staleSessionGenerationsAreRejected() {
    let requested = UUID()
    #expect(AppSession.requestMatchesCurrentGeneration(requested, current: requested))
    #expect(!AppSession.requestMatchesCurrentGeneration(requested, current: UUID()))
    #expect(!AppSession.requestMatchesCurrentGeneration(requested, current: nil))
  }

  @Test("termination deadline does not wait for a cancellation-resistant save")
  func terminationDeadlineIsHardBound() {
    let clock = ContinuousClock()
    let start = clock.now

    let completed = waitForTerminationOperation(timeout: 0.02) {
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
          continuation.resume()
        }
      }
    }

    #expect(!completed)
    #expect(clock.now - start < .milliseconds(150))
  }

  @Test("server URL normalization")
  func serverUrlNormalization() throws {
    let config = try NavidromeConfiguration(
      server: " music.example.test/navidrome/// ",
      username: "listener",
      password: "secret"
    )
    #expect(config.serverURL.absoluteString == "https://music.example.test/navidrome")
  }

  @Test("known MD5 vector")
  func knownMd5Vector() {
    #expect(
      NavidromeConfiguration.md5("passwordsalt") == "b305cadbb3bce54f3aa59c64fec00dea")
  }

  @Test("original stream policy")
  func originalStreamPolicy() throws {
    let config = try NavidromeConfiguration(
      server: "https://music.example.test/navidrome/",
      username: "listener name",
      password: "secret"
    )
    let url = try config.originalStreamURL(songID: "song/1", salt: "abc123")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

    #expect(components.path == "/navidrome/rest/stream.view")
    #expect(query["id"] == "song/1")
    #expect(query["format"] == "raw")
    #expect(query["u"] == "listener name")
    #expect(query["s"] == "abc123")
    #expect(query["t"] == NavidromeConfiguration.md5("secretabc123"))
    #expect(query["maxBitRate"] == nil)
    #expect(query["estimateContentLength"] == nil)
  }

  @Test("album rating request")
  func albumRatingRequest() throws {
    let config = try NavidromeConfiguration(
      server: "https://music.example.test/navidrome",
      username: "listener",
      password: "secret"
    )
    let url = try config.ratingURL(id: " album/1 ", rating: 4, salt: "abc123")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

    #expect(components.path == "/navidrome/rest/setRating.view")
    #expect(query["id"] == "album/1")
    #expect(query["rating"] == "4")
    #expect(query["u"] == "listener")
    #expect(query["s"] == "abc123")
  }

  @Test("scrobble request")
  func scrobbleRequest() throws {
    let config = try NavidromeConfiguration(
      server: "https://music.example.test/navidrome",
      username: "listener",
      password: "secret"
    )
    let url = try config.scrobbleURL(
      songID: " song/1 ",
      submission: true,
      timeMilliseconds: 1_721_234_567_890,
      salt: "abc123"
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

    #expect(components.path == "/navidrome/rest/scrobble.view")
    #expect(query["id"] == "song/1")
    #expect(query["submission"] == "true")
    #expect(query["time"] == "1721234567890")
    #expect(query["u"] == "listener")
    #expect(query["s"] == "abc123")
  }

  @Test("bookmark mutation requests use form bodies")
  func bookmarkMutationRequestsUseFormBodies() throws {
    let config = try NavidromeConfiguration(
      server: "https://music.example.test/navidrome",
      username: "listener",
      password: "secret"
    )
    let request = try config.bookmarkMutationRequest(
      endpoint: "createBookmark",
      songID: " track/1 ",
      positionMilliseconds: 0,
      comment: #"{"protocol":"album-resume-bookmark"}"#,
      salt: "abc123"
    )
    let items = try formItems(in: request)

    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/navidrome/rest/createBookmark.view")
    #expect(items.first { $0.name == "id" }?.value == "track/1")
    #expect(items.first { $0.name == "position" }?.value == "0")
    #expect(
      items.first { $0.name == "comment" }?.value
        == #"{"protocol":"album-resume-bookmark"}"#)
  }

  @Test("album resume comments are portable and recognizable")
  func albumResumeCommentsArePortableAndRecognizable() throws {
    let writer = AlbumResumeWriter(
      client: "Coda on su",
      platform: "macOS",
      appVersion: "2.1.1"
    )
    let comment = try #require(
      albumResumeComment(resumeSongID: "resume-track", writer: writer))
    let marker = try #require(albumResumeMarker(from: comment))

    #expect(Data(comment.utf8).count <= 255)
    #expect(marker.resumeSongID == "resume-track")
    let payload = try #require(JSONSerialization.jsonObject(with: Data(comment.utf8)) as? [String: Any])
    let diagnostics = try #require(payload["writer"] as? [String: String])
    #expect(diagnostics == ["client": "Coda on su", "platform": "macOS", "appVersion": "2.1.1"])
    #expect(albumResumeMarker(from: "ordinary bookmark") == nil)
    #expect(
      albumResumeMarker(
        from: #"{"protocol":"album-resume-bookmark","protocolVersion":2,"resumeSongId":"x"}"#
      ) == nil
    )
  }

  @Test("album resume readers ignore diagnostic metadata")
  func albumResumeIgnoresWriterMetadata() {
    for writer in ["null", "{}", #"{"client":"Android"}"#, #"{"platform":42}"#, "false", #""diagnostic""#] {
      let comment = #"{"protocol":"album-resume-bookmark","protocolVersion":1,"resumeSongId":"next","writer":\#(writer)}"#
      #expect(albumResumeMarker(from: comment)?.resumeSongID == "next")
    }
  }

  @Test("album resume completion uses a stable first-track anchor")
  func albumResumeCompletionUsesStableAnchor() throws {
    let first = RemoteSong(
      id: "track-1", title: "One", album: "Album", artist: "Artist", albumId: "album-1",
      track: 1)
    let second = RemoteSong(
      id: "track-2", title: "Two", album: "Album", artist: "Artist", albumId: "album-1",
      track: 2)
    let page = AlbumPage(
      album: RemoteAlbum(id: "album-1", name: "Album", artist: "Artist"),
      songs: [first, second]
    )

    #expect(
      albumResumeCompletionAction(
        completedSongID: first.id,
        album: page
      ) == .upsert(anchorSongID: first.id, resumeSongID: second.id)
    )

    #expect(
      albumResumeCompletionAction(
        completedSongID: second.id,
        album: page
      ) == .delete(anchorSongID: first.id)
    )
  }

  @Test("album resume accepts music songs and rejects non-music media")
  func albumResumeRequiresAlbumMusic() {
    let music = RemoteSong(
      id: "music", title: "Music", albumId: "album", type: "music", mediaType: "song")
    let legacyMusic = RemoteSong(id: "legacy", title: "Legacy", albumId: "album")
    let podcast = RemoteSong(
      id: "podcast", title: "Podcast", albumId: "album", type: "podcast", mediaType: "song")
    let audiobook = RemoteSong(
      id: "book", title: "Book", albumId: "album", type: "audiobook", mediaType: "song")
    let albumObject = RemoteSong(
      id: "album-object", title: "Album", albumId: "album", type: "music", mediaType: "album")
    let ungrouped = RemoteSong(id: "ungrouped", title: "Ungrouped", type: "music")

    #expect(isEligibleAlbumResumeSong(music))
    #expect(isEligibleAlbumResumeSong(legacyMusic))
    #expect(!isEligibleAlbumResumeSong(podcast))
    #expect(!isEligibleAlbumResumeSong(audiobook))
    #expect(!isEligibleAlbumResumeSong(albumObject))
    #expect(!isEligibleAlbumResumeSong(ungrouped))
  }

  @Test("album resume cards are newest-first and ignore foreign bookmarks")
  func albumResumeCardsAreNewestFirst() throws {
    let oldAnchor = RemoteSong(
      id: "old-anchor", title: "One", album: "Old Album", artist: "Artist",
      albumId: "old-album")
    let newAnchor = RemoteSong(
      id: "new-anchor", title: "One", album: "New Album", artist: "Artist",
      albumId: "new-album")
    let old = RemoteBookmark(
      comment: try #require(albumResumeComment(resumeSongID: "old-resume", writer: nil)),
      changed: "2026-08-01T10:00:00Z",
      entry: oldAnchor
    )
    let newer = RemoteBookmark(
      comment: try #require(albumResumeComment(resumeSongID: "new-resume", writer: nil)),
      changed: "2026-09-01T10:00:00Z",
      entry: newAnchor
    )
    let foreign = RemoteBookmark(
      comment: "podcast position",
      changed: "2026-10-01T10:00:00Z",
      entry: oldAnchor
    )

    let items = albumResumeItems(from: [old, foreign, newer])
    #expect(items.map(\.album.id) == ["new-album", "old-album"])
    #expect(items.map(\.resumeSongID) == ["new-resume", "old-resume"])
  }

  @Test("scrobble retry schedule")
  func scrobbleRetrySchedule() {
    #expect(scrobbleRetryDelays() == [1_000, 2_000, 4_000, 8_000, 16_000])
    #expect(scrobbleRetryDelays(maxAttempts: 1).isEmpty)
  }

  @Test("artist search excludes participation-only artists")
  func artistSearchExcludesParticipationOnlyArtists() {
    let results = [
      RemoteArtist(id: "album-artist", name: "Avantasia", albumCount: 8),
      RemoteArtist(id: "performer", name: "Avantasia, Jorn", albumCount: 0),
      RemoteArtist(id: "legacy", name: "Legacy Server Artist"),
    ].filter(\.isAlbumArtistSearchResult)
    #expect(results.map(\.id) == ["album-artist", "legacy"])
  }

  @Test("source metadata formatting")
  func sourceMetadataFormatting() {
    let song = RemoteSong(
      id: "1", title: "Track", suffix: "flac",
      bitRate: 2_350, bitDepth: 24, samplingRate: 96_000)
    #expect(song.technicalSummary == "FLAC · 24-bit · 96 kHz · 2350 kbps")
  }

  @Test("song presentation prefers the explicit album artist")
  func songPresentationPrefersExplicitAlbumArtist() throws {
    let data = Data(
      #"{"id":"track-1","title":"Track","artist":"ZILF • Guest One • Guest Two","displayAlbumArtist":"ZILF"}"#.utf8
    )
    let song = try JSONDecoder().decode(RemoteSong.self, from: data)
    let streamURL = try #require(URL(string: "https://music.example.test/stream"))
    let entry = QueueEntry.remoteSong(
      song,
      streamURL: streamURL,
      artworkURL: nil,
      nowPlayingArtworkURL: nil
    )

    #expect(song.artist == "ZILF • Guest One • Guest Two")
    #expect(song.artistName == "ZILF")
    #expect(entry.artist == "ZILF")
    #expect(
      RemoteSong(id: "legacy", title: "Legacy", artist: "Legacy Artist").artistName
        == "Legacy Artist"
    )
  }

  @Test("invalid URL rejection")
  func invalidUrlRejection() throws {
    #expect(throws: (any Error).self) {
      try NavidromeConfiguration(
        server: "ftp://music.example.test",
        username: "listener",
        password: "secret"
      )
    }
  }

  @Test("stored login configuration")
  func storedLoginConfiguration() throws {
    let stored = StoredLogin(
      serverURL: "https://music.example.test",
      username: "listener",
      password: "secret"
    )
    let data = try JSONEncoder().encode(stored)
    let decoded = try JSONDecoder().decode(StoredLogin.self, from: data)
    let config = try decoded.configuration

    #expect(config.serverURL.absoluteString == "https://music.example.test")
    #expect(config.username == "listener")
    #expect(config.password == "secret")
    #expect(decoded == stored)
  }

  @Test("saved queue form request")
  func savedQueueFormRequest() throws {
    let config = try NavidromeConfiguration(
      server: "https://music.example.test/navidrome",
      username: "listener name",
      password: "secret"
    )
    let request = try config.playQueueSaveRequest(
      songIDs: ["song/1", "song 2", "song&3"],
      currentIndex: 1,
      positionMilliseconds: 12_345,
      salt: "abc123"
    )
    let items = try formItems(in: request)

    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/navidrome/rest/savePlayQueue.view")
    #expect(request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(items.filter { $0.name == "id" }.compactMap(\.value) == ["song/1", "song 2", "song&3"])
    #expect(items.first { $0.name == "current" }?.value == "song 2")
    #expect(items.first { $0.name == "position" }?.value == "12345")
    #expect(items.first { $0.name == "u" }?.value == "listener name")
    #expect(items.first { $0.name == "s" }?.value == "abc123")
    #expect(
      items.first { $0.name == "t" }?.value
        == NavidromeConfiguration.md5("secretabc123"))
  }

  @Test("empty saved queue clears server queue")
  func emptySavedQueueClearsServerQueue() throws {
    let config = try NavidromeConfiguration(
      server: "https://music.example.test", username: "listener", password: "secret")
    let request = try config.playQueueSaveRequest(
      songIDs: [], currentIndex: 99, positionMilliseconds: 99_999, salt: "abc123")
    let names = try formItems(in: request).map(\.name)

    #expect(!names.contains("id"))
    #expect(!names.contains("current"))
    #expect(!names.contains("position"))
  }

  @Test("queue handoff snapshot")
  func queueHandoffSnapshot() {
    let entries = [
      QueueEntry(sourceID: "one", url: URL(string: "https://example.test/one")!, title: "One"),
      QueueEntry(sourceID: "two", url: URL(string: "https://example.test/two")!, title: "Two"),
    ]
    let snapshot = QueueHandoffSnapshot(queue: entries, currentIndex: 9, positionSeconds: 12.345)

    #expect(snapshot.songIDs == ["one", "two"])
    #expect(snapshot.currentIndex == 1)
    #expect(snapshot.positionMilliseconds == 12_345)
  }

  @Test("finished queue handoff is not resumable")
  func finishedQueueHandoffIsNotResumable() {
    let entries = [
      QueueEntry(sourceID: "one", url: URL(string: "https://example.test/one")!, title: "One"),
      QueueEntry(sourceID: "two", url: URL(string: "https://example.test/two")!, title: "Two"),
    ]
    let snapshot = QueueHandoffSnapshot(
      queue: entries,
      currentIndex: nil,
      positionSeconds: 999
    )

    #expect(snapshot.songIDs.isEmpty)
    #expect(snapshot.currentIndex == 0)
    #expect(snapshot.positionMilliseconds == 0)
  }

  @Test("Coda Mac queue recognition")
  func codaMacQueueRecognition() {
    let song = RemoteSong(id: "two", title: "Two")
    let ownQueue = RemotePlayQueue(
      current: "two",
      changedBy: NavidromeConfiguration.clientName.lowercased(),
      currentIndex: 99,
      entry: [song]
    )
    let externalQueue = RemotePlayQueue(changedBy: "Coda", entry: [song])

    #expect(ownQueue.wasWrittenByThisCoda)
    #expect(ownQueue.resolvedCurrentIndex == 0)
    #expect(!externalQueue.wasWrittenByThisCoda)
  }

  @Test("queue handoff disposition keeps restore and offer policy central")
  func queueHandoffDispositionPolicy() {
    let song = RemoteSong(id: "one", title: "One")
    let ownQueue = RemotePlayQueue(
      changedBy: NavidromeConfiguration.clientName,
      entry: [song]
    )
    let externalQueue = RemotePlayQueue(changedBy: "Coda Android", entry: [song])

    #expect(
      queueHandoffDisposition(
        for: ownQueue, allowsOwnedQueueRestore: true, localQueueIsEmpty: true,
        localPlaybackIsPlaying: false, queueWasHandled: false) == .restore
    )
    #expect(
      queueHandoffDisposition(
        for: externalQueue, allowsOwnedQueueRestore: true, localQueueIsEmpty: true,
        localPlaybackIsPlaying: false, queueWasHandled: false) == .offer
    )
    #expect(
      queueHandoffDisposition(
        for: ownQueue, allowsOwnedQueueRestore: false, localQueueIsEmpty: true,
        localPlaybackIsPlaying: false, queueWasHandled: false) == .ignore
    )
    #expect(
      queueHandoffDisposition(
        for: externalQueue, allowsOwnedQueueRestore: true, localQueueIsEmpty: true,
        localPlaybackIsPlaying: true, queueWasHandled: false) == .ignore
    )
    #expect(
      queueHandoffDisposition(
        for: externalQueue, allowsOwnedQueueRestore: true, localQueueIsEmpty: true,
        localPlaybackIsPlaying: false, queueWasHandled: true) == .ignore
    )
  }

  @Test("local queue ownership supersedes an external continue candidate")
  func localQueueOwnershipSupersedesExternalContinueCandidate() async {
    let session = AppSession(loadCredentials: false)
    let player = PlayerController(backend: TestPlaybackBackend())
    let coordinator = QueueHandoffCoordinator(session: session, player: player)
    let external = RemotePlayQueue(
      changedBy: "Coda Android",
      entry: [RemoteSong(id: "android-song", title: "Android Song")]
    )
    coordinator.observeRemoteQueue(external)

    #expect(coordinator.continueQueue == external)

    player.replaceQueue(
      [
        QueueEntry(
          sourceID: "mac-song",
          url: URL(string: "https://example.test/mac-song")!,
          title: "Mac Song"
        )
      ],
      startsPlaying: true
    )
    await Task.yield()
    await Task.yield()

    #expect(coordinator.continueQueue == nil)
  }

  @Test("ignored remote queues clear an obsolete continue candidate")
  func ignoredRemoteQueuesClearContinueCandidate() {
    let session = AppSession(loadCredentials: false)
    let player = PlayerController(backend: TestPlaybackBackend())
    let coordinator = QueueHandoffCoordinator(session: session, player: player)
    let external = RemotePlayQueue(
      changedBy: "Coda Android",
      entry: [RemoteSong(id: "android-song", title: "Android Song")]
    )

    coordinator.observeRemoteQueue(external)
    #expect(coordinator.continueQueue == external)

    session.markPlayQueueHandled(external)
    coordinator.observeRemoteQueue(external)
    #expect(coordinator.continueQueue == nil)

    let newerExternal = RemotePlayQueue(
      changedBy: "Coda Android",
      entry: [RemoteSong(id: "new-android-song", title: "New Android Song")]
    )
    coordinator.observeRemoteQueue(newerExternal)
    #expect(coordinator.continueQueue == newerExternal)

    coordinator.observeRemoteQueue(nil)
    #expect(coordinator.continueQueue == nil)
  }

  @Test("owned queues are never presented as external continue candidates")
  func ownedQueuesAreNotContinueCandidates() {
    let session = AppSession(loadCredentials: false)
    let player = PlayerController(backend: TestPlaybackBackend())
    let coordinator = QueueHandoffCoordinator(session: session, player: player)
    let owned = RemotePlayQueue(
      changedBy: NavidromeConfiguration.clientName,
      entry: [RemoteSong(id: "mac-song", title: "Mac Song")]
    )

    coordinator.observeRemoteQueue(owned)

    #expect(coordinator.continueQueue == nil)
  }

  @Test("human-readable device client identity")
  func humanReadableDeviceClientIdentity() {
    #expect(NavidromeConfiguration.makeClientName(deviceName: " su ") == "Coda on su")
    #expect(NavidromeConfiguration.makeClientName(deviceName: nil) == "Coda on Mac")
  }

  private func formItems(in request: URLRequest) throws -> [URLQueryItem] {
    guard let body = request.httpBody,
      let encoded = String(data: body, encoding: .utf8),
      let components = URLComponents(string: "https://form.invalid/?\(encoded)"),
      let items = components.queryItems
    else {
      throw NavidromeError.invalidResponse
    }
    return items
  }
}

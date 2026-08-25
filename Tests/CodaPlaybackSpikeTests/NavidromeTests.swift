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

  @Test("continue offer requires a paused Mac and an external unhandled queue")
  func continueOfferEligibility() {
    let external = RemotePlayQueue(
      changedBy: "Coda Android",
      entry: [RemoteSong(id: "one", title: "One")]
    )
    let own = RemotePlayQueue(
      changedBy: NavidromeConfiguration.clientName,
      entry: [RemoteSong(id: "one", title: "One")]
    )

    #expect(
      shouldOfferContinuePlaying(
        queue: external, macPlaybackIsPlaying: false, queueWasHandled: false))
    #expect(
      !shouldOfferContinuePlaying(
        queue: external, macPlaybackIsPlaying: true, queueWasHandled: false))
    #expect(
      !shouldOfferContinuePlaying(
        queue: external, macPlaybackIsPlaying: false, queueWasHandled: true))
    #expect(
      !shouldOfferContinuePlaying(
        queue: own, macPlaybackIsPlaying: false, queueWasHandled: false))
    #expect(
      !shouldOfferContinuePlaying(
        queue: RemotePlayQueue(), macPlaybackIsPlaying: false, queueWasHandled: false))
    #expect(
      shouldRevealContinuePlaying(
        queue: external,
        macPlaybackIsPlaying: false,
        queueWasHandled: false,
        nowPlayingIsPresented: true
      ))
    #expect(
      !shouldRevealContinuePlaying(
        queue: external,
        macPlaybackIsPlaying: false,
        queueWasHandled: false,
        nowPlayingIsPresented: false
      ))
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
